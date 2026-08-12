//  Routes an extension's chrome.tabs/chrome.windows calls onto AppEnvironment.
//  The reverse push (Orbit's own mutations -> the bridge) lives at the mutation points, not here.

import Foundation

enum ChromiumTabsSetup {
    /// Installs the C++-side delegate exactly once. Must not run before
    /// OrbitChromiumBridge.load() dlsym's the framework — see AppEnvironment.startEngineIfNeeded().
    static let installHandlerOnce: Void = {
        OrbitChromiumTabsBridge.shared.handler = ChromiumTabsRouter.shared
        OrbitChromiumManagementBridge.shared.install()
        OrbitChromiumPermissionsBridge.shared.install()
    }()
}

@MainActor
final class ChromiumTabsRouter: OrbitChromiumTabsBridgeHandler {

    static let shared = ChromiumTabsRouter()

    private init() {}

    func chromiumCreateTab(windowID: Int32, url: String, active: Bool, pinned: Bool)
        -> (handle: UnsafeMutableRawPointer, tabID: Int32)?
    {
        guard let environment = OrbitChromiumTabsBridge.shared.windowOwner(for: windowID) as? AppEnvironment,
              let spaceID = environment.activeSpace?.id
        else { return nil }
        let target = URL(string: url) ?? URL(string: "orbit://new-tab")!
        let tabID = environment.openTab(url: target, in: spaceID, section: .today, activate: active)
        if pinned {
            environment.pinTab(tabID)
        }
        guard let contents = environment.webContents[tabID] as? ChromiumWebContents,
              let registryTabID = OrbitChromiumTabsBridge.shared.existingTabID(for: tabID)
        else { return nil }
        return (contents.chromiumHandle, registryTabID)
    }

    func chromiumUpdateTabURL(tabID: Int32, url: String) -> Bool {
        guard let (environment, id) = resolve(tabID), let target = URL(string: url) else { return false }
        environment.loadInTab(id, url: target)
        return true
    }

    func chromiumActivateTab(tabID: Int32) -> Bool {
        guard let (environment, id) = resolve(tabID) else { return false }
        environment.activateTab(id)
        return true
    }

    func chromiumRemoveTab(tabID: Int32) -> Bool {
        guard let (environment, id) = resolve(tabID) else { return false }
        environment.closeTab(id)
        return true
    }

    func chromiumSetTabPinned(tabID: Int32, pinned: Bool) -> Bool {
        guard let (environment, id) = resolve(tabID) else { return false }
        if pinned {
            environment.pinTab(id)
        } else {
            environment.unpinTab(id)
        }
        return true
    }

    // Always "open this somewhere else" per orbit_extension_host_delegate.cc's contract, never a popup/options surface.
    // No windowID is given, so this targets the frontmost Orbit window, same as Cmd+T.
    func chromiumAdoptExtensionTab(
        handle: UnsafeMutableRawPointer, url: String, extensionID: String, disposition: Int32, userGesture: Bool
    ) -> Bool {
        guard let target = URL(string: url) else { return false }
        // 4 = newBackgroundTab (see OrbitSetExtensionTabRequestCallback's
        // WindowOpenDisposition comment in orbit_bridge_api.h) -- every other
        // disposition reaching this path opens active, matching Cmd+T.
        let active = disposition != 4
        return AppEnvironment.frontmost.adoptExtensionTab(handle: handle, url: target, active: active) != nil
    }

    private func resolve(_ tabID: Int32) -> (AppEnvironment, TabID)? {
        guard let uuid = OrbitChromiumTabsBridge.shared.tabUUID(for: tabID),
              let environment = OrbitChromiumTabsBridge.shared.tabWindowOwner(for: tabID) as? AppEnvironment
        else { return nil }
        return (environment, uuid)
    }
}
