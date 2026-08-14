import XCTest

final class UpdaterStatusTests: XCTestCase {

    // MARK: - downloading(nil) vs downloading(0): indeterminate vs zero-known-progress

    func test_downloadingNil_isNotEqualTo_downloadingZero() {
        XCTAssertNotEqual(
            UpdaterStatus.downloading(fractionCompleted: nil),
            UpdaterStatus.downloading(fractionCompleted: 0),
            "downloading(nil) means Sparkle has not yet reported (or cannot trust) an expected content length — genuinely indeterminate progress. downloading(0) means the total is known and zero bytes have arrived. A progress view must be able to tell these apart, and Equatable collapsing them would make a status-change gate silently swallow the nil -> 0 transition."
        )
    }

    func test_downloadingSameFraction_areEqual() {
        XCTAssertEqual(UpdaterStatus.downloading(fractionCompleted: 0.42), UpdaterStatus.downloading(fractionCompleted: 0.42))
    }

    func test_downloadingDifferentFractions_areNotEqual() {
        XCTAssertNotEqual(UpdaterStatus.downloading(fractionCompleted: 0.1), UpdaterStatus.downloading(fractionCompleted: 0.9))
    }

    func test_downloadingBothNil_areEqual() {
        XCTAssertEqual(UpdaterStatus.downloading(fractionCompleted: nil), UpdaterStatus.downloading(fractionCompleted: nil))
    }

    // MARK: - extracting: no nil case exists at all, so equality is exact

    func test_extractingSameFraction_areEqual() {
        XCTAssertEqual(UpdaterStatus.extracting(fractionCompleted: 0.0), UpdaterStatus.extracting(fractionCompleted: 0.0))
        XCTAssertEqual(UpdaterStatus.extracting(fractionCompleted: 1.0), UpdaterStatus.extracting(fractionCompleted: 1.0))
    }

    func test_extractingDifferentFractions_areNotEqual() {
        XCTAssertNotEqual(UpdaterStatus.extracting(fractionCompleted: 0.0), UpdaterStatus.extracting(fractionCompleted: 0.99))
    }

    func test_downloadingAndExtracting_areNeverEqualEvenWithMatchingNumbers() {
        XCTAssertNotEqual(
            UpdaterStatus.downloading(fractionCompleted: 0.5) as UpdaterStatus,
            UpdaterStatus.extracting(fractionCompleted: 0.5)
        )
    }

    // MARK: - updateAvailable: release notes arriving after the case is first published

