import Foundation

nonisolated enum SystemPasswordsCommand: Int, Sendable {
    case end = 0
    case handshake = 2
    case setIconAndTitle = 3
    case getLoginNamesForURL = 4
    case getPasswordForLoginName = 5
    case setPasswordForLoginNameAndURL = 6
    case newAccountForURL = 7
    case tabEvent = 8
    case passwordsDisabled = 9
    case reloginNeeded = 10
    case launchICloudPasswords = 11
    case iCloudPasswordsStateChange = 12
    case launchPasswordsApp = 13
    case getCapabilities = 14
    case oneTimeCodeAvailable = 15
    case getOneTimeCodes = 16
    case didFillOneTimeCode = 17
    case cancelPairing = 19
    case openURLInSafari = 1984
}

nonisolated enum SystemPasswordsAction: Int, Sendable {
    case unknown = -1
    case delete = 0
    case update = 1
    case search = 2
    case addNew = 3
    case maybeAdd = 4
    case ghostSearch = 5
}

nonisolated enum SystemPasswordsStatus: Int, Sendable {
    case success = 0
    case generic = 1
    case invalidParameter = 2
    case noResults = 3
    case failedDelete = 4
    case failedUpdate = 5
    case invalidMessageFormat = 6
    case duplicate = 7
    case unknownAction = 8
    case invalidSession = 9
    case serverError = 100
}

nonisolated struct SystemPasswordsCapabilities: Sendable, Equatable {
    var shouldUseBase64 = false
    var secretSessionVersion: Int?
    var canFillOneTimeCodes = false
    var scanForOTPURI = false
    var operatingSystemName: String?
    var operatingSystemMajorVersion: Int?
    var operatingSystemMinorVersion: Int?

    var encoding: SystemPasswordsBinaryEncoding { shouldUseBase64 ? .base64 : .hex }
}

/// A login Passwords holds for a site. Never carries the password.
nonisolated struct SystemPasswordLogin: Sendable, Equatable, Hashable {
    var username: String
    var sites: [String]
    var customTitle: String?
    var requiresAuthenticationToFill: Bool

    init(username: String, sites: [String] = [], customTitle: String? = nil, requiresAuthenticationToFill: Bool = false) {
        self.username = username
        self.sites = sites
        self.customTitle = customTitle
        self.requiresAuthenticationToFill = requiresAuthenticationToFill
    }
}

nonisolated struct SystemPasswordOneTimeCode: Sendable, Equatable, Hashable {
    var code: String
    var username: String?
    var domain: String?
    var source: String?

    /// The list step names a code without handing it over, exactly as it does for a password. The code itself is asked for when the person chooses it.
    var isHidden: Bool { code == SystemPasswordsMessages.passwordNotIncluded }
}

nonisolated enum SystemPasswordsProtocolError: Error, Equatable {
    case malformed(String)
    case handshakeRejected(Int)
    case unsupportedProtocolVersion
    case wrongPIN
    case serverProofMismatch
    case transactionMismatch
}

nonisolated enum SystemPasswordLookup: Equatable {
    case password(String)
    /// The helper is still waiting for the person to authenticate.
    case pending
    case notFound
}

