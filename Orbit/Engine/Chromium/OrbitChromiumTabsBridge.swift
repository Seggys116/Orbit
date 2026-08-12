//  Swift half of chrome.tabs/chrome.windows: allocates stable Int32 ids for
//  OrbitTabRegistry and answers its delegate calls; `handler` is AppEnvironment.

import Foundation

/// Implemented by whatever owns Orbit's real tab store (AppEnvironment).
/// Every method runs on the main actor, synchronously, re-entrantly from
/// within the C++ call stack handling the extension's API call.
@MainActor
protocol OrbitChromiumTabsBridgeHandler: AnyObject {
    /// Returns the new tab's OrbitWebContentsHandle (already wired up via
    /// tabCreated below) and its assigned tab id, or nil if windowID names
    /// no open Orbit window.
    func chromiumCreateTab(windowID: Int32, url: String, active: Bool, pinned: Bool)
        -> (handle: UnsafeMutableRawPointer, tabID: Int32)?
    func chromiumUpdateTabURL(tabID: Int32, url: String) -> Bool
    func chromiumActivateTab(tabID: Int32) -> Bool
    func chromiumRemoveTab(tabID: Int32) -> Bool
    func chromiumSetTabPinned(tabID: Int32, pinned: Bool) -> Bool

    /// `handle` already wraps a real, adopted content::WebContents. Returning
    /// true obligates the caller to materialize it as a real tab and call
    /// tabCreated(_:); returning false destroys `handle` and shows nothing.
    func chromiumAdoptExtensionTab(
        handle: UnsafeMutableRawPointer, url: String, extensionID: String, disposition: Int32, userGesture: Bool
    ) -> Bool
}

/// windows.json's WindowState enum, as chrome.windows reports Window.state.
enum OrbitWindowState: String {
    case normal
    case minimized
    case maximized
    case fullscreen
}

@MainActor
final class OrbitChromiumTabsBridge {

    static let shared = OrbitChromiumTabsBridge()

    weak var handler: OrbitChromiumTabsBridgeHandler?

    private let bridge = OrbitChromiumBridge.shared

    // 0 is reserved (means "none" throughout the C ABI -- see
    // orbit_bridge_api.h), so allocation starts at 1.
    private var nextTabID: Int32 = 1
    private var nextWindowID: Int32 = 1
    private var tabIDsByUUID: [UUID: Int32] = [:]
    private var windowIDsByObjectID: [ObjectIdentifier: Int32] = [:]

    // Reverse of the two maps above; populated only by tabCreated/windowCreated,
    // so an entry exists only for what is actually in OrbitTabRegistry.
    private var tabUUIDsByID: [Int32: UUID] = [:]
    private var tabOwnersByID: [Int32: AnyObject] = [:]
    private var windowOwnersByID: [Int32: AnyObject] = [:]

