import XCTest

// The wire format of Apple's password helper (Orbit/Features/SystemPasswords/SystemPasswordsWire.swift and
// SystemPasswordsProtocol.swift): native messaging framing, the binary encodings, the asymmetric SDATA layouts,
// the request bodies in the helper's own key order, and lenient reading of its replies.

nonisolated private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

nonisolated private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

nonisolated private func base64JSON(_ string: String) -> String { Data(string.utf8).base64EncodedString() }

final class NativeMessageFramingTests: XCTestCase {

    func testAMessageIsItsLittleEndianLengthThenItsBytes() {
        XCTAssertEqual([UInt8](NativeMessageFraming.encode(Data("{}".utf8))), [2, 0, 0, 0, 0x7B, 0x7D])
        let long = Data(repeating: 0x41, count: 0x0102)
        XCTAssertEqual([UInt8](NativeMessageFraming.encode(long).prefix(4)), [0x02, 0x01, 0, 0])
    }

    func testTheDecoderReassemblesMessagesSplitAnywhere() throws {
        let first = Data(#"{"cmd":14}"#.utf8)
        let second = Data(#"{"cmd":2,"payload":{}}"#.utf8)
        let stream = NativeMessageFraming.encode(first) + NativeMessageFraming.encode(second) + NativeMessageFraming.encode(Data())
        for split in 0...stream.count {
            var decoder = NativeMessageFraming.Decoder()
            var messages = try decoder.append(stream.prefix(split))
            messages += try decoder.append(stream.dropFirst(split))
            XCTAssertEqual(messages, [first, second, Data()], "split at \(split)")
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
    }

    func testTheDecoderWaitsForTheRestOfAMessage() throws {
        var decoder = NativeMessageFraming.Decoder()
        let framed = NativeMessageFraming.encode(Data("hello".utf8))
        for byte in framed.dropLast() {
            XCTAssertEqual(try decoder.append(Data([byte])), [])
        }
        XCTAssertEqual(try decoder.append(Data([framed.last!])), [Data("hello".utf8)])
    }

    func testAnAbsurdLengthPoisonsTheStream() {
        var decoder = NativeMessageFraming.Decoder()
        let length = UInt32(NativeMessageFraming.maximumMessageLength + 1)
        let header = Data([UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)])
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? NativeMessageFraming.Failure, .messageTooLarge(Int(length)))
        }
    }
}

final class SystemPasswordsEncodingTests: XCTestCase {

    func testHexIsPrefixedOnlyWhenAsked() {
        XCTAssertEqual(SystemPasswordsBinaryEncoding.hex.encode([0x00, 0xAB, 0x10]), "0x00ab10")
        XCTAssertEqual(SystemPasswordsBinaryEncoding.hex.encode([0x00, 0xAB, 0x10], hexPrefix: false), "00ab10")
        XCTAssertEqual(SystemPasswordsBinaryEncoding.base64.encode([0x00, 0xAB, 0x10], hexPrefix: true), "AKsQ")
    }

    func testDecodingAcceptsEitherHexSpellingAndRefusesJunk() {
        XCTAssertEqual(SystemPasswordsBinaryEncoding.hex.decode("0x00ab10"), [0x00, 0xAB, 0x10])
        XCTAssertEqual(SystemPasswordsBinaryEncoding.hex.decode("00AB10"), [0x00, 0xAB, 0x10])
        XCTAssertNil(SystemPasswordsBinaryEncoding.hex.decode("0x0ab"))
        XCTAssertNil(SystemPasswordsBinaryEncoding.hex.decode("zz"))
        XCTAssertEqual(SystemPasswordsBinaryEncoding.base64.decode("AKsQ"), [0x00, 0xAB, 0x10])
        XCTAssertNil(SystemPasswordsBinaryEncoding.base64.decode("not base64!"))
    }

