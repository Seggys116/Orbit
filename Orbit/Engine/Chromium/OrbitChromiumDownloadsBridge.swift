import AppKit
import Foundation
import OSLog
import Observation

@MainActor
final class OrbitChromiumDownloadsBridge {

    static let shared = OrbitChromiumDownloadsBridge()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "DownloadsBridge")

    private enum RequestError: String {
        case invalidID = "Invalid downloadId"
        case fileAlreadyDeleted = "Download file already deleted"
        case fileNotRemoved = "Unable to remove file"
    }

    private var lastPushedJSON: String?
    private var observationGeneration = 0

    private init() {}

    // Resolved per call, never captured: a live test repoints processRoot at its own scratch profile.
    private var store: DownloadStore { AppEnvironment.processRoot.downloadStore }

    func install() {
        OrbitChromiumBridge.shared.setDownloadsRequestCallback(
            OrbitChromiumDownloadsBridge.requestTrampoline,
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        lastPushedJSON = nil
        observationGeneration += 1
        pushSnapshot()
        observeStoreChanges(generation: observationGeneration)
    }

    func pushSnapshot() {
        let json = DownloadItemProjection.itemsJSON(for: store.downloads)
        guard json != lastPushedJSON else { return }
        lastPushedJSON = json
        OrbitChromiumBridge.shared.setDownloadsItems(json: json)
    }

    private func observeStoreChanges(generation: Int) {
        let store = self.store
        withObservationTracking {
            _ = store.downloads
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration else { return }
                self.pushSnapshot()
                self.observeStoreChanges(generation: generation)
            }
        }
    }

    // MARK: - Requests (C++ -> Swift)

    private static let requestTrampoline: OrbitChromiumBridge.DownloadsRequestCallback = {
        opaque, methodPtr, argsPtr, reply, replyContext in
        let method = methodPtr.map { String(cString: $0) } ?? ""
        let argsJSON = argsPtr.map { String(cString: $0) } ?? ""
        guard let opaque else {
            OrbitChromiumDownloadsBridge.send(reply, replyContext, json: #"{"error":"Invalid downloadId"}"#)
            return
        }
        let bridge = Unmanaged<OrbitChromiumDownloadsBridge>.fromOpaque(opaque).takeUnretainedValue()
        MainActor.assumeIsolated {
            let failure = bridge.perform(method: method, argsJSON: argsJSON)
            bridge.pushSnapshot()
            let json = failure.map { OrbitChromiumDownloadsBridge.errorJSON($0.rawValue) } ?? #"{"ok":true}"#
            OrbitChromiumDownloadsBridge.send(reply, replyContext, json: json)
        }
    }

    private static func send(
        _ reply: OrbitChromiumBridge.JSONReplyCallback?, _ context: UnsafeMutableRawPointer?, json: String
    ) {
        guard let reply else { return }
        json.withCString { reply(context, $0) }
    }

    private static func errorJSON(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"error":"Invalid downloadId"}"# }
        return json
    }

    private func perform(method: String, argsJSON: String) -> RequestError? {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]

        switch method {
        case "showDefaultFolder":
            _ = NSWorkspace.shared.open(OrbitChromiumDownloadsBridge.downloadsDirectory())
            return nil

        case "erase":
            guard let guids = arguments?["guids"] as? [String] else { return .invalidID }
            for guid in guids {
                guard let item = item(forGUID: guid) else { continue }
                store.remove(item.id)
            }
            return nil

        case "open":
            guard let item = item(forGUID: arguments?["guid"] as? String ?? "") else { return .invalidID }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return .fileAlreadyDeleted }
            if !NSWorkspace.shared.open(item.destinationURL) {
                Self.logger.error("chrome.downloads.open could not launch \(item.destinationURL.path, privacy: .public)")
            }
            return nil

        case "show":
            guard let item = item(forGUID: arguments?["guid"] as? String ?? "") else { return .invalidID }
            store.revealInFinder(item.id)
            return nil

        case "removeFile":
            guard let item = item(forGUID: arguments?["guid"] as? String ?? "") else { return .invalidID }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return .fileAlreadyDeleted }
            guard store.removeFile(item.id) else { return .fileNotRemoved }
            return nil

        default:
            return .invalidID
        }
    }

    private func item(forGUID guid: String) -> DownloadItem? {
        guard let uuid = UUID(uuidString: guid) else { return nil }
        return store.downloads.first { $0.id == uuid }
    }

    private static func downloadsDirectory() -> URL {
        (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
