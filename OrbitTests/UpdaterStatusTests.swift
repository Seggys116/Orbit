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
}