    func testJSONKeepsKeyOrderAndEscapes() {
        let value = WireJSON.object([
            ("b", .int(1)),
            ("a", .string("quote \" backslash \\ newline \n bell \u{07}")),
            ("c", .array([.bool(true), .int(-1)])),
        ])
        XCTAssertEqual(value.serialized, #"{"b":1,"a":"quote \" backslash \\ newline \n bell \u0007","c":[true,-1]}"#)
        let parsed = json(value.data)
        XCTAssertEqual(parsed["a"] as? String, "quote \" backslash \\ newline \n bell \u{07}")
    }

    func testATransactionIDNeverStartsWithAZeroByte() {
        let id = SystemPasswordsMessages.newTransactionID(encoding: .hex, bytes: [0] + [UInt8](repeating: 7, count: 15))
        XCTAssertEqual(id, "0x01" + String(repeating: "07", count: 15))
        let random = SystemPasswordsMessages.newTransactionID(encoding: .base64)
        XCTAssertEqual(SystemPasswordsBinaryEncoding.base64.decode(random)?.count, 16)
        XCTAssertNotEqual(SystemPasswordsBinaryEncoding.base64.decode(random)?.first, 0)
    }
}

final class SystemPasswordsCipherTests: XCTestCase {

    private let sessionKey = (0..<32).map { UInt8($0) }
    private let nonce = [UInt8](repeating: 0x5A, count: 16)
    private let plaintext = Data(#"{"ACT":5,"URL":"example.com"}"#.utf8)

    func testWhatOrbitSendsIsCiphertextThenTagThenNonce() throws {
        let cipher = try SystemPasswordsCipher(sessionKey: sessionKey)
        let sealed = try cipher.seal(plaintext, layout: .clientToHelper, nonce: nonce)
        XCTAssertEqual(sealed.count, plaintext.count + 16 + 16)
        XCTAssertEqual([UInt8](sealed.suffix(16)), nonce, "the nonce comes last")
        XCTAssertEqual(try cipher.open(sealed, layout: .clientToHelper), plaintext)
    }

    func testWhatTheHelperSendsIsNonceThenCiphertextThenTag() throws {
        let cipher = try SystemPasswordsCipher(sessionKey: sessionKey)
        let sealed = try cipher.seal(plaintext, layout: .helperToClient, nonce: nonce)
        XCTAssertEqual([UInt8](sealed.prefix(16)), nonce, "the nonce comes first")
        XCTAssertEqual(try cipher.open(sealed, layout: .helperToClient), plaintext)
    }

    func testBothLayoutsCarryTheSameCiphertextAndTag() throws {
        let cipher = try SystemPasswordsCipher(sessionKey: sessionKey)
        let outgoing = [UInt8](try cipher.seal(plaintext, layout: .clientToHelper, nonce: nonce))
        let incoming = [UInt8](try cipher.seal(plaintext, layout: .helperToClient, nonce: nonce))
        XCTAssertEqual(Array(outgoing.dropLast(16)), Array(incoming.dropFirst(16)))
    }

    func testOpeningWithTheWrongLayoutOrATamperedByteFails() throws {
        let cipher = try SystemPasswordsCipher(sessionKey: sessionKey)
        let sealed = try cipher.seal(plaintext, layout: .clientToHelper, nonce: nonce)
        XCTAssertThrowsError(try cipher.open(sealed, layout: .helperToClient))
        var tampered = [UInt8](sealed)
        tampered[3] ^= 0x01
        XCTAssertThrowsError(try cipher.open(Data(tampered), layout: .clientToHelper)) { error in
            XCTAssertEqual(error as? SystemPasswordsCipher.Failure, .authenticationFailed)
        }
        XCTAssertThrowsError(try cipher.open(Data(repeating: 0, count: 31), layout: .helperToClient)) { error in
            XCTAssertEqual(error as? SystemPasswordsCipher.Failure, .shortMessage)
        }
    }

    func testOnlyTheFirstSixteenBytesOfTheSessionKeyAreTheKey() throws {
        let sealed = try SystemPasswordsCipher(sessionKey: sessionKey).seal(plaintext, layout: .helperToClient)
        var differentTail = sessionKey
        differentTail[20] ^= 0xFF
        XCTAssertEqual(try SystemPasswordsCipher(sessionKey: differentTail).open(sealed, layout: .helperToClient), plaintext)
        var differentHead = sessionKey
        differentHead[0] ^= 0xFF
        XCTAssertThrowsError(try SystemPasswordsCipher(sessionKey: differentHead).open(sealed, layout: .helperToClient))
        XCTAssertThrowsError(try SystemPasswordsCipher(sessionKey: Array(sessionKey.prefix(15))))
    }
}

final class SystemPasswordsMessagesTests: XCTestCase {

