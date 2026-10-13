import Foundation
@testable import Orbit

// Test-only stand-ins for the Chromium bridges removed from the app. Live suites
// skip unless ORBIT_LIVE_ENGINE is set. The tab id map stays here so the
// registry tests still have a subject.

enum ChromiumBuild {
    static let version = "120.0.0.0"
    static let majorVersion = 120
    static let userAgentProduct = "Chrome/120"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

enum ChromiumTabsSetup {
    static let installHandlerOnce: Void = ()
}

@MainActor
final class ChromiumTabsRouter {
    static let shared = ChromiumTabsRouter()
    func chromiumAdoptExtensionTab(
        handle: UnsafeMutableRawPointer, url: String, extensionID: String, disposition: Int, userGesture: Bool
    ) -> Bool { false }
    static func resolve(_ id: Int32) {}
}

enum OrbitWindowState: String {
    case normal, minimized, maximized, fullscreen
}

@MainActor
final class OrbitChromiumBridge {
    static let shared = OrbitChromiumBridge()
    var contentBlockingDecisionHandler: ((String, String, Int) -> ContentBlockingDecision)?
    var extensionActionHandler: (() -> Void)?
    var extensionCommandsHandler: (() -> Void)?
    var browserReadyHandler: (() -> Void)?
    var searchSuggestEnabledHandler: (() -> Void)?
    var isReady = false
    var hasNewContentRequestCallback = false
    var supportsColorScheme = false
    func togglePictureInPicture(_ handle: UnsafeMutableRawPointer) -> Bool {
        let contents = Unmanaged<WebKitWebContents>.fromOpaque(handle).takeUnretainedValue()
        contents.togglePictureInPicture()
        return true
    }
}

@MainActor
final class OrbitChromiumBookmarksBridge {
    static let shared = OrbitChromiumBookmarksBridge()
    func install() {}
}

@MainActor
final class OrbitChromiumDownloadsBridge {
    static let shared = OrbitChromiumDownloadsBridge()
    func install() {}
}

@MainActor
final class OrbitChromiumHistoryBridge {
    static let shared = OrbitChromiumHistoryBridge()
    func install() {}
}

@MainActor
final class OrbitChromiumSearchBridge {
    static let shared = OrbitChromiumSearchBridge()

    enum Target: Equatable {
        case currentTab
        case newTab
        case newWindow
        case tab(Int32)
    }

    struct Resolution {
        var url: URL
        var target: Target
        var environment: AppEnvironment
        var tabID: TabID
    }

    private(set) var _test_lastResolution: Resolution?

    func _test_forgetLastResolution() { _test_lastResolution = nil }

    func perform(text: String, target: Target) -> String {
        switch target {
        case .tab(let id):
            return "No tab with id: \(id)."
        case .currentTab, .newTab, .newWindow:
            return "No active browser window."
        }
    }
}

@MainActor
final class OrbitChromiumSessionsBridge {
    static let shared = OrbitChromiumSessionsBridge()
    func recentlyClosedJSON(maxResults: Int32, in store: BrowserStore) -> String { "[]" }
}

@MainActor
final class OrbitChromiumTabsBridge {
    static let shared = OrbitChromiumTabsBridge()

    private struct TabRecord {
        var uuid: UUID
        var owner: AnyObject
    }

    private var nextTabID: Int32 = 1
    private var nextWindowID: Int32 = 1
    private var allocatedTabs: [UUID: Int32] = [:]
    private var createdTabs: [Int32: TabRecord] = [:]
    private var windows: [ObjectIdentifier: Int32] = [:]
    private var windowOwners: [Int32: AnyObject] = [:]

    func _test_tabID(for uuid: UUID) -> Int32 {
        if let existing = allocatedTabs[uuid] { return existing }
        let id = nextTabID
        nextTabID += 1
        allocatedTabs[uuid] = id
        return id
    }

    func _test_windowID(for owner: AnyObject) -> Int32 {
        let key = ObjectIdentifier(owner)
        if let existing = windows[key] { return existing }
        let id = nextWindowID
        nextWindowID += 1
        windows[key] = id
        windowOwners[id] = owner
        return id
    }

    func _test_registeredTabIDs(ownedBy owner: AnyObject) -> [Int32] {
        createdTabs.compactMap { id, record in record.owner === owner ? id : nil }
    }

    func existingTabID(for uuid: UUID) -> Int32? {
        createdTabs.first { $0.value.uuid == uuid }?.key
    }

    func tabUUID(for id: Int32) -> UUID? { createdTabs[id]?.uuid }

    func tabWindowOwner(for id: Int32) -> AnyObject? { createdTabs[id]?.owner }

    func isWindowRegistered(_ owner: AnyObject) -> Bool {
        windows[ObjectIdentifier(owner)] != nil
    }

    func windowOwner(for id: Int32) -> AnyObject? { windowOwners[id] }

    func tabCreated(
        tabUUID: UUID, handle: UnsafeMutableRawPointer, windowOwner: AnyObject,
        index: Int, active: Bool, pinned: Bool
    ) {
        let id = nextTabID
        nextTabID += 1
        allocatedTabs[tabUUID] = id
        createdTabs[id] = TabRecord(uuid: tabUUID, owner: windowOwner)
    }

    func tabMoved(tabUUID: UUID, windowOwner: AnyObject, fromIndex: Int, toIndex: Int) {}

    func tabRemoved(tabUUID: UUID, windowClosing: Bool) {
        guard let id = existingTabID(for: tabUUID) else { return }
        createdTabs[id] = nil
        allocatedTabs[tabUUID] = nil
    }

    func windowCreated(owner: AnyObject, focused: Bool) {
        _ = _test_windowID(for: owner)
    }

    func windowRemoved(owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if let id = windows.removeValue(forKey: key) {
            windowOwners[id] = nil
        }
    }

    func windowFocusChanged(owner: AnyObject?) {}

    func windowStateChanged(owner: AnyObject, state: OrbitWindowState) {}
}