    private init() {
        installDelegate()
        bridge.setExtensionTabRequestCallback(
            OrbitChromiumTabsBridge.extensionTabRequestTrampoline,
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - Id allocation

    #if DEBUG
    /// Test-only entry point for the allocator itself, since the real
    /// entry points (tabCreated, windowCreated, ...) require a live
    /// OrbitWebContentsHandle / window owner this unit doesn't have.
    func _test_tabID(for tabUUID: UUID) -> Int32 { tabID(for: tabUUID) }
    func _test_windowID(for owner: AnyObject) -> Int32 { windowID(for: owner) }
    /// The tabs still in OrbitTabRegistry under `owner` — what a live suite's
    /// teardown checks to prove it released everything it materialised.
    func _test_registeredTabIDs(ownedBy owner: AnyObject) -> [Int32] {
        tabOwnersByID.filter { $0.value === owner }.keys.sorted()
    }
    #endif

    private func tabID(for tabUUID: UUID) -> Int32 {
        if let existing = tabIDsByUUID[tabUUID] { return existing }
        let id = nextTabID
        nextTabID += 1
        tabIDsByUUID[tabUUID] = id
        return id
    }

    private func windowID(for owner: AnyObject) -> Int32 {
        let key = ObjectIdentifier(owner)
        if let existing = windowIDsByObjectID[key] { return existing }
        let id = nextWindowID
        nextWindowID += 1
        windowIDsByObjectID[key] = id
        return id
    }

    // MARK: - Reverse lookup (extension request -> Swift owner)

    /// Only ever non-nil for a tab id this bridge itself allocated via
    /// tabCreated below -- never for one an extension merely asked about by
    /// a guessed/stale id.
    func existingTabID(for tabUUID: UUID) -> Int32? { tabIDsByUUID[tabUUID] }
    func tabUUID(for tabID: Int32) -> UUID? { tabUUIDsByID[tabID] }
    /// The `windowOwner` tabCreated(_:) was given for this tab id.
    func tabWindowOwner(for tabID: Int32) -> AnyObject? { tabOwnersByID[tabID] }
    /// The `owner` windowCreated(_:) was given for this window id.
    func windowOwner(for windowID: Int32) -> AnyObject? { windowOwnersByID[windowID] }
    /// True only once windowCreated(owner:focused:) has actually pushed this
    /// owner into OrbitTabRegistry; a plain map lookup would false-claim a
    /// window whose tab was registered first, via the lazy allocator.
    func isWindowRegistered(_ owner: AnyObject) -> Bool {
        windowIDsByObjectID[ObjectIdentifier(owner)].map { windowOwnersByID[$0] != nil } ?? false
    }

    // MARK: - Push (Swift's own tab/window mutations -> OrbitTabRegistry)

    /// Call once, after the tab's WebContents already exists, whenever a
    /// real Orbit tab is created (never for an extension popup/options
    /// page's own WebContents -- those are not tabs).
    func tabCreated(
        tabUUID: UUID, handle: UnsafeMutableRawPointer, windowOwner: AnyObject,
        index: Int, active: Bool, pinned: Bool
    ) {
        let id = tabID(for: tabUUID)
        tabUUIDsByID[id] = tabUUID
        tabOwnersByID[id] = windowOwner
        bridge.tabsCreated(
            handle: handle, tabID: id, windowID: windowID(for: windowOwner),
            index: Int32(index), active: active, pinned: pinned
        )
    }

    /// Call before releasing/destroying the tab's WebContents.
    func tabRemoved(tabUUID: UUID, windowClosing: Bool) {
        guard let id = tabIDsByUUID.removeValue(forKey: tabUUID) else { return }
        tabUUIDsByID.removeValue(forKey: id)
        tabOwnersByID.removeValue(forKey: id)
        bridge.tabsRemoved(tabID: id, windowClosing: windowClosing)
    }

    /// `tabUUID` nil means the window shows no registered tab; pushed as
    /// reserved id 0, which clears the window's previously active tab.
    func activeTabChanged(tabUUID: UUID?, windowOwner: AnyObject, previousTabUUID: UUID?) {
        let previous = previousTabUUID.flatMap { tabIDsByUUID[$0] } ?? 0
        bridge.tabsActivated(
            tabID: tabUUID.map { tabID(for: $0) } ?? 0,
            windowID: windowID(for: windowOwner),
            previousTabID: previous
        )
    }

    func tabMoved(tabUUID: UUID, windowOwner: AnyObject, fromIndex: Int, toIndex: Int) {
        bridge.tabsMoved(
            tabID: tabID(for: tabUUID), windowID: windowID(for: windowOwner),
            fromIndex: Int32(fromIndex), toIndex: Int32(toIndex)
        )
    }

    func tabPinnedChanged(tabUUID: UUID, pinned: Bool) {
        guard let id = tabIDsByUUID[tabUUID] else { return }
        bridge.tabsSetPinned(tabID: id, pinned: pinned)
    }

    /// Silent on the other side (no chrome.tabs event); safe to push after
    /// every insert/close/pin/move to keep sibling indices from going stale.
    func tabIndexChanged(tabUUID: UUID, index: Int) {
        guard let id = tabIDsByUUID[tabUUID] else { return }
        bridge.tabsIndexChanged(tabID: id, index: Int32(index))
    }

    /// `owner` is whatever Swift considers one Orbit window's identity
    /// (e.g. its OrbitWindowController) -- only ever used as a dictionary
    /// key via ObjectIdentifier, never dereferenced here.
    func windowCreated(owner: AnyObject, focused: Bool) {
        let id = windowID(for: owner)
        windowOwnersByID[id] = owner
        bridge.windowsCreated(windowID: id, focused: focused)
    }

    func windowRemoved(owner: AnyObject) {
        guard let id = windowIDsByObjectID.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        windowOwnersByID.removeValue(forKey: id)
        bridge.windowsRemoved(windowID: id)
    }

    /// `owner` nil means every Orbit window lost focus (mirrors
    /// OrbitWindowsFocusChanged(0)'s own contract).
    func windowFocusChanged(owner: AnyObject?) {
        bridge.windowsFocusChanged(windowID: owner.map { windowID(for: $0) } ?? 0)
    }

    /// Only ever pushed for a window already registered by windowCreated --
    /// a state for a window chrome.windows has never been told about would
    /// be dropped on the other side anyway.
    func windowStateChanged(owner: AnyObject, state: OrbitWindowState) {
        guard let id = windowIDsByObjectID[ObjectIdentifier(owner)], windowOwnersByID[id] != nil else { return }
        bridge.windowsStateChanged(windowID: id, state: state.rawValue)
    }

    // MARK: - Delegate (extension -> Swift)

    private func installDelegate() {
        var layout = TabsDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        layout.createTab = OrbitChromiumTabsBridge.createTabTrampoline
        layout.updateTabURL = OrbitChromiumTabsBridge.updateTabURLTrampoline
        layout.activateTab = OrbitChromiumTabsBridge.activateTabTrampoline
        layout.removeTab = OrbitChromiumTabsBridge.removeTabTrampoline
        layout.setTabPinned = OrbitChromiumTabsBridge.setTabPinnedTrampoline
        bridge.setTabsDelegate(layout)
    }

    private static let createTabTrampoline: TabsDelegateLayout.CreateTab = {
        opaque, windowID, urlPtr, active, pinned, outHandle, outTabID in
        guard let opaque else { return 0 }
        let bridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        let url = urlPtr.map { String(cString: $0) } ?? ""
        return MainActor.assumeIsolated {
            guard let handler = bridge.handler,
                  let result = handler.chromiumCreateTab(
                      windowID: windowID, url: url, active: active != 0, pinned: pinned != 0
                  )
            else {
                return 0
            }
            outHandle?.pointee = result.handle
            outTabID?.pointee = result.tabID
            return 1
        }
    }

    private static let updateTabURLTrampoline: TabsDelegateLayout.UpdateTabURL = {
        opaque, tabID, urlPtr in
        guard let opaque else { return 0 }
        let bridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        let url = urlPtr.map { String(cString: $0) } ?? ""
        return MainActor.assumeIsolated {
            (bridge.handler?.chromiumUpdateTabURL(tabID: tabID, url: url) ?? false) ? 1 : 0
        }
    }

    private static let activateTabTrampoline: TabsDelegateLayout.ActivateTab = {
        opaque, tabID in
        guard let opaque else { return 0 }
        let bridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        return MainActor.assumeIsolated {
            (bridge.handler?.chromiumActivateTab(tabID: tabID) ?? false) ? 1 : 0
        }
    }

    private static let removeTabTrampoline: TabsDelegateLayout.RemoveTab = {
        opaque, tabID in
        guard let opaque else { return 0 }
        let bridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        return MainActor.assumeIsolated {
            (bridge.handler?.chromiumRemoveTab(tabID: tabID) ?? false) ? 1 : 0
        }
    }

    private static let setTabPinnedTrampoline: TabsDelegateLayout.SetTabPinned = {
        opaque, tabID, pinned in
        guard let opaque else { return 0 }
        let bridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        return MainActor.assumeIsolated {
            (bridge.handler?.chromiumSetTabPinned(tabID: tabID, pinned: pinned != 0) ?? false) ? 1 : 0
        }
    }

    private static let extensionTabRequestTrampoline: OrbitChromiumBridge.ExtensionTabRequestCallback = {
        opaque, handle, urlPtr, extensionIDPtr, disposition, userGesture in
        guard let opaque, let handle else { return 0 }
        let tabsBridge = Unmanaged<OrbitChromiumTabsBridge>.fromOpaque(opaque).takeUnretainedValue()
        let url = urlPtr.map { String(cString: $0) } ?? ""
        let extensionID = extensionIDPtr.map { String(cString: $0) } ?? ""
        return MainActor.assumeIsolated {
            let adopted = tabsBridge.handler?.chromiumAdoptExtensionTab(
                handle: handle, url: url, extensionID: extensionID, disposition: disposition,
                userGesture: userGesture != 0
            ) ?? false
            return adopted ? 1 : 0
        }
    }
}
