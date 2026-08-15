//  Answers chrome.history against Orbit's HistoryStore and pushes
//  onVisited/onVisitRemoved back. Every time crossing the ABI is milliseconds.

import Foundation
import OSLog

@MainActor
final class OrbitChromiumHistoryBridge {

    private typealias Result = OrbitHistoryDelegateLayout.Result
    private typealias SearchFn =
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Result?, UnsafeMutableRawPointer?) -> Void
    private typealias GetVisitsFn = SearchFn
    private typealias DeleteUrlFn = SearchFn
    private typealias AddUrlFn =
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Result?, UnsafeMutableRawPointer?) -> Void
    private typealias DeleteRangeFn =
        @convention(c) (UnsafeMutableRawPointer?, Double, Double, Result?, UnsafeMutableRawPointer?) -> Void
    private typealias DeleteAllFn =
        @convention(c) (UnsafeMutableRawPointer?, Result?, UnsafeMutableRawPointer?) -> Void

    static let shared = OrbitChromiumHistoryBridge()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "HistoryBridge")

    private var isInstalled = false

    private init() {}

    func install() {
        guard !isInstalled else { return }

        var layout = OrbitHistoryDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        layout.search = Self.searchTrampoline
        layout.getVisits = Self.getVisitsTrampoline
        layout.addUrl = Self.addUrlTrampoline
        layout.deleteUrl = Self.deleteUrlTrampoline
        layout.deleteRange = Self.deleteRangeTrampoline
        layout.deleteAll = Self.deleteAllTrampoline
        // False when the loaded framework exports no OrbitSetHistoryDelegate; nothing to push events to.
        isInstalled = OrbitChromiumBridge.shared.setHistoryDelegate(layout)
    }

    // MARK: - Push (Orbit's own history -> chrome.history events)

    func notifyVisited(_ row: HistoryStore.HistoryURLRow) {
        guard isInstalled else { return }
        guard let json = Self.encode(Self.historyItem(row)) else { return }
        OrbitChromiumBridge.shared.historyNotifyVisited(json: json)
    }

    private func notifyVisitRemoved(allHistory: Bool, urls: [URL]) {
        guard isInstalled else { return }
        guard allHistory || !urls.isEmpty else { return }
        let json = Self.encode(urls.map(\.absoluteString)) ?? "[]"
        OrbitChromiumBridge.shared.historyNotifyVisitRemoved(allHistory: allHistory, urlsJSON: json)
    }

    // MARK: - Delegate (chrome.history -> Orbit)

    private var environment: AppEnvironment { AppEnvironment.processRoot }

    private func search(_ queryJSON: String) async -> String {
        guard let store = environment.chromiumHistoryStore else { return "" }
        guard let query = Self.decode(queryJSON) else { return "" }

        let text = query["text"] as? String ?? ""
        let start = Self.date(query["startTime"])
        let end = Self.date(query["endTime"])
        let maxResults = (query["maxResults"] as? NSNumber).map { max($0.intValue, 0) } ?? 100
        guard maxResults > 0 else { return "[]" }

        do {
            let rows = try await store.urlRows(matchingText: text, start: start, end: end, limit: maxResults)
            return Self.encode(rows.map(Self.historyItem)) ?? ""
        } catch {
            Self.logger.error("chrome.history.search failed: \(String(describing: error), privacy: .public)")
            return ""
        }
    }

    private func getVisits(_ urlString: String) async -> String {
        guard let store = environment.chromiumHistoryStore else { return "" }
        guard let url = URL(string: urlString) else { return "" }
        do {
            let visits = try await store.visitRows(forURL: url)
            return Self.encode(visits.map(Self.visitItem)) ?? ""
        } catch {
            Self.logger.error("chrome.history.getVisits failed: \(String(describing: error), privacy: .public)")
            return ""
        }
    }

    private func addUrl(_ urlString: String, title: String) async -> String {
        guard let url = URL(string: urlString) else { return Self.failure("Url is invalid.") }
        let environment = self.environment
        guard environment.chromiumHistoryStore != nil else { return Self.failure("History is not available.") }
        guard let space = environment.activeSpace else {
            return Self.failure("No active Space to record the visit in.")
        }
        let row = await environment.recordVisitReportingItem(
            url: url, title: title, profileID: space.profileID, spaceID: space.id
        )
        guard row != nil else {
            return Self.failure("Orbit did not record the visit; this Space keeps no history.")
        }
        return Self.ok
    }

    private func deleteURL(_ urlString: String) async -> String {
        guard let url = URL(string: urlString) else { return Self.failure("Url is invalid.") }
        let environment = self.environment
        guard let store = environment.chromiumHistoryStore else { return Self.failure("History is not available.") }
        do {
            let removed = try await store.deleteEntries(matching: url)
            await environment.reloadHistoryCacheAfterBulkImport()
            if removed {
                notifyVisitRemoved(allHistory: false, urls: [url])
            }
            return Self.ok
        } catch {
            return Self.failure("Orbit could not delete \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    private func deleteRange(startMilliseconds: Double, endMilliseconds: Double) async -> String {
        let environment = self.environment
        guard let store = environment.chromiumHistoryStore else { return Self.failure("History is not available.") }
        let start = Date(timeIntervalSince1970: startMilliseconds / 1000)
        let end = Date(timeIntervalSince1970: endMilliseconds / 1000)
        guard start <= end else { return Self.ok }
        do {
            let purged = try await store.deleteVisits(in: start...end)
            await environment.reloadHistoryCacheAfterBulkImport()
            notifyVisitRemoved(allHistory: false, urls: purged)
            return Self.ok
        } catch {
            return Self.failure("Orbit could not delete that range: \(error.localizedDescription)")
        }
    }

    private func deleteAll() async -> String {
        guard await environment.clearAllHistory() else {
            return Self.failure("Orbit could not clear its history.")
        }
        notifyVisitRemoved(allHistory: true, urls: [])
        return Self.ok
    }

    // MARK: - Trampolines

    /// The one exit: `body` yields a String on every path, so the C++ callback runs exactly once.
    private static func reply(
        _ callback: Result?,
        _ callbackOpaque: UnsafeMutableRawPointer?,
        _ body: @escaping @MainActor () async -> String
    ) {
        guard let callback else { return }
        Task { @MainActor in
            let json = await body()
            json.withCString { callback(callbackOpaque, $0) }
        }
    }

    private static let searchTrampoline: SearchFn = { _, queryPtr, callback, callbackOpaque in
        let query = queryPtr.map { String(cString: $0) } ?? ""
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.search(query)
        }
    }

    private static let getVisitsTrampoline: GetVisitsFn = { _, urlPtr, callback, callbackOpaque in
        let url = urlPtr.map { String(cString: $0) } ?? ""
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.getVisits(url)
        }
    }

    private static let addUrlTrampoline: AddUrlFn = { _, urlPtr, titlePtr, callback, callbackOpaque in
        let url = urlPtr.map { String(cString: $0) } ?? ""
        let title = titlePtr.map { String(cString: $0) } ?? ""
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.addUrl(url, title: title)
        }
    }

    private static let deleteUrlTrampoline: DeleteUrlFn = { _, urlPtr, callback, callbackOpaque in
        let url = urlPtr.map { String(cString: $0) } ?? ""
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.deleteURL(url)
        }
    }

    private static let deleteRangeTrampoline: DeleteRangeFn = { _, start, end, callback, callbackOpaque in
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.deleteRange(
                startMilliseconds: start, endMilliseconds: end
            )
        }
    }

    private static let deleteAllTrampoline: DeleteAllFn = { _, callback, callbackOpaque in
        OrbitChromiumHistoryBridge.reply(callback, callbackOpaque) {
            await OrbitChromiumHistoryBridge.shared.deleteAll()
        }
    }

    // MARK: - Payloads

    private static let ok = "{\"ok\":true}"

    private static func failure(_ message: String) -> String {
        encode(["error": message]) ?? "{\"error\":\"The history operation failed.\"}"
    }

    private static func historyItem(_ row: HistoryStore.HistoryURLRow) -> [String: Any] {
        [
            "id": String(row.id),
            "url": row.url.absoluteString,
            "title": row.title,
            "lastVisitTime": row.lastVisit.timeIntervalSince1970 * 1000,
            "visitCount": row.visitCount,
            "typedCount": row.typedCount,
        ]
    }

    private static func visitItem(_ visit: HistoryStore.HistoryVisitRow) -> [String: Any] {
        [
            "id": String(visit.urlID),
            "visitId": String(visit.id),
            "visitTime": visit.visitTime.timeIntervalSince1970 * 1000,
            "referringVisitId": "0",
            "transition": visit.wasTyped ? "typed" : "link",
            "isLocal": true,
        ]
    }

    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    private static func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
