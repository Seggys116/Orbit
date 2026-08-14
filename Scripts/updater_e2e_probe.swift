import Foundation
import Sparkle

struct Options {
    var host = ""
    var feed: String?
    var mode = "install"
    var timeout: TimeInterval = 900
    var out = ""
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        func value() -> String {
            guard let next = arguments.first else {
                FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
                exit(2)
            }
            arguments.removeFirst()
            return next
        }
        switch flag {
        case "--host": options.host = value()
        case "--feed": options.feed = value()
        case "--mode": options.mode = value()
        case "--timeout": options.timeout = Double(value()) ?? 900
        case "--out": options.out = value()
        default:
            FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
            exit(2)
        }
    }
    return options
}

@MainActor
final class Probe: NSObject, SPUUserDriver, SPUUpdaterDelegate {

    private let options: Options
    private var updater: SPUUpdater!
    private var events: [[String: Any]] = []
    private var result: [String: Any] = [:]
    private var finished = false
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?

    init(options: Options) {
        self.options = options
        super.init()
    }

    private func record(_ name: String, _ detail: [String: Any] = [:]) {
        var event: [String: Any] = ["event": name, "at": Date().timeIntervalSince1970]
        event.merge(detail) { current, _ in current }
        events.append(event)
        FileHandle.standardError.write(Data("probe: \(name) \(detail)\n".utf8))
    }

    func run() {
        guard let bundle = Bundle(path: options.host) else { return finish("harness-error", ["message": "no bundle at \(options.host)"]) }
        result["hostVersionBefore"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            return finish("start-failed", ["message": (error as NSError).localizedDescription])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.finish("timeout")
        }
        record("check-started")
        updater.checkForUpdates()
    }

    private func finish(_ outcome: String, _ detail: [String: Any] = [:]) {
        guard !finished else { return }
        finished = true
        result["outcome"] = outcome
        result["events"] = events
        result.merge(detail) { current, _ in current }
        let json = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try? json.write(to: URL(fileURLWithPath: options.out))
        FileHandle.standardError.write(Data("probe: finished \(outcome)\n".utf8))
        exit(0)
    }

    // MARK: - SPUUpdaterDelegate

    @objc(feedURLStringForUpdater:)
    func feedURLString(for updater: SPUUpdater) -> String? { options.feed }

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record("valid-update", ["version": item.displayVersionString, "build": item.versionString])
    }

    @objc(updater:didDownloadUpdate:)
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        record("downloaded")
    }

    @objc(updater:didExtractUpdate:)
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        record("extracted")
    }

    @objc(updater:willInstallUpdate:)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        record("will-install")
    }

    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        record("will-relaunch")
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        record("aborted", ["message": (error as NSError).localizedDescription])
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        record("cycle-finished", ["message": error.map { ($0 as NSError).localizedDescription } ?? ""])
        finish(result["pendingOutcome"] as? String ?? "cycle-finished")
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        record("checking")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("update-found", ["version": appcastItem.displayVersionString, "build": appcastItem.versionString])
        result["offeredVersion"] = appcastItem.displayVersionString
        result["offeredBuild"] = appcastItem.versionString
        result["pendingOutcome"] = "update-found"
        if options.mode == "probe" {
            reply(.dismiss)
        } else {
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        record("no-update", ["message": (error as NSError).localizedDescription])
        result["pendingOutcome"] = "no-update"
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        record("updater-error", ["message": nsError.localizedDescription, "code": nsError.code])
        result["pendingOutcome"] = "rejected"
        result["errorMessage"] = nsError.localizedDescription
        result["errorCode"] = nsError.code
        result["errorChain"] = Probe.chain(of: nsError)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        record("download-started")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        record("download-length", ["bytes": expectedContentLength])
        result["expectedBytes"] = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        result["receivedBytes"] = (result["receivedBytes"] as? UInt64 ?? 0) + length
    }

    func showDownloadDidStartExtractingUpdate() {
        record("extracting")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        result["pendingOutcome"] = "ready-to-install"
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        record("installing", ["applicationTerminated": applicationTerminated])
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed", ["relaunched": relaunched])
        result["pendingOutcome"] = "installed"
        result["relaunched"] = relaunched
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        record("dismissed")
    }

    private static func chain(of error: NSError) -> [String] {
        var messages = [error.localizedDescription]
        var current: NSError? = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let next = current {
            messages.append(next.localizedDescription)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return messages
    }
}

let options = parseOptions()
var probe: Probe?
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        probe = Probe(options: options)
        probe?.run()
    }
}
RunLoop.main.run()
