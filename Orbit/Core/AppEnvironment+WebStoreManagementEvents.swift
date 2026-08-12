//  Pushes chrome.management events into any open Web Store tab whenever
//  ExtensionStore changes, regardless of whether Settings or the page caused it.

import Foundation

extension AppEnvironment {

    func startObservingExtensionStoreForWebStoreEvents() {
        extensionStore.addChangeObserver { [weak self] event in
            self?.broadcastExtensionManagementEvent(event)
        }
    }

    private func broadcastExtensionManagementEvent(_ event: ExtensionStore.ChangeEvent) {
        let name: String
        let resultJSON: String
        switch event {
        case .installed(let ext):
            name = "onInstalled"
            resultJSON = WebStorePrivateBridge.encodeEventResult(WebStorePrivateBridge.extensionInfoJSON(for: ext))
        case .uninstalled(let id):
            name = "onUninstalled"
            resultJSON = WebStorePrivateBridge.encodeEventResult(id)
        case .enabled(let ext):
            name = "onEnabled"
            resultJSON = WebStorePrivateBridge.encodeEventResult(WebStorePrivateBridge.extensionInfoJSON(for: ext))
        case .disabled(let ext):
            name = "onDisabled"
            resultJSON = WebStorePrivateBridge.encodeEventResult(WebStorePrivateBridge.extensionInfoJSON(for: ext))
        case .willReplace:
            // Pre-flight unload signal, not a settled state change -- the
            // .installed event that follows a completed update already
            // covers chrome.management.onInstalled for this id.
            return
        }

        let script = WebStorePrivateBridgeScript.managementEventScript(name: name, resultJSON: resultJSON)
        for contents in webContents.values where WebStorePrivateBridge.isWebStoreOrigin(contents.navigationState.url) {
            Task { [weak contents] in
                _ = try? await contents?.evaluateJavaScript(script)
            }
        }
    }
}
