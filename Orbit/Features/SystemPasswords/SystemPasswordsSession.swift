import Foundation
import OSLog

nonisolated enum SystemPasswordsState: Sendable, Equatable {
    case notStarted
    case starting
    /// macOS has no password helper at the expected place.
    case helperMissing
    /// This build is not signed with the web browser entitlement, so macOS would refuse it anyway.
    case unentitledBuild
    /// macOS killed the helper on launch: Orbit is not yet on the list of browsers allowed to use it. Probed again on the next launch only.
    case waitingForMacOS
    case notPaired
    case pairing
    case awaitingPIN
    case verifyingPIN
    case paired
    case unavailable(String)
}

nonisolated enum SystemPasswordsError: Error, Equatable {
    case helperMissing
    case unentitledBuild
    case waitingForMacOS
    case notPaired
    case sessionEnded
    case timedOut
    case cancelled
    case wrongPIN
    case notFound
    case helperFailed(String)
    case protocolFailure(String)
}

nonisolated enum SystemPasswordsSaveOutcome: Sendable, Equatable {
    case saved
    case alreadySaved
    /// The helper did not answer and the login did not show up when listed again.
    case unconfirmed
}

nonisolated struct SystemPasswordsUpdate: Sendable, Equatable {
    var state: SystemPasswordsState
    var canFillOneTimeCodes: Bool
}

