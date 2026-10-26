import SwiftUI
import XCTest

@MainActor
final class DownloadsFlyoutTests: XCTestCase {

    // MARK: - The relative time reads in full words

    func testRelativeTimeReadsExactlyAsArcsFlyoutDoes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            DownloadsFlyoutTime.string(for: now.addingTimeInterval(-60), relativeTo: now, locale: Locale(identifier: "en_US")),
            "1 minute ago",
            "Arc's flyout's fourth row reads exactly '1 minute ago' — see refs/reference/web/arc-library-icon-hover-downloads-flyout-frame.png."
        )
        XCTAssertEqual(
            DownloadsFlyoutTime.string(for: now.addingTimeInterval(-4 * 60), relativeTo: now, locale: Locale(identifier: "en_US")),
            "4 minutes ago",
            "Arc's flyout's second row reads exactly '4 minutes ago'."
        )
        XCTAssertEqual(
            DownloadsFlyoutTime.string(for: now.addingTimeInterval(-7 * 24 * 60 * 60), relativeTo: now, locale: Locale(identifier: "en_US")),
            "1 week ago",
            "Arc's flyout's first row reads exactly '1 week ago' — not 'last week', which is what dateTimeStyle = .named produces."
        )
    }

    // MARK: - Real thumbnails, really cached

    func testThumbnailStoreGeneratesAndThenCachesARealFilesPreview() async throws {
        let url = try writeTemporaryPNG(named: "orbit-flyout-thumbnail-\(UUID().uuidString).png")
        let side = OrbitMetrics.spaceBadgeSize

        XCTAssertNil(
            DownloadThumbnailStore.shared.cached(for: url, side: side, scale: 2),
            "Precondition: a file this test has only just written cannot already be in the thumbnail cache."
        )

        let generated = await DownloadThumbnailStore.shared.thumbnail(for: url, side: side, scale: 2)
        let thumbnail = try XCTUnwrap(
            generated,
            "QuickLook produced no representation for a real PNG on disk. The flyout would fall back to a generic type icon for every file, which is the exact thing Arc's flyout does not do."
        )
        XCTAssertGreaterThan(thumbnail.size.width, 0, "A zero-width thumbnail would draw nothing; the store must not cache one.")

        XCTAssertNotNil(
            DownloadThumbnailStore.shared.cached(for: url, side: side, scale: 2),
            "The store did not retain the thumbnail it just generated, so every pass of the pointer over the Library button would regenerate it."
        )
    }

    func testThumbnailStoreReturnsNilForAFileThatIsNotOnDiskYet() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orbit-flyout-absent-\(UUID().uuidString).bin")

        let generated = await DownloadThumbnailStore.shared.thumbnail(for: missing, side: OrbitMetrics.spaceBadgeSize, scale: 2)

        XCTAssertNil(
            generated,
            "QuickLook cannot preview a file that is not there, and the store must say so rather than hand back an empty image the row would draw as a blank square."
        )
        XCTAssertNil(
            DownloadThumbnailStore.shared.cached(for: missing, side: OrbitMetrics.spaceBadgeSize, scale: 2),
            "A failed generation must not leave anything in the cache."
        )
    }

    // MARK: - The preview only appears when nothing else owns the pointer

    func testDownloadsPreviewPresentsWhenNothingElseIsGoingOn() {
        XCTAssertTrue(
            SidebarBottomBar.canPresentDownloadsPreview(
                sidebarDragInFlight: false, menuIsOpen: false, primaryButtonIsDown: false, screenshotMode: false
            ),
            "Resting on the archive button with nothing else active must show the recent downloads."
        )
    }

    func testDownloadsPreviewStaysHiddenWhileAnythingElseOwnsThePointer() {
        XCTAssertFalse(
            SidebarBottomBar.canPresentDownloadsPreview(
                sidebarDragInFlight: true, menuIsOpen: false, primaryButtonIsDown: false, screenshotMode: false
            ),
            "A sidebar row drag passing over the button must not pop a panel up under it."
        )
        XCTAssertFalse(
            SidebarBottomBar.canPresentDownloadsPreview(
                sidebarDragInFlight: false, menuIsOpen: true, primaryButtonIsDown: false, screenshotMode: false
            ),
            "Another menu being open must keep the preview away."
        )
        XCTAssertFalse(
            SidebarBottomBar.canPresentDownloadsPreview(
                sidebarDragInFlight: false, menuIsOpen: false, primaryButtonIsDown: true, screenshotMode: false
            ),
            "A held mouse button means a drag or a press in progress, not a hover."
        )
        XCTAssertFalse(
            SidebarBottomBar.canPresentDownloadsPreview(
                sidebarDragInFlight: false, menuIsOpen: false, primaryButtonIsDown: false, screenshotMode: true
            ),
            "Screenshot mode renders the bar without hover surfaces."
        )
    }

    // MARK: - The panel stays inside the sidebar

    func testPlacementKeepsThePanelInsideTheContainerAtEveryWidth() {
        for containerWidth in stride(from: CGFloat(100), through: 600, by: 10) {
            for anchorMinX in [CGFloat(0), 6, 40, containerWidth, containerWidth + 200] {
                let placement = DownloadsPreviewLayout.placement(containerWidth: containerWidth, anchorMinX: anchorMinX)
                XCTAssertGreaterThanOrEqual(
                    placement.originX, DownloadsPreviewLayout.edgeInset,
                    "The panel starts left of the sidebar's padding at container \(containerWidth), anchor \(anchorMinX)."
                )
                XCTAssertLessThanOrEqual(
                    placement.originX + placement.width, max(containerWidth - DownloadsPreviewLayout.edgeInset, DownloadsPreviewLayout.edgeInset),
                    "The panel runs past the sidebar's right padding at container \(containerWidth), anchor \(anchorMinX)."
                )
                XCTAssertLessThanOrEqual(placement.width, DownloadsPreviewLayout.maxWidth)
            }
        }
    }

    func testPlacementShrinksThePanelToANarrowSidebarAndKeepsItAtFullWidthInAWideOne() {
        let narrow = DownloadsPreviewLayout.placement(containerWidth: 220, anchorMinX: 6)
        XCTAssertEqual(narrow.width, 220 - 2 * DownloadsPreviewLayout.edgeInset, "A 220pt sidebar leaves the panel the width between its paddings.")
        XCTAssertEqual(narrow.originX, DownloadsPreviewLayout.edgeInset, "The library button sits at the far left; the panel aligns to the sidebar padding, not to the button's own inset.")

        let wide = DownloadsPreviewLayout.placement(containerWidth: 600, anchorMinX: 6)
        XCTAssertEqual(wide.width, DownloadsPreviewLayout.maxWidth, "A wide sidebar does not stretch the panel.")
    }

    func testVisibleRowCountNeverLetsThePanelOutgrowTheSpaceAboveTheBar() {
        for spaceAbove in stride(from: CGFloat(0), through: 900, by: 5) {
            let maxHeight = DownloadsPreviewLayout.maxHeight(spaceAbove: spaceAbove)
            let rows = DownloadsPreviewLayout.visibleRowCount(rowCount: 6, maxHeight: maxHeight)
            let worstCase = DownloadsPreviewLayout.chromeHeightBound + CGFloat(rows) * DownloadsPreviewLayout.rowHeightBound
            if rows > 0 {
                XCTAssertLessThanOrEqual(worstCase, maxHeight ?? .infinity, "\(rows) rows overflow \(spaceAbove)pt above the bar.")
            }
            XCTAssertLessThanOrEqual(rows, 6)
        }
    }

    func testShortContainersShowFewerRowsAndTallOnesShowAll() {
        XCTAssertEqual(DownloadsPreviewLayout.visibleRowCount(rowCount: 6, maxHeight: DownloadsPreviewLayout.maxHeight(spaceAbove: 900)), 6)
        XCTAssertEqual(DownloadsPreviewLayout.visibleRowCount(rowCount: 6, maxHeight: DownloadsPreviewLayout.maxHeight(spaceAbove: 200)), 2)
        XCTAssertEqual(
            DownloadsPreviewLayout.visibleRowCount(rowCount: 6, maxHeight: DownloadsPreviewLayout.maxHeight(spaceAbove: 40)), 0,
            "With almost no room only the footer is kept."
        )
        XCTAssertEqual(DownloadsPreviewLayout.visibleRowCount(rowCount: 6, maxHeight: nil), 6, "An unknown bar position applies no cap.")
    }

    func testPanelRenderedInAShortContainerStaysUnderItsMaxHeight() throws {
        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.16, green: 0.14, blue: 0.22)], followsSystemAppearance: false)
        let spaceAbove: CGFloat = 200
        let image = renderDownloadsOverlay(theme: theme, containerWidth: 220, appearance: .darkAqua, withDownloads: true, spaceAbove: spaceAbove)
        let panel = try XCTUnwrap(opaqueBounds(of: image))
        let limit = try XCTUnwrap(DownloadsPreviewLayout.maxHeight(spaceAbove: spaceAbove))

        XCTAssertLessThanOrEqual(panel.height, limit + 1, "The panel is taller than the room above the bar.")
        XCTAssertGreaterThan(panel.height, DownloadsPreviewLayout.chromeHeightBound / 2, "The panel lost its footer.")
    }

    // MARK: - The panel wears the Space's theme

    func testPanelStaysInsideANarrowSidebarAndPaintsTheSpacesThemeNotTheSystemAppearance() throws {
        let dark = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.16, green: 0.14, blue: 0.22)], followsSystemAppearance: false)
        let light = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.93, green: 0.91, blue: 0.86)], followsSystemAppearance: false)
        let width: CGFloat = 220

        var surfaces: [String: [RGBA]] = [:]
        for (name, theme) in [("dark", dark), ("light", light)] {
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let image = renderDownloadsOverlay(theme: theme, containerWidth: width, appearance: appearance, withDownloads: true)
                let label = "\(name) theme under \(appearance.rawValue)"
                let panel = try XCTUnwrap(opaqueBounds(of: image), "Nothing opaque was painted for the \(label); the panel has no surface of its own.")

                XCTAssertGreaterThanOrEqual(panel.minX, DownloadsPreviewLayout.edgeInset - 1, "\(label): the panel pokes out of the sidebar's left edge.")
                XCTAssertLessThanOrEqual(panel.maxX, width - DownloadsPreviewLayout.edgeInset + 1, "\(label): the panel pokes out of the sidebar's right edge.")
                XCTAssertGreaterThanOrEqual(panel.minY, 0, "\(label): the panel is cut off at the top.")

                let sample = image.color(atX: Int(panel.midX), y: Int(panel.minY) + 3)
                let expected = expectedSurface(of: theme, appearance: appearance)
                XCTAssertTrue(
                    sample.isApproximately(expected, tolerance: 0.02),
                    "\(label): the panel surface is \(sample), expected the Space's own surface \(expected). A system popover colour would follow the appearance instead."
                )
                surfaces[name, default: []].append(sample)
            }
        }

        for (name, samples) in surfaces {
            XCTAssertTrue(
                samples[0].isApproximately(samples[1], tolerance: 0.02),
                "The \(name) Space's panel changes colour with the system appearance: \(samples[0]) vs \(samples[1])."
            )
        }
        if let darkSample = surfaces["dark"]?.first, let lightSample = surfaces["light"]?.first {
            XCTAssertFalse(darkSample.isApproximately(lightSample, tolerance: 0.05), "Different Space themes painted the same panel colour \(darkSample).")
        }
    }

    func testEmptyPanelStillPaintsAThemedSurfaceInsideTheSidebar() throws {
        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.12, green: 0.2, blue: 0.3)], followsSystemAppearance: false)
        let image = renderDownloadsOverlay(theme: theme, containerWidth: 220, appearance: .aqua, withDownloads: false)
        let panel = try XCTUnwrap(opaqueBounds(of: image), "The empty state painted no panel.")

        XCTAssertGreaterThanOrEqual(panel.minX, DownloadsPreviewLayout.edgeInset - 1)
        XCTAssertLessThanOrEqual(panel.maxX, 220 - DownloadsPreviewLayout.edgeInset + 1)
        XCTAssertTrue(
            image.containsNonBackgroundPixels(
                in: panel.insetBy(dx: 6, dy: 6),
                background: expectedSurface(of: theme, appearance: .aqua),
                tolerance: 0.1
            ),
            "The empty panel drew no text or divider over its surface."
        )
    }

    // MARK: - Panel rendering support

    private func renderDownloadsOverlay(
        theme: SpaceTheme,
        containerWidth: CGFloat,
        appearance: NSAppearance.Name,
        withDownloads: Bool,
        spaceAbove: CGFloat? = nil
    ) -> RenderedImage {
        let env = AppEnvironment()
        if withDownloads {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            let source = URL(string: "https://example.com/file")!
            env.recentDownloads = [
                DownloadItem(
                    sourceURL: source, destinationURL: directory.appendingPathComponent("movie.mov"),
                    suggestedFileName: "movie.mov", totalBytes: 1_000_000, receivedBytes: 400_000, state: .inProgress
                ),
                DownloadItem(
                    sourceURL: source, destinationURL: directory.appendingPathComponent("report.pdf"),
                    suggestedFileName: "report.pdf", totalBytes: 2_000, receivedBytes: 2_000, state: .completed,
                    finishedAt: Date().addingTimeInterval(-240)
                ),
                DownloadItem(
                    sourceURL: source, destinationURL: directory.appendingPathComponent("archive.zip"),
                    suggestedFileName: "archive.zip", state: .cancelled, finishedAt: Date().addingTimeInterval(-3_600)
                ),
            ]
        }

        let inset = (OrbitMetrics.sidebarBottomBarHeight - OrbitMetrics.sidebarBottomBarIconSize) / 2
        let size = CGSize(width: containerWidth, height: 480)
        let scene = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear
                .frame(width: containerWidth, height: OrbitMetrics.sidebarBottomBarHeight)
                .overlay(alignment: .bottomLeading) {
                    DownloadsPreviewOverlay(
                        theme: theme,
                        containerWidth: containerWidth,
                        spaceAbove: spaceAbove,
                        anchorMinX: inset,
                        anchorMidX: inset + OrbitMetrics.sidebarBottomBarIconSize / 2,
                        reduceMotion: true,
                        onHoverChange: { _ in },
                        onDismiss: {}
                    )
                }
        }
        .frame(width: size.width, height: size.height)
        .environment(env)
        .environment(\.orbitScreenshotModeDragDisabled, true)

        return render(scene, size: size, appearance: appearance)
    }

    private func opaqueBounds(of image: RenderedImage) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<Int(image.pointSize.height) {
            for x in 0..<Int(image.pointSize.width) where image.color(atX: x, y: y).a >= 0.97 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
        guard minX != Int.max else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func expectedSurface(of theme: SpaceTheme, appearance: NSAppearance.Name) -> RGBA {
        let side: CGFloat = 40
        let swatch = render(
            Color(theme.primary.nsColor)
                .overlay(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                .frame(width: side, height: side),
            size: CGSize(width: side, height: side),
            appearance: appearance
        )
        return swatch.color(atX: Int(side / 2), y: Int(side / 2))
    }

    // MARK: - The Library button leads the bottom bar

    func testLibraryButtonOccupiesTheBottomBarsLeadingSlotRegardlessOfSpaceCount() {
        let severalSpaces = renderBottomBar(spaceCount: 4)
        let oneSpace = renderBottomBar(spaceCount: 1)

        let bandWidth = OrbitMetrics.sidebarBottomBarHorizontalPadding + OrbitMetrics.sidebarBottomBarIconSize
        let differences = countingDifferences(severalSpaces, oneSpace, width: bandWidth)

        XCTAssertEqual(
            differences, 0,
            """
            The bottom bar's leading \(bandWidth)pt renders differently with four Spaces than with one \
            (\(differences) differing sample points), which means the Space switcher — the only part of \
            the row that appears or disappears with the Space count — is sitting in the leading slot. \
            Arc puts the Library button there and the Space icons after it \
            (refs/reference/web/arc-library-icon-hover-downloads-flyout-frame.png, and Library.gif \
            frame 0 from Arc Help Center article 19230634389911).
            """
        )
    }

    func testSpaceSwitcherStillRendersAfterTheLibraryButton() {
        let severalSpaces = renderBottomBar(spaceCount: 4)
        let oneSpace = renderBottomBar(spaceCount: 1)

        let bandWidth = OrbitMetrics.sidebarBottomBarHorizontalPadding + OrbitMetrics.sidebarBottomBarIconSize
        let differences = countingDifferences(
            severalSpaces, oneSpace,
            width: Self.bottomBarCanvas.width,
            skippingLeading: bandWidth
        )

        XCTAssertGreaterThan(
            differences, 0,
            """
            The bottom bar renders identically with four Spaces and with one, right across its width. \
            The Space switcher has to draw something with four Spaces — this fix reordered the row, it \
            did not remove the switcher (see SpaceSwitcherPagerRemovalTests for the below-two-Spaces case).
            """
        )
    }

    // MARK: - Bottom-bar rendering support

    private static let bottomBarCanvas = CGSize(
        width: OrbitMetrics.sidebarDefaultWidth,
        height: OrbitMetrics.sidebarBottomBarHeight
    )

    private func renderBottomBar(spaceCount: Int) -> RenderedImage {
        let env = AppEnvironment()
        var document = OrbitState()
        document.spaces = (0..<spaceCount).map { index in
            Space(name: "Space \(index)", icon: "circle", profileID: ProfileID(), order: index)
        }
        document.activeSpaceID = document.spaces.first?.id
        env.state = document

        return render(
            SidebarBottomBar(theme: SpaceTheme())
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: Self.bottomBarCanvas
        )
    }

    private func countingDifferences(
        _ lhs: RenderedImage,
        _ rhs: RenderedImage,
        width: CGFloat,
        skippingLeading: CGFloat = 0
    ) -> Int {
        var differences = 0
        for y in 0..<Int(Self.bottomBarCanvas.height) {
            for x in Int(skippingLeading)..<Int(width) {
                if !lhs.color(atX: x, y: y).isApproximately(rhs.color(atX: x, y: y), tolerance: 0.03) {
                    differences += 1
                }
            }
        }
        return differences
    }

    // MARK: - Files

    private func writeTemporaryPNG(named name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSColor.black.setFill()
        NSRect(x: 8, y: 8, width: 24, height: 24).fill()
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation, "Could not build TIFF data for the fixture image.")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), "Could not build a bitmap for the fixture image.")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "Could not encode the fixture image as PNG.")

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try png.write(to: url)
        return url
    }
}
