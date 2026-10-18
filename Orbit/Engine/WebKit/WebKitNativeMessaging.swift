import Foundation
import OSLog
import WebKit

private let nativeMessagingLogger = Logger(subsystem: "com.orbit.browser", category: "WebKitNativeMessaging")

/// Chrome's stdio native messaging, for extensions that declare "nativeMessaging": host
/// manifests are looked up where Chrome and main's Orbit looked, `allowed_origins` is
/// checked against the caller, and messages are framed with a native-endian 32-bit length.
enum NativeMessagingHostError: Error, Equatable {
    case invalidName
    case notFound
    case forbidden
    case failedToStart
    case hostExited
    case communication

    /// Chrome's own strings, so extensions matching on them keep working.
    var message: String {
        switch self {
        case .invalidName: return "Invalid native messaging host name specified."
        case .notFound: return "Specified native messaging host not found."
        case .forbidden: return "Access to the specified native messaging host is forbidden."
        case .failedToStart: return "Failed to start native messaging host."
        case .hostExited: return "Native host has exited."
        case .communication: return "Error when communicating with the native messaging host."
        }
    }
}

struct NativeMessagingHostManifest: Equatable {
    let name: String
    let description: String
    let path: URL
    let allowedOrigins: [String]

    /// Mirrors main's OrbitNativeMessagingHostManifest::Parse.
    static func load(from file: URL) throws -> NativeMessagingHostManifest {
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromeExtensionAPIError("Invalid manifest file.")
        }
        guard let name = object["name"] as? String, NativeMessagingHosts.isValidName(name) else {
            throw ChromeExtensionAPIError("Invalid value for name.")
        }
        guard let description = object["description"] as? String, !description.isEmpty else {
            throw ChromeExtensionAPIError("Invalid value for description.")
        }
        guard object["type"] as? String == "stdio" else {
            throw ChromeExtensionAPIError("Invalid value for type.")
        }
        guard let path = object["path"] as? String, !path.isEmpty else {
            throw ChromeExtensionAPIError("Invalid value for path.")
        }
        guard let origins = object["allowed_origins"] as? [Any] else {
            throw ChromeExtensionAPIError("Invalid value for allowed_origins. Expected a list of strings.")
        }
        var allowed: [String] = []
        for entry in origins {
            guard let pattern = entry as? String else {
                throw ChromeExtensionAPIError("allowed_origins must be list of strings.")
            }
            guard let origin = Self.extensionOrigin(fromPattern: pattern) else {
                throw ChromeExtensionAPIError("Pattern \"\(pattern)\" is not allowed.")
            }
            allowed.append(origin)
        }
        // Chrome resolves a relative path against the manifest's own directory.
        let hostPath = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : file.deletingLastPathComponent().appendingPathComponent(path)
        return NativeMessagingHostManifest(name: name, description: description, path: hostPath.standardizedFileURL, allowedOrigins: allowed)
    }

    /// The allowed set is a fixed list of extensions: no wildcards, no subdomain matching.
    static func extensionOrigin(fromPattern pattern: String) -> String? {
        let prefix = "chrome-extension://"
        guard pattern.lowercased().hasPrefix(prefix) else { return nil }
        var remainder = String(pattern.dropFirst(prefix.count))
        if remainder.hasSuffix("/*") { remainder.removeLast(2) }
        if remainder.hasSuffix("/") { remainder.removeLast() }
        guard !remainder.isEmpty, !remainder.contains("*"), !remainder.contains("/") else { return nil }
        return prefix + remainder.lowercased() + "/"
    }

    func allows(origin: String) -> Bool {
        allowedOrigins.contains(origin.lowercased())
    }
}

enum NativeMessagingHosts {
    /// This process's data root, then Chrome, Chromium, and the machine-wide directory.
    private static let searchDirectoryList: [URL] = OrbitDataRoot.nativeMessagingHostDirectories

