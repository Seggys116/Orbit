import XCTest
import AppKit

@MainActor
final class SpaceSwipeScrollPathTests: XCTestCase {

    // Counts every view-geometry call the app-wide .scrollWheel monitor could make.
    final class GeometrySpyView: SpaceSwipeGestureCatcher.PassThroughHitTestView {
        var convertCount = 0
        var boundsCount = 0

        override func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
            convertCount += 1
            return super.convert(point, from: view)
        }

        override var bounds: NSRect {
            get {
                boundsCount += 1
                return super.bounds
            }
            set { super.bounds = newValue }
        }
    }

    private func makeScrollEvent(phase: CGScrollPhase, deltaY: Double = -3) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        )!
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return NSEvent(cgEvent: cg)!
    }

    private func makeCoordinator() -> SpaceSwipeGestureCatcher.Coordinator {
        SpaceSwipeGestureCatcher.Coordinator(onBegin: {}, onChange: { _ in }, onEnd: { _, _ in })
    }

    private func makeWindow(hosting view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        window.contentView?.addSubview(view)
        return window
    }

    // MARK: - The monitor is app-wide, so its reject path must be free

    func test_scrollEventNotFromTheCatchersWindowDoesNoViewGeometryWork() {
        let spy = GeometrySpyView(frame: .zero)
        let window = makeWindow(hosting: spy)
        defer { window.close() }

        let coordinator = makeCoordinator()
        coordinator.attach(to: spy)
        XCTAssertNotEqual(
            coordinator.monitoredWindowNumber,
            0,
            "A real on-screen NSWindow always has a non-zero window number; without that the synthetic events below would not represent a foreign window."
        )

        spy.convertCount = 0
        spy.boundsCount = 0

        for phase in [CGScrollPhase.began, .changed, .changed, .ended] {
            let event = makeScrollEvent(phase: phase)
            XCTAssertEqual(
                event.windowNumber,
                0,
                "Synthetic CGEvent-backed scroll events carry window number 0, which is what makes them stand in for every wheel tick delivered to some other window."
            )
            XCTAssertTrue(
                coordinator.handle(event) === event,
                "NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) is application-wide: an event that is not for the sidebar's window must be passed straight back so the engine's own scrollWheel: still sees it."
            )
        }

        XCTAssertEqual(
            spy.convertCount,
            0,
            "Every wheel tick in the whole app runs this closure before RenderWidgetHostViewCocoa sees it. convert(_:from:) walks the view hierarchy, so doing it here taxes page scrolling on every surface."
        )
        XCTAssertEqual(
            spy.boundsCount,
            0,
            "bounds must not be read on the app-wide scroll path either — the containment test belongs behind the window check and the .began phase check."
        )
    }

    // Negative control: the spy really does count, so the zeroes above mean something.
    func test_geometrySpyCountsRealGeometryCalls() {
        let spy = GeometrySpyView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        _ = spy.convert(NSPoint(x: 10, y: 10), from: nil)
        _ = spy.bounds
        XCTAssertGreaterThan(spy.convertCount, 0)
        XCTAssertGreaterThan(spy.boundsCount, 0)
    }

    // The sidebar shares its window with the web view, so window scoping alone is not enough.
    func test_pageScrollingInTheSameWindowDoesNoViewGeometryWork() {
        let spy = GeometrySpyView(frame: .zero)
        let window = makeWindow(hosting: spy)
        defer { window.close() }

        let coordinator = makeCoordinator()
        coordinator.attach(to: spy)

        spy.convertCount = 0
        spy.boundsCount = 0

        for phase in [NSEvent.Phase.changed, .changed, .ended] {
            let event = TestScrollEvent(
                phase: phase,
                momentumPhase: [],
                locationInWindow: NSPoint(x: 700, y: 300),
                window: window,
                deltaX: 0,
                deltaY: -20
            )
            XCTAssertTrue(
                coordinator.handle(event) === event,
                "A wheel tick over the web view must be handed straight back untouched."
            )
        }

        XCTAssertEqual(
            spy.convertCount,
            0,
            "Only a gesture that has already begun inside the sidebar needs geometry; scrolling a page must not pay for a hit test it can never pass."
        )
        XCTAssertEqual(spy.boundsCount, 0)
    }

    func test_momentumScrollingInTheSameWindowDoesNoViewGeometryWork() {
        let spy = GeometrySpyView(frame: .zero)
        let window = makeWindow(hosting: spy)
        defer { window.close() }

        let coordinator = makeCoordinator()
        coordinator.attach(to: spy)

        spy.convertCount = 0
        spy.boundsCount = 0

        for momentum in [NSEvent.Phase.began, .changed, .changed, .ended] {
            let event = TestScrollEvent(
                phase: [],
                momentumPhase: momentum,
                locationInWindow: NSPoint(x: 700, y: 300),
                window: window,
                deltaX: 0,
                deltaY: -12
            )
            XCTAssertTrue(coordinator.handle(event) === event)
        }

        XCTAssertEqual(
            spy.convertCount,
            0,
            "Momentum is the longest, densest part of a flick — it is the worst place to walk a view hierarchy."
        )
        XCTAssertEqual(spy.boundsCount, 0)
    }

    // MARK: - One monitor, and only while the sidebar is really on screen

    func test_monitorExistsOnlyWhileTheCatcherIsInAWindow() {
        let view = SpaceSwipeGestureCatcher.PassThroughHitTestView(frame: .zero)
        let coordinator = makeCoordinator()
        coordinator.attach(to: view)

        XCTAssertFalse(
            coordinator.isMonitorInstalled,
            "A detached catcher must not install an application-wide scroll monitor — it would tax scrolling in every other window while showing nothing."
        )

        let window = makeWindow(hosting: view)
        defer { window.close() }

        XCTAssertTrue(coordinator.isMonitorInstalled)
        XCTAssertEqual(coordinator.monitoredWindowNumber, window.windowNumber)

        view.removeFromSuperview()

        XCTAssertFalse(
            coordinator.isMonitorInstalled,
            "Hiding the sidebar removes the catcher from its window; leaving the monitor behind is how monitor count grows with every sidebar toggle."
        )
        XCTAssertEqual(coordinator.monitoredWindowNumber, -1)
    }

    func test_reAttachingToAWindowDoesNotStackMonitors() {
        let view = SpaceSwipeGestureCatcher.PassThroughHitTestView(frame: .zero)
        let coordinator = makeCoordinator()
        coordinator.attach(to: view)

        let window = makeWindow(hosting: view)
        defer { window.close() }

        for _ in 0..<5 {
            view.removeFromSuperview()
            window.contentView?.addSubview(view)
        }

        XCTAssertTrue(coordinator.isMonitorInstalled)
        coordinator.detach()
        XCTAssertFalse(
            coordinator.isMonitorInstalled,
            "detach() must remove the one monitor; if attaching stacked several, this single removal would leave the rest running."
        )
    }

    // MARK: - The swipe itself still works

    func test_horizontalSwipeInsideTheCatcherIsStillDetectedAndSwallowed() {
        let view = SpaceSwipeGestureCatcher.PassThroughHitTestView(frame: .zero)
        let window = makeWindow(hosting: view)
        defer { window.close() }

        var began = 0
        var translations: [CGFloat] = []
        var ended: [(CGFloat, CGFloat)] = []
        let coordinator = SpaceSwipeGestureCatcher.Coordinator(
            onBegin: { began += 1 },
            onChange: { translations.append($0) },
            onEnd: { ended.append(($0, $1)) }
        )
        coordinator.attach(to: view)

        let begin = TestScrollEvent(
            phase: .began,
            momentumPhase: [],
            locationInWindow: NSPoint(x: 100, y: 300),
            window: window,
            deltaX: 0,
            deltaY: 0
        )
        XCTAssertNil(
            coordinator.handle(begin),
            "A precise scroll starting inside the sidebar must be claimed, or the space swipe never begins."
        )
        XCTAssertEqual(began, 1)

        for _ in 0..<4 {
            let move = TestScrollEvent(
                phase: .changed,
                momentumPhase: [],
                locationInWindow: NSPoint(x: 100, y: 300),
                window: window,
                deltaX: 20,
                deltaY: 1
            )
            XCTAssertNil(coordinator.handle(move))
        }
        XCTAssertFalse(translations.isEmpty, "Horizontal movement must drive the pager translation.")
        XCTAssertGreaterThan(translations.last ?? 0, 0)

        let end = TestScrollEvent(
            phase: .ended,
            momentumPhase: [],
            locationInWindow: NSPoint(x: 100, y: 300),
            window: window,
            deltaX: 0,
            deltaY: 0
        )
        XCTAssertNil(coordinator.handle(end))
        XCTAssertEqual(ended.count, 1, "The swipe must finalise so SpaceSwitchingSidebarContainer can commit or spring back.")
    }

    func test_verticalScrollInsideTheCatcherIsHandedBackToTheSidebarContent() {
        let view = SpaceSwipeGestureCatcher.PassThroughHitTestView(frame: .zero)
        let window = makeWindow(hosting: view)
        defer { window.close() }

        let coordinator = makeCoordinator()
        coordinator.attach(to: view)

        let begin = TestScrollEvent(
            phase: .began,
            momentumPhase: [],
            locationInWindow: NSPoint(x: 100, y: 300),
            window: window,
            deltaX: 0,
            deltaY: 0
        )
        _ = coordinator.handle(begin)

        var lastResult: NSEvent?
        for _ in 0..<4 {
            let move = TestScrollEvent(
                phase: .changed,
                momentumPhase: [],
                locationInWindow: NSPoint(x: 100, y: 300),
                window: window,
                deltaX: 0,
                deltaY: 20
            )
            lastResult = coordinator.handle(move)
        }
        XCTAssertNotNil(
            lastResult,
            "A vertical gesture over the sidebar belongs to the sidebar's own list, not to the space pager."
        )
    }
}

