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
        guard let helper = scheduleRelaunchAfterThisProcessExits() else {
            logger.error("could not schedule the relaunch helper; leaving Orbit running rather than quitting with no way back")
            return
        }
        isRelaunching = true
        logger.info("relaunching to apply pending changes")
        // AppKit refuses terminate: while a sheet or modal session is up ("App termination blocked by modal sheet"),
        // and the Restart button usually sits inside one. Close them, then quit once this action has unwound.
        // The run loop, not the main queue: applicationWillTerminate's engine shutdown must not run inside a main-queue block.
        dismissModalUI()
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
                // terminate: returns only when termination was refused; a granted quit never comes back here.
                logger.error("termination was refused; cancelling the relaunch")
                helper.terminate()
                isRelaunching = false
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private static func dismissModalUI() {
        if NSApp.modalWindow != nil {
            NSApp.stopModal()
        }
        for _ in 0..<4 {
            let attached = NSApp.windows.compactMap { window in window.attachedSheet.map { (window, $0) } }
            guard !attached.isEmpty else { return }
            for (window, sheet) in attached.reversed() {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
    }

    // A detached shell process that waits for this exact pid to exit, then reopens the bundle — avoids racing this process's own engine shutdown, which a plain "open" launched before exit could do.
    private static func scheduleRelaunchAfterThisProcessExits() -> Process? {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = #"while /bin/kill -0 "$1" >/dev/null 2>&1; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "orbit-relaunch", pid, bundlePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            logger.error("failed to launch the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