    static func searchDirectories() -> [URL] {
        searchDirectoryList
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        var previous: Character = "\0"
        var index = name.startIndex
        while index < name.endIndex {
            let character = name[index]
            let next = name.index(after: index)
            let allowed = (character >= "a" && character <= "z") || (character >= "0" && character <= "9")
                || character == "." || character == "_"
            guard allowed else { return false }
            if character == ".", index == name.startIndex || next == name.endIndex || previous == "." {
                return false
            }
            previous = character
            index = next
        }
        return true
    }

    static func resolve(name: String, origin: String) -> Result<NativeMessagingHostManifest, NativeMessagingHostError> {
        guard isValidName(name) else { return .failure(.invalidName) }
        let fileManager = FileManager.default
        guard let file = searchDirectories().lazy
            .map({ $0.appendingPathComponent("\(name).json") })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else { return .failure(.notFound) }
        let manifest: NativeMessagingHostManifest
        do {
            manifest = try NativeMessagingHostManifest.load(from: file)
        } catch {
            nativeMessagingLogger.error("Bad native messaging manifest for \(name, privacy: .public): \((error as? ChromeExtensionAPIError)?.message ?? error.localizedDescription, privacy: .public)")
            return .failure(.notFound)
        }
        guard manifest.name == name else { return .failure(.notFound) }
        guard manifest.allows(origin: origin) else { return .failure(.forbidden) }
        guard fileManager.isExecutableFile(atPath: manifest.path.path) else { return .failure(.notFound) }
        return .success(manifest)
    }
}

/// One running host. Reads and writes off the main thread; every callback lands on the main actor.
nonisolated final class NativeMessagingHostProcess: @unchecked Sendable {
    static let maximumIncomingMessageSize = 1024 * 1024

    private let manifest: NativeMessagingHostManifest
    private let origin: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeQueue = DispatchQueue(label: "com.orbit.native-messaging.write")
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var onMessage: (@MainActor (Any) -> Void)?
    private var onClose: (@MainActor (NativeMessagingHostError?) -> Void)?

    init(manifest: NativeMessagingHostManifest, origin: String) {
        self.manifest = manifest
        self.origin = origin
    }

    func start(onMessage: @escaping @MainActor (Any) -> Void, onClose: @escaping @MainActor (NativeMessagingHostError?) -> Void) throws {
        self.onMessage = onMessage
        self.onClose = onClose
        process.executableURL = manifest.path
        // The origin has to be the first argument.
        process.arguments = [origin]
        process.currentDirectoryURL = manifest.path.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        // The host's exit is seen as end-of-file on its stdout, after the last reply it wrote.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw NativeMessagingHostError.failedToStart
        }
        // Orbit's copies of the child's ends, or end-of-file never arrives.
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        // A host that exits early must turn the next write into an error, not a SIGPIPE that kills Orbit.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func send(_ message: Any) {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        } catch {
            finish(.communication)
            return
        }
        var length = UInt32(truncatingIfNeeded: body.count)
        var frame = Data()
        frame.reserveCapacity(MemoryLayout<UInt32>.size + body.count)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        let handle = input.fileHandleForWriting
        writeQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: frame)
            } catch {
                self?.finish(.communication)
            }
        }
    }

    /// Closing from Orbit's side: no close callback, the caller already knows.
    func terminate() {
        lock.lock()
        closed = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else {
            finish(.hostExited)
            return
        }
        var messages: [Any] = []
        var failure: NativeMessagingHostError?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        buffer.append(data)
        // One tail move for every complete frame in this read. Removing each frame from the
        // front copied the bytes still waiting behind it.
        var consumed = 0
        while buffer.count - consumed >= 4 {
            let header = buffer.startIndex + consumed
            let length = buffer[header ..< header + 4].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            guard length <= Self.maximumIncomingMessageSize else {
                failure = .communication
                break
            }
            guard buffer.count - consumed >= 4 + length else { break }
            let bodyStart = header + 4
            let body = buffer.subdata(in: bodyStart ..< bodyStart + length)
            guard let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
                failure = .communication
                break
            }
            messages.append(message)
            consumed += 4 + length
        }
        if consumed > 0 {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
        }
        lock.unlock()
        if !messages.isEmpty, let onMessage {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for message in messages { onMessage(message) }
                }
            }
        }
        if let failure {
            nativeMessagingLogger.error("Native messaging host \(self.manifest.name, privacy: .public) broke the protocol; closing")
            finish(failure)
        }
    }

    private func finish(_ error: NativeMessagingHostError?) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        guard let onClose else { return }
        // Delivered after any messages already queued, so a reply is never overtaken by the exit.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onClose(error) }
        }
    }
}

