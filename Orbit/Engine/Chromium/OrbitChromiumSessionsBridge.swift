//  Answers chrome.sessions against BrowserStore's real recently-closed list.

import Foundation

@MainActor
final class OrbitChromiumSessionsBridge {

    static let shared = OrbitChromiumSessionsBridge()

    private var changeObserver: NSObjectProtocol?

    private init() {}

    func install() {
        var layout = OrbitSessionsDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        layout.getRecentlyClosed = { _, maxResults, callback, callbackOpaque in
            MainActor.assumeIsolated {
                let json = OrbitChromiumSessionsBridge.shared.recentlyClosedJSON(maxResults: maxResults)
                json.withCString { callback?(callbackOpaque, $0) }
            }
        }
        layout.restore = { _, sessionIDPointer, callback, callbackOpaque in
            let sessionID = sessionIDPointer.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                let json = OrbitChromiumSessionsBridge.shared.restoreJSON(sessionID: sessionID)
                json.withCString { callback?(callbackOpaque, $0) }
            }
        }
        OrbitChromiumBridge.shared.setSessionsDelegate(layout)
        observeRecentlyClosedChanges()
    }

    private func observeRecentlyClosedChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .orbitRecentlyClosedDidChange, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { OrbitChromiumBridge.shared.sessionsNotifyChanged() }
        }
    }

    /// Resolved per call, never at install time: install runs before any window exists,
    /// and naming the process root then would build the wrong environment in a test host.
    private var environment: AppEnvironment { .frontmost }

    // MARK: - getRecentlyClosed

    private func recentlyClosedJSON(maxResults: Int32) -> String {
        recentlyClosedJSON(maxResults: maxResults, in: environment.store)
    }

    /// Split from the delegate entry point so a host-less test can drive it against a scratch store.
    func recentlyClosedJSON(maxResults: Int32, in store: BrowserStore) -> String {
        // Always a concrete count: C++ substitutes MAX_SESSION_RESULTS for an absent
        // filter, so 0 means the caller asked for none. A negative can no longer
        // reach here, and returning nothing is the safe reading if one does.
        let limit = min(Int(max(maxResults, 0)), store.recentlyClosedCapacity)

        var sessions: [[String: Any]] = []
        for record in store.recentlyClosedRecords.reversed() {
            guard sessions.count < limit else { break }
            guard let tab = store.tab(record.tabID) else { continue }
            sessions.append([
                "sessionId": record.tabID.uuidString,
                "lastModified": Int(record.closedAt.timeIntervalSince1970),
                "tab": closedTabValue(record: record, tab: tab),
            ])
        }
        return Self.encoded(sessions) ?? "[]"
    }

    // MARK: - restore

    private func restoreJSON(sessionID: String) -> String {
        let environment = self.environment
        let store = environment.store

        let record: ClosedTabRecord?
        if sessionID.isEmpty {
            record = store.recentlyClosedRecords.last
        } else if let tabID = UUID(uuidString: sessionID) {
            record = store.recentlyClosedRecords.last { $0.tabID == tabID }
        } else {
            record = nil
        }
        guard let record else {
            return Self.errorJSON(
                sessionID.isEmpty ? Self.noRecentlyClosedError : Self.invalidSessionIDError(sessionID)
            )
        }
        guard store.reopenClosedTab(record.tabID) else {
            return Self.errorJSON(Self.invalidSessionIDError(record.tabID.uuidString))
        }
        environment.activateTab(record.tabID)

        guard let tab = store.tab(record.tabID) else {
            return Self.errorJSON(Self.invalidSessionIDError(record.tabID.uuidString))
        }
        let session: [String: Any] = [
            "sessionId": record.tabID.uuidString,
            "lastModified": Int(Date().timeIntervalSince1970),
            "tab": restoredTabValue(tab: tab, in: store),
        ]
        return Self.encoded(session) ?? Self.errorJSON(Self.noSessionsAvailableError)
    }

    // MARK: - tabs.Tab payloads

    private func closedTabValue(record: ClosedTabRecord, tab: Tab) -> [String: Any] {
        let wasPinned = record.previousSection == .pinned
        let url = (wasPinned ? record.pinnedURL : nil) ?? tab.url
        let title = (wasPinned ? record.pinnedTitle : nil) ?? tab.displayTitle
        var value = Self.commonTabValue(tab: tab, url: url, title: title)
        // TAB_ID_NONE and WINDOW_ID_NONE: a closed tab is in no registry and no window.
        value["id"] = -1
        value["windowId"] = -1
        value["sessionId"] = record.tabID.uuidString
        value["index"] = -1
        value["active"] = false
        value["highlighted"] = false
        value["pinned"] = wasPinned
        value["discarded"] = true
        return value
    }

    /// `id` lets orbit_sessions_api.cc swap this for OrbitTabRegistry's own value,
    /// which is the one chrome.tabs would report for the now-live tab.
    private func restoredTabValue(tab: Tab, in store: BrowserStore) -> [String: Any] {
        var value = Self.commonTabValue(tab: tab, url: tab.url, title: tab.displayTitle)
        value["id"] = OrbitChromiumTabsBridge.shared.existingTabID(for: tab.id).map { Int($0) } ?? -1
        value["windowId"] = -1
        value["index"] = store.todayTabs(in: tab.spaceID).firstIndex { $0.id == tab.id } ?? -1
        value["active"] = true
        value["highlighted"] = true
        value["pinned"] = tab.section == .pinned
        value["discarded"] = false
        return value
    }

    private static func commonTabValue(tab: Tab, url: URL, title: String) -> [String: Any] {
        var value: [String: Any] = [
            "url": url.absoluteString,
            "title": title,
            "incognito": false,
            "autoDiscardable": true,
            "frozen": false,
            "groupId": -1,
            "mutedInfo": ["muted": tab.isMuted],
        ]
        if let faviconURL = tab.faviconURL {
            value["favIconUrl"] = faviconURL.absoluteString
        }
        return value
    }

    // MARK: - Errors

    private static let noRecentlyClosedError = "There are no recently closed sessions."
    private static let noSessionsAvailableError = "Recently closed sessions are not available."

    private static func invalidSessionIDError(_ sessionID: String) -> String {
        "Invalid session id: \"\(sessionID)\"."
    }

    private static func errorJSON(_ message: String) -> String {
        encoded(["error": message]) ?? "{\"error\":\"\(noSessionsAvailableError)\"}"
    }

    private static func encoded(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
