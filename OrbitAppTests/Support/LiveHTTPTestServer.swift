//  A tiny real HTTP/1.1 server on 127.0.0.1 for tests needing a genuine http://
//  navigation; also serves chunked/byte-range/precompressed bodies and a real RFC 6455 WebSocket.

import CryptoKit
import Darwin
import Foundation

final class LiveHTTPTestServer {

    struct RecordedRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    /// Every request head this server answered, in arrival order. Lets a test
    /// assert on what the real engine put on the wire, not just what the page reports.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RecordedRequest] = []

        func record(_ request: RecordedRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var all: [RecordedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func first(path: String) -> RecordedRequest? {
            all.first { $0.path == path }
        }
    }

    struct Route {
        let contentType: String
        let body: Data
        let extraHeaders: [String: String]
        let supportsRangeRequests: Bool

        init(contentType: String, body: String, extraHeaders: [String: String] = [:]) {
            self.contentType = contentType
            self.body = Data(body.utf8)
            self.extraHeaders = extraHeaders
            self.supportsRangeRequests = false
        }

        init(contentType: String, data: Data, extraHeaders: [String: String] = [:], supportsRangeRequests: Bool = false) {
            self.contentType = contentType
            self.body = data
            self.extraHeaders = extraHeaders
            self.supportsRangeRequests = supportsRangeRequests
        }
    }

    /// One write() per chunk with `interChunkDelay` between them, not the
    /// whole body at once, so the delay proves genuine progressive delivery.
    struct ChunkedRoute {
        let contentType: String
        let chunks: [Data]
        let interChunkDelay: TimeInterval

        init(contentType: String, chunks: [String], interChunkDelay: TimeInterval = 0.15) {
            self.contentType = contentType
            self.chunks = chunks.map { Data($0.utf8) }
            self.interChunkDelay = interChunkDelay
        }

        init(contentType: String, dataChunks: [Data], interChunkDelay: TimeInterval = 0.15) {
            self.contentType = contentType
            self.chunks = dataChunks
            self.interChunkDelay = interChunkDelay
        }
    }

    /// Answers `401` with `WWW-Authenticate` until the right `Authorization`
    /// arrives, then serves `route`. Every attempt lands in `requestLog`.
    struct AuthenticatedRoute {
        let realm: String
        let expectedAuthorization: String
        let route: Route

        init(realm: String, username: String, password: String, route: Route) {
            self.realm = realm
            let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
            self.expectedAuthorization = "Basic \(encoded)"
            self.route = route
        }
    }

    enum WebSocketBehavior {
        /// Sends `greeting` (if any) after the handshake, then echoes each
        /// text frame as "echo:<payload>"; "__orbit_server_close__" triggers a close instead.
        case echo(greeting: String?)
        /// Sends each of `messages` as its own text frame, `interval` apart,
        /// then waits for and acknowledges the client's close frame; no echoing.
        case serverPush(messages: [String], interval: TimeInterval)
    }

    enum ServerError: Error {
        case socketFailed(String)
    }

    /// Shared with every in-flight connection handler so a stalling route
    /// unblocks the moment stop() runs, instead of holding a queue thread forever.
    final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        func halt() {
            lock.lock()
            running = false
            lock.unlock()
        }
    }

    let port: UInt16
    let requestLog = RequestLog()

    private let listenSocket: Int32
    private let queue = DispatchQueue(label: "OrbitAppTests.LiveHTTPTestServer", attributes: .concurrent)
    private var isRunning = true

    private let liveness = Liveness()

