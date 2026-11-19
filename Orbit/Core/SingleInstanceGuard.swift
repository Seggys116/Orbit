import AppKit
import Darwin

/// Two copies of the same Orbit bundle would share one profile, both restore the window and both resume media.
enum SingleInstanceGuard {

    struct Instance: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let bundleURL: URL?
    }

    static func conflictingInstance(
        selfPID: pid_t,
        bundleIdentifier: String?,
        bundleURL: URL,
        running: [Instance]
    ) -> Instance? {
        guard let bundleIdentifier else { return nil }
        let ownPath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return running.first { other in
            other.processIdentifier != selfPID
                && other.bundleIdentifier == bundleIdentifier
                && other.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == ownPath
        }
    }

    /// Returns true when this process should continue launching. A copy that is still quitting gets a short grace period.
    @MainActor
    static func claim(gracePeriod: TimeInterval = 3) -> Bool {
        let bundle = Bundle.main
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? "")
            .map { Instance(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, bundleURL: $0.bundleURL) }
        guard let other = conflictingInstance(
            selfPID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: bundle.bundleURL,
            running: running
        ) else { return true }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if kill(other.processIdentifier, 0) != 0, errno == ESRCH { return true }
            usleep(50_000)
        }
        NSRunningApplication(processIdentifier: other.processIdentifier)?.activate()
        return false
    }
}
