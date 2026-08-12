//  OrbitContextMenuModelTests.swift covers the model/action layer; this covers
//  what OrbitContextMenuView actually renders as pixels, in both appearances.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class OrbitContextMenuVisualTests: XCTestCase {

    private static let canvasSize = CGSize(width: 400, height: 400)

    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    private static func scheme(for appearance: NSAppearance.Name) -> ColorScheme {
        appearance == .darkAqua ? .dark : .light
    }

    /// A token colour put through the same rasteriser the menu itself goes
    /// through, so an expectation is never a hand-converted colour-space guess.
    private func renderedSwatch<V: View>(_ view: V, appearance: NSAppearance.Name) -> RGBA {
        let size = CGSize(width: 40, height: 40)
        return render(view.frame(width: size.width, height: size.height), size: size, appearance: appearance)
            .averageColor(in: CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    private func surface(for appearance: NSAppearance.Name) -> RGBA {
        renderedSwatch(Rectangle().fill(OrbitColor.menuSurface(for: Self.scheme(for: appearance))), appearance: appearance)
    }

    private func singleItemEntries(
        title: String = "Item", systemImage: String? = "star", shortcut: String? = nil,
        isEnabled: Bool = true, isDestructive: Bool = false
    ) -> [OrbitContextMenuEntry] {
        [.item(OrbitContextMenuItem(
            title: title, systemImage: systemImage, shortcut: shortcut,
            isEnabled: isEnabled, isDestructive: isDestructive
        ) {})]
    }

    // Height of a menu whose entries are `rowCount` plain rows.
    private static func containerHeight(rowCount: Int) -> CGFloat {
        2 * OrbitMetrics.contextMenuVerticalPadding + CGFloat(rowCount) * OrbitMetrics.contextMenuRowHeight
    }

    // MARK: - Renders at all, in both appearances

    func test_menu_rendersNonNilContent_lightAndDark() {
        for appearance in Self.appearances {
            let entries: [OrbitContextMenuEntry] = [
                .item(OrbitContextMenuItem(title: "Back", systemImage: "chevron.left") {}),
                .divider(),
                .item(OrbitContextMenuItem(title: "Reload", systemImage: "arrow.clockwise") {}),
            ]
            let rendered = render(
                OrbitContextMenuView(entries: entries, onSelect: {}), size: Self.canvasSize, appearance: appearance
            )
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    // MARK: - Full menus, both appearances, written out for eyes

    func test_realMenus_renderInBothAppearances_andAreWrittenOutForInspection() {
        let rightClick: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Open Link in New Tab", systemImage: "arrow.up.forward.square") {}),
            .item(OrbitContextMenuItem(title: "Open Link in Little Orbit", systemImage: "rectangle.inset.filled") {}),
            .item(OrbitContextMenuItem(title: "Copy Link", systemImage: "link", shortcut: "⌘C") {}),
            .divider(),
            .item(OrbitContextMenuItem(title: "Back", systemImage: "chevron.left", shortcut: "⌘[", isEnabled: false) {}),
            .item(OrbitContextMenuItem(title: "Forward", systemImage: "chevron.right", shortcut: "⌘]") {}),
            .item(OrbitContextMenuItem(title: "Reload", systemImage: "arrow.clockwise", shortcut: "⌘R") {}),
            .divider(),
            .item(OrbitContextMenuItem(title: "Clear Downloads", systemImage: "trash", isDestructive: true) {}),
            .item(OrbitContextMenuItem(title: "Share", systemImage: "square.and.arrow.up", submenu: [
                .item(OrbitContextMenuItem(title: "Mail", systemImage: "envelope") {}),
            ]) {}),
        ]
        // The real "+" menu's shape: grouped by divider alone, no section labels.
        let plusMenu = SidebarNewItemOption.contextMenuEntries(in: AppEnvironment.demo)

        for appearance in Self.appearances {
            let suffix = appearance == .darkAqua ? "dark" : "light"

            let selection = OrbitMenuSelectionModel(entries: rightClick)
            selection.selectedItemID = rightClick.first(titled: "Copy Link")?.id
            let contextRendered = render(
                OrbitContextMenuView(entries: rightClick, onSelect: {}, selection: selection),
                size: CGSize(width: 300, height: 360), appearance: appearance
            )
            XCTAssertNotNil(contextRendered.boundingBoxOfContent(), "right-click menu, \(suffix)")
            contextRendered.writeDiagnosticPNG(named: "OrbitContextMenu-rightclick-\(suffix)")

            let plusRendered = render(
                OrbitContextMenuView(
                    entries: plusMenu, onSelect: {},
                    arrow: OrbitMenuArrow(edge: .bottom, offset: OrbitMetrics.contextMenuWidth / 2)
                ),
                size: CGSize(width: 300, height: 300), appearance: appearance
            )
            XCTAssertNotNil(plusRendered.boundingBoxOfContent(), "+ menu, \(suffix)")
            plusRendered.writeDiagnosticPNG(named: "OrbitContextMenu-plus-\(suffix)")
        }
    }

    // MARK: - Orbit draws its own opaque container, not system popover material

    func test_container_isDrawnInOrbitsOwnMenuSurfaceColour_lightAndDark() {
        for appearance in Self.appearances {
            let rendered = render(
                OrbitContextMenuView(entries: singleItemEntries(), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            // Right-hand side of the only row: inside the container, clear of
            // the icon, the title and the rounded corners.
            let sample = rendered.averageColor(in: CGRect(x: 180, y: 14, width: 55, height: 12))
            let expected = surface(for: appearance)
            XCTAssertTrue(
                sample.isApproximately(expected, tolerance: 0.03),
                "The menu container must be Orbit's own OrbitColor.menuSurface, not system material (appearance \(appearance.rawValue)): \(sample) vs \(expected)."
            )
            XCTAssertGreaterThan(sample.a, 0.9, "The container has to be opaque enough to read over any page (appearance \(appearance.rawValue)).")
        }
    }

    func test_container_paintsNothingOutsideItsOwnRoundedRect() {
        let rendered = render(
            OrbitContextMenuView(entries: singleItemEntries(), onSelect: {}),
            size: Self.canvasSize, appearance: .darkAqua
        )
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.height ?? -1, Self.containerHeight(rowCount: 1), accuracy: 1)
        XCTAssertEqual(
            rendered.color(atX: 300, y: 10).a, 0, accuracy: 0.02,
            "Nothing may be painted beyond the container -- the panel behind it is fully transparent."
        )
    }

    // MARK: - Width tracks OrbitMetrics.contextMenuWidth, the tokens contract

    func test_menu_rendersAtTheDeclaredContextMenuWidth() {
        let rendered = render(
            OrbitContextMenuView(entries: singleItemEntries(), onSelect: {}),
            size: Self.canvasSize, appearance: .darkAqua
        )
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(
            box?.width ?? -1, OrbitMetrics.contextMenuWidth, accuracy: 1,
            "The rendered menu did not track OrbitMetrics.contextMenuWidth -- the one place its width is supposed to come from."
        )
    }

    // MARK: - No anchor arrow on the right-click menu

    func test_rightClickMenu_drawsNoAnchorArrow_whileAnAnchoredMenuDoes() {
        for appearance in Self.appearances {
            let plain = render(
                OrbitContextMenuView(entries: singleItemEntries(), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let plainBox = plain.boundingBoxOfContent()
            XCTAssertEqual(
                plainBox?.height ?? -1, Self.containerHeight(rowCount: 1), accuracy: 1,
                "The right-click menu is exactly its rows plus its own padding -- an anchor arrow would make it taller (appearance \(appearance.rawValue))."
            )

            let beaked = render(
                OrbitContextMenuView(
                    entries: singleItemEntries(), onSelect: {},
                    arrow: OrbitMenuArrow(edge: .bottom, offset: OrbitMetrics.contextMenuWidth / 2)
                ),
                size: Self.canvasSize, appearance: appearance
            )
            let beakedBox = beaked.boundingBoxOfContent()
            XCTAssertEqual(
                beakedBox?.height ?? -1,
                Self.containerHeight(rowCount: 1) + OrbitMetrics.contextMenuArrowHeight, accuracy: 1,
                "A menu that asks for a beak must actually grow one (appearance \(appearance.rawValue))."
            )

            // Proves the difference above is a real, drawn beak at the arrow's
            // own offset -- and that it is a beak, not a full-width edge.
            let belowContainer = Self.containerHeight(rowCount: 1) + OrbitMetrics.contextMenuArrowHeight / 2
            XCTAssertGreaterThan(
                beaked.color(atX: Int(OrbitMetrics.contextMenuWidth / 2), y: Int(belowContainer)).a, 0.5,
                "No beak pixels found under the arrow's own offset (appearance \(appearance.rawValue))."
            )
            XCTAssertEqual(
                beaked.color(atX: 30, y: Int(belowContainer)).a, 0, accuracy: 0.02,
                "The beak must be a beak, not a full-width bar (appearance \(appearance.rawValue))."
            )
            XCTAssertEqual(
                plain.color(atX: Int(OrbitMetrics.contextMenuWidth / 2), y: Int(belowContainer)).a, 0, accuracy: 0.02,
                "The right-click menu drew something where an anchor arrow would be (appearance \(appearance.rawValue))."
            )
        }
    }

    // MARK: - The beak grows out of the edge, blunt-tipped

    /// Opaque span, in points, across one scanline of the rendered image.
    private func inkWidth(in rendered: RenderedImage, atY y: Int) -> Int {
        var count = 0
        for x in 0..<Int(Self.canvasSize.width) where rendered.color(atX: x, y: y).a > 0.5 {
            count += 1
        }
        return count
    }

    func test_beak_meetsTheEdgeAtFullWidth_andIsBluntedAtItsTip() {
        let baseY = Int(Self.containerHeight(rowCount: 1))
        let beakHeight = Int(OrbitMetrics.contextMenuArrowHeight)

        for appearance in Self.appearances {
            let rendered = render(
                OrbitContextMenuView(
                    entries: singleItemEntries(), onSelect: {},
                    arrow: OrbitMenuArrow(edge: .bottom, offset: OrbitMetrics.contextMenuWidth / 2)
                ),
                size: Self.canvasSize, appearance: appearance
            )

            // A plain triangle is at most its own width at the base; the filleted
            // beak must be WIDER than that right at the join -- that spread is the fillet.
            let atBase = inkWidth(in: rendered, atY: baseY)
            XCTAssertGreaterThan(
                atBase, Int(OrbitMetrics.contextMenuArrowWidth),
                "The beak meets the container edge as a corner, not a fillet -- \(atBase)pt where a plain triangle would already be at most \(Int(OrbitMetrics.contextMenuArrowWidth))pt (appearance \(appearance.rawValue))."
            )

            let nearTip = inkWidth(in: rendered, atY: baseY + beakHeight - 1)
            XCTAssertGreaterThanOrEqual(
                nearTip, 3,
                "The beak's tip must be blunted, not needle-sharp (appearance \(appearance.rawValue)): \(nearTip)pt wide one point above the tip."
            )
            XCTAssertLessThan(
                nearTip, atBase,
                "The beak must actually taper (appearance \(appearance.rawValue))."
            )
        }
    }

    // MARK: - Selection highlight is an inset rounded rect, not a full-bleed bar

    private func highlightedMenu(appearance: NSAppearance.Name) -> RenderedImage {
        let entries = singleItemEntries(title: "Highlighted")
        let selection = OrbitMenuSelectionModel(entries: entries)
        selection.selectedItemID = entries.flattenedItems.first?.id
        return render(
            OrbitContextMenuView(entries: entries, onSelect: {}, selection: selection),
            size: Self.canvasSize, appearance: appearance
        )
    }

    private static var rowMidY: CGFloat {
        OrbitMetrics.contextMenuVerticalPadding + OrbitMetrics.contextMenuRowHeight / 2
    }

    private static var highlightSampleRect: CGRect {
        CGRect(x: 185, y: rowMidY - 6, width: 45, height: 12)
    }

    /// Distance from a container edge inward, along the highlighted row, to the first
    /// non-surface pixel. Starts two points in so the container's own border isn't mistaken for it.
    private func gutterWidth(in rendered: RenderedImage, surface: RGBA, fromLeft: Bool) -> Int {
        let width = Int(OrbitMetrics.contextMenuWidth)
        let y = Int(Self.rowMidY)
        for step in 2..<width {
            let x = fromLeft ? step : width - 1 - step
            if !rendered.color(atX: x, y: y).isApproximately(surface, tolerance: 0.02) { return step }
        }
        return width
    }

    func test_selectionHighlight_isInsetFromTheContainerEdges_notFullBleed() {
        for appearance in Self.appearances {
            let rendered = highlightedMenu(appearance: appearance)
            let surface = surface(for: appearance)
            let inset = Int(OrbitMetrics.contextMenuRowHorizontalInset)

            let insideHighlight = rendered.averageColor(in: Self.highlightSampleRect)
            XCTAssertFalse(
                insideHighlight.isApproximately(surface, tolerance: 0.02),
                "The selected row must actually paint a highlight (appearance \(appearance.rawValue)): \(insideHighlight)."
            )

            // Measured, not sampled at one hand-picked point: a near-full-bleed
            // bar leaves a gutter of a point or two and would pass a spot check.
            for side in [true, false] {
                let gutter = gutterWidth(in: rendered, surface: surface, fromLeft: side)
                XCTAssertGreaterThanOrEqual(
                    gutter, inset - 2,
                    "The highlight runs too close to the container's \(side ? "left" : "right") edge: \(gutter)pt of surface, expected about \(inset)pt (appearance \(appearance.rawValue)). A selected row must read as an inset pill, never a full-bleed bar."
                )
            }
        }
    }

    func test_selectionHighlight_isTheDesaturatedMenuHighlight_notTheRawSystemAccent() {
        for appearance in Self.appearances {
            let rendered = highlightedMenu(appearance: appearance)
            let scheme = Self.scheme(for: appearance)
            let opacity = scheme == .dark
                ? OrbitMetrics.contextMenuHoverOpacityDark
                : OrbitMetrics.contextMenuHoverOpacityLight

            let expected = renderedSwatch(
                ZStack {
                    Rectangle().fill(OrbitColor.menuSurface(for: scheme))
                    Rectangle().fill(OrbitColor.menuHighlight(for: scheme).opacity(opacity))
                },
                appearance: appearance
            )
            let rawAccent = renderedSwatch(
                ZStack {
                    Rectangle().fill(OrbitColor.menuSurface(for: scheme))
                    Rectangle().fill(Color.accentColor.opacity(opacity))
                },
                appearance: appearance
            )
            let sample = rendered.averageColor(in: Self.highlightSampleRect)

            XCTAssertTrue(
                sample.isApproximately(expected, tolerance: 0.04),
                "The highlight must be OrbitColor.menuHighlight at the tokens' own opacity (appearance \(appearance.rawValue)): \(sample) vs \(expected)."
            )
            XCTAssertGreaterThan(
                Self.distance(sample, rawAccent), Self.distance(sample, expected),
                "The highlight reads as the raw system selection colour (appearance \(appearance.rawValue)): \(sample) sits closer to \(rawAccent) than to \(expected)."
            )
        }
    }

    /// A fully desaturated grey (the light-mode regression this guards) must fail;
    /// set clear of the tokens' real values (light 0.109, dark 0.166) and rasteriser noise.
    private static let minimumHighlightSaturation = 0.07

    func test_selectionHighlight_saturationSitsInsideItsBand_visiblyTintedButNeverShouty() {
        for appearance in Self.appearances {
            let rendered = highlightedMenu(appearance: appearance)
            let sample = rendered.averageColor(in: Self.highlightSampleRect)
            let measured = Self.saturation(sample)
            let rawAccent = renderedSwatch(Rectangle().fill(Color.accentColor), appearance: appearance)

            XCTAssertGreaterThan(
                measured, Self.minimumHighlightSaturation,
                "The highlight has washed out to a neutral grey (appearance \(appearance.rawValue)): \(sample) at saturation \(measured). It must carry a visible warm tint, not just darken the surface."
            )
            XCTAssertLessThan(
                measured, Self.saturation(rawAccent) * 0.5,
                "The highlight is far too saturated for a menu row (appearance \(appearance.rawValue)): \(sample) at saturation \(measured)."
            )
        }
    }

    /// The warm shift is the whole point of deriving the highlight rather than
    /// using the accent raw: whatever the accent is, the row must read warm.
    func test_selectionHighlight_readsWarm_itsRedChannelLeadingItsBlue() {
        for appearance in Self.appearances {
            let rendered = highlightedMenu(appearance: appearance)
            let surface = surface(for: appearance)
            let sample = rendered.averageColor(in: Self.highlightSampleRect)
            XCTAssertGreaterThan(
                sample.r - surface.r, sample.b - surface.b,
                "The highlight must shift the row warm, not cool (appearance \(appearance.rawValue)): \(sample) over \(surface)."
            )
            XCTAssertGreaterThan(
                sample.r - surface.r, sample.g - surface.g,
                "The highlight's red channel must lead its green for the row to read pink rather than neutral (appearance \(appearance.rawValue)): \(sample) over \(surface)."
            )
        }
    }

    // MARK: - The container's corners are generous, not a tight system radius

    func test_container_hasAGenerousCornerRadius() {
        let rendered = render(
            OrbitContextMenuView(entries: singleItemEntries(), onSelect: {}),
            size: Self.canvasSize, appearance: .darkAqua
        )
        // The corner "bite": transparent pixels inside the radius-sized square
        // at the container's top-left. A tighter radius takes a smaller bite.
        let radius = Int(OrbitMetrics.contextMenuCornerRadius)
        var transparent = 0
        for y in 0..<radius {
            for x in 0..<radius where rendered.color(atX: x, y: y).a < 0.5 {
                transparent += 1
            }
        }
        let expected = Double(radius * radius) * (1 - Double.pi / 4)
        XCTAssertGreaterThan(
            Double(transparent), expected * 0.5,
            "The container's corner is not being rounded at OrbitMetrics.contextMenuCornerRadius (\(radius)pt): only \(transparent) transparent pixels in its own corner square."
        )
        XCTAssertGreaterThanOrEqual(
            OrbitMetrics.contextMenuCornerRadius, 16,
            "The menu panel's radius must read as an Orbit surface, not a tight system popover."
        )
    }

    // MARK: - Dividers are real, thin, and inset from the container edges

    func test_divider_addsRealHeight_notJustAZeroSizedRow() {
        let withoutDivider = [
            OrbitContextMenuEntry.item(OrbitContextMenuItem(title: "One") {}),
            .item(OrbitContextMenuItem(title: "Two") {}),
        ]
        let withDivider = [
            OrbitContextMenuEntry.item(OrbitContextMenuItem(title: "One") {}),
            .divider(),
            .item(OrbitContextMenuItem(title: "Two") {}),
        ]

        let shortHeight = render(OrbitContextMenuView(entries: withoutDivider, onSelect: {}), size: Self.canvasSize, appearance: .darkAqua)
            .boundingBoxOfContent()?.height ?? 0
        let tallHeight = render(OrbitContextMenuView(entries: withDivider, onSelect: {}), size: Self.canvasSize, appearance: .darkAqua)
            .boundingBoxOfContent()?.height ?? 0

        XCTAssertGreaterThan(
            tallHeight, shortHeight,
            "Inserting a divider must make the menu taller; \(tallHeight) vs \(shortHeight) suggests it rendered as nothing."
        )
    }

    func test_divider_isDrawnAsAThinInsetLine_notEdgeToEdge() {
        let entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "One") {}),
            .divider(),
            .item(OrbitContextMenuItem(title: "Two") {}),
        ]
        // Top padding, one row, then the divider's own vertical padding.
        let lineY = OrbitMetrics.contextMenuVerticalPadding
            + OrbitMetrics.contextMenuRowHeight
            + OrbitMetrics.contextMenuDividerVerticalPadding
        let inset = OrbitMetrics.contextMenuRowHorizontalInset + OrbitMetrics.contextMenuRowHorizontalPadding

        for appearance in Self.appearances {
            let rendered = render(OrbitContextMenuView(entries: entries, onSelect: {}), size: Self.canvasSize, appearance: appearance)
            let surface = surface(for: appearance)

            let line = rendered.averageColor(
                in: CGRect(x: 120, y: lineY, width: 40, height: OrbitMetrics.contextMenuDividerThickness)
            )
            XCTAssertFalse(
                line.isApproximately(surface, tolerance: 0.015),
                "No divider was drawn at y=\(lineY) (appearance \(appearance.rawValue)): \(line) vs \(surface)."
            )

            let gutter = rendered.averageColor(in: CGRect(x: 2, y: lineY, width: inset - 4, height: OrbitMetrics.contextMenuDividerThickness))
            XCTAssertTrue(
                gutter.isApproximately(surface, tolerance: 0.015),
                "The divider runs edge to edge; it must be inset from the container (appearance \(appearance.rawValue)): \(gutter) vs \(surface)."
            )
        }
    }

    // MARK: - Shortcut hints sit on the right, dimmed

    func test_shortcutHint_isDrawnAgainstTheRightEdge_leavingTheTitleUntouched() {
        let leadingRegion = CGRect(x: 12, y: 10, width: 70, height: 18)
        let trailingRegion = CGRect(x: OrbitMetrics.contextMenuWidth - 50, y: 10, width: 32, height: 18)

        for appearance in Self.appearances {
            let without = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "New Tab"), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let with = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "New Tab", shortcut: "⌘T"), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )

            XCTAssertGreaterThan(
                Self.distance(without.averageColor(in: trailingRegion), with.averageColor(in: trailingRegion)), 0.02,
                "A shortcut hint must be drawn against the row's trailing edge (appearance \(appearance.rawValue))."
            )
            XCTAssertLessThan(
                Self.distance(without.averageColor(in: leadingRegion), with.averageColor(in: leadingRegion)), 0.01,
                "Adding a shortcut hint must not move or restyle the icon and title (appearance \(appearance.rawValue))."
            )
        }
    }

    func test_shortcutHint_readsDimmerThanTheTitleItSitsBeside() {
        for appearance in Self.appearances {
            let rendered = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "New Tab", shortcut: "⌘T"), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let surface = surface(for: appearance)
            let title = Self.contrast(rendered.averageColor(in: CGRect(x: 30, y: 12, width: 55, height: 14)), against: surface)
            let hint = Self.contrast(
                rendered.averageColor(in: CGRect(x: OrbitMetrics.contextMenuWidth - 46, y: 12, width: 28, height: 14)),
                against: surface
            )
            XCTAssertLessThan(
                hint, title,
                "The shortcut hint must be dimmer than the title (appearance \(appearance.rawValue)): \(hint) vs \(title)."
            )
        }
    }

    // MARK: - Destructive styling actually reads differently from normal styling

    private func rowSampleRect() -> CGRect {
        // Icon + title, well inside the first row -- avoids the row's own
        // rounded-rect edge and outer menu chrome.
        CGRect(x: 12, y: OrbitMetrics.contextMenuVerticalPadding + 4, width: 60, height: OrbitMetrics.contextMenuRowHeight - 8)
    }

    func test_destructiveItem_readsVisiblyDifferentFromANormalItem() {
        for appearance in Self.appearances {
            let normal = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "Delete", isDestructive: false), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let destructive = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "Delete", isDestructive: true), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let normalColor = normal.averageColor(in: rowSampleRect())
            let destructiveColor = destructive.averageColor(in: rowSampleRect())
            XCTAssertGreaterThan(
                Self.distance(normalColor, destructiveColor), 0.03,
                "A destructive item must read visibly different from a normal one (appearance \(appearance.rawValue)): \(normalColor) vs \(destructiveColor)."
            )
        }
    }

    func test_destructiveItem_isDrawnInRed_notMerelyDifferent() {
        for appearance in Self.appearances {
            let rendered = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "Delete", isDestructive: true), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let surface = surface(for: appearance)
            let sample = rendered.averageColor(in: rowSampleRect())
            XCTAssertGreaterThan(
                sample.r - surface.r, max(sample.g - surface.g, sample.b - surface.b),
                "A destructive item must be drawn in Orbit's red -- its red channel has to lead (appearance \(appearance.rawValue)): \(sample) over \(surface)."
            )
        }
    }

    // MARK: - Disabled styling actually dims the row, not a no-op flag

    func test_disabledItem_readsVisiblyDimmerThanAnEnabledItem() {
        for appearance in Self.appearances {
            let enabled = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "Inspect Element", isEnabled: true), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let disabled = render(
                OrbitContextMenuView(entries: singleItemEntries(title: "Inspect Element", isEnabled: false), onSelect: {}),
                size: Self.canvasSize, appearance: appearance
            )
            let surface = surface(for: appearance)
            let enabledContrast = Self.contrast(enabled.averageColor(in: rowSampleRect()), against: surface)
            let disabledContrast = Self.contrast(disabled.averageColor(in: rowSampleRect()), against: surface)
            XCTAssertLessThan(
                disabledContrast, enabledContrast,
                "A disabled item must read dimmer against the menu surface than an enabled one (appearance \(appearance.rawValue)): \(disabledContrast) vs \(enabledContrast)."
            )
        }
    }

    // MARK: - Colour maths

    private static func distance(_ a: RGBA, _ b: RGBA) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        let da = a.a - b.a
        return (dr * dr + dg * dg + db * db + da * da).squareRoot()
    }

    /// How far a sample sits from the surface it is drawn on -- "how visible is
    /// this ink", independent of whether the appearance is light or dark.
    private static func contrast(_ sample: RGBA, against surface: RGBA) -> Double {
        distance(sample, surface)
    }

    private static func saturation(_ color: RGBA) -> Double {
        let high = max(color.r, max(color.g, color.b))
        let low = min(color.r, min(color.g, color.b))
        guard high > 0.001 else { return 0 }
        return (high - low) / high
    }
}