/// The one conversation with Apple's password helper. It keeps the helper running for the life of the app, because a pairing does not
/// survive a restart of the helper; it pairs again only when the helper dies, says the session is over (command 9 or 10), or answers
/// STATUS 9. One request is in flight at a time, and replies are matched by command number.
actor SystemPasswordsSession {

    nonisolated let updates: AsyncStream<SystemPasswordsUpdate>
    private let updateContinuation: AsyncStream<SystemPasswordsUpdate>.Continuation

    private nonisolated static let logger = Logger(subsystem: "com.orbit.browser", category: "SystemPasswords")

    private nonisolated struct Channel: Sendable {
        var transactionID: String
        var cipher: SystemPasswordsCipher
    }

    private nonisolated struct PendingPairing: Sendable {
        var client: SRPClient
        var transactionID: String
        var salt: [UInt8]
        var serverPublicKey: [UInt8]
    }

    private nonisolated struct Waiter {
        var serial: Int
        var continuation: CheckedContinuation<Data, Error>
    }

    private let locate: @Sendable () -> URL?

    private var state: SystemPasswordsState = .notStarted
    private var capabilities = SystemPasswordsCapabilities()
    private var transport: SystemPasswordsTransport?
    private var generation = 0
    private var refusedByMacOS = false
    private var terminationError: SystemPasswordsError?
    private var pairing: PendingPairing?
    private var channel: Channel?

    private var inbox: [Data] = []
    private var waiter: Waiter?
    private var waiterSerial = 0
    private var waiterTimer: Task<Void, Never>?

    private var busy = false
    private var gateQueue: [CheckedContinuation<Void, Never>] = []

    init(locate: @escaping @Sendable () -> URL? = { SystemPasswordsHelperLocator.locate() }) {
        self.locate = locate
        (updates, updateContinuation) = AsyncStream.makeStream(of: SystemPasswordsUpdate.self, bufferingPolicy: .unbounded)
    }

    private func setState(_ new: SystemPasswordsState) {
        guard new != state else { return }
        state = new
        updateContinuation.yield(SystemPasswordsUpdate(state: new, canFillOneTimeCodes: capabilities.canFillOneTimeCodes))
    }

    // MARK: - Lifecycle

    /// Launches the helper once and asks for its capabilities. A helper macOS kills on launch leaves the session waiting for macOS until the next app launch.
    func start(isEntitled: Bool) async {
        guard state == .notStarted else { return }
        guard isEntitled else {
            setState(.unentitledBuild)
            return
        }
        await acquire()
        defer { release() }
        do {
            try await ensureRunning()
            setState(channel == nil ? .notPaired : .paired)
        } catch {
            Self.logger.info("the Passwords helper is not available: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureRunning() async throws {
        if transport != nil { return }
        if state == .unentitledBuild { throw SystemPasswordsError.unentitledBuild }
        if refusedByMacOS { throw SystemPasswordsError.waitingForMacOS }
        guard let executable = locate() else {
            setState(.helperMissing)
            throw SystemPasswordsError.helperMissing
        }
        setState(.starting)
        let launched = SystemPasswordsTransport(executable: executable, arguments: [SystemPasswordsMessages.extensionOrigin])
        do {
            try launched.launch()
        } catch {
            setState(.unavailable("The Passwords helper could not be started."))
            throw SystemPasswordsError.helperFailed(error.localizedDescription)
        }
        generation += 1
        let current = generation
        transport = launched
        terminationError = nil
        inbox.removeAll()
        Task { [weak self] in
            for await event in launched.events {
                await self?.handle(event, generation: current)
            }
        }

        // A helper killed at launch may already be gone; its exit, not this write, says why.
        try? launched.send(SystemPasswordsMessages.capabilitiesRequest())
        do {
            let reply = try await awaitCommand([SystemPasswordsCommand.getCapabilities.rawValue], timeout: .seconds(10))
            capabilities = SystemPasswordsMessages.capabilities(from: reply)
        } catch {
            if transport === launched {
                transport = nil
                launched.terminate()
                setState(.unavailable("The Passwords helper did not answer."))
            }
            throw error
        }
    }

    private func handle(_ event: SystemPasswordsTransport.Event, generation eventGeneration: Int) {
        guard eventGeneration == generation, transport != nil else { return }
        switch event {
        case .message(let data):
            receive(data)
        case .malformedStream:
            Self.logger.error("the Passwords helper sent a malformed message stream")
        case .terminated(let termination):
            transport = nil
            channel = nil
            pairing = nil
            inbox.removeAll()
            let error: SystemPasswordsError
            if termination.looksLikeLaunchRefusal {
                refusedByMacOS = true
                error = .waitingForMacOS
                setState(.waitingForMacOS)
                Self.logger.info("macOS stopped the Passwords helper at launch: Orbit is not yet allowed to use it")
            } else {
                error = .sessionEnded
                setState(state == .starting ? .unavailable("The Passwords helper stopped.") : .notPaired)
                Self.logger.info("the Passwords helper ended: \(String(describing: termination.cause), privacy: .public)")
            }
            terminationError = error
            failWaiter(error)
        }
    }

    private func receive(_ data: Data) {
        if let message = SystemPasswordsMessages.object(from: data), let command = SystemPasswordsMessages.command(of: message),
           command == SystemPasswordsCommand.passwordsDisabled.rawValue || command == SystemPasswordsCommand.reloginNeeded.rawValue {
            endPairing()
            failWaiter(.notPaired)
            return
        }
        if let current = waiter {
            waiter = nil
            waiterTimer?.cancel()
            waiterTimer = nil
            current.continuation.resume(returning: data)
        } else {
            inbox.append(data)
            if inbox.count > 32 { inbox.removeFirst() }
        }
    }

    private func endPairing() {
        channel = nil
        pairing = nil
        if transport != nil { setState(.notPaired) }
    }

    // MARK: - Waiting for replies

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { gateQueue.append($0) }
    }

    private func release() {
        if gateQueue.isEmpty {
            busy = false
        } else {
            gateQueue.removeFirst().resume()
        }
    }

    private func failWaiter(_ error: SystemPasswordsError) {
        guard let current = waiter else { return }
        waiter = nil
        waiterTimer?.cancel()
        waiterTimer = nil
        current.continuation.resume(throwing: error)
    }

    private func expireWaiter(_ serial: Int) {
        guard let current = waiter, current.serial == serial else { return }
        waiter = nil
        waiterTimer = nil
        current.continuation.resume(throwing: SystemPasswordsError.timedOut)
    }

    private func nextMessage(until deadline: ContinuousClock.Instant) async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard transport != nil else { throw terminationError ?? SystemPasswordsError.sessionEnded }
        guard ContinuousClock.now < deadline else { throw SystemPasswordsError.timedOut }
        waiterSerial += 1
        let serial = waiterSerial
        return try await withCheckedThrowingContinuation { continuation in
            waiter = Waiter(serial: serial, continuation: continuation)
            waiterTimer = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(serial)
            }
        }
    }

    private func awaitCommand(_ commands: Set<Int>, timeout: Duration) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while true {
            let data = try await nextMessage(until: deadline)
            guard let message = SystemPasswordsMessages.object(from: data),
                  let command = SystemPasswordsMessages.command(of: message),
                  commands.contains(command)
            else { continue }
            return message
        }
    }

    private func send(_ payload: Data) throws {
        guard let transport else { throw terminationError ?? SystemPasswordsError.sessionEnded }
        do {
            try transport.send(payload)
        } catch {
            throw SystemPasswordsError.sessionEnded
        }
    }

    // MARK: - Pairing

    /// Starts SRP: macOS shows a six-digit code, which the person types into Orbit for `submitPIN`.
    func beginPairing() async throws {
        await acquire()
        defer { release() }
        try await ensureRunning()
        channel = nil
        pairing = nil
        let encoding = capabilities.encoding
        let transactionID = SystemPasswordsMessages.newTransactionID(encoding: encoding)
        let client = SRPClient(identity: transactionID, privateKeyBytes: SystemPasswordsCipher.randomBytes(32))
        setState(.pairing)
        inbox.removeAll()
        do {
            try send(SystemPasswordsMessages.clientKeyExchange(
                transactionID: transactionID,
                publicKey: encoding.encode(client.publicKeyBytes)
            ))
            let reply = try await awaitCommand([SystemPasswordsCommand.handshake.rawValue], timeout: .seconds(30))
            let exchange: SystemPasswordsMessages.ServerKeyExchange
            do {
                exchange = try SystemPasswordsMessages.serverKeyExchange(from: reply, encoding: encoding)
            } catch let failure as SystemPasswordsProtocolError {
                throw SystemPasswordsError.protocolFailure(String(describing: failure))
            }
            guard exchange.transactionID == transactionID else {
                throw SystemPasswordsError.protocolFailure("the helper answered another pairing")
            }
            pairing = PendingPairing(client: client, transactionID: transactionID, salt: exchange.salt, serverPublicKey: exchange.serverPublicKey)
            setState(.awaitingPIN)
        } catch {
            pairing = nil
            if transport != nil { setState(.notPaired) }
            throw error
        }
    }

    func submitPIN(_ pin: String) async throws {
        await acquire()
        defer { release() }
        guard let pending = pairing else { throw SystemPasswordsError.notPaired }
        setState(.verifyingPIN)
        inbox.removeAll()
        let encoding = capabilities.encoding
        do {
            let proof: SRPClientProof
            do {
                proof = try pending.client.proof(password: pin, salt: pending.salt, serverPublicKeyBytes: pending.serverPublicKey)
            } catch {
                throw SystemPasswordsError.protocolFailure(String(describing: error))
            }
            try send(SystemPasswordsMessages.clientVerification(
                transactionID: pending.transactionID,
                proof: encoding.encode(proof.clientProof, hexPrefix: false)
            ))
            let reply = try await awaitCommand([SystemPasswordsCommand.handshake.rawValue], timeout: .seconds(30))
            let verification: SystemPasswordsMessages.ServerVerification
            do {
                verification = try SystemPasswordsMessages.serverVerification(from: reply, encoding: encoding)
            } catch SystemPasswordsProtocolError.wrongPIN {
                throw SystemPasswordsError.wrongPIN
            } catch let failure as SystemPasswordsProtocolError {
                throw SystemPasswordsError.protocolFailure(String(describing: failure))
            }
            guard verification.transactionID == pending.transactionID,
                  SRPClient.proofsMatch(verification.serverProof, proof.expectedServerProof)
            else { throw SystemPasswordsError.protocolFailure("the helper's proof did not match") }
            channel = Channel(transactionID: pending.transactionID, cipher: try SystemPasswordsCipher(sessionKey: proof.sessionKey))
            pairing = nil
            setState(.paired)
        } catch {
            pairing = nil
            if transport != nil { setState(.notPaired) }
            throw error
        }
    }

    /// Takes down the code macOS is showing. Not queued behind the pairing it cancels.
    func cancelPairing() {
        guard state == .pairing || state == .awaitingPIN || state == .verifyingPIN else { return }
        try? send(SystemPasswordsMessages.cancelPairingRequest())
        pairing = nil
        failWaiter(.cancelled)
        if transport != nil { setState(channel == nil ? .notPaired : .paired) }
    }

    // MARK: - Requests

    private func encryptedExchange(
        command: SystemPasswordsCommand,
        replies: Set<Int>,
        host: String?,
        query: String,
        body: Data,
        timeout: Duration,
        isFinal: ([String: Any]) -> Bool = { _ in true }
    ) async throws -> [String: Any] {
        guard transport != nil, let channel else { throw SystemPasswordsError.notPaired }
        let encoding = capabilities.encoding
        let sealed: Data
        do {
            sealed = try channel.cipher.seal(body, layout: .clientToHelper)
        } catch {
            throw SystemPasswordsError.protocolFailure("could not encrypt a request")
        }
        inbox.removeAll()
        try send(SystemPasswordsMessages.encryptedRequest(
            command: command,
            host: host,
            query: query,
            transactionID: channel.transactionID,
            sdata: encoding.encode([UInt8](sealed), hexPrefix: false)
        ))
        let deadline = ContinuousClock.now + timeout
        while true {
            let data = try await nextMessage(until: deadline)
            guard let message = SystemPasswordsMessages.object(from: data),
                  let replyCommand = SystemPasswordsMessages.command(of: message),
                  replies.contains(replyCommand),
                  let reply = SystemPasswordsMessages.encryptedReply(from: message),
                  reply.transactionID == channel.transactionID,
                  let sdata = encoding.decode(reply.sdata)
            else { continue }
            let plain: Data
            do {
                plain = try channel.cipher.open(Data(sdata), layout: .helperToClient)
            } catch {
                throw SystemPasswordsError.protocolFailure("could not decrypt a reply")
            }
            guard let decoded = SystemPasswordsMessages.object(from: plain) else {
                throw SystemPasswordsError.protocolFailure("a reply was not JSON")
            }
            if SystemPasswordsMessages.status(of: decoded) == .invalidSession {
                endPairing()
                throw SystemPasswordsError.notPaired
            }
            if isFinal(decoded) { return decoded }
        }
    }

    private static func host(of pageURL: String) -> String? {
        URL(string: pageURL)?.host()
    }

    private func listLogins(host: String) async throws -> [SystemPasswordLogin] {
        let body = try await encryptedExchange(
            command: .getLoginNamesForURL,
            replies: [SystemPasswordsCommand.getLoginNamesForURL.rawValue],
            host: host,
            query: SystemPasswordsMessages.loginNamesQuery,
            body: SystemPasswordsMessages.loginNamesBody(host: host),
            timeout: .seconds(15)
        )
        if SystemPasswordsMessages.status(of: body) == .noResults { return [] }
        return SystemPasswordsMessages.logins(from: body)
    }

    func logins(host: String) async throws -> [SystemPasswordLogin] {
        await acquire()
        defer { release() }
        return try await listLogins(host: host)
    }

    /// The helper asks the person to authenticate before it answers, so this waits up to two minutes.
    func password(username: String, host: String) async throws -> String {
        await acquire()
        defer { release() }
        let body = try await encryptedExchange(
            command: .getPasswordForLoginName,
            replies: [SystemPasswordsCommand.getPasswordForLoginName.rawValue],
            host: host,
            query: SystemPasswordsMessages.passwordQuery,
            body: SystemPasswordsMessages.passwordBody(host: host, username: username),
            timeout: .seconds(120),
            isFinal: { SystemPasswordsMessages.password(from: $0, username: username) != .pending }
        )
        switch SystemPasswordsMessages.password(from: body, username: username) {
        case .password(let password): return password
        case .pending, .notFound: throw SystemPasswordsError.notFound
        }
    }

    func save(username: String, password: String, host: String) async throws -> SystemPasswordsSaveOutcome {
        await acquire()
        defer { release() }
        do {
            let body = try await encryptedExchange(
                command: .setPasswordForLoginNameAndURL,
                replies: [SystemPasswordsCommand.setPasswordForLoginNameAndURL.rawValue, SystemPasswordsCommand.getLoginNamesForURL.rawValue],
                host: host,
                query: SystemPasswordsMessages.saveQuery,
                body: SystemPasswordsMessages.saveBody(host: host, username: username, password: password),
                timeout: .seconds(60)
            )
            switch SystemPasswordsMessages.status(of: body) {
            case .duplicate: return .alreadySaved
            case .success: return .saved
            case nil: break
            case let other?: throw SystemPasswordsError.helperFailed("STATUS \(other.rawValue)")
            }
        } catch SystemPasswordsError.timedOut {
            Self.logger.info("the Passwords helper did not answer a save; listing again to confirm it")
        }
        let listed = try await listLogins(host: host)
        return listed.contains { $0.username == username } ? .saved : .unconfirmed
    }

    func oneTimeCodes(pageURL: String, username: String?) async throws -> [SystemPasswordOneTimeCode] {
        await acquire()
        defer { release() }
        guard capabilities.canFillOneTimeCodes else { return [] }
        let body = try await encryptedExchange(
            command: .getOneTimeCodes,
            replies: [SystemPasswordsCommand.getOneTimeCodes.rawValue],
            host: Self.host(of: pageURL),
            query: SystemPasswordsMessages.oneTimeCodesQuery,
            body: SystemPasswordsMessages.oneTimeCodesBody(pageURL: pageURL, username: username),
            timeout: .seconds(15)
        )
        if SystemPasswordsMessages.status(of: body) == .noResults { return [] }
        return SystemPasswordsMessages.oneTimeCodes(from: body)
    }

    /// Asks for the code the person chose. Passwords may ask them to authenticate first, so this waits up to two minutes.
    func revealOneTimeCode(pageURL: String, username: String?) async throws -> String {
        await acquire()
        defer { release() }
        guard capabilities.canFillOneTimeCodes else { throw SystemPasswordsError.notFound }
        let body = try await encryptedExchange(
            command: .getOneTimeCodes,
            replies: [SystemPasswordsCommand.getOneTimeCodes.rawValue],
            host: Self.host(of: pageURL),
            query: SystemPasswordsMessages.oneTimeCodesQuery,
            body: SystemPasswordsMessages.oneTimeCodeSearchBody(pageURL: pageURL, username: username),
            timeout: .seconds(120),
            isFinal: { SystemPasswordsMessages.revealedOneTimeCode(from: $0, username: username) != .pending }
        )
        switch SystemPasswordsMessages.revealedOneTimeCode(from: body, username: username) {
        case .password(let code): return code
        case .pending, .notFound: throw SystemPasswordsError.notFound
        }
    }

    /// Tells Passwords the code was used, so it can tidy up. A missing answer is not an error.
    func didFillOneTimeCode(pageURL: String, username: String) async {
        await acquire()
        defer { release() }
        guard capabilities.canFillOneTimeCodes else { return }
        _ = try? await encryptedExchange(
            command: .didFillOneTimeCode,
            replies: [SystemPasswordsCommand.didFillOneTimeCode.rawValue],
            host: Self.host(of: pageURL),
            query: SystemPasswordsMessages.didFillOneTimeCodeQuery,
            body: SystemPasswordsMessages.didFillOneTimeCodeBody(pageURL: pageURL, username: username),
            timeout: .seconds(5)
        )
    }
}
