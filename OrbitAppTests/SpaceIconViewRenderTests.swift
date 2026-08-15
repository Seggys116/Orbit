import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SpaceIconViewRenderTests: XCTestCase {

    // One environment for the whole suite: four separate AppEnvironment.demo
    // evaluations build four unrelated environments.
    private lazy var env: AppEnvironment = AppEnvironment.demo

    private let background = Color(red: 0.2, green: 0.2, blue: 0.9)

    private func renderOnBackground(_ icon: SpaceIcon, size: CGFloat, foreground: Color = .white, canvas: CGFloat = 60) -> RenderedImage {
        render(
            ZStack {
                background
                SpaceIconView(icon: icon, size: size, foregroundColor: foreground)
            }
            .frame(width: canvas, height: canvas),
            size: CGSize(width: canvas, height: canvas)
        )
    }

    // MARK: - The dot: real, deliberate, and modest — not full-bleed, not a placeholder

    func test_none_drawsSomethingAtTheCentre() {
        let image = renderOnBackground(.none, size: 40)
        let backgroundColor = image.color(atX: 1, y: 1)
        let centre = image.color(atX: 30, y: 30)
        XCTAssertFalse(
            centre.isApproximately(backgroundColor),
            "a .none Space must draw a visible dot, not leave the box empty — SpaceIconView's `.none` case is what the user's reference screenshot calls a deliberate dot, not a missing-asset hole"
        )
    }

    func test_none_dotDoesNotFillTheWholeBox() {
        let image = renderOnBackground(.none, size: 40, canvas: 60)
        let backgroundColor = image.color(atX: 1, y: 1)
        let iconFrameCorner = image.color(atX: 11, y: 11) // ~ (60-40)/2 = 10 is the icon frame's own top-left
        XCTAssertTrue(
            iconFrameCorner.isApproximately(backgroundColor, tolerance: 0.08),
            "the dot filled all the way to the corner of its own box — SpaceIconView.dotDiameterFraction should draw a dot smaller than its box, not a full-bleed circle"
        )
    }

    func test_none_dotUsesTheSuppliedForegroundColor() {
        let orange = Color(red: 1, green: 0.4, blue: 0)
        let image = renderOnBackground(.none, size: 40, foreground: orange)
        let centre = image.color(atX: 30, y: 30)
        XCTAssertEqual(centre.r, 1.0, accuracy: 0.15)
        XCTAssertEqual(centre.g, 0.4, accuracy: 0.15)
        XCTAssertEqual(centre.b, 0.0, accuracy: 0.15)
    }

    // MARK: - The other three cases

    func test_symbol_drawsSomethingAtTheCentre() {
        let image = renderOnBackground(.symbol("star.fill"), size: 40)
        let backgroundColor = image.color(atX: 1, y: 1)
        let centre = image.color(atX: 30, y: 30)
        XCTAssertFalse(centre.isApproximately(backgroundColor), "an SF Symbol icon drew nothing")
    }

    // MARK: - Clipping (Defect 1: the sidebar header's Space icon was cropped)

    // Mirrors the sidebar header's own container exactly: a size x size frame with .clipped(),
    // which is how the real hosting layer treats an oversized glyph in this app (see
    // TabRowView's folder-icon frame, and SidebarTopRow's sidebarToggleGlyphScale comment).
    // A symbol whose font size equals its container (the pre-fix behaviour) fills that box
    // edge-to-edge with no margin, so its own glyph bounding box crops against these walls.
    private func renderClipped(_ icon: SpaceIcon, size: CGFloat, foreground: Color = .white) -> RenderedImage {
        render(
            ZStack {
                background
                SpaceIconView(icon: icon, size: size, foregroundColor: foreground)
            }
            .frame(width: size, height: size)
            .clipped(),
            size: CGSize(width: size, height: size)
        )
    }

    // "display" is a wide, edge-filling SF Symbol design (the monitor/screen glyph the owner's
    // screenshot showed cropped) — a good stand-in for any symbol whose own bounding box is not
    // comfortably inset within the point size the app renders it at.
    private static let wideSymbols = ["display", "tv", "rectangle.on.rectangle", "star.fill"]

    func test_symbol_atSidebarHeaderSize_leavesMarginOnAllFourEdges() {
        let size = OrbitMetrics.sidebarSpaceIconSize
        for symbol in Self.wideSymbols {
            let image = renderClipped(.symbol(symbol), size: size)
            let backgroundColor = image.color(atX: 0, y: 0)
            let edgeRing = image.containsNonBackgroundPixels(
                in: CGRect(x: 0, y: 0, width: size, height: 1),
                background: backgroundColor
            ) || image.containsNonBackgroundPixels(
                in: CGRect(x: 0, y: size - 1, width: size, height: 1),
                background: backgroundColor
            ) || image.containsNonBackgroundPixels(
                in: CGRect(x: 0, y: 0, width: 1, height: size),
                background: backgroundColor
            ) || image.containsNonBackgroundPixels(
                in: CGRect(x: size - 1, y: 0, width: 1, height: size),
                background: backgroundColor
            )
            XCTAssertFalse(
                edgeRing,
                "'\(symbol)' painted right up to (or past) its \(size)pt container's own edge — " +
                "SpaceIconView's .symbol case must leave a margin (OrbitMetrics.spaceIconSymbolScaleFraction) " +
                "so the sidebar header's clipped container never crops the glyph"
            )
        }
    }

    func test_symbol_atBottomSwitcherSize_leavesMarginOnAllFourEdges() {
        let size: CGFloat = 28
        for symbol in Self.wideSymbols {
            let image = renderClipped(.symbol(symbol), size: size)
            let backgroundColor = image.color(atX: 0, y: 0)
            let touchesTop = image.containsNonBackgroundPixels(in: CGRect(x: 0, y: 0, width: size, height: 1), background: backgroundColor)
            let touchesBottom = image.containsNonBackgroundPixels(in: CGRect(x: 0, y: size - 1, width: size, height: 1), background: backgroundColor)
            let touchesLeft = image.containsNonBackgroundPixels(in: CGRect(x: 0, y: 0, width: 1, height: size), background: backgroundColor)
            let touchesRight = image.containsNonBackgroundPixels(in: CGRect(x: size - 1, y: 0, width: 1, height: size), background: backgroundColor)
            XCTAssertFalse(touchesTop || touchesBottom || touchesLeft || touchesRight, "'\(symbol)' at the bottom switcher's icon size crops against its container")
        }
    }

    func test_emoji_drawsSomethingAtTheCentre() {
        let image = renderOnBackground(.emoji("🚀"), size: 40)
        let backgroundColor = image.color(atX: 1, y: 1)
        let centre = image.color(atX: 30, y: 30)
        XCTAssertFalse(centre.isApproximately(backgroundColor), "an emoji icon drew nothing")
    }

    func test_image_drawsTheImportedPixels() throws {
        let orangeImage = NSImage(size: NSSize(width: 8, height: 8))
        orangeImage.lockFocus()
        NSColor(calibratedRed: 1, green: 0.4, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        orangeImage.unlockFocus()
        guard let tiff = orangeImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("could not synthesize a PNG fixture on this machine")
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceIconViewRenderTests-\(UUID().uuidString).png")
        try png.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let id = try AppEnvironment.processRoot.spaceIconImages.importImage(fromFileAt: fileURL)
        defer { AppEnvironment.processRoot.spaceIconImages.deleteImage(for: id) }

        let image = renderOnBackground(.image(id), size: 40)
        let centre = image.color(atX: 30, y: 30)
        XCTAssertGreaterThan(centre.r, 0.7, "the imported image's dominant red channel did not come through")
        XCTAssertLessThan(centre.b, 0.3, "the imported image should have almost no blue, unlike the blue .none/.image-fallback dot comparisons elsewhere in this file")
        XCTAssertGreaterThan(centre.r, centre.b, "red must clearly dominate blue for this fixture's orange")
    }

    func test_image_withAnUnknownID_fallsBackToTheDotRatherThanBlank() {
        let neverImported = SpaceIconImageID()
        let dotImage = renderOnBackground(.none, size: 40)
        let missingImage = renderOnBackground(.image(neverImported), size: 40)

        let dotCentre = dotImage.color(atX: 30, y: 30)
        let missingCentre = missingImage.color(atX: 30, y: 30)
        let backgroundColor = dotImage.color(atX: 1, y: 1)

        XCTAssertFalse(missingCentre.isApproximately(backgroundColor), "a missing custom image must not render as an empty box")
        XCTAssertTrue(missingCentre.isApproximately(dotCentre, tolerance: 0.06), "a missing custom image must fall back to exactly the dot, not some other placeholder")
    }

    // MARK: - Defect 1: the sidebar header (SpaceTitleRow), emoji AND SF Symbol, human-inspected

    // A dark, opaque backing: SpaceTitleRow itself paints none (the real sidebar's own
    // ThemeBackgroundView does that), and its text/icon foreground is near-white — invisible
    // against a transparent PNG composited over a white viewer without this.
    private func onDarkBacking<V: View>(_ content: V, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.14, green: 0.13, blue: 0.17)
            content
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    func test_symbol_display_isAResolvableSFSymbol() {
        XCTAssertTrue(OrbitSymbolName.isResolvable("display"), "'display' (the monitor/screen glyph) must resolve as a real SF Symbol on this OS, or this test's own fixture needs a different symbol name.")
    }

    func test_spaceTitleRow_emojiIcon_rendersUncroppedInTheRealHeader() {
        let space = Space(name: "Reading List", icon: "📚", iconIsEmoji: true, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarSpaceNameRowHeight)
        let image = render(
            onDarkBacking(SpaceTitleRow(space: space).environment(env), size: size),
            size: size
        )
        image.writeDiagnosticPNG(named: "SpaceTitleRow-emoji")
        XCTAssertNotNil(image.boundingBoxOfContent(), "the header drew nothing at all")
    }

    func test_spaceTitleRow_symbolIcon_rendersUncroppedInTheRealHeader() {
        let space = Space(name: "Systems", icon: "display", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarSpaceNameRowHeight)
        let image = render(
            onDarkBacking(SpaceTitleRow(space: space).environment(env), size: size),
            size: size
        )
        image.writeDiagnosticPNG(named: "SpaceTitleRow-symbol")
        XCTAssertNotNil(image.boundingBoxOfContent(), "the header drew nothing at all")
    }

    // Both icon kinds in the same header row's own icon slot, stacked into one PNG for a single
    // side-by-side human look — the top row is the emoji case, the bottom the SF Symbol case.
    func test_spaceTitleRow_emojiAndSymbol_sideBySide_forHumanInspection() {
        let emojiSpace = Space(name: "Reading List", icon: "📚", iconIsEmoji: true, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let symbolSpace = Space(name: "Systems", icon: "display", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())

        let width: CGFloat = 260
        let rowHeight = OrbitMetrics.sidebarSpaceNameRowHeight
        let size = CGSize(width: width, height: rowHeight * 2)
        let content = VStack(spacing: 0) {
            SpaceTitleRow(space: emojiSpace)
            SpaceTitleRow(space: symbolSpace)
        }
        .environment(env)

        let image = render(onDarkBacking(content, size: size), size: size)
        image.writeDiagnosticPNG(named: "SpaceTitleRow-emoji-and-symbol")
        XCTAssertNotNil(image.boundingBoxOfContent(), "the header drew nothing at all")
    }

    // MARK: - End to end: Create Space with nothing picked really renders the dot

    func test_aSpaceCreatedWithoutPickingAnIcon_rendersTheDot() throws {
        let id = try XCTUnwrap(NewSpaceFlowAction.create(
            name: "No Icon Chosen",
            icon: "circle.grid.2x2",
            iconIsEmoji: false,
            iconOverride: SpaceIcon.none,
            theme: SpaceTheme(),
            in: env
        ))
        defer { if env.space(id) != nil { env.deleteSpace(id) } }

        let space = try XCTUnwrap(env.space(id))
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none)

        let dotImage = renderOnBackground(.none, size: 40)
        let spaceImage = renderOnBackground(space.resolvedIcon, size: 40)
        XCTAssertTrue(
            spaceImage.color(atX: 30, y: 30).isApproximately(dotImage.color(atX: 30, y: 30), tolerance: 0.06),
            "a Space created without picking an icon must render identically to the explicit dot case"
        )
    }
}
