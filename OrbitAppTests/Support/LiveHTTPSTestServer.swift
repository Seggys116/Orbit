//  A real TLS origin presenting a refused cert (hand-encoded X.509 since LibreSSL's
//  `req` can't set arbitrary notBefore/notAfter), deliberately self-signed and expired.

import Foundation
import Security

final class LiveHTTPSTestServer {

    enum ServerError: Error, CustomStringConvertible {
        case keyGeneration(String)
        case signing(String)
        case pythonMissing
        case launchFailed(String)
        case noPort(String)

        var description: String {
            switch self {
            case .keyGeneration(let detail): return "key generation failed: \(detail)"
            case .signing(let detail): return "certificate signing failed: \(detail)"
            case .pythonMissing: return "no python3 interpreter found"
            case .launchFailed(let detail): return "server launch failed: \(detail)"
            case .noPort(let detail): return "server never reported a port: \(detail)"
            }
        }
    }

    struct Route {
        var contentType: String
        var body: String

        init(contentType: String = "text/html; charset=utf-8", body: String) {
            self.contentType = contentType
            self.body = body
        }
    }

    /// What the served certificate actually says, so a test asserts against
    /// these rather than against a copy of the same literals.
    struct CertificateFacts {
        var issuerCommonName: String
        var subjectCommonName: String
        var notBefore: Date
        var notAfter: Date
    }

    let port: UInt16
    let certificate: CertificateFacts

    private let process: Process
    private let directory: URL
    private var isStopped = false

    var baseURL: URL { URL(string: "https://127.0.0.1:\(port)")! }

    init(
        routes: [String: Route],
        issuerCommonName: String = "Orbit Test Untrusted CA",
        subjectCommonName: String = "127.0.0.1",
        notBefore: Date = Date(timeIntervalSince1970: 1_262_304_000),  // 2010-01-01
        notAfter: Date = Date(timeIntervalSince1970: 1_293_840_000)    // 2011-01-01
    ) throws {
        certificate = CertificateFacts(
            issuerCommonName: issuerCommonName,
            subjectCommonName: subjectCommonName,
            notBefore: notBefore,
            notAfter: notAfter
        )

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitLiveHTTPS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let material = try SelfSignedCertificate.make(
            issuerCommonName: issuerCommonName,
            subjectCommonName: subjectCommonName,
            notBefore: notBefore,
            notAfter: notAfter
        )
        let certificateURL = directory.appendingPathComponent("cert.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        try material.certificatePEM.write(to: certificateURL, atomically: true, encoding: .utf8)
        try material.privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)

        let scriptURL = directory.appendingPathComponent("server.py")
        try LiveHTTPSTestServer.serverScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let encodedRoutes = try JSONSerialization.data(
            withJSONObject: routes.mapValues { ["contentType": $0.contentType, "body": $0.body] }
        )

        guard let interpreter = LiveHTTPSTestServer.pythonInterpreter() else { throw ServerError.pythonMissing }

        let output = Pipe()
        process = Process()
        process.executableURL = interpreter
        process.arguments = [
            scriptURL.path,
            certificateURL.path,
            keyURL.path,
            String(data: encodedRoutes, encoding: .utf8) ?? "{}",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ServerError.launchFailed(String(describing: error))
        }

        // The script binds port 0 and prints the kernel's choice, so no
        // window exists for another process to take a port this side picked first.
        port = try LiveHTTPSTestServer.readPort(from: output, process: process)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    // MARK: - Launching

    private static func pythonInterpreter() -> URL? {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func readPort(from pipe: Pipe, process: Process) throws -> UInt16 {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let line = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[..<line], as: UTF8.self)
                guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)) else {
                    throw ServerError.noPort("unparseable first line \(text.debugDescription)")
                }
                return value
            }
            guard process.isRunning || !buffer.isEmpty else {
                throw ServerError.noPort("interpreter exited with status \(process.terminationStatus)")
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
            } else {
                buffer.append(chunk)
            }
        }
        throw ServerError.noPort("timed out")
    }

    private static let serverScript = """
    import http.server, json, ssl, sys

    routes = json.loads(sys.argv[3])

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            entry = routes.get(self.path.split("?")[0])
            if entry is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return
            body = entry["body"].encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", entry["contentType"])
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    """
}

// MARK: - Certificate generation

enum SelfSignedCertificate {

    struct Material {
        var certificatePEM: String
        var privateKeyPEM: String
    }

