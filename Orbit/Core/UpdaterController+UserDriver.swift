#if ORBIT_SPARKLE
import Foundation
import OSLog
import Sparkle

extension UpdaterController: SPUUserDriver {

    // MARK: - Permission

    // Should never fire in the running app (SUEnableAutomaticChecks is set
    // in Info.plist) but is required by the protocol regardless.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        status = .checking
        checkCancellation = cancellation
    }

    // MARK: - Found

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        checkCancellation = nil
        pendingAppcastItem = appcastItem
        pendingChoiceReply = reply
        status = .updateAvailable(
            version: appcastItem.displayVersionString,
            releaseNotesHTML: nil,
            isInformationOnly: appcastItem.isInformationOnlyUpdate
        )
    }

    // MARK: - Release notes

    // Both methods below must guard that status is still .updateAvailable for the same version, since the user may already have replied .install by the time either runs and overwriting that would revive a stale Install button.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard case .updateAvailable(let version, _, let isInformationOnly) = status else { return }
        let html = Self.decodeReleaseNotes(downloadData)
        status = .updateAvailable(version: version, releaseNotesHTML: html, isInformationOnly: isInformationOnly)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        Self.logger.notice("Release notes failed to download: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - No update / error

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        clearPendingState()
        status = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        clearPendingState()
        status = .error(message: UpdaterController.presentableMessage(for: error as NSError))
        acknowledgement()
    }

    // MARK: - Download

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        checkCancellation = nil
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        downloadCancellation = cancellation
        status = .downloading(fractionCompleted: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        updateDownloadProgress()
    }

    // MARK: - Extraction

    func showDownloadDidStartExtractingUpdate() {
        // Per Sparkle's own doc: the cancellation block may be invoked at any point before this, not after.
        downloadCancellation = nil
        status = .extracting(fractionCompleted: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        status = .extracting(fractionCompleted: progress)
    }

    // MARK: - Ready to relaunch

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoiceReply = reply
        status = .readyToRelaunch(version: pendingAppcastItem?.displayVersionString ?? "")
    }

    // MARK: - Installing

    // status is deliberately left as whatever got the driver here (.readyToRelaunch, ordinarily): UpdaterStatus has no distinct "installing" case, and retryQuitForInstall() invokes the stored closure when needed.
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        pendingRetryTerminatingApplication = applicationTerminated ? nil : retryTerminatingApplication
    }

    // MARK: - Installed

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        clearPendingState()
        status = .idle
        acknowledgement()
    }

    // MARK: - Teardown

    func dismissUpdateInstallation() {
        clearPendingState()
        status = .idle
    }

    // MARK: - Optional: focus

    // @objc(showUpdateInFocus) must pin the exact selector, since an @optional protocol requirement is matched by -respondsToSelector: at the call site, not by compiler witness-table checking, so a mismatched inferred selector would silently never be called.
    @objc(showUpdateInFocus)
    func showUpdateInFocus() {
        onRequestFocus?()
    }

    // MARK: - Release notes decoding

    /// Falls back to UTF-8 when no charset was reported, or it can't be resolved.
    private static func decodeReleaseNotes(_ downloadData: SPUDownloadData) -> String? {
        if let ianaName = downloadData.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if nsEncoding != UInt(bitPattern: Int(NSNotFound)) {
                    let encoding = String.Encoding(rawValue: nsEncoding)
                    if let decoded = String(data: downloadData.data, encoding: encoding) {
                        return decoded
                    }
                }
            }
        }
        return String(data: downloadData.data, encoding: .utf8)
    }
}

#endif
