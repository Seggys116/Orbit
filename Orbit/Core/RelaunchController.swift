//  The one path that restarts Orbit for start-up-only changes (extensions foremost).
//  Tabs survive relaunch independently of this; it only adds a flush before quitting.

import AppKit
import Foundation
import OSLog

@MainActor
enum RelaunchController {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "Relaunch")

    // Read by OrbitAppDelegate.applicationShouldTerminate to skip the "quit with N tabs open?" prompt: the user already confirmed by choosing to restart, and this path does not lose tabs.
    private(set) static var isRelaunching = false

    static func relaunch(host: AppEnvironment = .shared) {
        guard !isRelaunching else { return }
        // A stray call here would quit the whole xctest process rather than the app under test.
        guard !DebugFlags.isRunningUnderTests else {
            logger.error("relaunch() ignored under XCTest")
            return
        }
        // Synchronous, not the debounced autosave: flush before anything might quit before that timer fires.
        try? host.store.saveNow()
        guard scheduleRelaunchAfterThisProcessExits() else {
            logger.error("could not schedule the relaunch helper; leaving Orbit running rather than quitting with no way back")
            return
        }
        isRelaunching = true
        logger.info("relaunching to apply pending changes")
        NSApp.terminate(nil)
    }

    // A detached shell process that waits for this exact pid to exit, then reopens the bundle — avoids racing this process's own engine shutdown, which a plain "open" launched before exit could do.
    @discardableResult
    private static func scheduleRelaunchAfterThisProcessExits() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; /usr/bin/open \"\(bundleURL.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            return true
        } catch {
            logger.error("failed to launch the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