/// Everything said to and heard from Apple's password helper, as pure data. Request bodies are JSON in the order the helper's own
/// extension writes them; replies are read leniently because the helper sends some values as numbers or strings and some objects as JSON text.
nonisolated enum SystemPasswordsMessages {

    static let extensionOrigin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"
    static let browserName = "Orbit"
    static let protocolVersion = "1.0"
    static let passwordNotIncluded = "Not Included"
    static let placeholderUsername = "Passwords not saved"

    static let loginNamesQuery = "CmdGetLoginNames4URL"
    static let passwordQuery = "CmdGetPassword4LoginName"
    static let saveQuery = "CmdSetPassword4LoginName_URL"
    static let oneTimeCodesQuery = "CmdGetOneTimeCodes"
    static let didFillOneTimeCodeQuery = "CmdDidFillOneTimeCode"

    // MARK: - Outgoing

    static func capabilitiesRequest() -> Data {
        WireJSON.object([("cmd", .int(SystemPasswordsCommand.getCapabilities.rawValue))]).data
    }

    static func cancelPairingRequest() -> Data {
        WireJSON.object([("cmd", .int(SystemPasswordsCommand.cancelPairing.rawValue))]).data
    }

    /// A transaction id: 16 random bytes whose first byte is not zero, in the helper's encoding. Also the SRP identity.
    static func newTransactionID(encoding: SystemPasswordsBinaryEncoding, bytes: [UInt8]? = nil) -> String {
        var raw = bytes ?? SystemPasswordsCipher.randomBytes(16)
        if raw.first == 0 { raw[0] = 1 }
        return encoding.encode(raw)
    }

    static func clientKeyExchange(transactionID: String, publicKey: String) -> Data {
        let pake = WireJSON.object([
            ("TID", .string(transactionID)),
            ("MSG", .int(0)),
            ("A", .string(publicKey)),
            ("VER", .string(protocolVersion)),
            ("PROTO", .array([.int(0), .int(1)])),
        ])
        let inner = WireJSON.object([
            ("QID", .string("m0")),
            ("PAKE", .string(Data(pake.serialized.utf8).base64EncodedString())),
            ("HSTBRSR", .string(browserName)),
        ])
        return WireJSON.object([("cmd", .int(SystemPasswordsCommand.handshake.rawValue)), ("msg", .string(inner.serialized))]).data
    }

    static func clientVerification(transactionID: String, proof: String) -> Data {
        let pake = WireJSON.object([
            ("TID", .string(transactionID)),
            ("MSG", .int(2)),
            ("M", .string(proof)),
        ])
        let inner = WireJSON.object([
            ("QID", .string("m2")),
            ("HSTBRSR", .string(browserName)),
            ("PAKE", .string(Data(pake.serialized.utf8).base64EncodedString())),
        ])
        return WireJSON.object([("cmd", .int(SystemPasswordsCommand.handshake.rawValue)), ("msg", .string(inner.serialized))]).data
    }

    static func encryptedRequest(command: SystemPasswordsCommand, host: String?, query: String, transactionID: String, sdata: String) -> Data {
        let payload = WireJSON.object([
            ("QID", .string(query)),
            ("SMSG", .object([("TID", .string(transactionID)), ("SDATA", .string(sdata))])),
        ])
        var outer: [(String, WireJSON)] = [
            ("cmd", .int(command.rawValue)),
            ("tabId", .int(0)),
            ("frameId", .int(0)),
        ]
        if let host { outer.append(("url", .string(host))) }
        outer.append(("payload", .string(payload.serialized)))
        return WireJSON.object(outer).data
    }

    static func loginNamesBody(host: String) -> Data {
        WireJSON.object([("ACT", .int(SystemPasswordsAction.ghostSearch.rawValue)), ("URL", .string(host))]).data
    }

    static func passwordBody(host: String, username: String) -> Data {
        WireJSON.object([
            ("ACT", .int(SystemPasswordsAction.search.rawValue)),
            ("URL", .string(host)),
            ("USR", .string(username)),
        ]).data
    }

    static func saveBody(host: String, username: String, password: String) -> Data {
        WireJSON.object([
            ("ACT", .int(SystemPasswordsAction.maybeAdd.rawValue)),
            ("URL", .string("")),
            ("USR", .string("")),
            ("PWD", .string("")),
            ("NURL", .string(host)),
            ("NUSR", .string(username)),
            ("NPWD", .string(password)),
        ]).data
    }

    static func oneTimeCodesBody(pageURL: String, username: String?) -> Data {
        var pairs: [(String, WireJSON)] = [
            ("ACT", .int(SystemPasswordsAction.ghostSearch.rawValue)),
            ("TYPE", .string("oneTimeCodes")),
            ("frameURLs", .array([.string(pageURL)])),
        ]
        if let username, !username.isEmpty { pairs.append(("username", .string(username))) }
        return WireJSON.object(pairs).data
    }

    /// Asks for the code itself, for one username, once the person has chosen it from the list.
    static func oneTimeCodeSearchBody(pageURL: String, username: String?) -> Data {
        var pairs: [(String, WireJSON)] = [
            ("ACT", .int(SystemPasswordsAction.search.rawValue)),
            ("TYPE", .string("oneTimeCodes")),
            ("frameURLs", .array([.string(pageURL)])),
        ]
        if let username, !username.isEmpty {
            pairs.append(("USR", .string(username)))
            pairs.append(("username", .string(username)))
        }
        return WireJSON.object(pairs).data
    }

    static func didFillOneTimeCodeBody(pageURL: String, username: String) -> Data {
        WireJSON.object([
            ("ACT", .int(SystemPasswordsAction.search.rawValue)),
            ("TYPE", .string("oneTimeCodes")),
            ("frameURLs", .array([.string(pageURL)])),
            ("username", .string(username)),
        ]).data
    }

    // MARK: - Incoming

    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// An object, or a string holding one.
    static func nestedObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String { return object(from: Data(text.utf8)) }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func command(of message: [String: Any]) -> Int? {
        integer(message["cmd"])
    }

    private static func pake(of message: [String: Any]) throws -> [String: Any] {
        guard let payload = nestedObject(message["payload"]) else { throw SystemPasswordsProtocolError.malformed("handshake reply has no payload") }
        guard let encoded = payload["PAKE"] as? String,
              let decoded = Data(base64Encoded: encoded),
              let pake = object(from: decoded)
        else { throw SystemPasswordsProtocolError.malformed("handshake reply has no PAKE") }
        return pake
    }

    private static func speaksVersionOne(_ value: Any?) -> Bool {
        if let single = integer(value) { return single == 1 }
        if let list = value as? [Any] { return list.count == 1 && integer(list.first) == 1 }
        return false
    }

    nonisolated struct ServerKeyExchange: Equatable, Sendable {
        var transactionID: String
        var serverPublicKey: [UInt8]
        var salt: [UInt8]
    }

    static func serverKeyExchange(from message: [String: Any], encoding: SystemPasswordsBinaryEncoding) throws -> ServerKeyExchange {
        let pake = try pake(of: message)
        if let code = integer(pake["ErrCode"]), code != 0 { throw SystemPasswordsProtocolError.handshakeRejected(code) }
        guard integer(pake["MSG"]) == 1 else { throw SystemPasswordsProtocolError.malformed("expected the server key exchange") }
        guard speaksVersionOne(pake["PROTO"]) else { throw SystemPasswordsProtocolError.unsupportedProtocolVersion }
        guard let transactionID = pake["TID"] as? String,
              let serverText = pake["B"] as? String, let serverPublicKey = encoding.decode(serverText), !serverPublicKey.isEmpty,
              let saltText = pake["s"] as? String, let salt = encoding.decode(saltText), !salt.isEmpty
        else { throw SystemPasswordsProtocolError.malformed("server key exchange is missing TID, B or s") }
        return ServerKeyExchange(transactionID: transactionID, serverPublicKey: serverPublicKey, salt: salt)
    }

    nonisolated struct ServerVerification: Equatable, Sendable {
        var transactionID: String
        var serverProof: [UInt8]
    }

    static func serverVerification(from message: [String: Any], encoding: SystemPasswordsBinaryEncoding) throws -> ServerVerification {
        let pake = try pake(of: message)
        switch integer(pake["ErrCode"]) ?? 0 {
        case 0: break
        case 1: throw SystemPasswordsProtocolError.wrongPIN
        case let code: throw SystemPasswordsProtocolError.handshakeRejected(code)
        }
        guard integer(pake["MSG"]) == 3 else { throw SystemPasswordsProtocolError.malformed("expected the server verification") }
        guard let transactionID = pake["TID"] as? String,
              let proofText = pake["HAMK"] as? String, let proof = encoding.decode(proofText), !proof.isEmpty
        else { throw SystemPasswordsProtocolError.malformed("server verification is missing TID or HAMK") }
        return ServerVerification(transactionID: transactionID, serverProof: proof)
    }

    static func capabilities(from message: [String: Any]) -> SystemPasswordsCapabilities {
        var capabilities = SystemPasswordsCapabilities()
        guard let object = nestedObject(message["capabilities"]) else { return capabilities }
        capabilities.shouldUseBase64 = object["shouldUseBase64"] as? Bool ?? false
        capabilities.secretSessionVersion = integer(object["secretSessionVersion"])
        capabilities.canFillOneTimeCodes = object["canFillOneTimeCodes"] as? Bool ?? false
        capabilities.scanForOTPURI = object["scanForOTPURI"] as? Bool ?? false
        if let system = nestedObject(object["operatingSystem"]) {
            capabilities.operatingSystemName = system["name"] as? String
            capabilities.operatingSystemMajorVersion = integer(system["majorVersion"])
            capabilities.operatingSystemMinorVersion = integer(system["minorVersion"])
        }
        return capabilities
    }

    nonisolated struct EncryptedReply: Equatable, Sendable {
        var transactionID: String
        var sdata: String
    }

    static func encryptedReply(from message: [String: Any]) -> EncryptedReply? {
        guard let payload = nestedObject(message["payload"]),
              let smsg = nestedObject(payload["SMSG"]),
              let transactionID = smsg["TID"] as? String,
              let sdata = smsg["SDATA"] as? String
        else { return nil }
        return EncryptedReply(transactionID: transactionID, sdata: sdata)
    }

    static func status(of body: [String: Any]) -> SystemPasswordsStatus? {
        integer(body["STATUS"]).flatMap(SystemPasswordsStatus.init(rawValue:))
    }

    /// `Entries` as a list, or `Entry_0`, `Entry_1` and so on, each an object or JSON text, in order.
    static func entries(of body: [String: Any]) -> [[String: Any]] {
        if let list = body["Entries"] as? [Any] {
            return list.compactMap(nestedObject)
        }
        let numbered = body.keys.compactMap { key -> (Int, String)? in
            guard key.hasPrefix("Entry_"), let index = Int(key.dropFirst("Entry_".count)) else { return nil }
            return (index, key)
        }
        return numbered.sorted { $0.0 < $1.0 }.compactMap { nestedObject(body[$0.1]) }
    }

    private static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        return integer(value).map { $0 != 0 } ?? false
    }

    static func logins(from body: [String: Any]) -> [SystemPasswordLogin] {
        let bodyNeedsAuthentication = flag(body["RequiresUserAuthenticationToFill"])
        var seen = Set<String>()
        var logins: [SystemPasswordLogin] = []
        for entry in entries(of: body) {
            guard let username = entry["USR"] as? String, username != placeholderUsername else { continue }
            guard seen.insert(username).inserted else { continue }
            let sites = (entry["sites"] as? [Any])?.compactMap { $0 as? String } ?? []
            let title = (entry["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            logins.append(SystemPasswordLogin(
                username: username,
                sites: sites,
                customTitle: title,
                requiresAuthenticationToFill: bodyNeedsAuthentication || flag(entry["RequiresUserAuthenticationToFill"])
            ))
        }
        return logins
    }

    static func password(from body: [String: Any], username: String) -> SystemPasswordLookup {
        var candidates = entries(of: body)
        if candidates.isEmpty, body["PWD"] != nil { candidates = [body] }
        let matching = candidates.filter { ($0["USR"] as? String) == username }
        let chosen = matching.first ?? (candidates.count == 1 && candidates[0]["USR"] == nil ? candidates[0] : nil)
        guard let entry = chosen, let password = entry["PWD"] as? String else { return .notFound }
        if password == passwordNotIncluded { return .pending }
        return .password(password)
    }

    static func oneTimeCodes(from body: [String: Any]) -> [SystemPasswordOneTimeCode] {
        entries(of: body).compactMap { entry in
            guard let code = oneTimeCodeText(entry["code"]),
                  code == passwordNotIncluded || PasswordAutofillPolicy.isValidOneTimeCode(code) else { return nil }
            return SystemPasswordOneTimeCode(
                code: code,
                username: entry["username"] as? String,
                domain: entry["domain"] as? String,
                source: entry["source"] as? String
            )
        }
    }

    /// A code is text, but a helper that sends it as a number still means the digits.
    private static func oneTimeCodeText(_ value: Any?) -> String? {
        if let text = value as? String { return stripped(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    /// Codes are shown in groups ("123 456"), and a field wants the digits alone.
    private static func stripped(_ text: String) -> String {
        text == passwordNotIncluded ? text : text.filter { !$0.isWhitespace && $0 != "-" }
    }

    /// The code the helper returned for `username` after the person chose it: still pending while it waits for authentication.
    static func revealedOneTimeCode(from body: [String: Any], username: String?) -> SystemPasswordLookup {
        let candidates = oneTimeCodes(from: body)
        guard !candidates.isEmpty else { return .notFound }
        let matching = candidates.filter { username == nil || $0.username == username }
        guard let chosen = matching.first ?? (candidates.count == 1 ? candidates.first : nil) else { return .notFound }
        return chosen.isHidden ? .pending : .password(chosen.code)
    }
}
