import AppKit
import XCTest

@MainActor
final class OrbitScrollerTests: XCTestCase {

    // MARK: - Width

    func test_theScrollerIsThinnerThanAppKitsAtEveryControlSizeAndStyle() {
        let sizes: [NSControl.ControlSize] = [.regular, .small, .mini, .large]
        let styles: [NSScroller.Style] = [.overlay, .legacy]

        for size in sizes {
            for style in styles {
                let orbit = OrbitScroller.scrollerWidth(for: size, scrollerStyle: style)
                let stock = NSScroller.scrollerWidth(for: size, scrollerStyle: style)

                XCTAssertEqual(
                    orbit, OrbitScrollerMetrics.thickness,
                    "Orbit's scroller must be \(OrbitScrollerMetrics.thickness)pt at every control size and scroller style; at size \(size.rawValue)/style \(style.rawValue) it reported \(orbit)."
                )
                XCTAssertLessThan(
                    orbit, stock,
                    "Orbit's scroller must be narrower than AppKit's — that is the whole point of the type. At control size \(size.rawValue), scroller style \(style.rawValue), AppKit measures \(stock)pt and Orbit measures \(orbit)pt."
                )
            }
        }
    }

    func test_theScrollerDeclaresItselfUsableUnderOverlayScrollerStyle() {
        XCTAssertTrue(
            OrbitScroller.isCompatibleWithOverlayScrollers,
            "AppKit substitutes its own scroller for any custom subclass that does not declare overlay compatibility, which would undo the width override on the default macOS configuration."
        )
    }

    // MARK: - Installation

    func test_aRealScrollViewLaysOutTheThinScrollerOnBothAxes() {
        let stock = makeScrollView()
        let stockVertical = stock.verticalScroller?.frame.width ?? 0
        let stockHorizontal = stock.horizontalScroller?.frame.height ?? 0
        XCTAssertGreaterThan(
            stockVertical, OrbitScrollerMetrics.thickness,
            "The premise of this test is that AppKit's own scroller is wider than Orbit's. It measured \(stockVertical)pt."
        )

        let orbit = makeScrollView()
        XCTAssertTrue(OrbitScrollerInstaller.apply(to: orbit), "A scroll view with stock scrollers must be reported as changed.")
        orbit.tile()
        orbit.layoutSubtreeIfNeeded()

        guard let vertical = orbit.verticalScroller, let horizontal = orbit.horizontalScroller else {
            return XCTFail("The installer must leave both scrollers in place, not remove them.")
        }
        XCTAssertTrue(vertical is OrbitScroller, "The vertical scroller must be Orbit's, not \(type(of: vertical)).")
        XCTAssertTrue(horizontal is OrbitScroller, "The horizontal scroller must be Orbit's, not \(type(of: horizontal)).")

        XCTAssertEqual(vertical.frame.width, OrbitScrollerMetrics.thickness, accuracy: 0.01,
                       "AppKit must lay the vertical scroller out at Orbit's width. The same harness measures \(stockVertical)pt with AppKit's own scroller.")
        XCTAssertEqual(horizontal.frame.height, OrbitScrollerMetrics.thickness, accuracy: 0.01,
                       "AppKit must lay the horizontal scroller out at Orbit's width. The same harness measures \(stockHorizontal)pt with AppKit's own scroller.")
    }

    func test_applyingTwiceReplacesNothingTheSecondTime() {
        let scrollView = makeScrollView()
        XCTAssertTrue(OrbitScrollerInstaller.apply(to: scrollView))
        let vertical = scrollView.verticalScroller
        let horizontal = scrollView.horizontalScroller

        XCTAssertFalse(
            OrbitScrollerInstaller.apply(to: scrollView),
            "A scroll view that already has Orbit's scrollers must be reported as unchanged."
        )
        XCTAssertTrue(scrollView.verticalScroller === vertical, "The vertical scroller instance must survive a second apply.")
        XCTAssertTrue(scrollView.horizontalScroller === horizontal, "The horizontal scroller instance must survive a second apply.")
    }

    func test_aScrollViewWithNoScrollerIsLeftWithoutOne() {
        let scrollView = makeScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        XCTAssertFalse(
            OrbitScrollerInstaller.apply(to: scrollView),
            "A scroll view that shows no indicators must be reported as unchanged."
        )
        XCTAssertFalse(scrollView.hasVerticalScroller, "The retrofit must not switch a hidden vertical indicator back on.")
        XCTAssertFalse(scrollView.hasHorizontalScroller, "The retrofit must not switch a hidden horizontal indicator back on.")
    }

