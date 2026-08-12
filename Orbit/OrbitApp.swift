import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Must stay non-empty: an empty Settings scene still claims Cmd-, in AppKit.
        Settings {
            SettingsSceneRedirectView()
        }
    }
}
