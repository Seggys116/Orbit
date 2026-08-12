//  `@main` lives here, not in `Orbit/OrbitApp.swift` (excluded via `DEMO_EXCLUDES`): a module allows only one.
//  `Settings` hosts `SettingsSceneRedirectView`, not `EmptyView()`: AppKit treats an empty one as a live Cmd-, command.
//  This file cannot share code with `Orbit/OrbitApp.swift`, so a change to one scene body belongs in both.

import SwiftUI

@main
struct OrbitDemoApp: App {
    @NSApplicationDelegateAdaptor(OrbitDemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsSceneRedirectView()
        }
    }
}