    func test_aWindowSweepReachesNestedScrollViews() {
        let outer = makeScrollView()
        let inner = makeScrollView(width: 120, height: 120)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        container.addSubview(inner)
        outer.documentView = container

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.addSubview(outer)

        OrbitScrollerInstaller.sweep(root)

        XCTAssertTrue(outer.verticalScroller is OrbitScroller, "The sweep must reach a scroll view nested one level under the root.")
        XCTAssertTrue(inner.verticalScroller is OrbitScroller, "The sweep must reach a scroll view nested inside another scroll view's document view.")
    }

    // MARK: - Drawing

    func test_theKnobPaintsAThinCentredPillAndNoTrack() {
        let (window, scrollView) = makeHostedScrollView()
        withExtendedLifetime(window) {
            guard let vertical = scrollView.verticalScroller as? OrbitScroller,
                  let horizontal = scrollView.horizontalScroller as? OrbitScroller else {
                return XCTFail("The installer must have replaced both scrollers before this test can measure them.")
            }

            let verticalBitmap = paintKnob(of: vertical)
            let verticalKnob = vertical.rect(for: .knob)
            let knobRow = Int(vertical.bounds.height - verticalKnob.midY)
            let paintedColumns = paintedIndices(in: verticalBitmap, row: knobRow)

            XCTAssertFalse(paintedColumns.isEmpty, "The vertical knob must paint something at its own mid-point (row \(knobRow) of \(verticalBitmap.pixelsHigh)).")
            XCTAssertLessThanOrEqual(
                CGFloat(paintedColumns.count), OrbitScrollerMetrics.knobThickness,
                "The vertical knob must be no thicker than \(OrbitScrollerMetrics.knobThickness)pt; it painted columns \(paintedColumns) of a \(verticalBitmap.pixelsWide)pt band."
            )
            XCTAssertEqual(
                Double(paintedColumns.reduce(0, +)) / Double(paintedColumns.count),
                Double(vertical.bounds.midX) - 0.5, accuracy: 1.0,
                "The vertical knob must sit centred in the scroller's band, not against either edge."
            )

            let horizontalBitmap = paintKnob(of: horizontal)
            let horizontalKnob = horizontal.rect(for: .knob)
            let paintedRows = paintedIndices(in: horizontalBitmap, column: Int(horizontalKnob.midX))

            XCTAssertFalse(paintedRows.isEmpty, "The horizontal knob must paint something at its own mid-point.")
            XCTAssertLessThanOrEqual(
                CGFloat(paintedRows.count), OrbitScrollerMetrics.knobThickness,
                "The horizontal knob must be no thicker than \(OrbitScrollerMetrics.knobThickness)pt; it painted rows \(paintedRows) of a \(horizontalBitmap.pixelsHigh)pt band."
            )

            let trackOnly = blankBitmap(size: vertical.bounds.size)
            draw(into: trackOnly) {
                vertical.drawKnobSlot(in: vertical.rect(for: .knobSlot), highlight: true)
            }
            for row in stride(from: 0, to: trackOnly.pixelsHigh, by: 8) {
                XCTAssertTrue(
                    paintedIndices(in: trackOnly, row: row).isEmpty,
                    "Orbit's scroller must paint no track at all, highlighted or not; row \(row) came back painted."
                )
            }
        }
    }

    // MARK: - Harness

    private func makeScrollView(width: CGFloat = 300, height: CGFloat = 200) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: width * 2, height: height * 4))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeHostedScrollView() -> (NSWindow, NSScrollView) {
        let scrollView = makeScrollView()
        _ = OrbitScrollerInstaller.apply(to: scrollView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.layoutIfNeeded()
        return (window, scrollView)
    }

    private func blankBitmap(size: NSSize) -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("Could not allocate a \(size) bitmap to draw a scroller into.")
        }
        return rep
    }

    private func draw(into bitmap: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func paintKnob(of scroller: OrbitScroller) -> NSBitmapImageRep {
        let bitmap = blankBitmap(size: scroller.bounds.size)
        draw(into: bitmap) { scroller.drawKnob() }
        return bitmap
    }

    private func paintedIndices(in bitmap: NSBitmapImageRep, row: Int) -> [Int] {
        guard row >= 0, row < bitmap.pixelsHigh else { return [] }
        return (0..<bitmap.pixelsWide).filter { (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0.02 }
    }

    private func paintedIndices(in bitmap: NSBitmapImageRep, column: Int) -> [Int] {
        guard column >= 0, column < bitmap.pixelsWide else { return [] }
        return (0..<bitmap.pixelsHigh).filter { (bitmap.colorAt(x: column, y: $0)?.alphaComponent ?? 0) > 0.02 }
    }
}