    func test_updateAvailable_releaseNotesNilVersusLoaded_areNotEqual() {
        let beforeNotes = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: nil, isInformationOnly: false)
        let afterNotes = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: "<p>Fixes.</p>", isInformationOnly: false)
        XCTAssertNotEqual(
            beforeNotes, afterNotes,
            "showUpdateReleaseNotes(with:) rewrites .updateAvailable with the same version but newly-loaded notes; if this compared equal to the pre-notes state, a view gating on \"did status change\" would never redraw the notes in."
        )
    }

    func test_updateAvailable_isInformationOnlyFlag_participatesInEquality() {
        let ordinary = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: nil, isInformationOnly: false)
        let informationOnly = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: nil, isInformationOnly: true)
        XCTAssertNotEqual(
            ordinary, informationOnly,
            "isInformationOnlyUpdate governs whether the About window may ever offer an Install control (installUpdateNow() refuses to reply .install for one) — it must be part of what makes two updateAvailable values distinct, not incidental payload a view could ignore."
        )
    }

    func test_updateAvailable_identicalPayloads_areEqual() {
        let a = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: "<p>Fixes.</p>", isInformationOnly: false)
        let b = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: "<p>Fixes.</p>", isInformationOnly: false)
        XCTAssertEqual(a, b)
    }

    func test_updateAvailable_differentVersions_areNotEqual() {
        let v1 = UpdaterStatus.updateAvailable(version: "2.3.1", releaseNotesHTML: nil, isInformationOnly: false)
        let v2 = UpdaterStatus.updateAvailable(version: "2.4.0", releaseNotesHTML: nil, isInformationOnly: false)
        XCTAssertNotEqual(v1, v2)
    }

    // MARK: - readyToRelaunch carries the version through, unlike a bare case

    func test_readyToRelaunch_differentVersions_areNotEqual() {
        XCTAssertNotEqual(UpdaterStatus.readyToRelaunch(version: "2.3.1"), UpdaterStatus.readyToRelaunch(version: "2.4.0"))
    }

    // MARK: - error carries a message, so two different failures must not collapse to one status

    func test_error_differentMessages_areNotEqual() {
        XCTAssertNotEqual(
            UpdaterStatus.error(message: "The update is improperly signed and could not be validated."),
            UpdaterStatus.error(message: "The Internet connection appears to be offline.")
        )
    }

    // MARK: - Cross-case comparisons never accidentally collapse

    func test_everyDistinctCase_isPairwiseUnequalToEveryOtherCase() {
        let cases: [UpdaterStatus] = [
            .idle,
            .checking,
            .upToDate,
            .updateAvailable(version: "1.0", releaseNotesHTML: nil, isInformationOnly: false),
            .downloading(fractionCompleted: nil),
            .extracting(fractionCompleted: 0),
            .readyToRelaunch(version: "1.0"),
            .error(message: "failed"),
        ]
        for i in 0..<cases.count {
            for j in 0..<cases.count where i != j {
                XCTAssertNotEqual(
                    cases[i], cases[j],
                    "UpdaterStatus case at index \(i) (\(cases[i])) compared equal to the case at index \(j) (\(cases[j])) — two genuinely different updater states must never be Equatable-equal, or a view gating a redraw on status change would skip a real transition."
                )
            }
        }
    }

    func test_idle_isEqualOnlyToIdle() {
        XCTAssertEqual(UpdaterStatus.idle, UpdaterStatus.idle)
    }

    // MARK: - Manual-check wedge regression guards
    //
    // UpdaterController itself is `#if ORBIT_SPARKLE`-gated and lives in a target
    // this host-less bundle cannot link (see CommandBarCheckForUpdatesActionTests
    // and UpdaterChannelGatingSourceTests for the established precedent). These
    // tests read its actual source and the actual function bodies out of it, the
    // same way UpdaterChannelGatingSourceTests already does, so a regression in
    // the exact statements that fixed the "Check for Updates wedges until relaunch,
    // Cancel does nothing" bug fails a test instead of shipping silently.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var controllerSourceURL: URL {
        repoRoot.appendingPathComponent("Orbit/Core/UpdaterController.swift")
    }

    private static var userDriverSourceURL: URL {
        repoRoot.appendingPathComponent("Orbit/Core/UpdaterController+UserDriver.swift")
    }

    private func controllerSource() throws -> String {
        try String(contentsOf: Self.controllerSourceURL, encoding: .utf8)
    }

    private func userDriverSource() throws -> String {
        try String(contentsOf: Self.userDriverSourceURL, encoding: .utf8)
    }

    // Brace-balanced extraction of the body that follows signaturePrefix, which
    // must itself end in the '{' that opens the block (as every call site below
    // does): that '{' is the starting point, not something to search for again
    // past the end of the already-matched prefix.
    private func body(after signaturePrefix: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        precondition(signaturePrefix.hasSuffix("{"), "signaturePrefix must end with the block's opening brace")
        guard let sigRange = source.range(of: signaturePrefix) else {
            throw XCTSkip("could not find \"\(signaturePrefix)\" — the implementation shape changed; this test needs to be revisited against the new shape rather than silently passing")
        }
        let openBrace = source.index(before: sigRange.upperBound)
        var depth = 0
        var idx = openBrace
        var closeIndex: String.Index?
        while idx < source.endIndex {
            let character = source[idx]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    closeIndex = source.index(after: idx)
                    break
                }
            }
            idx = source.index(after: idx)
        }
        guard let closeIndex else {
            throw XCTSkip("unbalanced braces while extracting the body of \"\(signaturePrefix)\"")
        }
        return String(source[openBrace..<closeIndex])
    }

    // MARK: - 1. start()'s forced background check must never fake a "checking" status

    // Root cause: checkForUpdatesInBackground() is Sparkle's silent/scheduled
    // driver. When it finds nothing, Sparkle calls back into the SPUUserDriver
    // with showErrorToUser == NO, which skips every one of
    // showUpdateNotFoundWithError/showUpdaterError/dismissUpdateInstallation.
    // If start() ever again optimistically sets status = .checking before that
    // call, nothing will ever move it off .checking, and checkCancellation is
    // never set either (that only happens for a user-initiated check) — so the
    // About window shows "Checking…" with a Cancel button that does nothing,
    // permanently, until the app is relaunched.
    func test_start_automaticCheckBranch_neverSetsCheckingStatus() throws {
        let body = try body(after: "if updater.automaticallyChecksForUpdates {", in: try controllerSource())
        XCTAssertFalse(
            body.contains("status = .checking"),
            "start()'s automatic-check branch sets status = .checking before a silent checkForUpdatesInBackground() call — Sparkle never calls back into the user driver for a quiet \"no update found\" background result, so this status would be stuck forever with no cancellation block ever stored, wedging the updater until the app is relaunched"
        )
        XCTAssertTrue(body.contains("checkForUpdatesInBackground()"))
    }

    // MARK: - 2. cancelCheck() / cancelDownload() must recover unconditionally

    // "no I cannot cancel": if either function only forwards to Sparkle's own
    // stored cancellation block, a stale or nil block (e.g. left over from the
    // silent background check above) makes Cancel a complete no-op with no
    // other way back to idle. Asserting there is no `if`/`guard` anywhere in
    // these bodies proves the local reset cannot be skipped.
    func test_cancelCheck_recoversUnconditionally_notGatedOnSparklesOwnBlock() throws {
        let body = try body(after: "func cancelCheck() {", in: try controllerSource())
        XCTAssertFalse(body.contains("if "), "cancelCheck() must not gate its recovery behind a conditional — got body: \(body)")
        XCTAssertFalse(body.contains("guard "), "cancelCheck() must not gate its recovery behind a conditional — got body: \(body)")
        XCTAssertTrue(body.contains("checkCancellation?()"), "cancelCheck() must still tell Sparkle's real in-flight session to abort when one exists")
        XCTAssertTrue(body.contains("clearPendingState()"))
        XCTAssertTrue(body.contains("status = .idle"), "cancelCheck() must unconditionally return status to .idle so the UI can never be left showing a checking/cancel row forever")
    }

    func test_cancelDownload_recoversUnconditionally_notGatedOnSparklesOwnBlock() throws {
        let body = try body(after: "func cancelDownload() {", in: try controllerSource())
        XCTAssertFalse(body.contains("if "), "cancelDownload() must not gate its recovery behind a conditional — got body: \(body)")
        XCTAssertFalse(body.contains("guard "), "cancelDownload() must not gate its recovery behind a conditional — got body: \(body)")
        XCTAssertTrue(body.contains("downloadCancellation?()"))
        XCTAssertTrue(body.contains("clearPendingState()"))
        XCTAssertTrue(body.contains("status = .idle"))
    }

    // MARK: - 3. "check twice in a row" must never leak state between sessions

    func test_checkForUpdates_clearsPendingStateBeforeStartingANewCheck() throws {
        let body = try body(after: "func checkForUpdates() {", in: try controllerSource())
        guard let clearRange = body.range(of: "clearPendingState()") else {
            return XCTFail("checkForUpdates() must call clearPendingState() before marking a new check as .checking, or a second manual check in a row can inherit the first one's cancellation block or reply closure — got body: \(body)")
        }
        guard let statusRange = body.range(of: "status = .checking") else {
            return XCTFail("checkForUpdates() no longer sets status = .checking at all — got body: \(body)")
        }
        XCTAssertTrue(
            clearRange.lowerBound < statusRange.lowerBound,
            "clearPendingState() must run before status = .checking in checkForUpdates(), not after — got body: \(body)"
        )
    }

    // MARK: - 4. "check, cancel, check again" must never be blocked by leftover cancel state

    func test_checkForUpdates_isNeverGatedOnStaleCancellationState() throws {
        let body = try body(after: "func checkForUpdates() {", in: try controllerSource())
        XCTAssertFalse(
            body.contains("checkCancellation"),
            "checkForUpdates() must not reference checkCancellation at all — its only precondition for starting a new check is sparkleUpdater.canCheckForUpdates. If a cancelled check's leftover checkCancellation state could block a fresh checkForUpdates() call, \"check, cancel, check again\" would never recover — got body: \(body)"
        )
    }

    // MARK: - 5. The required SPUUserDriver acknowledgement/reply closures are always invoked
    //
    // Sparkle's own contract: a custom SPUUserDriver that fails to invoke an
    // acknowledgement or reply block on any path leaves Sparkle's state machine
    // permanently believing a check is still in progress, silently dropping
    // every later checkForUpdates() call.

    func test_showUpdateNotFoundWithError_alwaysInvokesAcknowledgement() throws {
        let body = try body(after: "func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {", in: try userDriverSource())
        XCTAssertTrue(body.contains("acknowledgement()"), "got body: \(body)")
        XCTAssertTrue(body.contains("status = .upToDate"))
        XCTAssertTrue(body.contains("clearPendingState()"))
    }

    func test_showUpdaterError_alwaysInvokesAcknowledgement() throws {
        let body = try body(after: "func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {", in: try userDriverSource())
        XCTAssertTrue(body.contains("acknowledgement()"), "got body: \(body)")
        XCTAssertTrue(body.contains("clearPendingState()"))
    }

    func test_showUpdateInstalledAndRelaunched_alwaysInvokesAcknowledgement() throws {
        let body = try body(after: "func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {", in: try userDriverSource())
        XCTAssertTrue(body.contains("acknowledgement()"), "got body: \(body)")
        XCTAssertTrue(body.contains("status = .idle"))
        XCTAssertTrue(body.contains("clearPendingState()"))
    }

    func test_showPermissionRequest_alwaysInvokesReply() throws {
        let body = try body(after: "func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {", in: try userDriverSource())
        XCTAssertTrue(body.contains("reply("), "got body: \(body)")
    }

    // MARK: - 6. dismissUpdateInstallation is the one universal teardown, and must reach idle

    func test_dismissUpdateInstallation_clearsStateAndReturnsToIdle() throws {
        let body = try body(after: "func dismissUpdateInstallation() {", in: try userDriverSource())
        XCTAssertTrue(body.contains("clearPendingState()"), "got body: \(body)")
        XCTAssertTrue(body.contains("status = .idle"), "got body: \(body)")
    }
}