// A scroll event whose window, phase and deltas are all controllable; NSEvent(cgEvent:)
// cannot carry a window number, and the monitor's first decision is exactly that field.
private final class TestScrollEvent: NSEvent, @unchecked Sendable {
    private let stubPhase: NSEvent.Phase
    private let stubMomentumPhase: NSEvent.Phase
    private let stubLocation: NSPoint
    private weak var stubWindow: NSWindow?
    private let stubDeltaX: CGFloat
    private let stubDeltaY: CGFloat
    private let stubTimestamp: TimeInterval

    init(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        locationInWindow: NSPoint,
        window: NSWindow?,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) {
        stubPhase = phase
        stubMomentumPhase = momentumPhase
        stubLocation = locationInWindow
        stubWindow = window
        stubDeltaX = deltaX
        stubDeltaY = deltaY
        stubTimestamp = ProcessInfo.processInfo.systemUptime
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var type: NSEvent.EventType { .scrollWheel }
    override var phase: NSEvent.Phase { stubPhase }
    override var momentumPhase: NSEvent.Phase { stubMomentumPhase }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: NSPoint { stubLocation }
    override var window: NSWindow? { stubWindow }
    override var windowNumber: Int { stubWindow?.windowNumber ?? 0 }
    override var scrollingDeltaX: CGFloat { stubDeltaX }
    override var scrollingDeltaY: CGFloat { stubDeltaY }
    override var timestamp: TimeInterval { stubTimestamp }
}