    static func make(
        issuerCommonName: String,
        subjectCommonName: String,
        notBefore: Date,
        notAfter: Date
    ) throws -> Material {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            // Never a keychain item: a test must not leave key material behind,
            // and nothing here needs a SecIdentity.
            kSecAttrIsPermanent as String: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw LiveHTTPSTestServer.ServerError.keyGeneration(String(describing: error?.takeRetainedValue()))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw LiveHTTPSTestServer.ServerError.keyGeneration("SecKeyCopyPublicKey returned nil")
        }
        guard let pkcs1PublicKey = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw LiveHTTPSTestServer.ServerError.keyGeneration(String(describing: error?.takeRetainedValue()))
        }
        guard let pkcs1PrivateKey = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw LiveHTTPSTestServer.ServerError.keyGeneration(String(describing: error?.takeRetainedValue()))
        }

        let signatureAlgorithm = MinimalDER.sequence([MinimalDER.oid([1, 2, 840, 113549, 1, 1, 11]), MinimalDER.null])
        let subjectPublicKeyInfo = MinimalDER.sequence([
            MinimalDER.sequence([MinimalDER.oid([1, 2, 840, 113549, 1, 1, 1]), MinimalDER.null]),
            MinimalDER.bitString(pkcs1PublicKey),
        ])

        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        serial[0] |= 0x01

        let tbs = MinimalDER.sequence([
            MinimalDER.explicit(0, MinimalDER.integer(2)),
            MinimalDER.integer(serial),
            signatureAlgorithm,
            name(commonName: issuerCommonName),
            MinimalDER.sequence([MinimalDER.utcTime(notBefore), MinimalDER.utcTime(notAfter)]),
            name(commonName: subjectCommonName),
            subjectPublicKeyInfo,
            MinimalDER.explicit(3, MinimalDER.sequence(extensions(subjectCommonName: subjectCommonName))),
        ])

        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error
        ) as Data? else {
            throw LiveHTTPSTestServer.ServerError.signing(String(describing: error?.takeRetainedValue()))
        }

        let certificate = MinimalDER.sequence([tbs, signatureAlgorithm, MinimalDER.bitString(signature)])
        return Material(
            certificatePEM: pem(label: "CERTIFICATE", der: certificate),
            privateKeyPEM: pem(label: "RSA PRIVATE KEY", der: pkcs1PrivateKey)
        )
    }

    private static func name(commonName: String) -> Data {
        MinimalDER.sequence([MinimalDER.set([MinimalDER.sequence([MinimalDER.oid([2, 5, 4, 3]), MinimalDER.utf8String(commonName)])])])
    }

    // subjectAltName is not optional, or Chromium rejects the certificate for
    // the name and the error under test changes.
    private static func extensions(subjectCommonName: String) -> [Data] {
        var result: [Data] = [
            extensionEntry(oid: [2, 5, 29, 19], critical: true, value: MinimalDER.sequence([])),
            extensionEntry(
                oid: [2, 5, 29, 15], critical: true,
                // digitalSignature + keyEncipherment, 6 unused bits.
                value: Data([0x03, 0x02, 0x05, 0xA0])
            ),
            extensionEntry(
                oid: [2, 5, 29, 37], critical: false,
                value: MinimalDER.sequence([MinimalDER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])
            ),
        ]
        if let octets = ipv4Octets(subjectCommonName) {
            result.append(
                extensionEntry(
                    oid: [2, 5, 29, 17], critical: false,
                    // GeneralNames { iPAddress [7] IMPLICIT OCTET STRING }
                    value: MinimalDER.sequence([MinimalDER.tlv(0x87, Data(octets))])
                )
            )
        } else {
            result.append(
                extensionEntry(
                    oid: [2, 5, 29, 17], critical: false,
                    // GeneralNames { dNSName [2] IMPLICIT IA5String }
                    value: MinimalDER.sequence([MinimalDER.tlv(0x82, Data(subjectCommonName.utf8))])
                )
            )
        }
        return result
    }

    private static func extensionEntry(oid: [UInt], critical: Bool, value: Data) -> Data {
        var parts = [MinimalDER.oid(oid)]
        if critical { parts.append(MinimalDER.boolean(true)) }
        parts.append(MinimalDER.octetString(value))
        return MinimalDER.sequence(parts)
    }

    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func pem(label: String, der: Data) -> String {
        let encoded = der.base64EncodedString()
        var lines: [String] = ["-----BEGIN \(label)-----"]
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 64, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        lines.append("-----END \(label)-----")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Minimal DER encoder

enum MinimalDER {

    static let null = Data([0x05, 0x00])

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func sequence(_ parts: [Data]) -> Data { tlv(0x30, parts.reduce(into: Data()) { $0.append($1) }) }

    static func set(_ parts: [Data]) -> Data { tlv(0x31, parts.reduce(into: Data()) { $0.append($1) }) }

    static func explicit(_ tagNumber: UInt8, _ content: Data) -> Data { tlv(0xA0 | tagNumber, content) }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining != 0
        if let first = bytes.first, first >= 0x80 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func integer(_ value: Data) -> Data {
        var bytes = Array(value)
        while bytes.count > 1, bytes[0] == 0, bytes[1] < 0x80 { bytes.removeFirst() }
        if let first = bytes.first, first >= 0x80 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func bitString(_ content: Data) -> Data {
        var payload = Data([0])
        payload.append(content)
        return tlv(0x03, payload)
    }

    static func octetString(_ content: Data) -> Data { tlv(0x04, content) }

    static func boolean(_ value: Bool) -> Data { Data([0x01, 0x01, value ? 0xFF : 0x00]) }

    static func utf8String(_ value: String) -> Data { tlv(0x0C, Data(value.utf8)) }

    static func oid(_ components: [UInt]) -> Data {
        guard components.count >= 2 else { return tlv(0x06, Data()) }
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var group: [UInt8] = [UInt8(component & 0x7F)]
            var remaining = component >> 7
            while remaining > 0 {
                group.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
                remaining >>= 7
            }
            bytes.append(contentsOf: group)
        }
        return tlv(0x06, Data(bytes))
    }

    // UTCTime, not GeneralizedTime: RFC 5280 requires it for any date before
    // 2050, which every date this file produces is.
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
