import XCTest

// OnboardingFlow.swift, OnboardingPlanetScene.swift and GlyphPlanetMath.swift are compiled into the test bundle (see ORBIT_TESTS_REUSED_SOURCES).

final class OnboardingFlowTests: XCTestCase {

    // MARK: - Steps

    func test_steps_areNamedAndInOrder() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.title),
            ["Welcome", "Import", "Spaces", "Shortcuts", "Finish"]
        )
    }

    func test_stepTitles_areSentenceCaseWithNoNumbers() {
        for step in OnboardingStep.allCases {
            XCTAssertNotEqual(step.title, step.title.uppercased(), "\(step) title is all caps")
            XCTAssertFalse(step.title.contains(where: \.isNumber), "\(step) title carries a number")
        }
    }

    // MARK: - Navigation

    func test_advance_walksEveryStepThenStopsAtFinish() {
        var flow = OnboardingFlowState()
        var visited: [OnboardingStep] = [flow.step]
        while flow.advance() { visited.append(flow.step) }

        XCTAssertEqual(visited, OnboardingStep.allCases)
        XCTAssertTrue(flow.isLast)
        XCTAssertFalse(flow.advance(), "advancing past the last step must be refused")
        XCTAssertEqual(flow.step, .finish)
    }

    func test_back_isRefusedOnWelcome_andStepsBackOtherwise() {
        var flow = OnboardingFlowState()
        XCTAssertFalse(flow.canGoBack)
        XCTAssertFalse(flow.back())

        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.step, .spaces)
        XCTAssertTrue(flow.back())
        XCTAssertEqual(flow.step, .importBrowser)
    }

    func test_whileBusy_noNavigationIsAllowed() {
        var flow = OnboardingFlowState(step: .importBrowser, isBusy: true)

        XCTAssertFalse(flow.advance(), "an import in flight must not be walked away from")
        XCTAssertFalse(flow.back())
        XCTAssertFalse(flow.go(to: .welcome))
        XCTAssertEqual(flow.step, .importBrowser)

        flow.isBusy = false
        XCTAssertTrue(flow.advance())
    }

    func test_goTo_onlyAcceptsEarlierSteps() {
        var flow = OnboardingFlowState(step: .shortcuts)

        XCTAssertFalse(flow.go(to: .finish), "later steps commit choices earlier ones feed; no jumping ahead")
        XCTAssertFalse(flow.go(to: .shortcuts), "the current step is not an earlier one")
        XCTAssertEqual(flow.step, .shortcuts)

        XCTAssertTrue(flow.go(to: .importBrowser))
        XCTAssertEqual(flow.step, .importBrowser)
    }

    func test_railStatus_marksDoneCurrentAndUpcoming() {
        let flow = OnboardingFlowState(step: .spaces)

        XCTAssertEqual(flow.status(of: .welcome), .done)
        XCTAssertEqual(flow.status(of: .importBrowser), .done)
        XCTAssertEqual(flow.status(of: .spaces), .current)
        XCTAssertEqual(flow.status(of: .shortcuts), .upcoming)
        XCTAssertEqual(flow.status(of: .finish), .upcoming)
    }

    // MARK: - Primary action

    func test_primaryAction_onPlainSteps_isNextUntilFinish() {
        for step in [OnboardingStep.welcome, .spaces, .shortcuts] {
            let flow = OnboardingFlowState(step: step)
            XCTAssertEqual(flow.primaryAction(hasImportSource: false, importPhase: .idle), .next, "\(step)")
        }
        XCTAssertEqual(
            OnboardingFlowState(step: .finish).primaryAction(hasImportSource: false, importPhase: .idle),
            .finish
        )
    }

    func test_primaryAction_onImport_dependsOnSourceAndPhase() {
        let flow = OnboardingFlowState(step: .importBrowser)

        XCTAssertEqual(flow.primaryAction(hasImportSource: false, importPhase: .idle), .next)
        XCTAssertEqual(flow.primaryAction(hasImportSource: true, importPhase: .idle), .startImport)
        XCTAssertEqual(flow.primaryAction(hasImportSource: true, importPhase: .failed), .startImport, "a failed import can be retried")
        XCTAssertEqual(flow.primaryAction(hasImportSource: true, importPhase: .done), .next)
    }

    func test_primaryTitle_followsTheImportPhase() {
        let flow = OnboardingFlowState(step: .importBrowser)

        XCTAssertEqual(flow.primaryTitle(importSourceName: nil, importPhase: .idle), "Continue")
        XCTAssertEqual(flow.primaryTitle(importSourceName: "Arc", importPhase: .idle), "Import from Arc")
        XCTAssertEqual(flow.primaryTitle(importSourceName: "Arc", importPhase: .failed), "Import from Arc")
        XCTAssertEqual(flow.primaryTitle(importSourceName: "Arc", importPhase: .running), "Importing")
        XCTAssertEqual(flow.primaryTitle(importSourceName: "Arc", importPhase: .done), "Continue")
    }

    func test_primaryTitle_onOtherSteps() {
        XCTAssertEqual(OnboardingFlowState(step: .welcome).primaryTitle(importSourceName: nil, importPhase: .idle), "Get started")
        XCTAssertEqual(OnboardingFlowState(step: .spaces).primaryTitle(importSourceName: nil, importPhase: .idle), "Continue")
        XCTAssertEqual(OnboardingFlowState(step: .shortcuts).primaryTitle(importSourceName: nil, importPhase: .idle), "Continue")
        XCTAssertEqual(OnboardingFlowState(step: .finish).primaryTitle(importSourceName: nil, importPhase: .idle), "Finish")
    }

    func test_maybeLater_isOnlyOfferedOnImportWithASourceNotYetImported() {
        let importStep = OnboardingFlowState(step: .importBrowser)

        XCTAssertFalse(importStep.offersMaybeLater(hasImportSource: false, importPhase: .idle))
        XCTAssertTrue(importStep.offersMaybeLater(hasImportSource: true, importPhase: .idle))
        XCTAssertTrue(importStep.offersMaybeLater(hasImportSource: true, importPhase: .failed))
        XCTAssertFalse(importStep.offersMaybeLater(hasImportSource: true, importPhase: .done))
        XCTAssertFalse(OnboardingFlowState(step: .spaces).offersMaybeLater(hasImportSource: true, importPhase: .idle))
    }

    // MARK: - Planet scene

    private func scene(
        _ step: OnboardingStep,
        phase: OnboardingImportPhase = .idle,
        hasSource: Bool = false,
        fraction: Double = 0,
        tint: PlanetColor? = nil,
        tried: Int = 0
    ) -> OnboardingPlanetScene {
        OnboardingPlanetScene.scene(
            step: step,
            importPhase: phase,
            hasImportSource: hasSource,
            importFraction: fraction,
            spaceTint: tint,
            shortcutsTried: tried
        )
    }

    func test_planetFill_isWholeOutsideImport() {
        for step in [OnboardingStep.welcome, .spaces, .shortcuts, .finish] {
            XCTAssertEqual(scene(step, phase: .running, hasSource: true, fraction: 0.2).fill, 1, "\(step)")
        }
    }

    func test_planetFill_onImport_tracksProgress() {
        XCTAssertEqual(scene(.importBrowser, hasSource: false).fill, 1, "nothing to import leaves the planet whole")
        XCTAssertEqual(scene(.importBrowser, phase: .idle, hasSource: true).fill, 0)
        XCTAssertEqual(scene(.importBrowser, phase: .failed, hasSource: true, fraction: 0.6).fill, 0)
        XCTAssertEqual(scene(.importBrowser, phase: .running, hasSource: true, fraction: 0.37).fill, 0.37, accuracy: 1e-12)
        XCTAssertEqual(scene(.importBrowser, phase: .running, hasSource: true, fraction: 1.4).fill, 1, "fill is clamped")
        XCTAssertEqual(scene(.importBrowser, phase: .done, hasSource: true, fraction: 0.5).fill, 1)
    }

    func test_spacesScene_retintsToTheSelectedSpace() {
        let teal = PlanetColor(hex: 0x1F7A8C)
        let tinted = scene(.spaces, tint: teal)
        let plain = scene(.spaces, tint: nil)

        XCTAssertEqual(plain.palette, .violet)
        XCTAssertNotEqual(tinted.palette, plain.palette)
        XCTAssertEqual(tinted.palette, GlyphPlanetPalette.tinted(by: teal))
    }

    func test_shortcutsScene_leansInAsKeysLand() {
        let none = scene(.shortcuts, tried: 0).tiltDegrees
        let two = scene(.shortcuts, tried: 2).tiltDegrees

        XCTAssertEqual(two - none, 2 * OnboardingPlanetScene.tiltPerShortcut, accuracy: 1e-12)
        XCTAssertEqual(scene(.shortcuts, tried: -3).tiltDegrees, none, "a negative count is treated as none")
    }

    func test_everyStepHasItsOwnPlanetPose() {
        let poses = OnboardingStep.allCases.map { step -> [Double] in
            let value = scene(step)
            return [value.tiltDegrees, value.bands]
        }
        XCTAssertEqual(Set(poses.map { "\($0)" }).count, OnboardingStep.allCases.count)
    }
}
