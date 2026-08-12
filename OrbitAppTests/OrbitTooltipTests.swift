//  Regression guard: SwiftUI's help(...) showed nothing on any control in the app.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class OrbitTooltipTests: XCTestCase {

    // MARK: - The backing view's own contract

    func test_backingView_registersAnAppKitTooltipTrackingAreaAtItsOwnFrame() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let backing = OrbitTooltipBackingView(frame: NSRect(x: 40, y: 20, width: 48, height: 16))
        backing.apply("Close This Pane")
        host.addSubview(backing)
        backing.layoutSubtreeIfNeeded()

        XCTAssertEqual(backing.tooltipText, "Close This Pane")

        let tooltipAreas = backing.trackingAreas.filter {
            "\(type(of: $0.owner ?? NSNull()))".contains("ToolTip")
        }
        XCTAssertEqual(
            tooltipAreas.count, 1,
            "The view must make AppKit register an NSToolTipManager tracking area on itself — that registration, at this view's own frame, is the whole reason this type exists instead of SwiftUI's window-wide one"
        )
        XCTAssertEqual(
            tooltipAreas.first?.rect, backing.bounds,
            "The area must cover the control's real bounds, not the window"
        )
    }

    func test_backingView_isNeverAClickTargetAndNeverDragsTheWindow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let backing = OrbitTooltipBackingView(frame: NSRect(x: 40, y: 20, width: 48, height: 16))
        backing.apply("Anything")
        host.addSubview(backing)

        let hit = host.hitTest(NSPoint(x: 64, y: 28))
        XCTAssertFalse(
            hit === backing,
            "A tooltip backing that claims a point would eat the click on the control it labels — SpaceSwipeGestureCatcher's defect, exactly"
        )
        XCTAssertTrue(
            hit === host,
            "The point must fall through to the view behind the backing rather than being swallowed"
        )
        XCTAssertNil(
            backing.hitTest(NSPoint(x: 64, y: 28)),
            "Asked directly, in its superview's space, the backing must still decline"
        )
        XCTAssertFalse(
            backing.mouseDownCanMoveWindow,
            "Inside the window's 32pt titlebar band this would drag the window instead of letting the control beneath it work"
        )
    }

    func test_backingView_treatsBlankTextAsNoTooltipRatherThanAnEmptyBubble() {
        let backing = OrbitTooltipBackingView()

        backing.apply("")
        XCTAssertNil(backing.tooltipText)

        backing.apply("   \n ")
        XCTAssertNil(backing.tooltipText, "Whitespace is not a label; AppKit would show an empty bubble for it")

        backing.apply("  New…  ")
        XCTAssertEqual(backing.tooltipText, "New…", "A real label survives, trimmed")
    }

    func test_backingView_updatesInPlaceWhenTheHelpTextChanges() {
        let backing = OrbitTooltipBackingView()
        backing.apply("Collapse")
        backing.apply("Expand")
        XCTAssertEqual(backing.tooltipText, "Expand", "Computed help text (Collapse/Expand, per-tab titles) must follow its source")
    }

    // MARK: - The modifier, through a real hosting view

    func test_theModifierPutsARealTooltipCarryingViewIntoTheAppKitTree() {
        let hosting = NSHostingView(
            rootView: Button("Spaces") {}
                .buttonStyle(.plain)
                .orbitTooltip("Personal")
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        hosting.safeAreaRegions = []
        hosting.layoutSubtreeIfNeeded()

        let backings = Self.backingViews(in: hosting)
        XCTAssertEqual(backings.count, 1, "Exactly one tooltip backing per orbitTooltip call site")
        XCTAssertEqual(backings.first?.tooltipText, "Personal")
    }

    // AppKit's automatic rect was measured as (0,0,0,0) for the NSHostingController shape.
    func test_theTooltipRectIsRegisteredInBothOfOrbitsWindowShapes() {
        func backing(inHostingSubviewWindow: Bool) -> OrbitTooltipBackingView? {
            let content = Button("Spaces") {}
                .buttonStyle(.plain)
                .orbitTooltip("Personal")

            let window: NSWindow
            let root: NSView
            if inHostingSubviewWindow {
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                    styleMask: [.titled, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                let hosting = NSHostingView(rootView: content)
                hosting.safeAreaRegions = []
                hosting.sizingOptions = []
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                hosting.frame = container.bounds
                hosting.autoresizingMask = [.width, .height]
                container.addSubview(hosting)
                window.contentView = container
                root = container
            } else {
                let controller = NSHostingController(rootView: content)
                window = NSWindow(contentViewController: controller)
                window.setFrame(NSRect(x: 0, y: 0, width: 300, height: 200), display: true)
                root = window.contentView ?? controller.view
            }
            window.orderFront(nil)
            window.displayIfNeeded()
            root.layoutSubtreeIfNeeded()
            return Self.backingViews(in: root).first
        }

        for isSubviewShape in [true, false] {
            let shape = isSubviewShape ? "hosting-as-subview (main window)" : "NSHostingController (auxiliary windows)"
            guard let view = backing(inHostingSubviewWindow: isSubviewShape) else {
                XCTFail("No tooltip backing was hosted at all in \(shape)")
                continue
            }
            let areas = view.trackingAreas.filter {
                "\(type(of: $0.owner ?? NSNull()))".contains("ToolTip")
            }
            XCTAssertEqual(areas.count, 1, "No tooltip tracking area in \(shape)")
            XCTAssertFalse(
                areas.first.map { $0.rect.isEmpty } ?? true,
                "An empty tooltip rect in \(shape) is a tooltip that can never be triggered — this is exactly what setting NSView.toolTip produced here"
            )
        }
    }

    // Checked at the source, not SwiftUI's hosted subview order (a private implementation detail).
    func test_theModifierAttachesTheBackingBehindTheControlNotOverIt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Orbit/UI/Controls/OrbitTooltip.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("background(OrbitTooltipBacking("),
            "The backing must be attached as a background; as an overlay it would sit in front of the control it labels"
        )
        XCTAssertFalse(
            source.contains("overlay(OrbitTooltipBacking("),
            "An overlay would be the view AppKit resolves first at every point on the control"
        )
    }

    // MARK: - The sweep

    func test_noProductionSourceStillUsesSwiftUIsOwnHelpModifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Orbit")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard url.lastPathComponent != "OrbitTooltip.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".help(") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offenders.sorted(), [],
            "These files still call SwiftUI's help(...), which shows no tooltip in this app's hosting configuration. Use orbitTooltip(_:)."
        )
    }

    // MARK: - Helpers

    private static func backingViews(in root: NSView) -> [OrbitTooltipBackingView] {
        var found: [OrbitTooltipBackingView] = []
        if let backing = root as? OrbitTooltipBackingView { found.append(backing) }
        for subview in root.subviews { found.append(contentsOf: backingViews(in: subview)) }
        return found
    }

}
