// No heading, no divider, no button: rows bottom-aligned above the bottom bar. Every
// assertion is a relationship between renders, a string Arc displays, or a real transition.

import SwiftUI
import XCTest

@MainActor
final class DownloadsFlyoutTests: XCTestCase {

    // MARK: - Fixtures

    private static let canvas = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 420)

    private func makeDownload(
        name: String,
        finishedAt: Date? = Date(timeIntervalSinceNow: -120)
    ) -> DownloadItem {
        DownloadItem(
            sourceURL: URL(string: "https://example.com/\(name)")!,
            destinationURL: URL(fileURLWithPath: "/tmp/OrbitDownloadsFlyoutTests/\(name)"),
            suggestedFileName: name,
            state: .completed,
            startedAt: Date(timeIntervalSinceNow: -300),
            finishedAt: finishedAt
        )
    }

    private func renderFlyout(_ downloads: [DownloadItem], size: CGSize = DownloadsFlyoutTests.canvas) -> RenderedImage {
        render(
            DownloadsFlyoutView(theme: SpaceTheme(), downloads: downloads)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: size
        )
    }

    // MARK: - No heading, no divider, no button

    func testFlyoutWithNoDownloadsPaintsNothingAtAll() {
        let rendered = renderFlyout([])

        if let box = rendered.boundingBoxOfContent(tolerance: 0.03) {
            rendered.writeDiagnosticPNG(named: "DownloadsFlyout-empty-FAILED")
            XCTFail(
                """
                A downloads flyout with nothing downloaded painted content at \(box). Arc's flyout \
                (refs/reference/web/arc-library-icon-hover-downloads-flyout-frame.png) has no heading, \
                no divider and no button, so with no rows there is nothing left to draw — and \
                refs/ARC_INTERACTION.md §5 forbids placeholder copy in its place. See the diagnostic PNG.
                """
            )
        }
    }

    func testFlyoutWithDownloadsPaintsThem() {
        let rendered = renderFlyout([makeDownload(name: "Report.pdf"), makeDownload(name: "Photo.heic")])

        guard rendered.boundingBoxOfContent(tolerance: 0.03) != nil else {
            rendered.writeDiagnosticPNG(named: "DownloadsFlyout-populated-FAILED")
            XCTFail("The flyout painted nothing with two downloads in it, so the empty-state assertion above is measuring a view that cannot draw. See the diagnostic PNG.")
            return
        }
    }

    // MARK: - Bottom-aligned, and growing upwards

    func testFlyoutRowsSitAtTheBottomOfThePanel() {
        let rendered = renderFlyout([makeDownload(name: "Report.pdf"), makeDownload(name: "Photo.heic")])

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            XCTFail("Nothing was drawn, so this test cannot say where it landed — see testFlyoutWithDownloadsPaintsThem.")
            return
        }
        let gapAbove = box.minY
        let gapBelow = Self.canvas.height - box.maxY

        XCTAssertLessThan(
            gapBelow, gapAbove,
            """
            The flyout's rows are \(gapBelow)pt from the panel's bottom edge and \(gapAbove)pt from its \
            top — i.e. top-aligned. Arc bottom-aligns them against the sidebar's bottom bar \
            (refs/reference/web/arc-library-icon-hover-downloads-flyout-frame.png).
            """
        )
    }

    func testAddingRowsExtendsTheListUpwardsAndLeavesItsBottomEdgeAlone() {
        let one = renderFlyout([makeDownload(name: "Report.pdf")])
        let three = renderFlyout([
            makeDownload(name: "Report.pdf"),
            makeDownload(name: "Photo.heic"),
            makeDownload(name: "Notes.txt"),
        ])

        guard let oneBox = one.boundingBoxOfContent(tolerance: 0.03),
              let threeBox = three.boundingBoxOfContent(tolerance: 0.03) else {
            XCTFail("One or both renders painted nothing — see testFlyoutWithDownloadsPaintsThem.")
            return
        }

        XCTAssertEqual(
            threeBox.maxY, oneBox.maxY, accuracy: 2,
            """
            The list's bottom edge moved from \(oneBox.maxY)pt to \(threeBox.maxY)pt when two rows were \
            added. Bottom-aligned means the bottom edge is the anchor and extra rows grow away from it.
            """
        )
        XCTAssertLessThan(
            threeBox.minY, oneBox.minY,
            """
            Three rows did not reach higher up the panel (\(threeBox.minY)pt) than one row \
            (\(oneBox.minY)pt), so rows are not stacking upwards from the bottom.
            """
        )
    }

    // MARK: - The second line reads the way Arc's does

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

    // MARK: - For human eyes

    func testWriteFlyoutImageForHumanInspection() {
        let downloads = [
            makeDownload(name: "IMG_4632.HEIC", finishedAt: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)),
            makeDownload(name: "Draft_Proposal_Movember.pages", finishedAt: Date(timeIntervalSinceNow: -4 * 60)),
            makeDownload(name: "Untitled spreadsheet.numbers", finishedAt: Date(timeIntervalSinceNow: -2 * 60)),
            makeDownload(name: "Half Baked Harvest (Recipes).pdf", finishedAt: Date(timeIntervalSinceNow: -60)),
        ]
        let theme = SpaceTheme()
        let view = VStack(spacing: 0) {
            DownloadsFlyoutView(theme: theme, downloads: downloads)
            SidebarBottomBar(theme: theme).environment(AppEnvironment())
        }
        .environment(\.orbitScreenshotModeDragDisabled, true)
        .background { ThemeBackgroundView(theme: theme, blur: 0) }

        render(view, size: CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: 420))
            .writeDiagnosticPNG(named: "DownloadsFlyout-over-theme")
    }

    // MARK: - An empty flyout must never open in the first place

    func testHoveringTheLibraryButtonWithNothingDownloadedDoesNotOpenThePanel() {
        XCTAssertFalse(
            SidebarBottomBar.shouldOpenFlyout(isHoveringButton: true, isHoveringFlyout: false, downloadCount: 0),
            """
            Hovering the Library button with nothing downloaded opened the flyout panel. That panel paints \
            opaque theme colour over the whole sidebar and the empty flyout paints nothing into it, so the \
            tab list simply vanishes for as long as the pointer rests on the archive glyph — which is what \
            every user sees on first launch.
            """
        )
        XCTAssertFalse(
            SidebarBottomBar.shouldOpenFlyout(isHoveringButton: false, isHoveringFlyout: true, downloadCount: 0),
            "The grace period that lets the pointer travel from the button onto the panel must not be able to hold an empty panel open either."
        )
    }

    func testHoveringTheLibraryButtonWithDownloadsStillOpensThePanel() {
        XCTAssertTrue(
            SidebarBottomBar.shouldOpenFlyout(isHoveringButton: true, isHoveringFlyout: false, downloadCount: 1),
            "One download is enough to have something to present, and Arc's Help Center describes hovering the Library icon as the way to reach recent files."
        )
        XCTAssertTrue(
            SidebarBottomBar.shouldOpenFlyout(isHoveringButton: false, isHoveringFlyout: true, downloadCount: 4),
            "The pointer moving off the button and onto the panel's own rows must keep the panel open, or the rows could never be clicked or dragged."
        )
        XCTAssertFalse(
            SidebarBottomBar.shouldOpenFlyout(isHoveringButton: false, isHoveringFlyout: false, downloadCount: 4),
            "With the pointer nowhere near either surface the panel must close regardless of how many downloads there are."
        )
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