    /// `stallingRoutes` accept and record the request but never answer, so a
    /// navigation stays pending; used to observe visible vs. committed URL. They unblock on stop().
    init(
        routes: [String: Route],
        chunkedRoutes: [String: ChunkedRoute] = [:],
        webSocketRoutes: [String: WebSocketBehavior] = [:],
        authenticatedRoutes: [String: AuthenticatedRoute] = [:],
        stallingRoutes: Set<String> = []
    ) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed("socket() failed: \(String(cString: strerror(errno)))") }
        listenSocket = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0 // ask the kernel for an ephemeral port

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw ServerError.socketFailed("bind() failed: \(String(cString: strerror(errno)))")
        }

        guard listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw ServerError.socketFailed("listen() failed: \(String(cString: strerror(errno)))")
        }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &actualLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw ServerError.socketFailed("getsockname() failed: \(String(cString: strerror(errno)))")
        }
        port = UInt16(bigEndian: actual.sin_port)

        let acceptSocket = fd
        let acceptRoutes = routes
        let acceptChunkedRoutes = chunkedRoutes
        let acceptWebSocketRoutes = webSocketRoutes
        let acceptAuthenticatedRoutes = authenticatedRoutes
        let acceptStallingRoutes = stallingRoutes
        let acceptRequestLog = requestLog
        let acceptLiveness = liveness
        queue.async { [weak self] in
            while self?.isRunning ?? false {
                let client = accept(acceptSocket, nil, nil)
                guard client >= 0 else { continue }
                self?.queue.async {
                    LiveHTTPTestServer.handle(
                        client: client,
                        routes: acceptRoutes,
                        chunkedRoutes: acceptChunkedRoutes,
                        webSocketRoutes: acceptWebSocketRoutes,
                        authenticatedRoutes: acceptAuthenticatedRoutes,
                        stallingRoutes: acceptStallingRoutes,
                        requestLog: acceptRequestLog,
                        liveness: acceptLiveness
                    )
                }
            }
        }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var webSocketBaseURL: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    func stop() {
        isRunning = false
        liveness.halt()
        Darwin.close(listenSocket)
    }

    // MARK: - Per-connection handling

    private static func handle(
        client: Int32,
        routes: [String: Route],
        chunkedRoutes: [String: ChunkedRoute],
        webSocketRoutes: [String: WebSocketBehavior],
        authenticatedRoutes: [String: AuthenticatedRoute],
        stallingRoutes: Set<String>,
        requestLog: RequestLog,
        liveness: Liveness
    ) {
        guard let head = readRequestHead(client) else {
            Darwin.close(client)
            return
        }
        requestLog.record(RecordedRequest(method: head.method, path: head.path, headers: head.headers))

        if stallingRoutes.contains(head.path) {
            while liveness.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
            Darwin.close(client)
            return
        }

        if let behavior = webSocketRoutes[head.path],
           (head.headers["upgrade"] ?? "").lowercased() == "websocket",
           let key = head.headers["sec-websocket-key"] {
            handleWebSocket(client: client, key: key, behavior: behavior)
            Darwin.close(client)
            return
        }

        defer { Darwin.close(client) }

        if let chunked = chunkedRoutes[head.path] {
            writeChunked(client: client, route: chunked)
            return
        }

        if let authenticated = authenticatedRoutes[head.path] {
            guard head.headers["authorization"] == authenticated.expectedAuthorization else {
                var response = "HTTP/1.1 401 Unauthorized\r\n"
                response += "WWW-Authenticate: Basic realm=\"\(authenticated.realm)\", charset=\"UTF-8\"\r\n"
                response += "Content-Type: text/html\r\n"
                response += "Content-Length: 0\r\n"
                response += "Connection: close\r\n\r\n"
                writeAll(client, Data(response.utf8))
                return
            }
            writeRoute(client: client, route: authenticated.route, head: head)
            return
        }

        guard let route = routes[head.path] else {
            writeAll(client, Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }

        writeRoute(client: client, route: route, head: head)
    }

    private static func writeRoute(
        client: Int32,
        route: Route,
        head: (method: String, path: String, headers: [String: String])
    ) {
        if route.supportsRangeRequests,
           let rangeHeader = head.headers["range"],
           let range = parseByteRange(rangeHeader, totalLength: route.body.count) {
            let slice = route.body.subdata(in: range)
            var response = "HTTP/1.1 206 Partial Content\r\n"
            response += "Content-Type: \(route.contentType)\r\n"
            response += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(route.body.count)\r\n"
            response += "Accept-Ranges: bytes\r\n"
            for (name, value) in route.extraHeaders { response += "\(name): \(value)\r\n" }
            response += "Content-Length: \(slice.count)\r\n"
            response += "Connection: close\r\n\r\n"
            var responseData = Data(response.utf8)
            responseData.append(slice)
            writeAll(client, responseData)
            return
        }

        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(route.contentType)\r\n"
        if route.supportsRangeRequests { response += "Accept-Ranges: bytes\r\n" }
        for (name, value) in route.extraHeaders { response += "\(name): \(value)\r\n" }
        response += "Content-Length: \(route.body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var responseData = Data(response.utf8)
        responseData.append(route.body)
        writeAll(client, responseData)
    }

    private static func writeChunked(client: Int32, route: ChunkedRoute) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(route.contentType)\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"
        writeAll(client, Data(head.utf8))

        for chunk in route.chunks {
            let sizeLine = String(chunk.count, radix: 16) + "\r\n"
            writeAll(client, Data(sizeLine.utf8))
            writeAll(client, chunk)
            writeAll(client, Data("\r\n".utf8))
            if route.interChunkDelay > 0 {
                Thread.sleep(forTimeInterval: route.interChunkDelay)
            }
        }
        writeAll(client, Data("0\r\n\r\n".utf8))
    }

    /// Handles "bytes=A-B"/"bytes=A-" and the suffix form "bytes=-N" (last N
    /// bytes). The empty first component of "-N" means suffix, not "start defaults to 0".
    private static func parseByteRange(_ header: String, totalLength: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), totalLength > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffixLength = Int(parts[1]), suffixLength > 0 else { return nil }
            let start = max(0, totalLength - suffixLength)
            return start..<totalLength
        }

        guard let start = Int(parts[0]), start >= 0, start < totalLength else { return nil }
        let end = min(totalLength - 1, parts[1].isEmpty ? totalLength - 1 : (Int(parts[1]) ?? totalLength - 1))
        guard start <= end else { return nil }
        return start..<(end + 1)
    }

    // MARK: - WebSocket (RFC 6455)

    private static let webSocketAcceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private static func handleWebSocket(client: Int32, key: String, behavior: WebSocketBehavior) {
        let digest = Insecure.SHA1.hash(data: Data((key + webSocketAcceptGUID).utf8))
        let accept = Data(digest).base64EncodedString()

        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        writeAll(client, Data(response.utf8))

        switch behavior {
        case let .echo(greeting):
            if let greeting { writeFrame(client, opcode: 0x1, payload: Data(greeting.utf8)) }
            runEchoLoop(client)
        case let .serverPush(messages, interval):
            for message in messages {
                writeFrame(client, opcode: 0x1, payload: Data(message.utf8))
                if interval > 0 { Thread.sleep(forTimeInterval: interval) }
            }
            waitForCloseAndAcknowledge(client)
        }
    }

    private static func runEchoLoop(_ client: Int32) {
        while true {
            guard let frame = readFrame(client) else { return }
            switch frame.opcode {
            case 0x8:
                writeFrame(client, opcode: 0x8, payload: frame.payload)
                return
            case 0x9:
                writeFrame(client, opcode: 0xA, payload: frame.payload)
            case 0x1, 0x2:
                let text = String(decoding: frame.payload, as: UTF8.self)
                if text == "__orbit_server_close__" {
                    writeFrame(client, opcode: 0x8, payload: Data())
                    return
                }
                writeFrame(client, opcode: 0x1, payload: Data("echo:\(text)".utf8))
            default:
                break
            }
        }
    }

    private static func waitForCloseAndAcknowledge(_ client: Int32) {
        guard let frame = readFrame(client), frame.opcode == 0x8 else { return }
        writeFrame(client, opcode: 0x8, payload: frame.payload)
    }

    private static func readFrame(_ client: Int32) -> (opcode: UInt8, payload: Data)? {
        guard let header = readExact(client, 2) else { return nil }
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var length = Int(header[1] & 0x7F)
        if length == 126 {
            guard let extended = readExact(client, 2) else { return nil }
            length = Int(extended[0]) << 8 | Int(extended[1])
        } else if length == 127 {
            guard let extended = readExact(client, 8) else { return nil }
            length = extended.reduce(0) { ($0 << 8) | Int($1) }
        }
        var maskKey: [UInt8] = []
        if masked {
            guard let key = readExact(client, 4) else { return nil }
            maskKey = key
        }
        guard let payloadBytes = readExact(client, length) else { return nil }
        var payload = payloadBytes
        if masked {
            for index in 0..<payload.count {
                payload[index] ^= maskKey[index % 4]
            }
        }
        return (opcode, Data(payload))
    }

    private static func writeFrame(_ client: Int32, opcode: UInt8, payload: Data) {
        var header: [UInt8] = [0x80 | opcode] // FIN=1, single-frame messages only -- every fixture message here fits in one.
        let count = payload.count
        if count <= 125 {
            header.append(UInt8(count))
        } else if count <= 0xFFFF {
            header.append(126)
            header.append(UInt8((count >> 8) & 0xFF))
            header.append(UInt8(count & 0xFF))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((count >> shift) & 0xFF))
            }
        }
        // Server-to-client frames must never be masked (RFC 6455 5.1).
        var data = Data(header)
        data.append(payload)
        writeAll(client, data)
    }

    private static func readExact(_ client: Int32, _ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(client, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            guard read > 0 else { return nil }
            offset += read
        }
        return buffer
    }

    // MARK: - Request line + headers

    private static func readRequestHead(_ client: Int32) -> (method: String, path: String, headers: [String: String])? {
        guard let requestLine = readLine(client) else { return nil }
        let components = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        let method = String(components[0])
        let path = String(components[1])

        var headers: [String: String] = [:]
        while let line = readLine(client), !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (method, path, headers)
    }

    private static func readLine(_ client: Int32) -> String? {
        var line = ""
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let count = read(client, &buffer, 1)
            guard count == 1 else { return line.isEmpty ? nil : line }
            let byte = buffer[0]
            if byte == UInt8(ascii: "\n") { return line }
            if byte != UInt8(ascii: "\r") { line.append(Character(UnicodeScalar(byte))) }
        }
    }

    private static func writeAll(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(client, base + offset, rawBuffer.count - offset)
                guard written > 0 else { break }
                offset += written
            }
        }
    }
}
