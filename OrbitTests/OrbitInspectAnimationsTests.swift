import XCTest

final class OrbitInspectAnimationsTests: XCTestCase {


    func testCubicBezierLinearIsIdentity() {
        for i in 0...10 {
            let t = Double(i) / 10.0
            let result = OrbitAnimationsLogic.evaluateCubicBezier(0.0, 0.0, 1.0, 1.0, t: t)
            XCTAssertEqual(result, t, accuracy: 0.001, "linear bezier should be identity at t=\(t)")
        }
    }

    func testCubicBezierEaseEndpoints() {
        let p1x = 0.25, p1y = 0.1, p2x = 0.25, p2y = 1.0
        XCTAssertEqual(OrbitAnimationsLogic.evaluateCubicBezier(p1x, p1y, p2x, p2y, t: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateCubicBezier(p1x, p1y, p2x, p2y, t: 1.0), 1.0, accuracy: 0.001)
    }

    func testCubicBezierEaseInSlowStart() {
        // ease-in: slow at beginning, faster toward the end
        let p1x = 0.42, p1y = 0.0, p2x = 1.0, p2y = 1.0
        let at25 = OrbitAnimationsLogic.evaluateCubicBezier(p1x, p1y, p2x, p2y, t: 0.25)
        let at75 = OrbitAnimationsLogic.evaluateCubicBezier(p1x, p1y, p2x, p2y, t: 0.75)
        XCTAssertLessThan(at25, 0.25, "ease-in should be below linear at 25%")
        XCTAssertLessThan(at75, 0.75, "ease-in stays below linear until it reaches 1")
        XCTAssertGreaterThan(at75, at25, "and it is still increasing")
    }

    func testCubicBezierParseRoundTrip() {
        let css = "cubic-bezier(0.25, 0.46, 0.45, 0.94)"
        let parsed = OrbitAnimationsLogic.parseEasing(css)
        guard case .cubicBezier(let p1x, let p1y, let p2x, let p2y) = parsed else {
            XCTFail("Expected cubicBezier parse result")
            return
        }
        XCTAssertEqual(p1x, 0.25, accuracy: 0.001)
        XCTAssertEqual(p1y, 0.46, accuracy: 0.001)
        XCTAssertEqual(p2x, 0.45, accuracy: 0.001)
        XCTAssertEqual(p2y, 0.94, accuracy: 0.001)
    }

    func testCubicBezierNamedEase() {
        guard case .cubicBezier(let a, let b, let c, let d) = OrbitAnimationsLogic.parseEasing("ease") else {
            XCTFail("ease should parse as cubicBezier"); return
        }
        XCTAssertEqual(a, 0.25, accuracy: 0.001)
        XCTAssertEqual(b, 0.1,  accuracy: 0.001)
        XCTAssertEqual(c, 0.25, accuracy: 0.001)
        XCTAssertEqual(d, 1.0,  accuracy: 0.001)
    }

    func testLinearEasingParsesAsIdentity() {
        let parsed = OrbitAnimationsLogic.parseEasing("linear")
        XCTAssertEqual(parsed, ParsedEasing.identity)
    }

    func testEasingEvaluationWithParsedIdentity() {
        let t = 0.6
        let result = OrbitAnimationsLogic.evaluateEasing(.identity, t: t)
        XCTAssertEqual(result, t, accuracy: 0.001)
    }


    func testStepsJumpEndBasic() {
        // steps(4, jump-end): output is 0 from 0..0.25, 0.25 from 0.25..0.5, etc.
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpEnd, t: 0.00), 0.00, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpEnd, t: 0.24), 0.00, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpEnd, t: 0.25), 0.25, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpEnd, t: 1.00), 1.00, accuracy: 0.001)
    }

    func testStepsJumpStartBasic() {
        // steps(4, jump-start): immediately jumps to 0.25 at t=0
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpStart, t: 0.0), 0.25, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateSteps(count: 4, jumpTerm: .jumpStart, t: 1.0), 1.00, accuracy: 0.001)
    }

    func testStepsJumpNoneDegenerateN1() {
        // jump-none with n=1: degenerate, should not divide by zero
        let result = OrbitAnimationsLogic.evaluateSteps(count: 1, jumpTerm: .jumpNone, t: 0.5)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testStepsJumpBoth() {
        // steps(2, jump-both): each step adds 1/(n+1) = 1/3
        let r0 = OrbitAnimationsLogic.evaluateSteps(count: 2, jumpTerm: .jumpBoth, t: 0.0)
        let r1 = OrbitAnimationsLogic.evaluateSteps(count: 2, jumpTerm: .jumpBoth, t: 1.0)
        XCTAssertEqual(r0, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(r1, 1.0, accuracy: 0.001)
    }

    func testStepsParseFromCSS() {
        let parsed = OrbitAnimationsLogic.parseEasing("steps(3, jump-start)")
        guard case .steps(let n, let jump) = parsed else {
            XCTFail("Expected steps parse"); return
        }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(jump, ParsedEasing.StepJump.jumpStart)
    }

    func testStepsParseStartAlias() {
        let parsed = OrbitAnimationsLogic.parseEasing("steps(2, start)")
        guard case .steps(let n, let jump) = parsed else {
            XCTFail(); return
        }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(jump, ParsedEasing.StepJump.jumpStart)
    }

    func testStepsParseEndAlias() {
        let parsed = OrbitAnimationsLogic.parseEasing("steps(4, end)")
        guard case .steps(let n, let jump) = parsed else {
            XCTFail(); return
        }
        XCTAssertEqual(n, 4)
        XCTAssertEqual(jump, ParsedEasing.StepJump.jumpEnd)
    }


    func testLinearFunctionTwoStopsIsIdentity() {
        let stops: [(Double, Double)] = [(0.0, 0.0), (1.0, 1.0)]
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 1.0), 1.0, accuracy: 0.001)
    }

    func testLinearFunctionNonUniform() {
        // Rapid rise to 1 in first quarter, flat afterward
        let stops: [(Double, Double)] = [(0.0, 0.0), (0.25, 1.0), (1.0, 1.0)]
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 0.125), 0.5, accuracy: 0.001)
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 0.5),   1.0, accuracy: 0.001)
    }

    func testLinearFunctionClampsBelowZero() {
        let stops: [(Double, Double)] = [(0.0, 0.5), (1.0, 0.8)]
        XCTAssertEqual(OrbitAnimationsLogic.evaluateLinearStops(stops, t: 0.0), 0.5, accuracy: 0.001)
    }


    func testActiveDurationFinite() {
        XCTAssertEqual(OrbitAnimationsLogic.activeDuration(duration: 300, iterations: 2), 600, accuracy: 0.001)
    }

    func testActiveDurationSingleIteration() {
        XCTAssertEqual(OrbitAnimationsLogic.activeDuration(duration: 500, iterations: 1), 500, accuracy: 0.001)
    }

    func testActiveDurationInfinite() {
        XCTAssertTrue(OrbitAnimationsLogic.activeDuration(duration: 300, iterations: .infinity).isInfinite)
    }

    func testActiveDurationZeroDuration() {
        XCTAssertEqual(OrbitAnimationsLogic.activeDuration(duration: 0, iterations: 3), 0)
    }

    func testActiveDurationZeroIterations() {
        XCTAssertEqual(OrbitAnimationsLogic.activeDuration(duration: 300, iterations: 0), 0)
    }


    func testIterationProgressNormalMidpoint() {
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 150, duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "normal", fill: "none"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 0.5, accuracy: 0.001)
    }

    func testIterationProgressBeforeDelayNoFill() {
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 50, duration: 300, delay: 100, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "normal", fill: "none"
        )
        XCTAssertNil(p, "before delay with fill=none should return nil")
    }

    func testIterationProgressBackwardsFill() {
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 50, duration: 300, delay: 100, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "normal", fill: "backwards"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 0.0, accuracy: 0.001)
    }

    func testIterationProgressForwardsFill() {
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 600, duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "normal", fill: "forwards"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 1.0, accuracy: 0.001)
    }

    func testIterationProgressAfterEndNoFill() {
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 600, duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "normal", fill: "none"
        )
        XCTAssertNil(p)
    }

    func testIterationProgressReverseMidpoint() {
        // reverse at midpoint → progress = 0.5 (mirrored mid-point is still 0.5)
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 150, duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "reverse", fill: "none"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 0.5, accuracy: 0.001)
    }

    func testIterationProgressReverseAtQuarter() {
        // At t=75/300=0.25, reversed: should be 0.75
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 75, duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0, direction: "reverse", fill: "none"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 0.75, accuracy: 0.001)
    }

    func testIterationProgressAlternateSecondIter() {
        // 2 iterations, alternate: at localTime=450 (150ms into the reversed second iteration) progress is 0.5
        let p = OrbitAnimationsLogic.iterationProgress(
            localTime: 450, duration: 300, delay: 0, endDelay: 0,
            iterations: 2, iterationStart: 0, direction: "alternate", fill: "none"
        )
        XCTAssertNotNil(p)
        XCTAssertEqual(p!, 0.5, accuracy: 0.001)
    }

    // MARK: - Compositability

    func testCompositableProperties() {
        XCTAssertTrue(OrbitAnimationsLogic.isCompositableProperty("transform"))
        XCTAssertTrue(OrbitAnimationsLogic.isCompositableProperty("opacity"))
        XCTAssertTrue(OrbitAnimationsLogic.isCompositableProperty("filter"))
        XCTAssertTrue(OrbitAnimationsLogic.isCompositableProperty("backdrop-filter"))
    }

    func testNonCompositableProperties() {
        XCTAssertFalse(OrbitAnimationsLogic.isCompositableProperty("width"))
        XCTAssertFalse(OrbitAnimationsLogic.isCompositableProperty("height"))
        XCTAssertFalse(OrbitAnimationsLogic.isCompositableProperty("top"))
        XCTAssertFalse(OrbitAnimationsLogic.isCompositableProperty("background-color"))
        XCTAssertFalse(OrbitAnimationsLogic.isCompositableProperty("box-shadow"))
    }

    func testLayoutTriggerHint() {
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("width"), "layout")
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("margin-top"), "layout")
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("font-size"), "layout")
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("flex-basis"), "layout")
    }

    func testPaintTriggerHint() {
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("background-color"), "paint")
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("box-shadow"), "paint")
        XCTAssertEqual(OrbitAnimationsLogic.compositabilityHint("color"), "paint")
    }

    func testCompositedPropertyHintNil() {
        XCTAssertNil(OrbitAnimationsLogic.compositabilityHint("transform"))
        XCTAssertNil(OrbitAnimationsLogic.compositabilityHint("opacity"))
        XCTAssertNil(OrbitAnimationsLogic.compositabilityHint("filter"))
    }

    // MARK: - Grouping

    func testGroupRowsByElement() {
        let records = [
            makeRecord(id: "a1", elementID: 1, label: "div.foo"),
            makeRecord(id: "a2", elementID: 2, label: "span.bar"),
            makeRecord(id: "a3", elementID: 1, label: "div.foo"),
        ]
        let groups = OrbitAnimationsLogic.groupRows(records)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].elementID, 1)
        XCTAssertEqual(groups[0].rows.count, 2)
        XCTAssertEqual(groups[1].elementID, 2)
        XCTAssertEqual(groups[1].rows.count, 1)
    }

    func testGroupRowsPreservesInsertionOrder() {
        let records = [
            makeRecord(id: "b1", elementID: 10, label: "a"),
            makeRecord(id: "b2", elementID: 20, label: "b"),
            makeRecord(id: "b3", elementID: 10, label: "a"),
        ]
        let groups = OrbitAnimationsLogic.groupRows(records)
        XCTAssertEqual(groups.map { $0.elementID }, [10, 20])
    }

    func testGroupRowsSingleElement() {
        let records = [
            makeRecord(id: "c1", elementID: 5, label: "p"),
        ]
        let groups = OrbitAnimationsLogic.groupRows(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.count, 1)
    }

    // MARK: - Time ruler ticks

    func testRulerTicksNonEmpty() {
        let ticks = OrbitAnimationsLogic.rulerTicks(totalDuration: 1000, availableWidth: 600)
        XCTAssertFalse(ticks.isEmpty)
    }

    func testRulerTicksFirstTickIsZero() {
        let ticks = OrbitAnimationsLogic.rulerTicks(totalDuration: 1000, availableWidth: 600)
        XCTAssertEqual(ticks.first?.ms ?? -1, 0.0, accuracy: 0.001)
    }

    func testRulerTicksAreSorted() {
        let ticks = OrbitAnimationsLogic.rulerTicks(totalDuration: 2000, availableWidth: 600)
        for i in 1..<ticks.count {
            XCTAssertGreaterThanOrEqual(ticks[i].ms, ticks[i - 1].ms)
        }
    }

    func testRulerTicksMajorHaveLabels() {
        let ticks = OrbitAnimationsLogic.rulerTicks(totalDuration: 1000, availableWidth: 600)
        for tick in ticks where tick.isMajor {
            XCTAssertFalse(tick.label.isEmpty, "major tick should have label at ms=\(tick.ms)")
        }
    }

    func testRulerFormatMilliseconds() {
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(0), "0ms")
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(100), "100ms")
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(500), "500ms")
    }

    func testRulerFormatSeconds() {
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(1000), "1s")
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(2000), "2s")
        XCTAssertEqual(OrbitAnimationsLogic.formatRulerTime(2500), "2.5s")
    }

    // MARK: - Event ring buffer

    func testRingBufferCaps() {
        var buffer: [AnimEvent] = []
        for i in 0..<600 {
            OrbitAnimationsLogic.addToRingBuffer(
                AnimEvent(id: "e\(i)", timestamp: Double(i), type: "animationstart",
                          elementLabel: "div", animationName: "fade", elapsedTime: 0),
                buffer: &buffer, cap: 500
            )
        }
        XCTAssertEqual(buffer.count, 500)
        XCTAssertEqual(buffer.last?.id, "e599")
    }

    func testRingBufferBelowCap() {
        var buffer: [AnimEvent] = []
        for i in 0..<10 {
            OrbitAnimationsLogic.addToRingBuffer(
                AnimEvent(id: "e\(i)", timestamp: Double(i), type: "animationend",
                          elementLabel: "p", animationName: "slide", elapsedTime: 0.3),
                buffer: &buffer, cap: 500
            )
        }
        XCTAssertEqual(buffer.count, 10)
    }

    func testRingBufferEvictsOldest() {
        var buffer: [AnimEvent] = []
        for i in 0..<5 {
            OrbitAnimationsLogic.addToRingBuffer(
                AnimEvent(id: "e\(i)", timestamp: Double(i), type: "transitionend",
                          elementLabel: "div", animationName: "opacity", elapsedTime: 0),
                buffer: &buffer, cap: 3
            )
        }
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.first?.id, "e2")
        XCTAssertEqual(buffer.last?.id, "e4")
    }

    // MARK: - Scrubber position <-> time

    func testScrubberXAtMidpoint() {
        let x = OrbitAnimationsLogic.scrubberX(currentTime: 500, totalDuration: 1000, width: 300)
        XCTAssertEqual(x, 150.0, accuracy: 0.001)
    }

    func testScrubberXAtStart() {
        let x = OrbitAnimationsLogic.scrubberX(currentTime: 0, totalDuration: 1000, width: 300)
        XCTAssertEqual(x, 0.0, accuracy: 0.001)
    }

    func testScrubberXAtEnd() {
        let x = OrbitAnimationsLogic.scrubberX(currentTime: 1000, totalDuration: 1000, width: 300)
        XCTAssertEqual(x, 300.0, accuracy: 0.001)
    }

    func testTimeFromScrubberXMidpoint() {
        let t = OrbitAnimationsLogic.timeFromScrubberX(150, totalDuration: 1000, width: 300)
        XCTAssertEqual(t, 500, accuracy: 0.001)
    }

    func testTimeFromScrubberXClampsNegative() {
        let t = OrbitAnimationsLogic.timeFromScrubberX(-50, totalDuration: 1000, width: 300)
        XCTAssertEqual(t, 0.0, accuracy: 0.001)
    }

    func testTimeFromScrubberXClampsOver() {
        let t = OrbitAnimationsLogic.timeFromScrubberX(400, totalDuration: 1000, width: 300)
        XCTAssertEqual(t, 1000.0, accuracy: 0.001)
    }

    func testScrubberRoundTrip() {
        let originalTime = 730.0
        let width = 500.0
        let duration = 2000.0
        let x = OrbitAnimationsLogic.scrubberX(currentTime: originalTime, totalDuration: duration, width: width)
        let roundTrip = OrbitAnimationsLogic.timeFromScrubberX(x, totalDuration: duration, width: width)
        XCTAssertEqual(roundTrip, originalTime, accuracy: 0.001)
    }

    // MARK: - Non-composited records

    func testNonCompositedFiltersOpacityOut() {
        let records = [makeRecord(id: "nc1", elementID: 1, label: "div", properties: ["opacity"])]
        let nc = OrbitAnimationsLogic.nonCompositedRecords(from: records)
        XCTAssertEqual(nc.count, 0, "opacity is composited and should not appear")
    }

    func testNonCompositedIncludesWidth() {
        let records = [makeRecord(id: "nc2", elementID: 2, label: "p", properties: ["width"])]
        let nc = OrbitAnimationsLogic.nonCompositedRecords(from: records)
        XCTAssertEqual(nc.count, 1)
        XCTAssertTrue(nc[0].properties.contains("width"))
    }

    func testNonCompositedMixed() {
        let records = [
            makeRecord(id: "nc3", elementID: 3, label: "h1", properties: ["transform", "background-color"]),
        ]
        let nc = OrbitAnimationsLogic.nonCompositedRecords(from: records)
        XCTAssertEqual(nc.count, 1)
        XCTAssertFalse(nc[0].properties.contains("transform"), "transform should be excluded")
        XCTAssertTrue(nc[0].properties.contains("background-color"))
    }

    func testNonCompositedGoneExcluded() {
        var r = makeRecord(id: "gone", elementID: 1, label: "div", properties: ["width"])
        r.isGone = true
        let nc = OrbitAnimationsLogic.nonCompositedRecords(from: [r])
        XCTAssertEqual(nc.count, 0, "gone animations should not appear in nonComposited")
    }

    // MARK: - Bar segments

    func testBarSegmentsAllPresent() {
        let segs = OrbitAnimationsLogic.barSegments(
            delay: 100, duration: 300, endDelay: 50, iterations: 1, totalDuration: 500)
        let kinds = Set(segs.map { $0.kind })
        XCTAssertTrue(kinds.contains("delay"))
        XCTAssertTrue(kinds.contains("active"))
        XCTAssertTrue(kinds.contains("end-delay"))
    }

    func testBarSegmentsNoDelayOrEndDelay() {
        let segs = OrbitAnimationsLogic.barSegments(
            delay: 0, duration: 300, endDelay: 0, iterations: 1, totalDuration: 300)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, "active")
    }

    // MARK: - Iteration separators

    func testIterationSeparatorsCount() {
        let seps = OrbitAnimationsLogic.iterationSeparators(
            delay: 0, duration: 300, iterations: 3, totalDuration: 900)
        XCTAssertEqual(seps.count, 2)  // separators between 1|2 and 2|3
    }

    func testIterationSeparatorsPositions() {
        let seps = OrbitAnimationsLogic.iterationSeparators(
            delay: 0, duration: 300, iterations: 3, totalDuration: 900)
        XCTAssertEqual(seps[0], 300.0 / 900.0, accuracy: 0.001)
        XCTAssertEqual(seps[1], 600.0 / 900.0, accuracy: 0.001)
    }

    func testIterationSeparatorsNoneForSingle() {
        let seps = OrbitAnimationsLogic.iterationSeparators(
            delay: 0, duration: 300, iterations: 1, totalDuration: 300)
        XCTAssertTrue(seps.isEmpty)
    }

    // MARK: - Helpers

    private func makeRecord(
        id: String,
        elementID: Int,
        label: String,
        properties: [String] = ["opacity"]
    ) -> AnimRecord {
        AnimRecord(
            id: id, type: .waapi, elementID: elementID, elementLabel: label,
            selector: label, name: id, properties: properties,
            playState: .running, playbackRate: 1.0,
            duration: 300, delay: 0, endDelay: 0,
            iterations: 1, iterationStart: 0,
            direction: .normal, fill: .fillNone,
            easing: "ease", composite: "replace",
            currentTime: 150, startTime: nil,
            keyframes: [], timelineKind: .document,
            scrollSource: "", isGone: false
        )
    }
}
