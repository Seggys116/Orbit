import XCTest
import SwiftUI
import AppKit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class FolderGlyphBlankSlotRegressionTests: XCTestCase {

    // MARK: - Fixtures

    private var glyphColumn: (minX: CGFloat, maxX: CGFloat) {
        let minX = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
        return (minX, minX + OrbitMetrics.sidebarFolderToggleSize)
    }

    private let rowSize = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)

    // "rocket" is not an SF Symbol; Image(systemName:) draws nothing for it.
    private let unresolvableSymbolName = "rocket"

    private func makeSpace(pinned: [SidebarNode]) -> (env: AppEnvironment, spaceID: SpaceID) {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        let space = Space(name: "Personal", profileID: profile.id, pinned: pinned)
        env.state.profiles = [profile]
        env.state.spaces = [space]
        return (env, space.id)
    }

    // MARK: - Requirement 1: the resolvability test itself

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitSymbolName_isResolvable_rejectsANameThatIsNotAnSFSymbol

    func test_orbitSymbolName_isResolvable_rejectsANameThatIsNotAnSFSymbol() {
        XCTAssertFalse(
            OrbitSymbolName.isResolvable(unresolvableSymbolName),
            "\"\(unresolvableSymbolName)\" is not an SF Symbol on this SDK — NSImage(systemSymbolName:) returns nil " +
            "for it, and Image(systemName:) therefore draws nothing at all. If this assertion ever fails because " +
            "Apple shipped the symbol, pick another genuinely-absent name; do not delete the test, because the " +
            "silent-blank behaviour it pins down is a property of Image(systemName:), not of this one string."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitSymbolName_isResolvable_acceptsRealSFSymbols

    func test_orbitSymbolName_isResolvable_acceptsRealSFSymbols() {
        for name in ["folder", "tray.full", "paperplane.fill", "airplane", "book.closed"] {
            XCTAssertTrue(
                OrbitSymbolName.isResolvable(name),
                "\"\(name)\" is a real SF Symbol and must be reported resolvable — a check that rejected real " +
                "symbols would push every custom folder icon back to the default drawn glyph, which is the " +
                "opposite defect."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitSymbolName_isResolvable_rejectsEmptyAndWhitespaceOnlyNames

    func test_orbitSymbolName_isResolvable_rejectsEmptyAndWhitespaceOnlyNames() {
        XCTAssertFalse(OrbitSymbolName.isResolvable(""))
        XCTAssertFalse(
            OrbitSymbolName.isResolvable("   \n\t "),
            "A whitespace-only stored icon must not be treated as a drawable symbol — it draws nothing, which is " +
            "the same blank slot this whole file exists to prevent."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_orbitSymbolName_isResolvable_isStableAcrossRepeatedCalls

    func test_orbitSymbolName_isResolvable_isStableAcrossRepeatedCalls() {
        for _ in 0..<3 {
            XCTAssertTrue(OrbitSymbolName.isResolvable("folder"))
            XCTAssertFalse(OrbitSymbolName.isResolvable(unresolvableSymbolName))
        }
    }

    // MARK: - Requirement 2: the defect itself, in real rendered pixels

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRow_withUnresolvableSymbolIcon_stillDrawsInkInTheGlyphColumn

    func test_pinnedFolderRow_withUnresolvableSymbolIcon_stillDrawsInkInTheGlyphColumn() {
        for isExpanded in [false, true] {
            let ink = glyphColumnInkCount(icon: unresolvableSymbolName, iconIsEmoji: false, isExpanded: isExpanded)
            XCTAssertGreaterThan(
                ink, 0,
                "A folder whose stored icon is \"\(unresolvableSymbolName)\" — a name that is not an SF Symbol — " +
                "drew NOTHING in its glyph column (isExpanded: \(isExpanded)). That is the user's reported defect " +
                "verbatim (\"i dont see the folder glyph or the one set its just blank\"), reproduced against the " +
                "demo fixture's own \"Q4 Launches\" folder in real on-screen pixels. PinnedFolderRowView" +
                ".folderGlyph must fall back to the drawn FolderToggleGlyph for any icon name " +
                "OrbitSymbolName.isResolvable(_:) rejects, never to an empty slot."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRow_withUnresolvableSymbolIcon_rendersTheSameGlyphAsNoIconAtAll

    func test_pinnedFolderRow_withUnresolvableSymbolIcon_rendersTheSameGlyphAsNoIconAtAll() {
        for isExpanded in [false, true] {
            let withBadIcon = glyphColumnInkCount(icon: unresolvableSymbolName, iconIsEmoji: false, isExpanded: isExpanded)
            let withNoIcon = glyphColumnInkCount(icon: nil, iconIsEmoji: false, isExpanded: isExpanded)
            XCTAssertEqual(
                withBadIcon, withNoIcon,
                "An unresolvable icon name must fall all the way back to the default drawn FolderToggleGlyph, so " +
                "the glyph column's ink is identical to a folder with no custom icon (isExpanded: \(isExpanded)): " +
                "measured \(withBadIcon) vs \(withNoIcon) inked samples. A different count here means the fallback " +
                "is drawing something other than the real default glyph."
            )
        }
    }

    // MARK: - Requirement 3: every configuration that already worked, still works

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRow_withNoCustomIcon_drawsInkInTheGlyphColumn_inBothExpandStates

    func test_pinnedFolderRow_withNoCustomIcon_drawsInkInTheGlyphColumn_inBothExpandStates() {
        for isExpanded in [false, true] {
            XCTAssertGreaterThan(
                glyphColumnInkCount(icon: nil, iconIsEmoji: false, isExpanded: isExpanded), 0,
                "The default drawn FolderToggleGlyph must draw real ink in the glyph column (isExpanded: " +
                "\(isExpanded)) — this is the row's entire disclosure affordance now that the rotating chevron " +
                "is gone."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRow_withResolvableSymbolIcon_drawsInkInTheGlyphColumn

    func test_pinnedFolderRow_withResolvableSymbolIcon_drawsInkInTheGlyphColumn() {
        XCTAssertGreaterThan(
            glyphColumnInkCount(icon: "tray.full", iconIsEmoji: false, isExpanded: false), 0,
            "A custom SF Symbol that really exists must still draw — the resolvability guard must not have been " +
            "bought by rejecting valid symbols."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_pinnedFolderRow_withEmojiIcon_drawsInkInTheGlyphColumn

    func test_pinnedFolderRow_withEmojiIcon_drawsInkInTheGlyphColumn() {
        XCTAssertGreaterThan(
            glyphColumnInkCount(icon: "🔥", iconIsEmoji: true, isExpanded: false), 0,
            "A custom emoji icon is not a symbol name and must never be run through the SF Symbol resolvability " +
            "check at all — it must draw exactly as it always did."
        )
    }

    // MARK: - Requirement 4: the fixture that shipped the bad name

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyNonEmojiIconNameInTheDemoFixture_resolvesToARealSFSymbol

    func test_everyNonEmojiIconNameInTheDemoFixture_resolvesToARealSFSymbol() {
        let state = OrbitState.demo
        var checked = 0

        func checkFolder(_ folder: Folder, spaceName: String) {
            if let icon = folder.icon, !icon.isEmpty, !folder.iconIsEmoji {
                checked += 1
                XCTAssertTrue(
                    OrbitSymbolName.isResolvable(icon),
                    "OrbitState.demo's \"\(spaceName)\" Space has a pinned folder \"\(folder.name)\" whose icon " +
                    "\"\(icon)\" is not an SF Symbol on this SDK. Image(systemName:) draws nothing at all for such " +
                    "a name, so this folder's glyph slot renders blank in the demo and in every screenshot — the " +
                    "exact defect reported against \"Q4 Launches\" and its \"rocket\" icon. Use a real symbol name."
                )
            }
            for child in folder.children {
                if case .folder(let nested) = child { checkFolder(nested, spaceName: spaceName) }
            }
        }

        for space in state.spaces {
            let icon = space.icon
            if !icon.isEmpty, !space.iconIsEmoji {
                checked += 1
                XCTAssertTrue(
                    OrbitSymbolName.isResolvable(icon),
                    "OrbitState.demo's Space \"\(space.name)\" has icon \"\(icon)\", which is not an SF Symbol on " +
                    "this SDK — SpaceIconView would draw nothing for it."
                )
            }
            for node in space.pinned {
                if case .folder(let folder) = node { checkFolder(folder, spaceName: space.name) }
            }
        }

        XCTAssertGreaterThan(
            checked, 0,
            "This guard found no non-emoji icon names in OrbitState.demo at all, so it proved nothing. Either the " +
            "fixture stopped using SF Symbol icons (in which case delete this test deliberately) or this walk no " +
            "longer reaches them (in which case fix the walk)."
        )
    }

    // MARK: - Helpers

    private func glyphColumnInkCount(icon: String?, iconIsEmoji: Bool, isExpanded: Bool) -> Int {
        let folder = Folder(name: "Reading", isExpanded: isExpanded, icon: icon, iconIsEmoji: iconIsEmoji)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        guard let rendered = hostedRenderRow(
            PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: SpaceTheme(), depth: 0).environment(env),
            size: rowSize
        ) else {
            XCTFail("hostedRender produced no bitmap for PinnedFolderRowView (icon: \(icon ?? "nil")).")
            return 0
        }

        let column = glyphColumn
        var inked = 0
        for x in Int(column.minX.rounded(.down))...Int(column.maxX.rounded(.up)) {
            for y in 0..<Int(rowSize.height) {
                if !rendered.color(atX: x, y: y).isApproximately(.clear, tolerance: 0.06) { inked += 1 }
            }
        }
        if inked == 0 {
            rendered.writeDiagnosticPNG(
                named: "FolderGlyphBlankSlot-FAILED-icon-\(icon ?? "none")-expanded-\(isExpanded)"
            )
        }
        return inked
    }
}

// MARK: - Test-only helper: NSHostingView-based rendering

// ImageRenderer cannot flatten PinnedFolderRowView's NSViewRepresentable glyph and paints a placeholder over the slot instead.
@MainActor
private func hostedRenderRow<V: View>(_ view: V, size: CGSize, colorScheme: ColorScheme = .dark) -> RenderedImage? {
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
