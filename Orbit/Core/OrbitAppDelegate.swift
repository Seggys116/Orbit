import AppKit
import OSLog

@MainActor
class OrbitAppDelegate: NSObject, NSApplicationDelegate {

    static let quitLog = Logger(subsystem: "com.orbit.browser", category: "Quit")
    static let engineLog = Logger(subsystem: "com.orbit.browser", category: "Engine")

    // Every member below must read this, not AppEnvironment.shared directly —
    // OrbitDemoAppDelegate overrides it, and .shared would build the real environment in the demo process.
    var host: AppEnvironment { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Inert without ORBIT_SMOKE_PROBE=1. First and last statements of this
        // method on purpose: Scripts/app-launch-smoke tells a crash before the
        // delegate ran from one inside it by which stages reached disk.
        AppSmokeProbe.noteStage(.delegateEntered)

        // Must start here, not from a live test's stack: BrowserMainLoop never returns,
        // so whichever pump it nests inside never returns either. This hung the live suite.
        if ProcessInfo.processInfo.environment["ORBIT_LIVE_ENGINE"] != nil {
            // Must set the private profile before loadAndStart, which traps if set after OrbitMain is scheduled.
            // The .ephemeral choice here is a matching constraint: the engine LiveChromiumEngineHost
            // builds later asks for this same directory. A trap crash restarts the host and still
            // reports "Executed 0 tests" as a pass.
            // Errors are logged, not swallowed, or a live test just times out with no explanation.
            do {
                if let directory = EngineStorageDirectory.directory(for: .ephemeral) {
                    try OrbitChromiumBridge.shared.setUserDataDirectory(directory.path)
                }
                try OrbitChromiumBridge.shared.loadAndStart()
            } catch {
                Self.engineLog.error(
                    "ORBIT_LIVE_ENGINE: the engine could not be started: \(String(describing: error), privacy: .public)"
                )
            }
        }

        // Before the guard below: the live-engine test host opens real
        // inspectors and needs the same appearance tracking the real app has.
        EngineAppearance.startObserving()

        // XCTestConfigurationFilePath is set exactly when this process is
        // hosting a test bundle — bail out before opening any window or engine.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Before anything else can name AppEnvironment.shared by accident.
        AppEnvironment.processRoot = host

        // ORBIT_SPARKLE, not canImport(Sparkle) — the latter is also true in
        // the host-less OrbitTests target, which cannot resolve UpdaterController.
        #if ORBIT_SPARKLE
        UpdaterController.shared.start()
        #endif

        NSApp.mainMenu = MainMenuBuilder.build()
        GlobalKeyEventMonitor.shared.start()

        // origin, not openTornOffWindow's processRoot default: needed to find the tab's already-live WebContents.
        SidebarTearOff.handler = { payload, point, origin in
            OrbitWindowController.openTornOffWindow(adopting: payload.nodeID, at: point, on: origin)
        }

        SidebarTearOff.frontmostEnvironmentResolver = { OrbitWindowController.frontmostEnvironment }

        // Before the first window opens, so no surface ever paints a stock 17pt scroller first.
        OrbitScrollerInstaller.start()

        // Must run before the first window opens, or the shell has nothing to present for those surfaces.
        FeatureRegistration.installAll(into: host)

        if OnboardingWindowController.showIfNeeded(on: host) == nil {
            OrbitWindowController.openNewWindow(on: host)
        }

        // Inert without ORBIT_WEBSTORE_PROBE=1. Runs on both schemes:
        // OrbitDemoAppDelegate calls through to this via super before its
        // own probes. See Orbit/Core/WebStoreInstallVerifyProbe.swift.
        WebStoreInstallVerifyProbe.runIfEnabled(host: host)

        // Inert without ORBIT_SMOKE_PROBE=1. Runs on both schemes, through the
        // same super call. See Orbit/Core/AppSmokeProbe.swift.
        AppSmokeProbe.noteStage(.delegateFinished)
        AppSmokeProbe.runIfEnabled(host: host)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            OrbitWindowController.openNewWindow(on: host)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            host.handleExternalOpen(url: url)
        }
    }

    // Must return .terminateLater: the browser process's own nested NSApplication pump is on this thread's stack, and tearing it down from inside that pump is unsafe.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // RelaunchController.relaunch() is itself the user's confirmation — asking again here would just be redundant, and tabs are not lost on this path.
        let shouldWarn = !RelaunchController.isRelaunching && QuitConfirmation.shouldConfirm(openTabCount: host.openTabCount)
        var userConfirmedQuit = true
        if shouldWarn {
            let alert = NSAlert()
            alert.messageText = QuitConfirmation.message(openTabCount: host.openTabCount)
            alert.informativeText = QuitConfirmation.informativeText
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            userConfirmedQuit = alert.runModal() == .alertFirstButtonReturn
        }

        let decision = Self.terminationDecision(
            shouldWarn: shouldWarn,
            userConfirmedQuit: userConfirmedQuit,
            isEngineRunning: host.engine != nil
        )

        Self.quitLog.info("applicationShouldTerminate -> \(String(describing: decision), privacy: .public)")

        if decision == .terminateLater {
            Self.performOnMainRunLoop {
                Self.quitLog.info("replying to applicationShouldTerminate")
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return decision
    }

    /// The run loop, not the main queue: the serial main queue cannot start
    /// anything while `NSApp.terminate` is on the stack of one of its own blocks.
    static func performOnMainRunLoop(_ work: @escaping () -> Void) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// userConfirmedQuit is ignored when shouldWarn is false.
    static func terminationDecision(
        shouldWarn: Bool,
        userConfirmedQuit: Bool,
        isEngineRunning: Bool
    ) -> NSApplication.TerminateReply {
        guard !shouldWarn || userConfirmedQuit else {
            return .terminateCancel
        }
        return isEngineRunning ? .terminateLater : .terminateNow
    }

    // The one guaranteed place a graceful quit runs code: applicationShouldTerminateAfterLastWindowClosed
    // is false, so nothing else reaches here except via applicationShouldTerminate above.
    func applicationWillTerminate(_ notification: Notification) {
        let began = Date()
        Self.quitLog.info("applicationWillTerminate began")

        // Must come first: otherwise OnboardingWindowController.windowWillClose
        // treats the window AppKit is about to close as "skip the rest of setup".
        OnboardingWindowController.isApplicationTerminating = true

        // Must run before shutdownEngine() below, while editors are still
        // mounted — the last point flushAll() can reach a pending edit.
        // try?, not try: a write failure here must not block termination.
        DocumentEditorFlushRegistry.shared.flushAll()
        try? host.store.saveNow()
        try? host.noteStore.saveNow()
        try? host.easelStore.saveNow()

        // Safe only from this exact call site: applicationShouldTerminate
        // above guarantees this thread is off Chromium's nested pump stack by now.
        let engineFinished = host.shutdownEngine()

        Self.quitLog.info(
            "applicationWillTerminate finished in \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s (engine teardown completed: \(engineFinished, privacy: .public))"
        )

        // The last stage Scripts/app-launch-smoke expects: a quit that never
        // gets here is a shutdown that hung or died, and the harness fails on
        // the missing stage rather than on a process that merely went away.
        if engineFinished {
            AppSmokeProbe.noteStage(.engineShutdown)
        } else {
            AppSmokeProbe.noteTeardownIncomplete()
        }
    }
}
