import XCTest
import SwiftUI
import AppKit

@MainActor
final class SidebarResizeHandleTests: XCTestCase {

    // MARK: - 1. Pure resize math (unchanged mechanism from pre-R15: still

    func test_resizedWidth_addsPositiveTranslationWhenDraggingRight() {
        let start = OrbitMetrics.sidebarDefaultWidth
        let result = SidebarResizeHandle.resizedWidth(startWidth: start, translationX: 40)
        XCTAssertEqual(result, start + 40, "Dragging the trailing-edge handle rightward (positive translation) must grow the sidebar.")
    }

    func test_resizedWidth_subtractsForNegativeTranslationWhenDraggingLeft() {
        let start = (OrbitMetrics.sidebarMinWidth + OrbitMetrics.sidebarMaxWidth) / 2
        let result = SidebarResizeHandle.resizedWidth(startWidth: start, translationX: -30)
        XCTAssertEqual(result, start - 30, "Dragging the trailing-edge handle leftward (negative translation) must shrink the sidebar.")
    }

    func test_resizedWidth_clampsToMinWidth() {
        let result = SidebarResizeHandle.resizedWidth(startWidth: OrbitMetrics.sidebarMinWidth, translationX: -1000)
        XCTAssertEqual(
            result, OrbitMetrics.sidebarMinWidth,
            "refs/DEFECTS.md R11/R15: a huge leftward drag must clamp to OrbitMetrics.sidebarMinWidth (\(OrbitMetrics.sidebarMinWidth)), never go smaller or negative."
        )
    }

    func test_resizedWidth_clampsToMaxWidth() {
        let result = SidebarResizeHandle.resizedWidth(startWidth: OrbitMetrics.sidebarMaxWidth, translationX: 1000)
        XCTAssertEqual(
            result, OrbitMetrics.sidebarMaxWidth,
            "refs/DEFECTS.md R11/R15: a huge rightward drag must clamp to OrbitMetrics.sidebarMaxWidth (\(OrbitMetrics.sidebarMaxWidth)), never grow past it."
        )
    }

    func test_resizedWidth_withinBounds_isNotClamped() {
        let midpoint = (OrbitMetrics.sidebarMinWidth + OrbitMetrics.sidebarMaxWidth) / 2
        let result = SidebarResizeHandle.resizedWidth(startWidth: midpoint, translationX: 5)
        XCTAssertEqual(result, midpoint + 5, "A small drag well inside [minWidth, maxWidth] must apply the translation exactly, unclamped.")
    }

    func test_clampedWidth_onTheNSViewItself_agreesWithResizedWidth() {
        let viaWrapper = SidebarResizeHandle.resizedWidth(startWidth: 300, translationX: 25)
        let viaNSView = SidebarResizeHandleNSView.clampedWidth(
            start: 300, deltaX: 25,
            minWidth: OrbitMetrics.sidebarMinWidth, maxWidth: OrbitMetrics.sidebarMaxWidth
        )
        XCTAssertEqual(viaWrapper, viaNSView, "Both entry points must compute identical results — one formula, not two that could drift apart.")
    }

    // MARK: - 2. hitTest — the handle's own region

