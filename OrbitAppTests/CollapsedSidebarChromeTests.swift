import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class CollapsedSidebarChromeTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    private func makeTab(splitIndex: Int = 0) -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        var tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com")!, title: "")
        tab.splitIndex = splitIndex
        env.state.tabs[tab.id] = tab
        return tab
    }

    private var fourthNavBox: CGRect {
        let x = OrbitToolbarMetrics.leadingPadding
            + OrbitToolbarMetrics.navIconSize * 3
            + OrbitToolbarMetrics.navIconSpacing * 3
        return CGRect(
            x: x + 2,
            y: OrbitToolbarMetrics.topPadding,
            width: OrbitToolbarMetrics.navIconSize - 4,
            height: OrbitToolbarMetrics.height
        )
    }

    private func renderHeader(tab: Orbit.Tab, width: CGFloat) -> RenderedImage {
        render(
            ToolbarView(tab: tab)
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: CGSize(width: width, height: OrbitToolbarMetrics.totalHeight)
        )
    }

    // MARK: - 1. The toggle appears exactly when the sidebar is collapsed

    func test_sidebarCollapsed_paneHeaderDrawsAFourthLeadingControl() throws {
        let tab = makeTab()
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        env.isSidebarVisible = false
        let collapsed = renderHeader(tab: tab, width: 640)
        collapsed.writeDiagnosticPNG(named: "collapsed-sidebar-pane-header")

        let background = collapsed.color(atX: 2, y: 2)
        XCTAssertTrue(
            collapsed.containsNonBackgroundPixels(in: fourthNavBox, background: background),
            "With the sidebar collapsed the nav cluster must carry four controls — sidebar toggle, back, forward, reload — so the fourth box \(fourthNavBox) has ink in it."
        )
    }

    func test_sidebarVisible_paneHeaderKeepsItsThreeLeadingControls() throws {
        let tab = makeTab()
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        env.isSidebarVisible = true
        let docked = renderHeader(tab: tab, width: 641)

        let background = docked.color(atX: 2, y: 2)
        XCTAssertFalse(
            docked.containsNonBackgroundPixels(in: fourthNavBox, background: background),
            "While the sidebar is docked its toggle lives in `SidebarTopRow`; a second one here would be two controls for one piece of state."
        )
    }

    func test_sidebarCollapsed_trailingSplitPaneDrawsNoToggle() throws {
        let leading = makeTab(splitIndex: 0)
        let trailing = makeTab(splitIndex: 1)
        defer {
            env.state.tabs.removeValue(forKey: leading.id)
            env.state.tabs.removeValue(forKey: trailing.id)
        }

        env.isSidebarVisible = false
        let leadingPane = renderHeader(tab: leading, width: 642)
        let trailingPane = renderHeader(tab: trailing, width: 643)

        XCTAssertTrue(
            leadingPane.containsNonBackgroundPixels(in: fourthNavBox, background: leadingPane.color(atX: 2, y: 2)),
            "Pane 0 is the leftmost pane — the edge the sidebar slides in from — and is the one that carries the toggle."
        )
        XCTAssertFalse(
            trailingPane.containsNonBackgroundPixels(in: fourthNavBox, background: trailingPane.color(atX: 2, y: 2)),
            "A right-hand split pane must not draw a second toggle for the same window-wide state."
        )
    }

    // MARK: - 2. The resize handle's grabber

    private func drawHandle(height: CGFloat, scale: CGFloat, dragging: Bool = false) throws -> NSBitmapImageRep {
        let width = OrbitMetrics.sidebarResizeHandleWidth
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let enter = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        view.mouseEntered(with: enter)
        if dragging {
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: width / 2, y: height / 2),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            view.mouseDown(with: down)
        }

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        bitmap.size = NSSize(width: width * scale, height: height * scale)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixelsPerPoint(_ bitmap: NSBitmapImageRep) -> CGFloat {
        CGFloat(bitmap.pixelsWide) / OrbitMetrics.sidebarResizeHandleWidth
    }

    private func writeMagnifiedPNG(_ bitmap: NSBitmapImageRep, named: String, magnification: CGFloat) {
        let size = NSSize(width: CGFloat(bitmap.pixelsWide) * magnification, height: CGFloat(bitmap.pixelsHigh) * magnification)
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        guard let pixels = canvas.bitmapData else { return }
        let background: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.18, 0.18, 0.20)
        for y in 0..<canvas.pixelsHigh {
            for x in 0..<canvas.pixelsWide {
                let source = bitmap.colorAt(x: Int(CGFloat(x) / magnification), y: Int(CGFloat(y) / magnification))?
                    .usingColorSpace(.sRGB)
                let alpha = source?.alphaComponent ?? 0
                let offset = y * canvas.bytesPerRow + x * (canvas.bitsPerPixel / 8)
                func blend(_ channel: CGFloat, over base: CGFloat) -> UInt8 {
                    UInt8(max(0, min(255, (channel * alpha + base * (1 - alpha)) * 255)))
                }
                pixels[offset] = blend(source?.redComponent ?? 0, over: background.r)
                pixels[offset + 1] = blend(source?.greenComponent ?? 0, over: background.g)
                pixels[offset + 2] = blend(source?.blueComponent ?? 0, over: background.b)
                pixels[offset + 3] = 255
            }
        }

        guard let data = canvas.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrbitTests-Diagnostics", isDirectory: true)
            .appendingPathComponent("\(named).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        print("CollapsedSidebarChromeTests: wrote \(named) PNG to \(url.path)")
    }

    private func paintedSpan(_ bitmap: NSBitmapImageRep, row: Int) -> (maxAlpha: CGFloat, range: ClosedRange<Int>?) {
        var maxAlpha: CGFloat = 0
        var first: Int?
        var last: Int?
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: row) else { continue }
            let alpha = color.alphaComponent
            maxAlpha = max(maxAlpha, alpha)
            if alpha > 0.05 {
                if first == nil { first = x }
                last = x
            }
        }
        guard let first, let last else { return (maxAlpha, nil) }
        return (maxAlpha, first...last)
    }

    func test_resizeHandle_grabberIsWhiteThickAndInsetTopAndBottom() throws {
        let height: CGFloat = 64
        let bitmap = try drawHandle(height: height, scale: 1)
        let ppp = pixelsPerPoint(bitmap)
        writeMagnifiedPNG(bitmap, named: "sidebar-resize-handle-hover", magnification: 4)

        let middle = paintedSpan(bitmap, row: bitmap.pixelsHigh / 2)
        let span = try XCTUnwrap(middle.range, "The grabber must paint something across the handle's middle while hovered.")
        XCTAssertEqual(
            CGFloat(span.count) / ppp, SidebarResizeHandleNSView.grabberWidth, accuracy: 1,
            "Thicker than the 2pt line it replaced: \(SidebarResizeHandleNSView.grabberWidth)pt wide, centred in the \(OrbitMetrics.sidebarResizeHandleWidth)pt strip."
        )

        let centreX = (span.lowerBound + span.upperBound) / 2
        let centre = try XCTUnwrap(bitmap.colorAt(x: centreX, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(centre.redComponent, centre.greenComponent, accuracy: 0.02, "White has no hue — a red channel above the green is the accent colour coming back.")
        XCTAssertEqual(centre.redComponent, centre.blueComponent, accuracy: 0.02)
        XCTAssertGreaterThan(centre.redComponent, 0.85, "The grabber paints white, not a mid grey.")

        let insetProbe = Int(SidebarResizeHandleNSView.grabberVerticalInset / 2 * ppp)
        XCTAssertNil(paintedSpan(bitmap, row: insetProbe).range, "Top inset must be clear — the grabber is a floating pill, not a full-height rule.")
        XCTAssertNil(paintedSpan(bitmap, row: bitmap.pixelsHigh - 1 - insetProbe).range, "Bottom inset must be clear for the same reason.")
        XCTAssertNotNil(
            paintedSpan(bitmap, row: Int((SidebarResizeHandleNSView.grabberVerticalInset + 4) * ppp)).range,
            "Just below the inset the pill must have started."
        )
    }

    func test_resizeHandle_drawsNothingAtRest() throws {
        let view = SidebarResizeHandleNSView(frame: NSRect(x: 0, y: 0, width: OrbitMetrics.sidebarResizeHandleWidth, height: 200))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        XCTAssertNil(
            paintedSpan(bitmap, row: bitmap.pixelsHigh / 2).range,
            "Unhovered and undragged, the handle stays invisible — it is an affordance that appears under the pointer, not a permanent divider."
        )
    }

    func test_resizeHandle_isBrighterWhileDragging() throws {
        let hovering = try drawHandle(height: 300, scale: 1)
        let dragging = try drawHandle(height: 300, scale: 1, dragging: true)

        let hoverAlpha = paintedSpan(hovering, row: hovering.pixelsHigh / 2).maxAlpha
        let dragAlpha = paintedSpan(dragging, row: dragging.pixelsHigh / 2).maxAlpha
        XCTAssertGreaterThan(dragAlpha, hoverAlpha, "Dragging is the stronger of the two states, same two-step feedback the old accent line had.")
    }
}
