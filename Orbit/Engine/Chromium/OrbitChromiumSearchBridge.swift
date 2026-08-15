//  Answers chrome.search.query with Orbit's own configured search engine.

import AppKit
import Foundation
import OSLog

@MainActor
final class OrbitChromiumSearchBridge {

    static let shared = OrbitChromiumSearchBridge()

    /// `tab` carries the OrbitTabRegistry id the extension named, which may name no open tab.
    enum Target: Equatable {
        case currentTab
        case newTab
        case newWindow
        case tab(Int32)

        init(disposition: Int32) {
            switch disposition {
            case 1: self = .newTab
            case 2: self = .newWindow
            default: self = .currentTab
            }
        }
    }

    private static let noActiveBrowserError = "No active browser."
    private static let missingProviderError = "Missing default search provider."

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "SearchBridge")

    private init() {}

    func install() {
        var layout = OrbitSearchDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        // Never inline: this arrives re-entrantly from the extension function's
        // own call stack, and NEW_WINDOW builds an AppKit window from here.
        layout.query = { _, textPtr, disposition, hasTabID, tabID, callback, callbackOpaque in
            let text = textPtr.map { String(cString: $0) } ?? ""
            let target: Target = hasTabID != 0 ? .tab(tabID) : Target(disposition: disposition)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let error = OrbitChromiumSearchBridge.shared.perform(text: text, target: target)
                    error.withCString { callback?(callbackOpaque, $0) }
                }
            }
        }
        if !OrbitChromiumBridge.shared.setSearchDelegate(layout) {
            Self.logger.notice("chrome.search is unavailable in this Orbit Framework build")
        }
    }

    /// "" on success; anything else reaches the extension as runtime.lastError.
    func perform(text: String, target: Target) -> String {
        switch target {
        case .tab(let registryTabID):
            guard let tabID = OrbitChromiumTabsBridge.shared.tabUUID(for: registryTabID),
                  let environment = OrbitChromiumTabsBridge.shared.tabWindowOwner(for: registryTabID) as? AppEnvironment
            else { return "No tab with id: \(registryTabID)." }
            guard let url = searchURL(for: text, in: environment, space: environment.tab(tabID)?.spaceID)
            else { return Self.missingProviderError }
            environment.loadInTab(tabID, url: url)
            record(url: url, target: target, environment: environment, tabID: tabID)

        case .currentTab:
            let environment = AppEnvironment.frontmost
            guard let tabID = environment.activeTabID else { return Self.noActiveBrowserError }
            guard let url = searchURL(for: text, in: environment, space: environment.activeSpace?.id)
            else { return Self.missingProviderError }
            environment.loadInTab(tabID, url: url)
            record(url: url, target: target, environment: environment, tabID: tabID)

        case .newTab:
            let environment = AppEnvironment.frontmost
            guard let spaceID = environment.activeSpace?.id else { return Self.noActiveBrowserError }
            guard let url = searchURL(for: text, in: environment, space: spaceID)
            else { return Self.missingProviderError }
            let tabID = environment.openTab(url: url, in: spaceID, section: .today, activate: true)
            record(url: url, target: target, environment: environment, tabID: tabID)

        case .newWindow:
            // Resolved before the window exists, so an unusable query leaves no empty window behind.
            let host = AppEnvironment.frontmost
            guard host.activeSpace != nil else { return Self.noActiveBrowserError }
            guard let url = searchURL(for: text, in: host, space: host.activeSpace?.id)
            else { return Self.missingProviderError }
            let environment = OrbitWindowController.openNewWindow(on: host).session.environment
            guard let spaceID = environment.activeSpace?.id else { return Self.noActiveBrowserError }
            let tabID = environment.openTab(url: url, in: spaceID, section: .today, activate: true)
            record(url: url, target: target, environment: environment, tabID: tabID)
        }
        return ""
    }

    private func searchURL(for text: String, in environment: AppEnvironment, space spaceID: SpaceID?) -> URL? {
        environment.searchEngine(forSpace: spaceID).searchURL(for: text)
    }

    #if DEBUG
    struct Resolution {
        var url: URL
        var target: Target
        var environment: AppEnvironment
        var tabID: TabID
    }

    /// The URL the last query built and the surface it went to, so the live
    /// suite never has to wait on a results page.
    private(set) var _test_lastResolution: Resolution?

    func _test_forgetLastResolution() { _test_lastResolution = nil }
    #endif

    private func record(url: URL, target: Target, environment: AppEnvironment, tabID: TabID) {
        #if DEBUG
        _test_lastResolution = Resolution(url: url, target: target, environment: environment, tabID: tabID)
        #endif
    }
}