    func testTheClientKeyExchangeIsWrittenInTheExtensionsOrder() throws {
        let data = SystemPasswordsMessages.clientKeyExchange(transactionID: "VElE", publicKey: "QUFB")
        let outer = text(data)
        XCTAssertTrue(outer.hasPrefix(#"{"cmd":2,"msg":"#), outer)
        let msg = try XCTUnwrap(json(data)["msg"] as? String)
        XCTAssertTrue(msg.hasPrefix(#"{"QID":"m0","PAKE":""#), msg)
        XCTAssertTrue(msg.hasSuffix(#"","HSTBRSR":"Orbit"}"#), msg)
        let pake = try XCTUnwrap(json(Data(msg.utf8))["PAKE"] as? String)
        XCTAssertEqual(text(try XCTUnwrap(Data(base64Encoded: pake))), #"{"TID":"VElE","MSG":0,"A":"QUFB","VER":"1.0","PROTO":[0,1]}"#)
    }

    func testTheClientVerificationPutsTheBrowserBeforeThePAKE() throws {
        let data = SystemPasswordsMessages.clientVerification(transactionID: "VElE", proof: "TU1N")
        let msg = try XCTUnwrap(json(data)["msg"] as? String)
        XCTAssertTrue(msg.hasPrefix(#"{"QID":"m2","HSTBRSR":"Orbit","PAKE":""#), msg)
        let pake = try XCTUnwrap(json(Data(msg.utf8))["PAKE"] as? String)
        XCTAssertEqual(text(try XCTUnwrap(Data(base64Encoded: pake))), #"{"TID":"VElE","MSG":2,"M":"TU1N"}"#)
    }

    func testAnEncryptedRequestCarriesItsQueryAndSealedMessageAsJSONText() throws {
        let data = SystemPasswordsMessages.encryptedRequest(
            command: .getLoginNamesForURL, host: "example.com", query: SystemPasswordsMessages.loginNamesQuery, transactionID: "VElE", sdata: "U0RBVEE="
        )
        XCTAssertEqual(
            text(data),
            #"{"cmd":4,"tabId":0,"frameId":0,"url":"example.com","payload":"{\"QID\":\"CmdGetLoginNames4URL\",\"SMSG\":{\"TID\":\"VElE\",\"SDATA\":\"U0RBVEE=\"}}"}"#
        )
        let withoutHost = SystemPasswordsMessages.encryptedRequest(
            command: .getOneTimeCodes, host: nil, query: SystemPasswordsMessages.oneTimeCodesQuery, transactionID: "T", sdata: "S"
        )
        XCTAssertNil(json(withoutHost)["url"])
    }

    func testRequestBodies() {
        XCTAssertEqual(text(SystemPasswordsMessages.loginNamesBody(host: "example.com")), #"{"ACT":5,"URL":"example.com"}"#)
        XCTAssertEqual(
            text(SystemPasswordsMessages.passwordBody(host: "example.com", username: "alice")),
            #"{"ACT":2,"URL":"example.com","USR":"alice"}"#
        )
        XCTAssertEqual(
            text(SystemPasswordsMessages.saveBody(host: "example.com", username: "alice", password: "p\"w")),
            #"{"ACT":4,"URL":"","USR":"","PWD":"","NURL":"example.com","NUSR":"alice","NPWD":"p\"w"}"#
        )
        XCTAssertEqual(
            text(SystemPasswordsMessages.oneTimeCodesBody(pageURL: "https://example.com/login", username: nil)),
            #"{"ACT":5,"TYPE":"oneTimeCodes","frameURLs":["https://example.com/login"]}"#
        )
        XCTAssertEqual(
            text(SystemPasswordsMessages.didFillOneTimeCodeBody(pageURL: "https://example.com/login", username: "alice")),
            #"{"ACT":2,"TYPE":"oneTimeCodes","frameURLs":["https://example.com/login"],"username":"alice"}"#
        )
        XCTAssertEqual(text(SystemPasswordsMessages.capabilitiesRequest()), #"{"cmd":14}"#)
        XCTAssertEqual(text(SystemPasswordsMessages.cancelPairingRequest()), #"{"cmd":19}"#)
    }

    private func handshakeReply(_ pake: String, payloadAsText: Bool = false) -> [String: Any] {
        let payload: [String: Any] = ["QID": "m0", "PAKE": base64JSON(pake)]
        if payloadAsText {
            let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return ["cmd": 2, "payload": encoded]
        }
        return ["cmd": 2, "payload": payload]
    }

    func testTheServerKeyExchangeIsRead() throws {
        for asText in [false, true] {
            let reply = handshakeReply(#"{"TID":"VElE","MSG":1,"B":"AQID","s":"BAUG","PROTO":1}"#, payloadAsText: asText)
            let exchange = try SystemPasswordsMessages.serverKeyExchange(from: reply, encoding: .base64)
            XCTAssertEqual(exchange, .init(transactionID: "VElE", serverPublicKey: [1, 2, 3], salt: [4, 5, 6]))
        }
        let hex = handshakeReply(#"{"TID":"0x01","MSG":"1","B":"0x0a0b","s":"0x0c","PROTO":[1]}"#)
        XCTAssertEqual(
            try SystemPasswordsMessages.serverKeyExchange(from: hex, encoding: .hex),
            .init(transactionID: "0x01", serverPublicKey: [10, 11], salt: [12])
        )
    }

    func testABadServerKeyExchangeIsRefused() {
        XCTAssertThrowsError(try SystemPasswordsMessages.serverKeyExchange(
            from: handshakeReply(#"{"TID":"T","MSG":1,"B":"AQ==","s":"AQ==","PROTO":1,"ErrCode":3}"#), encoding: .base64
        )) { XCTAssertEqual($0 as? SystemPasswordsProtocolError, .handshakeRejected(3)) }
        XCTAssertThrowsError(try SystemPasswordsMessages.serverKeyExchange(
            from: handshakeReply(#"{"TID":"T","MSG":1,"B":"AQ==","s":"AQ==","PROTO":0}"#), encoding: .base64
        )) { XCTAssertEqual($0 as? SystemPasswordsProtocolError, .unsupportedProtocolVersion) }
        XCTAssertThrowsError(try SystemPasswordsMessages.serverKeyExchange(
            from: handshakeReply(#"{"TID":"T","MSG":1,"s":"AQ==","PROTO":1}"#), encoding: .base64
        ))
        XCTAssertThrowsError(try SystemPasswordsMessages.serverKeyExchange(from: ["cmd": 2], encoding: .base64))
    }

    func testTheServerVerificationIsReadAndAWrongPINIsItsOwnError() throws {
        let good = handshakeReply(#"{"TID":"T","MSG":"3","ErrCode":0,"HAMK":"AQID"}"#)
        XCTAssertEqual(try SystemPasswordsMessages.serverVerification(from: good, encoding: .base64), .init(transactionID: "T", serverProof: [1, 2, 3]))
        let wrong = handshakeReply(#"{"TID":"T","MSG":3,"ErrCode":1}"#)
        XCTAssertThrowsError(try SystemPasswordsMessages.serverVerification(from: wrong, encoding: .base64)) {
            XCTAssertEqual($0 as? SystemPasswordsProtocolError, .wrongPIN)
        }
    }

    func testCapabilitiesDefaultToOffWhenAbsent() {
        let full = SystemPasswordsMessages.capabilities(from: [
            "cmd": 14,
            "capabilities": [
                "shouldUseBase64": true, "secretSessionVersion": 1, "canFillOneTimeCodes": true,
                "operatingSystem": ["name": "macos", "majorVersion": 26, "minorVersion": 1],
            ] as [String: Any],
        ])
        XCTAssertTrue(full.shouldUseBase64)
        XCTAssertEqual(full.encoding, .base64)
        XCTAssertTrue(full.canFillOneTimeCodes)
        XCTAssertFalse(full.scanForOTPURI)
        XCTAssertEqual(full.secretSessionVersion, 1)
        XCTAssertEqual(full.operatingSystemMajorVersion, 26)
        XCTAssertEqual(SystemPasswordsMessages.capabilities(from: ["cmd": 14]), SystemPasswordsCapabilities())
        XCTAssertEqual(SystemPasswordsCapabilities().encoding, .hex)
    }

    func testAnEncryptedReplyIsFoundWhetherItsPartsAreObjectsOrText() {
        let objects: [String: Any] = ["cmd": 4, "payload": ["QID": "x", "SMSG": ["TID": "T", "SDATA": "S"]]]
        XCTAssertEqual(SystemPasswordsMessages.encryptedReply(from: objects), .init(transactionID: "T", sdata: "S"))
        let texts: [String: Any] = ["cmd": 4, "payload": #"{"QID":"x","SMSG":"{\"TID\":\"T\",\"SDATA\":\"S\"}"}"#]
        XCTAssertEqual(SystemPasswordsMessages.encryptedReply(from: texts), .init(transactionID: "T", sdata: "S"))
        XCTAssertNil(SystemPasswordsMessages.encryptedReply(from: ["cmd": 4]))
    }

    func testLoginsAreReadFromEntriesOrNumberedEntryKeys() {
        let listed: [String: Any] = [
            "STATUS": 0,
            "Entries": [
                ["USR": "alice", "sites": ["example.com"], "customTitle": ""],
                ["USR": SystemPasswordsMessages.placeholderUsername, "sites": []],
                ["USR": "bob", "sites": ["login.example.com"], "customTitle": "Work"],
                ["USR": "alice", "sites": ["www.example.com"]],
            ] as [Any],
        ]
        XCTAssertEqual(SystemPasswordsMessages.logins(from: listed), [
            SystemPasswordLogin(username: "alice", sites: ["example.com"]),
            SystemPasswordLogin(username: "bob", sites: ["login.example.com"], customTitle: "Work"),
        ])
        let numbered: [String: Any] = [
            "Entry_10": #"{"USR":"carol"}"#,
            "Entry_2": ["USR": "bob", "RequiresUserAuthenticationToFill": true] as [String: Any],
            "STATUS": "0",
        ]
        XCTAssertEqual(SystemPasswordsMessages.logins(from: numbered).map(\.username), ["bob", "carol"])
        XCTAssertEqual(SystemPasswordsMessages.logins(from: numbered).first?.requiresAuthenticationToFill, true)
        XCTAssertEqual(SystemPasswordsMessages.status(of: numbered), .success)
        XCTAssertEqual(SystemPasswordsMessages.status(of: ["STATUS": 9]), .invalidSession)
    }

    func testAPasswordIsReadForItsUsernameAndAPendingOneIsNotAPassword() {
        let body: [String: Any] = ["Entries": [["USR": "bob", "PWD": "bob-pw"], ["USR": "alice", "PWD": "alice-pw"]] as [Any]]
        XCTAssertEqual(SystemPasswordsMessages.password(from: body, username: "alice"), .password("alice-pw"))
        XCTAssertEqual(SystemPasswordsMessages.password(from: body, username: "carol"), .notFound)
        let pending: [String: Any] = ["Entries": [["USR": "alice", "PWD": SystemPasswordsMessages.passwordNotIncluded]] as [Any]]
        XCTAssertEqual(SystemPasswordsMessages.password(from: pending, username: "alice"), .pending)
        XCTAssertEqual(SystemPasswordsMessages.password(from: ["USR": "alice", "PWD": "top-level"], username: "alice"), .password("top-level"))
        XCTAssertEqual(SystemPasswordsMessages.password(from: ["STATUS": 3], username: "alice"), .notFound)
    }

    func testOneTimeCodesKeepOnlyCodesThatCouldBeTyped() {
        let body: [String: Any] = ["Entries": [
            ["code": "123456", "username": "alice", "domain": "example.com", "source": "Messages"],
            ["code": "12<b>34"],
            ["username": "nobody"],
        ] as [Any]]
        XCTAssertEqual(SystemPasswordsMessages.oneTimeCodes(from: body), [
            SystemPasswordOneTimeCode(code: "123456", username: "alice", domain: "example.com", source: "Messages"),
        ])
    }
}

final class SystemPasswordPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = URL(string: "https://accounts.example.com")!

    private func submission(_ username: String, _ password: String, isNew: Bool = false, origin: URL? = nil) -> PasswordSubmission {
        PasswordSubmission(origin: origin ?? self.origin, username: username, password: password, isNewPassword: isNew)
    }

    func testTheHostAskedAboutIsTheFramesOwn() {
        XCTAssertEqual(SystemPasswordPolicy.host(of: URL(string: "https://Accounts.Example.com:8443")!), "accounts.example.com")
        XCTAssertEqual(SystemPasswordPolicy.host(of: URL(string: "https://example.com.")!), "example.com")
        XCTAssertEqual(SystemPasswordPolicy.host(of: URL(string: "http://[::1]:3000")!), "::1")
        XCTAssertNil(SystemPasswordPolicy.host(of: URL(string: "file:///tmp/x")!))
    }

    func testAnUnknownUsernameIsOfferedForSaving() {
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission(" carol ", "pw"), knownUsernames: ["alice"], filled: nil, now: now),
            .save(username: "carol")
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("carol", "pw"), knownUsernames: [], filled: nil, now: now),
            .save(username: "carol")
        )
    }

    func testAKnownUsernameSignInIsLeftAloneUnlessItIsANewPassword() {
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("alice", "pw"), knownUsernames: ["alice"], filled: nil, now: now),
            .nothing,
            "Passwords will not say what it holds, so a plain sign-in is not second-guessed"
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("alice", "pw", isNew: true), knownUsernames: ["alice"], filled: nil, now: now),
            .update(username: "alice")
        )
    }

    func testChangingAPasswordOrbitJustFilledIsOfferedAsAnUpdate() {
        let record = SystemPasswordFillRecord(origin: URL(string: "https://example.com")!, username: "alice", password: "filled", date: now)
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("alice", "filled"), knownUsernames: ["alice"], filled: record, now: now),
            .nothing
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("alice", "typed-over"), knownUsernames: ["alice"], filled: record, now: now),
            .update(username: "alice")
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(
                submission: submission("alice", "typed-over"), knownUsernames: ["alice"], filled: record,
                now: now.addingTimeInterval(SystemPasswordFillRecord.lifetime + 1)
            ),
            .nothing,
            "an old fill says nothing about this sign-in"
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(
                submission: submission("alice", "typed-over", origin: URL(string: "https://other.test")!), knownUsernames: ["alice"],
                filled: record, now: now
            ),
            .nothing,
            "a fill on another site says nothing about this one"
        )
    }

    func testAChangePasswordPageWithNoUsernameUpdatesTheSitesOnlyLogin() {
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("", "new", isNew: true), knownUsernames: ["alice"], filled: nil, now: now),
            .update(username: "alice")
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("", "new", isNew: true), knownUsernames: ["alice", "bob"], filled: nil, now: now),
            .nothing
        )
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(submission: submission("", "new", isNew: false), knownUsernames: ["alice"], filled: nil, now: now),
            .nothing
        )
    }

    func testNothingIsOfferedForAnEmptyPasswordOrAPlainHTTPPage() {
        XCTAssertEqual(SystemPasswordPolicy.saveDecision(submission: submission("alice", ""), knownUsernames: [], filled: nil, now: now), .nothing)
        XCTAssertEqual(
            SystemPasswordPolicy.saveDecision(
                submission: submission("alice", "pw", origin: URL(string: "http://example.com")!), knownUsernames: [], filled: nil, now: now
            ),
            .nothing
        )
    }

    func testAFillRecordKeepsNoPassword() {
        let record = SystemPasswordFillRecord(origin: origin, username: "alice", password: "hunter2-secret", date: now)
        XCTAssertFalse(String(describing: record).contains("hunter2-secret"))
        XCTAssertEqual(record.siteKey, "example.com")
    }

    func testThePreviousStepsUsernameIsListedFirst() {
        let logins = ["alice", "bob", "carol"].map { SystemPasswordLogin(username: $0) }
        XCTAssertEqual(SystemPasswordPolicy.ordered(logins, preferredUsername: "carol").map(\.username), ["carol", "alice", "bob"])
        XCTAssertEqual(SystemPasswordPolicy.ordered(logins, preferredUsername: nil).map(\.username), ["alice", "bob", "carol"])
        XCTAssertEqual(SystemPasswordPolicy.ordered(logins, preferredUsername: "nobody").map(\.username), ["alice", "bob", "carol"])
    }

    func testALoginWithNoUsernameIsTitledByPasswords() {
        XCTAssertEqual(SystemPasswordPolicy.rowTitle(for: SystemPasswordLogin(username: "alice")), "alice")
        XCTAssertEqual(SystemPasswordPolicy.rowTitle(for: SystemPasswordLogin(username: "", customTitle: "Router")), "Router")
        XCTAssertEqual(SystemPasswordPolicy.rowTitle(for: SystemPasswordLogin(username: "")), "Password with no user name")
    }
}

final class SystemPasswordsHelperLocatorTests: XCTestCase {

    func testOnlyAHelperInsideSystemIsTrusted() {
        let manifest = Data(#"{"name":"com.apple.passwordmanager","path":"\#(SystemPasswordsHelperLocator.knownExecutablePath)","type":"stdio"}"#.utf8)
        XCTAssertEqual(SystemPasswordsHelperLocator.executablePath(fromManifest: manifest), SystemPasswordsHelperLocator.knownExecutablePath)
        XCTAssertNil(SystemPasswordsHelperLocator.executablePath(fromManifest: Data(#"{"path":"/Library/Evil/helper"}"#.utf8)))
        XCTAssertNil(SystemPasswordsHelperLocator.executablePath(fromManifest: Data(#"{"path":"/System/../tmp/helper"}"#.utf8)))
        XCTAssertNil(SystemPasswordsHelperLocator.executablePath(fromManifest: Data(#"{"path":"relative/helper"}"#.utf8)))
        XCTAssertNil(SystemPasswordsHelperLocator.executablePath(fromManifest: Data("not json".utf8)))
    }

    func testTheLaunchRefusalIsAnEarlySilentKill() {
        XCTAssertTrue(SystemPasswordsTermination(cause: .signal(SIGKILL), uptime: 0.2, receivedAnyMessage: false).looksLikeLaunchRefusal)
        XCTAssertFalse(SystemPasswordsTermination(cause: .signal(SIGKILL), uptime: 0.2, receivedAnyMessage: true).looksLikeLaunchRefusal)
        XCTAssertFalse(SystemPasswordsTermination(cause: .signal(SIGKILL), uptime: 600, receivedAnyMessage: false).looksLikeLaunchRefusal)
        XCTAssertFalse(SystemPasswordsTermination(cause: .signal(SIGTERM), uptime: 0.2, receivedAnyMessage: false).looksLikeLaunchRefusal)
        XCTAssertFalse(SystemPasswordsTermination(cause: .exited(137), uptime: 0.2, receivedAnyMessage: false).looksLikeLaunchRefusal)
    }
}
