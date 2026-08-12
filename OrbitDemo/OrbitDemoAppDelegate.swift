import AppKit

@MainActor
final class OrbitDemoAppDelegate: OrbitAppDelegate {

    /// Must be `demoApp`, not `demo`: `demo` hands back a new environment on every access, so the delegate and the window would end up holding different objects and the demo would show state that nothing could mutate.
    override var host: AppEnvironment { .demoApp }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        // Before super: super opens the first window, and that is what calls
        // startEngineIfNeeded(). This is the last moment no engine exists, so it is the only
        // point a baseline of the real profile can be taken that the engine cannot have touched.
        DemoEngineProbe.captureBaseline()
        super.applicationDidFinishLaunching(notification)
        DemoEngineProbe.runIfEnabled()
        DemoCaptureDriver.runIfEnabled()
        SettingsVerificationProbe.runIfEnabled()
        // Inert without `ORBIT_FOLDER_TOGGLE_PROBE=1`.
        FolderToggleCrashProbe.runIfEnabled()
        // Must run last: it samples NSApp.mainMenu and needs super's own NSApp.mainMenu = MainMenuBuilder.build() to have happened first.
        DemoMenuBarProbe.runIfEnabled()
    }
}
