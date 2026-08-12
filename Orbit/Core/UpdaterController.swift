import Foundation
import Observation
import OSLog

#if ORBIT_SPARKLE
import Sparkle

@MainActor
@Observable
final class UpdaterController: NSObject {

    static let logger = Logger(subsystem: "com.orbit.browser", category: "UpdaterController")

    static let shared = UpdaterController()

    // MARK: - The one observable status

    // internal, not private(set): every write happens in
    // UpdaterController+UserDriver.swift, a separate file, and Swift's
    // private is lexically file-scoped. Nothing outside this type should assign to it.
    var status: UpdaterStatus = .idle

    var onRequestFocus: (() -> Void)?

    static let prereleaseChannelName = "beta"

    // MARK: - Sparkle

    // Implicitly-unwrapped, not guard let at every call site: every member
    // below is only ever called after start(), except where noted.
    private var sparkleUpdater: SPUUpdater!

    // MARK: - In-flight state the driver callbacks fill in and drain
    //
    // internal, not private, for the same file-scoping reason status above is.

    var checkCancellation: (() -> Void)?

    var downloadCancellation: (() -> Void)?

    var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?

    var pendingAppcastItem: SUAppcastItem?

    var pendingRetryTerminatingApplication: (() -> Void)?

    var expectedDownloadLength: UInt64 = 0
    var receivedDownloadLength: UInt64 = 0

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    // Idempotent. Forces one checkForUpdatesInBackground() right after
    // start() succeeds (Sparkle's own recommended fix) so a browser
    // relaunched within the same scheduled-check window still checks on every launch.
    func start() {
        guard sparkleUpdater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        sparkleUpdater = updater
        do {
            try updater.start()
        } catch {
            status = .error(message: Self.presentableMessage(for: error as NSError))
            return
        }
        if updater.automaticallyChecksForUpdates {
            status = .checking
            updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - The one shared entry point

    func checkForUpdates() {
        guard let sparkleUpdater else { return }
        if sparkleUpdater.canCheckForUpdates {
            // Set optimistically rather than waiting for the driver's own
            // callback, so a bound button reflects the click on the same run loop turn.
            status = .checking
        }
        sparkleUpdater.checkForUpdates()
    }

    var canCheckForUpdates: Bool { sparkleUpdater?.canCheckForUpdates ?? false }

    // MARK: - Resolving an offered update

    func installUpdateNow() {
        guard let reply = pendingChoiceReply else { return }
        if let item = pendingAppcastItem, item.isInformationOnlyUpdate {
            // Sparkle's contract forbids a .install reply when
            // isInformationOnlyUpdate is true — .dismiss is the honest counterpart.
            pendingChoiceReply = nil
            pendingAppcastItem = nil
            reply(.dismiss)
            return
        }
        pendingChoiceReply = nil
        reply(.install)
    }

    func remindMeLater() {
        guard let reply = pendingChoiceReply else { return }
        pendingChoiceReply = nil
        reply(.dismiss)
    }

    func skipThisVersion() {
        guard let reply = pendingChoiceReply else { return }
        pendingChoiceReply = nil
        reply(.skip)
    }

    func cancelCheck() {
        checkCancellation?()
    }

    func cancelDownload() {
        downloadCancellation?()
    }

    func retryQuitForInstall() {
        pendingRetryTerminatingApplication?()
    }

    // MARK: - Preferences: which state is Sparkle's and which is Orbit's

    var isAutomaticCheckEnabled: Bool {
        get { sparkleUpdater?.automaticallyChecksForUpdates ?? true }
        set { sparkleUpdater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { sparkleUpdater?.lastUpdateCheckDate }

    // Also calls SPUUpdater.resetUpdateCycle() — without it, toggling this
    // would only take effect on the next scheduled or manual check.
    var isPrereleaseChannelEnabled: Bool {
        get { UpdaterPreferences.isPrereleaseChannelEnabled }
        set {
            UpdaterPreferences.isPrereleaseChannelEnabled = newValue
            sparkleUpdater?.resetUpdateCycle()
        }
    }

    // MARK: - Error presentation

    static func presentableMessage(for error: NSError) -> String {
        var message = error.localizedDescription
        if let suggestion = error.localizedRecoverySuggestion, !suggestion.isEmpty {
            message += "\n\n" + suggestion
        }
        return message
    }

    // MARK: - Download progress bookkeeping

    func updateDownloadProgress() {
        guard expectedDownloadLength > 0 else {
            status = .downloading(fractionCompleted: nil)
            return
        }
        let fraction = min(1.0, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        status = .downloading(fractionCompleted: fraction)
    }

    // Does not invoke any of the reply/cancellation closures — the caller decides the session is over.
    func clearPendingState() {
        checkCancellation = nil
        downloadCancellation = nil
        pendingChoiceReply = nil
        pendingAppcastItem = nil
        pendingRetryTerminatingApplication = nil
        expectedDownloadLength = 0
        receivedDownloadLength = 0
    }
}

#endif