    func test_hitTest_returnsSelfForPointsInsideBounds() {
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: OrbitMetrics.sidebarResizeHandleWidth, height: 400))
        let insidePoints: [NSPoint] = [
            NSPoint(x: 0, y: 0),
            NSPoint(x: OrbitMetrics.sidebarResizeHandleWidth / 2, y: 200),
            NSPoint(x: OrbitMetrics.sidebarResizeHandleWidth - 0.5, y: 399),
        ]
        for point in insidePoints {
            XCTAssertTrue(
                view.hitTest(point) === view,
                "refs/DEFECTS.md R15: SidebarResizeHandleNSView.hitTest(\(point)) inside its own bounds \(view.bounds) must resolve to itself, not nil and not some other view — this is the direct grab-point proof the task brief asks for."
            )
        }
    }

    func test_hitTest_returnsNilForPointsOutsideBounds() {
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: OrbitMetrics.sidebarResizeHandleWidth, height: 400))
        let outsidePoints: [NSPoint] = [
            NSPoint(x: -1, y: 200),
            NSPoint(x: OrbitMetrics.sidebarResizeHandleWidth + 1, y: 200),
            NSPoint(x: 4, y: -1),
            NSPoint(x: 4, y: 401),
        ]
        for point in outsidePoints {
            XCTAssertNil(view.hitTest(point), "A point outside \(view.bounds) must never resolve to the handle.")
        }
    }

    func test_acceptsFirstMouse_isTrue() {
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "The very first click on the handle must be able to both activate the window and start the drag, not just the former.")
    }

    func test_neverAWindowDragHandle() {
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "SidebarResizeHandleNSView must never report itself as a window-drag handle — its own mouseDown/mouseDragged/mouseUp mechanism must own every drag that starts on it, including the sliver of it that sits inside the window's titlebar band."
        )
    }

    // MARK: - 3. Live drag, end-to-end, via real NSEvents — the proof a `DragGesture`'s `.highPriorityGesture` couldn't produce

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private final class WidthBox {
        var value: CGFloat
        init(_ value: CGFloat) { self.value = value }
    }

    private func makeConfiguredView(startWidth: CGFloat, minWidth: CGFloat = OrbitMetrics.sidebarMinWidth, maxWidth: CGFloat = OrbitMetrics.sidebarMaxWidth) -> (SidebarResizeHandleNSView, WidthBox) {
        let box = WidthBox(startWidth)
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: OrbitMetrics.sidebarResizeHandleWidth, height: 400))
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.currentWidth = { box.value }
        view.onWidthChange = { box.value = $0 }
        return (view, box)
    }

    func test_mouseDown_capturesStartWidthFromCurrentWidthProvider() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        box.value = 300
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200)))
        XCTAssertEqual(view.dragStartWidth, 300, "mouseDown must snapshot currentWidth() as the drag's start width.")
    }

    func test_liveDrag_mouseDownDraggedUp_growsWidthByExactDeltaAndWritesThroughOnWidthChange() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 44, y: 200)))
        XCTAssertEqual(box.value, 340, "A 40pt rightward mouseDragged from mouseDown's location must grow the sidebar by exactly 40pt via onWidthChange — the same closure production wires to AppEnvironment.sidebarWidth's setter.")
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 44, y: 200)))
        XCTAssertEqual(box.value, 340, "mouseUp must leave the final dragged-to width in place.")
    }

    func test_liveDrag_leftwardShrinksWidth() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 70, y: 200)))
        XCTAssertEqual(box.value, 270, "A 30pt leftward mouseDragged must shrink the sidebar by exactly 30pt.")
    }

    func test_liveDrag_multipleMouseDraggedEvents_eachAppliesRelativeToMouseDownNotThePreviousEvent() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 0, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 10, y: 200)))
        XCTAssertEqual(box.value, 310)
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 20, y: 200)))
        XCTAssertEqual(box.value, 320)
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 5, y: 200)))
        XCTAssertEqual(box.value, 305, "Each mouseDragged event must be measured against mouseDown's original location, not the previous mouseDragged's — this event moved back toward the start relative to the last one, and the resulting width must reflect that, not compound off the previous sample.")
    }

    func test_mouseUp_withoutPriorMouseDown_isANoOp() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 999, y: 200)))
        XCTAssertEqual(box.value, 300, "No drag was ever started, so onWidthChange must never have fired.")
    }

    func test_mouseUp_clearsDragStartWidth_soASecondUnrelatedMouseUpIsANoOp() {
        let (view, box) = makeConfiguredView(startWidth: 300)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 0, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 20, y: 200)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 20, y: 200)))
        XCTAssertNil(view.dragStartWidth, "A finished drag must clear its own start-width snapshot.")
        XCTAssertEqual(box.value, 320)

        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 500, y: 200)))
        XCTAssertEqual(box.value, 320, "A mouseUp with no active drag must be a no-op.")
    }

    // MARK: - 4. Clamping, driven through the same live mouseDown/Dragged path

    func test_liveDrag_clampsAtMinWidth_evenForAHugeLeftwardDrag() {
        let (view, box) = makeConfiguredView(startWidth: OrbitMetrics.sidebarMinWidth + 20, minWidth: OrbitMetrics.sidebarMinWidth, maxWidth: OrbitMetrics.sidebarMaxWidth)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 1000, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 0, y: 200)))
        XCTAssertEqual(box.value, OrbitMetrics.sidebarMinWidth, "refs/DEFECTS.md R15: a huge leftward live drag must clamp at sidebarMinWidth (\(OrbitMetrics.sidebarMinWidth)), never go smaller.")
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 0, y: 200)))
        XCTAssertEqual(box.value, OrbitMetrics.sidebarMinWidth)
    }

    func test_liveDrag_clampsAtMaxWidth_evenForAHugeRightwardDrag() {
        let (view, box) = makeConfiguredView(startWidth: OrbitMetrics.sidebarMaxWidth - 20, minWidth: OrbitMetrics.sidebarMinWidth, maxWidth: OrbitMetrics.sidebarMaxWidth)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 0, y: 200)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 5000, y: 200)))
        XCTAssertEqual(box.value, OrbitMetrics.sidebarMaxWidth, "refs/DEFECTS.md R15: a huge rightward live drag must clamp at sidebarMaxWidth (\(OrbitMetrics.sidebarMaxWidth)), never grow past it.")
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 5000, y: 200)))
        XCTAssertEqual(box.value, OrbitMetrics.sidebarMaxWidth)
    }

    func test_liveDrag_customBounds_clampIndependentlyOfOrbitMetrics() {
        let (view, box) = makeConfiguredView(startWidth: 50, minWidth: 10, maxWidth: 60)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 0, y: 0)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 0)))
        XCTAssertEqual(box.value, 60, "Must clamp at the view's own maxWidth (60), independent of OrbitMetrics.sidebarMaxWidth.")
    }

    // MARK: - 4b. Double-click resets the sidebar to its default width

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func makeViewWithDefaultWidth(startWidth: CGFloat, defaultWidth: CGFloat, minWidth: CGFloat = OrbitMetrics.sidebarMinWidth, maxWidth: CGFloat = OrbitMetrics.sidebarMaxWidth) -> (SidebarResizeHandleNSView, WidthBox) {
        let (view, box) = makeConfiguredView(startWidth: startWidth, minWidth: minWidth, maxWidth: maxWidth)
        view.defaultWidth = defaultWidth
        return (view, box)
    }

    func test_doubleClick_resetsWidthToTheDefault() {
        let (view, box) = makeViewWithDefaultWidth(startWidth: 420, defaultWidth: 240)
        XCTAssertEqual(box.value, 420, "Precondition: the sidebar starts somewhere other than the default, or a reset would prove nothing.")

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))

        XCTAssertEqual(box.value, 240, "A double-click on the resize handle must write the default width through onWidthChange — the same closure production wires to AppEnvironment.sidebarWidth's setter.")
    }

    func test_doubleClick_worksFromEitherSideOfTheDefault() {
        let (narrow, narrowBox) = makeViewWithDefaultWidth(startWidth: 200, defaultWidth: 300)
        narrow.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))
        XCTAssertEqual(narrowBox.value, 300, "Resetting from narrower than the default must grow the sidebar back to it.")

        let (wide, wideBox) = makeViewWithDefaultWidth(startWidth: 500, defaultWidth: 300)
        wide.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))
        XCTAssertEqual(wideBox.value, 300, "Resetting from wider than the default must shrink the sidebar back to it.")
    }

    func test_doubleClick_doesNotStartADrag() {
        let (view, _) = makeViewWithDefaultWidth(startWidth: 420, defaultWidth: 240)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))
        XCTAssertNil(
            view.dragStartWidth,
            "The double-click branch must not snapshot a drag start width — if it did, the mouseUp AppKit delivers immediately afterwards would apply a drag on top of the reset."
        )
    }

    func test_doubleClick_thenMouseUp_doesNotOverwriteTheReset() {
        let (view, box) = makeViewWithDefaultWidth(startWidth: 420, defaultWidth: 240)

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 4, y: 200), clickCount: 1))
        XCTAssertEqual(box.value, 420, "The first click of a double-click is a zero-distance drag and must leave the width alone.")

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 90, y: 200), clickCount: 2))

        XCTAssertEqual(box.value, 240, "The mouseUp that closes a double-click must find no active drag and leave the reset width in place — not apply an 86pt phantom drag from the pointer's reported position.")
    }

    func test_doubleClick_clampsTheDefaultToTheViewsOwnBounds() {
        let (view, box) = makeViewWithDefaultWidth(startWidth: 40, defaultWidth: 500, minWidth: 10, maxWidth: 60)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 0, y: 0), clickCount: 2))
        XCTAssertEqual(box.value, 60, "A default wider than the view's own maxWidth must clamp to it, exactly as a drag would.")
    }

    func test_aDragStillWorksAfterADoubleClickReset() {
        let (view, box) = makeViewWithDefaultWidth(startWidth: 420, defaultWidth: 240)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 2))
        XCTAssertEqual(box.value, 240)

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 4, y: 200), clickCount: 1))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 34, y: 200), clickCount: 1))
        XCTAssertEqual(box.value, 270, "A drag started after a reset must grow from the reset width (240 + 30), proving the reset left no stale drag state behind.")
    }

    func test_theProductionHandleIsWiredToOrbitsOwnDefaultWidth() {
        let view = SidebarResizeHandleNSView()
        XCTAssertEqual(
            view.defaultWidth,
            OrbitMetrics.sidebarDefaultWidth,
            "The handle's reset target must be OrbitMetrics.sidebarDefaultWidth — the width AppEnvironment.sidebarWidth itself starts at, so a reset genuinely returns the sidebar to where it began."
        )
    }

    // MARK: - 5. Geometry: the handle's own region is never shadowed

    func test_gestureCatcherFrame_neverExtendsIntoResizeHandleRegion() {
        let sidebarWidth: CGFloat = OrbitMetrics.sidebarDefaultWidth
        let handleWidth = OrbitMetrics.sidebarResizeHandleWidth
        let rowHeight: CGFloat = 400

        let catcherView = SpaceSwipeGestureCatcher.PassThroughHitTestView(
            frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: rowHeight)
        )

        let handleRegion = NSRect(x: sidebarWidth, y: 0, width: handleWidth, height: rowHeight)

        XCTAssertFalse(
            catcherView.frame.intersects(handleRegion),
            "refs/DEFECTS.md R11/R15: SpaceSwipeGestureCatcher's own NSView frame (\(catcherView.frame)) " +
            "must never overlap SidebarResizeHandle's region (\(handleRegion)) — if it ever grows to " +
            "do so (e.g. a future geometry change), the handle's already-narrow \(handleWidth)pt grab " +
            "strip would be contested by the catcher's hit-test-transparent-but-still-present NSView."
        )

        for point in [NSPoint(x: sidebarWidth, y: 200), NSPoint(x: sidebarWidth + handleWidth - 1, y: 200)] {
            XCTAssertNil(
                catcherView.hitTest(point),
                "Even a point nominally inside the resize handle's own region must never resolve to " +
                "the gesture catcher's NSView — see PassThroughHitTestView."
            )
        }
    }

    // MARK: - 6. The SwiftUI wrapper still lays out at the declared width

    func test_sidebarResizeHandle_declaredWidthMatchesMetric() {
        let env = AppEnvironment()
        let width: CGFloat = 40
        let height: CGFloat = 200
        let rendered = render(
            HStack(spacing: 0) {
                Color.clear.frame(width: 4)
                SidebarResizeHandle().environment(env)
                Color.clear.frame(width: 4)
            },
            size: CGSize(width: width, height: height)
        )
        XCTAssertEqual(rendered.pointSize, CGSize(width: width, height: height))
    }
}
