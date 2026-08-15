//  Swift half of chrome.bookmarks: pushes Orbit's Spaces as one tree and
//  performs every mutation the registry asks for.

import Foundation
import Observation
import OSLog

@MainActor
final class OrbitChromiumBookmarksBridge {

    static let shared = OrbitChromiumBookmarksBridge()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "BookmarksBridge")

    private var lastPushedJSON: String?
    private var pushScheduled = false

    private init() {}

    // Resolved per call, never captured: processRoot falls back to the real user profile.
    private var store: BrowserStore { AppEnvironment.processRoot.store }

    func install() {
        OrbitChromiumBridge.shared.setBookmarksRequestCallback(
            OrbitChromiumBookmarksBridge.requestTrampoline,
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        lastPushedJSON = nil
        pushSnapshot()
        observeStoreChanges()
    }

    func pushSnapshot() {
        let json = BookmarkTreeProjection.treeJSON(for: store.state)
        guard json != lastPushedJSON else { return }
        lastPushedJSON = json
        OrbitChromiumBridge.shared.setBookmarksTree(json: json)
    }

    // MARK: - Observation

    private func observeStoreChanges() {
        withObservationTracking {
            _ = store.state
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedulePush()
                self.observeStoreChanges()
            }
        }
    }

    // state changes on every navigation and title edit, so several in one turn coalesce
    // into one push, and pushSnapshot drops it entirely when the tree itself is unchanged.
    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            self.pushSnapshot()
        }
    }

    // MARK: - Requests

    private static let requestTrampoline: OrbitChromiumBridge.BookmarksRequestCallback = {
        opaque, methodPtr, argsPtr, reply, replyContext in
        let method = methodPtr.map { String(cString: $0) } ?? ""
        let argsJSON = argsPtr.map { String(cString: $0) } ?? "{}"
        MainActor.assumeIsolated {
            let bookmarks = opaque
                .map { Unmanaged<OrbitChromiumBookmarksBridge>.fromOpaque($0).takeUnretainedValue() }
                ?? OrbitChromiumBookmarksBridge.shared
            bookmarks.respond(
                bookmarks.perform(method: method, argsJSON: argsJSON), reply: reply, context: replyContext
            )
        }
    }

    private func perform(method: String, argsJSON: String) -> [String: String] {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        do {
            let id = try BookmarkMutationRouter.apply(method: method, args: args, store: store)
            pushSnapshot()
            return ["id": id.rawValue]
        } catch let error as BookmarkMutationError {
            pushSnapshot()
            return ["error": error.message]
        } catch {
            Self.logger.error("chrome.bookmarks \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return ["error": BookmarkErrors.unavailable]
        }
    }

    private func respond(
        _ payload: [String: String],
        reply: OrbitChromiumBridge.JSONReplyCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":"Bookmarks are not available."}"#
        json.withCString { reply?(context, $0) }
    }
}