/// The engine's side of chrome.runtime.sendNativeMessage and connectNative for real hosts.
@MainActor
final class WebKitNativeMessaging {
    private var oneShots: [ObjectIdentifier: NativeMessagingHostProcess] = [:]
    private var connections: [ObjectIdentifier: (host: NativeMessagingHostProcess, port: WKWebExtension.MessagePort, extensionID: String)] = [:]

    static func origin(forExtensionID id: String) -> String {
        "chrome-extension://\(id.lowercased())/"
    }

    /// Starts the host, sends one message and answers with the host's first reply.
    func sendMessage(_ message: Any, to applicationIdentifier: String, extensionID: String, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        let origin = Self.origin(forExtensionID: extensionID)
        let manifest: NativeMessagingHostManifest
        switch NativeMessagingHosts.resolve(name: applicationIdentifier, origin: origin) {
        case .success(let found): manifest = found
        case .failure(let error):
            replyHandler(nil, ChromeExtensionAPIError(error.message))
            return
        }
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin)
        let key = ObjectIdentifier(host)
        var answered = false
        do {
            try host.start(onMessage: { [weak self] reply in
                guard !answered else { return }
                answered = true
                replyHandler(reply, nil)
                host.terminate()
                self?.oneShots[key] = nil
            }, onClose: { [weak self] error in
                self?.oneShots[key] = nil
                guard !answered else { return }
                answered = true
                replyHandler(nil, ChromeExtensionAPIError((error ?? .hostExited).message))
            })
        } catch {
            replyHandler(nil, ChromeExtensionAPIError(((error as? NativeMessagingHostError) ?? .failedToStart).message))
            return
        }
        oneShots[key] = host
        host.send(message)
    }

    /// Relays a connectNative port to a host for as long as both ends stay open.
    func connect(_ port: WKWebExtension.MessagePort, extensionID: String, completionHandler: @escaping ((any Error)?) -> Void) {
        let origin = Self.origin(forExtensionID: extensionID)
        let manifest: NativeMessagingHostManifest
        switch NativeMessagingHosts.resolve(name: port.applicationIdentifier ?? "", origin: origin) {
        case .success(let found): manifest = found
        case .failure(let error):
            completionHandler(ChromeExtensionAPIError(error.message))
            return
        }
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin)
        let key = ObjectIdentifier(port)
        do {
            try host.start(onMessage: { [weak port] message in
                port?.sendMessage(message, completionHandler: nil)
            }, onClose: { [weak self, weak port] error in
                self?.connections[key] = nil
                guard let port, !port.isDisconnected else { return }
                let reason = (error ?? .hostExited).message
                port.sendMessage(["__orbitDisconnectError": reason]) { _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !port.isDisconnected else { return }
                            port.disconnect(throwing: ChromeExtensionAPIError(reason))
                        }
                    }
                }
            })
        } catch {
            completionHandler(ChromeExtensionAPIError(((error as? NativeMessagingHostError) ?? .failedToStart).message))
            return
        }
        connections[key] = (host, port, extensionID)
        port.messageHandler = { [weak host] message, error in
            guard error == nil, let message else { return }
            host?.send(message)
        }
        port.disconnectHandler = { [weak self] _ in
            Task { @MainActor in
                self?.connections.removeValue(forKey: key)?.host.terminate()
            }
        }
        completionHandler(nil)
    }

    /// Unloading an extension closes every host it started.
    func closeAll(forExtensionID extensionID: String) {
        for (key, connection) in connections where connection.extensionID == extensionID {
            connections[key] = nil
            connection.host.terminate()
            if !connection.port.isDisconnected { connection.port.disconnect() }
        }
    }
}
