import XCTest
import SwiftUI
import AppKit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class FolderToggleGlyphRenderTests: XCTestCase {

    // MARK: - Fixtures

    private let toggleSize = OrbitMetrics.sidebarFolderToggleSize

    private let highResScale: CGFloat = 8

    private func makeFolder(icon: String? = nil, iconIsEmoji: Bool = false, isExpanded: Bool = true) -> Folder {
        Folder(name: "Reading", isExpanded: isExpanded, icon: icon, iconIsEmoji: iconIsEmoji)
    }

    // MARK: - Requirement 1: closed vs. open produce measurably different ink

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_closedAndOpenGlyphShapes_produceMeasurablyDifferentInkAtProductionSize

    func test_closedAndOpenGlyphShapes_produceMeasurablyDifferentInkAtProductionSize() {
        let closed = render(
            FolderClosedGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )
        let open = render(
            FolderOpenGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )

        let diffPixels = differingAlphaPixelCount(closed, open)
        let totalPixels = closed.bitmap.pixelsWide * closed.bitmap.pixelsHigh

        if diffPixels == 0 {
            closed.writeDiagnosticPNG(named: "FolderToggleGlyph-closed-FAILED-identical")
            open.writeDiagnosticPNG(named: "FolderToggleGlyph-open-FAILED-identical")
        }
        XCTAssertGreaterThan(
            diffPixels, 200,
            "FolderClosedGlyphShape and FolderOpenGlyphShape must draw measurably different ink at " +
            "\(toggleSize)pt (production size, OrbitMetrics.sidebarFolderToggleSize) — the front flap peeling " +
            "open is a real, visible geometry change (see FolderToggleGlyph.swift's own header), not a subtle " +
            "recolouring. Measured \(diffPixels) of \(totalPixels) backing pixels differing in alpha " +
            "(scale \(highResScale)); 0 here would mean the two shapes draw identical paths."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_folderToggleGlyph_closedAndOpenStates_produceMeasurablyDifferentInk

    func test_folderToggleGlyph_closedAndOpenStates_produceMeasurablyDifferentInk() {
        let closed = render(
            FolderToggleGlyph(isOpen: false).foregroundStyle(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )
        let open = render(
            FolderToggleGlyph(isOpen: true).foregroundStyle(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )

        let diffPixels = differingAlphaPixelCount(closed, open)

        if diffPixels == 0 {
            closed.writeDiagnosticPNG(named: "FolderToggleGlyph-view-closed-FAILED-identical")
            open.writeDiagnosticPNG(named: "FolderToggleGlyph-view-open-FAILED-identical")
        }
        XCTAssertGreaterThan(
            diffPixels, 200,
            "FolderToggleGlyph(isOpen: false) and FolderToggleGlyph(isOpen: true) must render measurably " +
            "different ink — this is the row's entire disclosure affordance now that the rotating chevron is " +
            "gone (Orbit/UI/Sidebar/TabRowView.swift's PinnedFolderRowView header, user quote). Measured " +
            "\(diffPixels) differing backing pixels."
        )
    }

    // MARK: - Requirement 2: both shapes draw a real folder-like silhouette

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_closedGlyphShape_drawsNonEmptyInkMatchingItsDocumentedBoundingBox

    func test_closedGlyphShape_drawsNonEmptyInkMatchingItsDocumentedBoundingBox() {
        let rendered = render(
            FolderClosedGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )

        guard let box = inkBoundingBox(rendered) else {
            rendered.writeDiagnosticPNG(named: "FolderClosedGlyphShape-FAILED-empty")
            XCTFail("FolderClosedGlyphShape drew no ink at all at \(toggleSize)pt.")
            return
        }

        assertBoundingBoxMatchesSpec(
            box,
            frameSize: toggleSize,
            expectedMinXFraction: 0.0833, expectedMaxXFraction: 0.9167,
            expectedMinYFraction: 0.1250, expectedMaxYFraction: 0.8750,
            shapeName: "FolderClosedGlyphShape",
            rendered: rendered
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_openGlyphShape_drawsNonEmptyInkMatchingItsDocumentedBoundingBox

    func test_openGlyphShape_drawsNonEmptyInkMatchingItsDocumentedBoundingBox() {
        let rendered = render(
            FolderOpenGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )

        guard let box = inkBoundingBox(rendered) else {
            rendered.writeDiagnosticPNG(named: "FolderOpenGlyphShape-FAILED-empty")
            XCTFail("FolderOpenGlyphShape drew no ink at all at \(toggleSize)pt.")
            return
        }

        assertBoundingBoxMatchesSpec(
            box,
            frameSize: toggleSize,
            expectedMinXFraction: 0.0833, expectedMaxXFraction: 0.9120,
            expectedMinYFraction: 0.1250, expectedMaxYFraction: 0.8750,
            shapeName: "FolderOpenGlyphShape",
            rendered: rendered
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_closedAndOpenGlyphShapes_shareVerticalCentreAndHaveNearIdenticalWidth

    func test_closedAndOpenGlyphShapes_shareVerticalCentreAndHaveNearIdenticalWidth() {
        let closed = render(
            FolderClosedGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )
        let open = render(
            FolderOpenGlyphShape().fill(.black),
            size: CGSize(width: toggleSize, height: toggleSize),
            scale: highResScale
        )

        guard let closedBox = inkBoundingBox(closed), let openBox = inkBoundingBox(open) else {
            closed.writeDiagnosticPNG(named: "FolderToggleGlyph-centre-closed-FAILED-empty")
            open.writeDiagnosticPNG(named: "FolderToggleGlyph-centre-open-FAILED-empty")
            XCTFail("Expected both FolderClosedGlyphShape and FolderOpenGlyphShape to draw ink.")
            return
        }

        let closedCentreY = closedBox.midY
        let openCentreY = openBox.midY
        let centreYDelta = abs(closedCentreY - openCentreY)
        if centreYDelta > 0.5 {
            closed.writeDiagnosticPNG(named: "FolderToggleGlyph-centre-closed-FAILED")
            open.writeDiagnosticPNG(named: "FolderToggleGlyph-centre-open-FAILED")
        }
        XCTAssertLessThanOrEqual(
            centreYDelta, 0.5,
            "The closed shape's ink vertical centre (\(closedCentreY)pt) and the open shape's " +
            "(\(openCentreY)pt) must match — both are documented at unit-space centre y=0.5000 " +
            "(FolderToggleGlyph.swift's header) — otherwise the glyph visibly shifts vertically when a folder " +
            "row is toggled."
        )

        let widthDelta = abs(closedBox.width - openBox.width)
        XCTAssertLessThanOrEqual(
            widthDelta, 0.5,
            "The closed shape's ink width (\(closedBox.width)pt) and the open shape's (\(openBox.width)pt) " +
            "must be near-identical — documented as 0.9167-0.0833=0.8334 vs 0.9120-0.0833=0.8287 of the frame " +
            "(FolderToggleGlyph.swift's header), a ~0.0047 unit-space gap — so the row's layout cannot jitter " +
            "horizontally when toggled. Measured delta \(widthDelta)pt."
        )
    }

    // MARK: - Requirement 3: a custom icon is never overridden by the new default glyph

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_control_pinnedFolderRowView_withNoCustomIcon_rendersDifferentInkAcrossExpandedStates

    func test_control_pinnedFolderRowView_withNoCustomIcon_rendersDifferentInkAcrossExpandedStates() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let size = CGSize(width: 200, height: OrbitMetrics.sidebarRowHeight)

        guard
            let collapsed = hostedRender(
                PinnedFolderRowView(folder: makeFolder(isExpanded: false), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            ),
            let expanded = hostedRender(
                PinnedFolderRowView(folder: makeFolder(isExpanded: true), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            )
        else {
            XCTFail("hostedRender produced no bitmap for PinnedFolderRowView.")
            return
        }

        let diffPixels = differingColorPointCount(collapsed, expanded)
        if diffPixels == 0 {
            collapsed.writeDiagnosticPNG(named: "PinnedFolderRow-control-collapsed-FAILED-identical")
            expanded.writeDiagnosticPNG(named: "PinnedFolderRow-control-expanded-FAILED-identical")
        }
        XCTAssertGreaterThan(
            diffPixels, 0,
            "Control: a folder with no custom icon must render visibly different content between collapsed " +
            "and expanded (FolderToggleGlyph's closed/open swap) — 0 differing points here means this render " +
            "path cannot detect a glyph change at all, which would make the 'unchanged with a custom icon' " +
            "tests below meaningless."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRowView_withCustomEmojiIcon_rendersUnchangedAcrossExpandedStates

    func test_pinnedFolderRowView_withCustomEmojiIcon_rendersUnchangedAcrossExpandedStates() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let size = CGSize(width: 200, height: OrbitMetrics.sidebarRowHeight)
        let folderIcon = "🔥"

        guard
            let collapsed = hostedRender(
                PinnedFolderRowView(folder: makeFolder(icon: folderIcon, iconIsEmoji: true, isExpanded: false), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            ),
            let expanded = hostedRender(
                PinnedFolderRowView(folder: makeFolder(icon: folderIcon, iconIsEmoji: true, isExpanded: true), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            )
        else {
            XCTFail("hostedRender produced no bitmap for PinnedFolderRowView.")
            return
        }

        guard let collapsedBox = collapsed.boundingBoxOfContent(tolerance: 0.03),
              let expandedBox = expanded.boundingBoxOfContent(tolerance: 0.03) else {
            collapsed.writeDiagnosticPNG(named: "PinnedFolderRow-emoji-collapsed-FAILED-empty")
            expanded.writeDiagnosticPNG(named: "PinnedFolderRow-emoji-expanded-FAILED-empty")
            XCTFail("Expected a folder with a custom emoji icon to draw visible content in both states.")
            return
        }

        let diffPixels = differingColorPointCount(collapsed, expanded)
        if diffPixels > 0 || abs(collapsedBox.minX - expandedBox.minX) > 3 {
            collapsed.writeDiagnosticPNG(named: "PinnedFolderRow-emoji-collapsed-FAILED")
            expanded.writeDiagnosticPNG(named: "PinnedFolderRow-emoji-expanded-FAILED")
        }
        XCTAssertEqual(
            diffPixels, 0,
            "A folder with a custom emoji icon (\"\(folderIcon)\") must render pixel-identical content whether " +
            "collapsed or expanded — the default open/closed FolderToggleGlyph swap must never override a " +
            "user-chosen icon. Measured \(diffPixels) differing point-space samples between the two states."
        )
        XCTAssertEqual(
            collapsedBox.minX, expandedBox.minX, accuracy: 3,
            "The custom icon's own leading edge must not shift between collapsed (\(collapsedBox.minX)pt) and " +
            "expanded (\(expandedBox.minX)pt) — a shift here would mean a different glyph is being substituted " +
            "underneath it in one of the two states."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRowView_withCustomSFSymbolIcon_rendersUnchangedAcrossExpandedStates

    func test_pinnedFolderRowView_withCustomSFSymbolIcon_rendersUnchangedAcrossExpandedStates() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let size = CGSize(width: 200, height: OrbitMetrics.sidebarRowHeight)
        let folderIcon = "tray.full"

        guard
            let collapsed = hostedRender(
                PinnedFolderRowView(folder: makeFolder(icon: folderIcon, iconIsEmoji: false, isExpanded: false), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            ),
            let expanded = hostedRender(
                PinnedFolderRowView(folder: makeFolder(icon: folderIcon, iconIsEmoji: false, isExpanded: true), spaceID: SpaceID(), theme: theme, depth: 0).environment(env),
                size: size
            )
        else {
            XCTFail("hostedRender produced no bitmap for PinnedFolderRowView.")
            return
        }

        guard let collapsedBox = collapsed.boundingBoxOfContent(tolerance: 0.03),
              let expandedBox = expanded.boundingBoxOfContent(tolerance: 0.03) else {
            collapsed.writeDiagnosticPNG(named: "PinnedFolderRow-symbol-collapsed-FAILED-empty")
            expanded.writeDiagnosticPNG(named: "PinnedFolderRow-symbol-expanded-FAILED-empty")
            XCTFail("Expected a folder with a custom SF Symbol icon to draw visible content in both states.")
            return
        }

        let diffPixels = differingColorPointCount(collapsed, expanded)
        if diffPixels > 0 || abs(collapsedBox.minX - expandedBox.minX) > 3 {
            collapsed.writeDiagnosticPNG(named: "PinnedFolderRow-symbol-collapsed-FAILED")
            expanded.writeDiagnosticPNG(named: "PinnedFolderRow-symbol-expanded-FAILED")
        }
        XCTAssertEqual(
            diffPixels, 0,
            "A folder with a custom SF Symbol icon (\"\(folderIcon)\") must render pixel-identical content " +
            "whether collapsed or expanded — same proof, same reasoning, as the emoji case above. Measured " +
            "\(diffPixels) differing point-space samples between the two states."
        )
        XCTAssertEqual(
            collapsedBox.minX, expandedBox.minX, accuracy: 3,
            "The custom icon's own leading edge must not shift between collapsed (\(collapsedBox.minX)pt) and " +
            "expanded (\(expandedBox.minX)pt)."
        )
    }

    // MARK: - Requirement 4: FolderIconInput.resolve(typed:)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_emptyString_clearsToDefault

    func test_resolve_emptyString_clearsToDefault() {
        XCTAssertEqual(FolderIconInput.resolve(typed: ""), .clearToDefault)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_whitespaceOnlyString_clearsToDefault

    func test_resolve_whitespaceOnlyString_clearsToDefault() {
        XCTAssertEqual(
            FolderIconInput.resolve(typed: "   \n\t "), .clearToDefault,
            "Whitespace-only input must be treated the same as truly empty input — a user who selects the " +
            "field's placeholder text and hits Save without typing anything should still reset to the default " +
            "glyph, not leave the icon unchanged."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_singleEmoji_resolvesToEmojiCase

    func test_resolve_singleEmoji_resolvesToEmojiCase() {
        XCTAssertEqual(FolderIconInput.resolve(typed: "🔥"), .emoji("🔥"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_emojiWithSurroundingWhitespace_isTrimmedBeforeClassification

    func test_resolve_emojiWithSurroundingWhitespace_isTrimmedBeforeClassification() {
        XCTAssertEqual(
            FolderIconInput.resolve(typed: "  🔥  "), .emoji("🔥"),
            "Leading/trailing whitespace must be trimmed before classification, matching " +
            "PinnedFolderRowView.promptToChangeIcon's own NSTextField input, which a user can pad with stray " +
            "spaces without meaning to."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_validSFSymbolName_resolvesToSymbolCase

    func test_resolve_validSFSymbolName_resolvesToSymbolCase() {
        XCTAssertEqual(FolderIconInput.resolve(typed: "tray.full"), .symbol("tray.full"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_validSFSymbolNameWithSurroundingWhitespace_isTrimmed

    func test_resolve_validSFSymbolNameWithSurroundingWhitespace_isTrimmed() {
        XCTAssertEqual(FolderIconInput.resolve(typed: "  tray.full  "), .symbol("tray.full"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_unrecognisedNonEmojiText_leavesIconUnchanged

    func test_resolve_unrecognisedNonEmojiText_leavesIconUnchanged() {
        XCTAssertEqual(
            FolderIconInput.resolve(typed: "not-a-real-sf-symbol-name-xyz"), .unchanged,
            "Text that is neither empty, an emoji, nor a real SF Symbol name must resolve to .unchanged — " +
            "PinnedFolderRowView.promptToChangeIcon's own doc comment: 'leave the folder's icon exactly as it " +
            "was', mirroring GitHubLiveFolderRowView.promptToChangeIcon's identical refusal rather than storing " +
            "an icon that would render as an empty glyph slot."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_lowRangeDingbatishScalar_isNotClassifiedAsEmoji

    func test_resolve_lowRangeDingbatishScalar_isNotClassifiedAsEmoji() {
        XCTAssertEqual(
            FolderIconInput.resolve(typed: "#"), .unchanged,
            "\"#\" (U+0023) is marked Emoji=Yes by Unicode but sits below the 0x238C threshold " +
            "FolderIconInput.resolve(typed:) checks for exactly this reason (see its own doc comment) — it " +
            "must not be classified as .emoji(\"#\")."
        )
    }

    // MARK: - Requirement 5: AppEnvironment.setFolderIcon reaches BrowserStore.setFolderIcon

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_browserStoreSetFolderIcon_setsIconAndPersistsIntoTheFolderTree

    func test_browserStoreSetFolderIcon_setsIconAndPersistsIntoTheFolderTree() {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-FolderIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Reading", in: space.id)
        XCTAssertNil(store.folder(folderID, in: space.id)?.icon, "A freshly created folder must start with no custom icon.")

        store.setFolderIcon("🔥", isEmoji: true, forFolder: folderID, in: space.id)

        let afterSet = store.folder(folderID, in: space.id)
        XCTAssertEqual(afterSet?.icon, "🔥")
        XCTAssertEqual(afterSet?.iconIsEmoji, true)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_browserStoreSetFolderIcon_switchingFromEmojiToSFSymbol_updatesBothFields

    func test_browserStoreSetFolderIcon_switchingFromEmojiToSFSymbol_updatesBothFields() {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-FolderIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Reading", in: space.id)
        store.setFolderIcon("🔥", isEmoji: true, forFolder: folderID, in: space.id)

        store.setFolderIcon("tray.full", isEmoji: false, forFolder: folderID, in: space.id)

        let folder = store.folder(folderID, in: space.id)
        XCTAssertEqual(folder?.icon, "tray.full")
        XCTAssertEqual(
            folder?.iconIsEmoji, false,
            "Switching from an emoji icon to an SF Symbol must also flip iconIsEmoji — a stale `true` here " +
            "would make PinnedFolderRowView.folderGlyph render \"tray.full\" as literal emoji text instead of " +
            "resolving it through Image(systemName:)."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_browserStoreSetFolderIcon_clearingBackToNil_removesTheCustomIcon

    func test_browserStoreSetFolderIcon_clearingBackToNil_removesTheCustomIcon() {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-FolderIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = store.activeSpace!
        let folderID = store.createFolder(name: "Reading", in: space.id)
        store.setFolderIcon("🔥", isEmoji: true, forFolder: folderID, in: space.id)
        XCTAssertNotNil(store.folder(folderID, in: space.id)?.icon, "Fixture setup: the folder must have a custom icon before this test clears it.")

        store.setFolderIcon(nil, isEmoji: false, forFolder: folderID, in: space.id)

        let cleared = store.folder(folderID, in: space.id)
        XCTAssertNil(cleared?.icon, "Passing nil must clear the custom icon back to the default drawn glyph.")
        XCTAssertEqual(cleared?.iconIsEmoji, false)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_browserStoreSetFolderIcon_mutationIsVisibleThroughThePinnedTree

    func test_browserStoreSetFolderIcon_mutationIsVisibleThroughThePinnedTree() {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-FolderIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let store = BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
        let space = store.activeSpace!
        let outerID = store.createFolder(name: "Outer", in: space.id)
        let innerID = store.createFolder(name: "Inner", in: space.id, parent: outerID)

        store.setFolderIcon("📌", isEmoji: true, forFolder: innerID, in: space.id)

        let outer = store.pinnedNodes(in: space.id).first { $0.id == outerID }
        guard case .folder(let outerFolder) = outer else {
            XCTFail("Expected the outer folder to still be a .folder node in the Pinned tree.")
            return
        }
        guard case .folder(let innerFolder) = outerFolder.children.first(where: { $0.id == innerID }) else {
            XCTFail("Expected the inner folder to still be reachable as a child of the outer folder.")
            return
        }
        XCTAssertEqual(
            innerFolder.icon, "📌",
            "setFolderIcon on a nested folder must mutate that folder in place within the Pinned tree, " +
            "reachable the same way SidebarNodeRow's own recursion reaches it."
        )
    }
}

// MARK: - Test-only helpers: NSHostingView-based rendering (requirement 3)

@MainActor
private func hostedRender<V: View>(_ view: V, size: CGSize, colorScheme: ColorScheme = .dark) -> RenderedImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    let hosted = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, colorScheme)
    let hostingView = NSHostingView(rootView: hosted)
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / size.width
    return RenderedImage(bitmap: rep, pointSize: size, scale: scale)
}

// MARK: - Test-only helpers: raw-pixel measurement

@MainActor
private func inkBoundingBox(_ rendered: RenderedImage, alphaThreshold: Double = 0.5) -> CGRect? {
    let width = rendered.bitmap.pixelsWide
    let height = rendered.bitmap.pixelsHigh
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

    for y in 0..<height {
        for x in 0..<width {
            guard let color = rendered.bitmap.colorAt(x: x, y: y) else { continue }
            if Double(color.alphaComponent) > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
    }
    guard minX <= maxX, minX != Int.max else { return nil }
    return CGRect(
        x: CGFloat(minX) / rendered.scale,
        y: CGFloat(minY) / rendered.scale,
        width: CGFloat(maxX - minX) / rendered.scale,
        height: CGFloat(maxY - minY) / rendered.scale
    )
}

@MainActor
private func differingAlphaPixelCount(_ a: RenderedImage, _ b: RenderedImage, tolerance: Double = 0.12) -> Int {
    let width = min(a.bitmap.pixelsWide, b.bitmap.pixelsWide)
    let height = min(a.bitmap.pixelsHigh, b.bitmap.pixelsHigh)
    var count = 0
    for y in 0..<height {
        for x in 0..<width {
            let alphaA = Double(a.bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            let alphaB = Double(b.bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            if abs(alphaA - alphaB) > tolerance { count += 1 }
        }
    }
    return count
}

@MainActor
private func differingColorPointCount(_ a: RenderedImage, _ b: RenderedImage, tolerance: Double = 0.04) -> Int {
    let width = Int(min(a.pointSize.width, b.pointSize.width).rounded(.down))
    let height = Int(min(a.pointSize.height, b.pointSize.height).rounded(.down))
    var count = 0
    for y in 0..<max(height, 0) {
        for x in 0..<max(width, 0) {
            if !a.color(atX: x, y: y).isApproximately(b.color(atX: x, y: y), tolerance: tolerance) {
                count += 1
            }
        }
    }
    return count
}

@MainActor
private func assertBoundingBoxMatchesSpec(
    _ box: CGRect,
    frameSize: CGFloat,
    expectedMinXFraction: CGFloat,
    expectedMaxXFraction: CGFloat,
    expectedMinYFraction: CGFloat,
    expectedMaxYFraction: CGFloat,
    shapeName: String,
    rendered: RenderedImage,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectedMinX = frameSize * expectedMinXFraction
    let expectedMaxX = frameSize * expectedMaxXFraction
    let expectedMinY = frameSize * expectedMinYFraction
    let expectedMaxY = frameSize * expectedMaxYFraction
    let accuracy: CGFloat = 0.75

    var failed = false
    if abs(box.minX - expectedMinX) > accuracy { failed = true }
    if abs(box.maxX - expectedMaxX) > accuracy { failed = true }
    if abs(box.minY - expectedMinY) > accuracy { failed = true }
    if abs(box.maxY - expectedMaxY) > accuracy { failed = true }
    if failed {
        rendered.writeDiagnosticPNG(named: "\(shapeName)-FAILED-boundingBox")
    }

    XCTAssertEqual(box.minX, expectedMinX, accuracy: accuracy, "\(shapeName)'s ink left edge", file: file, line: line)
    XCTAssertEqual(box.maxX, expectedMaxX, accuracy: accuracy, "\(shapeName)'s ink right edge", file: file, line: line)
    XCTAssertEqual(box.minY, expectedMinY, accuracy: accuracy, "\(shapeName)'s ink top edge", file: file, line: line)
    XCTAssertEqual(box.maxY, expectedMaxY, accuracy: accuracy, "\(shapeName)'s ink bottom edge", file: file, line: line)

    let widthFraction = box.width / frameSize
    let heightFraction = box.height / frameSize
    XCTAssertGreaterThan(
        widthFraction, 0.6,
        "\(shapeName)'s ink should span most of the frame's width (documented ~83% of \(frameSize)pt); " +
        "measured \(Int(widthFraction * 100))%.",
        file: file, line: line
    )
    XCTAssertGreaterThan(
        heightFraction, 0.6,
        "\(shapeName)'s ink should span most of the frame's height (documented 75% of \(frameSize)pt); " +
        "measured \(Int(heightFraction * 100))%.",
        file: file, line: line
    )
}
