import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SidebarNewItemMenuViewTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func activate(_ tab: Orbit.Tab) {
        env.selectSpace(tab.spaceID)
        env.activeTabID = tab.id
    }

    // MARK: - Sections cover exactly SidebarNewItemOption.allCases: no dropped, no duplicated option

    func test_menuSections_containExactlyAllCasesWithNoOmissionOrDuplicate() {
        let flattened = SidebarNewItemOption.menuSections.flatMap(\.options)
        XCTAssertEqual(flattened.count, SidebarNewItemOption.allCases.count, "Every real creation option must appear in exactly one section — dropping or duplicating one here is a dead end for the user.")
        XCTAssertEqual(Set(flattened), Set(SidebarNewItemOption.allCases))
    }

    func test_menuSections_haveNoEmptySection() {
        for section in SidebarNewItemOption.menuSections {
            XCTAssertFalse(section.options.isEmpty, "Section \"\(section.title)\" has no options.")
        }
    }

    // MARK: - Icons: every option has a real, non-empty SF Symbol

    func test_everyOption_hasANonEmptySymbolName() {
        for option in SidebarNewItemOption.allCases {
            XCTAssertFalse(option.symbolName.isEmpty, "\(option) has no symbolName.")
        }
    }

    // MARK: - Shortcut hints: reflect the real ShortcutRegistry, never a hardcoded guess

    func test_shortcutDisplayString_forBoundCommands_matchesTheRealDefaultBinding() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        XCTAssertEqual(SidebarNewItemOption.newTab.shortcutDisplayString(registry: registry), registry.binding(for: .newTabCommandBar)?.displayString)
        XCTAssertEqual(SidebarNewItemOption.newTab.shortcutDisplayString(registry: registry), "⌘T")

        XCTAssertEqual(SidebarNewItemOption.newSplitView.shortcutDisplayString(registry: registry), registry.binding(for: .addSplit)?.displayString)
        XCTAssertEqual(SidebarNewItemOption.newNote.shortcutDisplayString(registry: registry), "⌃N")
        XCTAssertEqual(SidebarNewItemOption.newEasel.shortcutDisplayString(registry: registry), "⌃⇧L")
    }

    func test_shortcutDisplayString_forUnboundCommands_isNil() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        XCTAssertNil(SidebarNewItemOption.newFolder.shortcutDisplayString(registry: registry), "New Folder ships unbound by default; the row must show no hint, not a stale/guessed one.")
        XCTAssertNil(SidebarNewItemOption.newSpace.shortcutDisplayString(registry: registry))
        XCTAssertNil(SidebarNewItemOption.newBoost.shortcutDisplayString(registry: registry))
    }

    func test_shortcutDisplayString_reflectsAUserRemap_notJustTheFactoryDefault() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        registry.setBinding(.cmdShift("f"), for: .newFolder)
        XCTAssertEqual(SidebarNewItemOption.newFolder.shortcutDisplayString(registry: registry), "⇧⌘F")
    }

    // MARK: - Availability matches whether perform(in:) is a real no-op — the "no dead end" contract

    // store.activeSpace falls back to spaces.first, so the unavailable state needs no Space at all.
    func test_newFolder_isAvailable_iffThereIsAnActiveSpace() {
        XCTAssertNotNil(env.activeSpace, "test precondition: demo environment must start with an active Space.")
        XCTAssertTrue(SidebarNewItemOption.newFolder.isAvailable(in: env))
        XCTAssertNil(SidebarNewItemOption.newFolder.unavailableReason(in: env))

        env.state.spaces = []
        XCTAssertNil(env.activeSpace, "test precondition: no Spaces left means no active Space.")
        XCTAssertFalse(SidebarNewItemOption.newFolder.isAvailable(in: env))
        XCTAssertNotNil(SidebarNewItemOption.newFolder.unavailableReason(in: env))
    }

    func test_newFolder_whenUnavailable_performIsAGenuineNoOp() {
        env.state.spaces = []
        XCTAssertFalse(SidebarNewItemOption.newFolder.isAvailable(in: env))

        let before = env.state.tabs.count
        SidebarNewItemOption.newFolder.perform(in: env)
        // No active Space means createFolder(name:in:) never even gets a spaceID to target.
        XCTAssertEqual(env.state.tabs.count, before)
    }

    func test_newBoost_isAvailable_iffTheActiveTabHasAHost() {
        env.activeTabID = nil
        XCTAssertFalse(SidebarNewItemOption.newBoost.isAvailable(in: env), "No active tab: must be unavailable.")
        XCTAssertEqual(SidebarNewItemOption.newBoost.unavailableReason(in: env), "No page is open to attach a Boost to.")

        let tab = makeTab(url: "https://boosts.example.com/page")
        activate(tab)
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        XCTAssertTrue(SidebarNewItemOption.newBoost.isAvailable(in: env))
        XCTAssertNil(SidebarNewItemOption.newBoost.unavailableReason(in: env))
    }

    func test_newBoost_whenUnavailable_performPostsNoNotification() {
        env.activeTabID = nil
        XCTAssertFalse(SidebarNewItemOption.newBoost.isAvailable(in: env))

        var received = false
        let observer = NotificationCenter.default.addObserver(forName: .orbitPresentBoostsEditor, object: nil, queue: nil) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        SidebarNewItemOption.newBoost.perform(in: env)

        XCTAssertFalse(received)
    }

    // MARK: - The five always-available options are never gated

    func test_alwaysAvailableOptions_areAvailableEvenWithNoActiveSpaceOrTab() {
        env.state.spaces = []
        env.activeTabID = nil
        for option: SidebarNewItemOption in [.newTab, .newSplitView, .newSpace, .newNote, .newEasel] {
            XCTAssertTrue(option.isAvailable(in: env), "\(option) must never be gated — it either always succeeds or falls back to the Command Bar on its own.")
            XCTAssertNil(option.unavailableReason(in: env))
        }
    }

    // MARK: - Row style is pure and testably distinct: hover, disabled, light/dark

    func test_rowBackground_onlyHighlightsWhenHoveringAndAvailable() {
        XCTAssertEqual(SidebarNewItemMenuStyle.rowBackground(isHovering: false, isAvailable: true, colorScheme: .dark), .clear)
        XCTAssertEqual(SidebarNewItemMenuStyle.rowBackground(isHovering: true, isAvailable: false, colorScheme: .dark), .clear, "A disabled row must never paint a hover fill.")
        XCTAssertNotEqual(SidebarNewItemMenuStyle.rowBackground(isHovering: true, isAvailable: true, colorScheme: .dark), .clear)
    }

    func test_rowBackground_hoverFill_differsBetweenLightAndDark() {
        let light = SidebarNewItemMenuStyle.rowBackground(isHovering: true, isAvailable: true, colorScheme: .light)
        let dark = SidebarNewItemMenuStyle.rowBackground(isHovering: true, isAvailable: true, colorScheme: .dark)
        XCTAssertNotEqual(light, dark)
    }

    func test_rowForeground_disabledIsDimmerThanEnabled_inBothAppearances() {
        for scheme: ColorScheme in [.light, .dark] {
            let rendered = render(
                VStack(spacing: 0) {
                    Text("x").foregroundStyle(SidebarNewItemMenuStyle.rowForeground(isAvailable: true, colorScheme: scheme)).background(Color.black)
                    Text("x").foregroundStyle(SidebarNewItemMenuStyle.rowForeground(isAvailable: false, colorScheme: scheme)).background(Color.black)
                }
                .font(.system(size: 40, weight: .black)),
                size: CGSize(width: 60, height: 100),
                appearance: scheme == .dark ? .darkAqua : .aqua
            )
            let enabledSample = rendered.averageColor(in: CGRect(x: 0, y: 0, width: 60, height: 50))
            let disabledSample = rendered.averageColor(in: CGRect(x: 0, y: 50, width: 60, height: 50))
            XCTAssertGreaterThan(enabledSample.a, disabledSample.a, "appearance \(scheme)")
        }
    }

    // MARK: - Renders real, non-empty content in both appearances

    func test_view_rendersNonEmptyContent_inBothAppearances() {
        let expectedShortcuts = SidebarNewItemOption.allCases.filter { $0.shortcutDisplayString() != nil }.count
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                SidebarNewItemMenuView(dismiss: {}).environment(env)
                    .environment(\.orbitScreenshotModeDragDisabled, true),
                size: CGSize(width: SidebarNewItemMenuMetrics.width, height: 400),
                appearance: appearance
            )

            let dividers = Self.dividerBands(rendered)
            XCTAssertEqual(
                dividers.count, SidebarNewItemOption.menuSections.count - 1,
                "\(appearance.rawValue): \(dividers.count) divider(s) painted for \(SidebarNewItemOption.menuSections.count) sections."
            )

            let leading = Self.rowBands(rendered, xRange: 14..<32)
            XCTAssertEqual(
                leading.count, SidebarNewItemOption.menuSections.count + SidebarNewItemOption.allCases.count,
                "\(appearance.rawValue): \(leading.count) band(s) of ink in the icon column for \(SidebarNewItemOption.menuSections.count) section headers plus \(SidebarNewItemOption.allCases.count) rows -- a header or a row painted nothing."
            )

            let hints = Self.rowBands(rendered, xRange: 195..<219)
            XCTAssertEqual(
                hints.count, expectedShortcuts,
                "\(appearance.rawValue): \(hints.count) shortcut hint(s) painted for \(expectedShortcuts) bound option(s)."
            )
        }
    }

    func test_view_widthMatchesItsDeclaredMetric() {
        let rendered = render(
            SidebarNewItemMenuView(dismiss: {}).environment(env).background(Color.red),
            size: CGSize(width: 500, height: 500),
            appearance: .darkAqua
        )
        let box = rendered.boundingBoxOfContent()
        XCTAssertEqual(box?.width ?? -1, SidebarNewItemMenuMetrics.width, accuracy: 1)
    }

    // MARK: - Every row is reachable through the real view, with a working action

    func test_view_containsARowForEveryOption_andEachInvokesTheRealPerform() {
        for option in SidebarNewItemOption.allCases {
            var dismissed = false
            let row = SidebarNewItemMenuRow(
                option: option,
                isAvailable: true,
                unavailableReason: nil,
                shortcutDisplayString: option.shortcutDisplayString()
            ) {
                dismissed = true
            }
            let rendered = render(
                row.environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
                size: CGSize(width: SidebarNewItemMenuMetrics.width, height: 60),
                appearance: .darkAqua
            )
            XCTAssertTrue(
                Self.hasInk(rendered, in: CGRect(x: 8, y: 0, width: 20, height: 60)),
                "\(option) row painted no icon."
            )
            XCTAssertFalse(
                Self.hasInk(rendered, in: CGRect(x: 28, y: 0, width: 8, height: 60)),
                "\(option) row painted into the gutter between its icon and its title -- the title has slid left into the icon's place."
            )
            XCTAssertTrue(
                Self.hasInk(rendered, in: CGRect(x: 37, y: 0, width: 25, height: 60)),
                "\(option) row painted no title beside its icon."
            )
            XCTAssertEqual(
                Self.hasInk(rendered, in: CGRect(x: 180, y: 0, width: 46, height: 60)),
                option.shortcutDisplayString() != nil,
                "\(option) row's trailing shortcut hint does not match its binding (\(option.shortcutDisplayString() ?? "unbound"))."
            )

            row.action()
            XCTAssertTrue(dismissed, "\(option) row's action must fire when invoked.")
        }
    }

    // MARK: - The content SidebarBottomBar presents (pure data; OrbitContextMenuVisualTests covers rendering)

    func test_contextMenuEntries_flattenedTitles_matchAllCasesInOrder() {
        let entries = SidebarNewItemOption.contextMenuEntries(in: env)
        XCTAssertEqual(entries.flattenedItems.map(\.title), SidebarNewItemOption.allCases.map(\.title))
    }

    // The "+" menu separates its groups with a divider alone, never a section label.
    func test_contextMenuEntries_groupWithDividersAndNoSectionHeaders() {
        let entries = SidebarNewItemOption.contextMenuEntries(in: env)

        for entry in entries {
            if case .section(_, let title, _) = entry {
                XCTFail("The \"+\" menu must carry no section header, but found \"\(title)\".")
            }
        }

        let dividers = entries.filter { if case .divider = $0 { return true } else { return false } }
        XCTAssertEqual(
            dividers.count, SidebarNewItemOption.menuSections.count - 1,
            "Every group boundary from menuSections must still be drawn as a divider."
        )

        // The dividers must fall on the real group boundaries, not anywhere.
        var titlesBetweenDividers: [[String]] = [[]]
        for entry in entries {
            switch entry {
            case .divider: titlesBetweenDividers.append([])
            case .item(let item): titlesBetweenDividers[titlesBetweenDividers.count - 1].append(item.title)
            case .section: break
            }
        }
        XCTAssertEqual(titlesBetweenDividers, SidebarNewItemOption.menuSections.map { $0.options.map(\.title) })
    }

    func test_contextMenuEntries_everyItem_hasTheOptionsSymbolAsIcon() {
        let entries = SidebarNewItemOption.contextMenuEntries(in: env)
        let itemsByTitle = Dictionary(uniqueKeysWithValues: entries.flattenedItems.map { ($0.title, $0) })
        for option in SidebarNewItemOption.allCases {
            XCTAssertEqual(itemsByTitle[option.title]?.systemImage, option.symbolName, "\(option)")
        }
    }

    func test_contextMenuEntries_isEnabledAndTooltip_matchIsAvailableAndUnavailableReason() {
        env.state.spaces = []
        env.activeTabID = nil
        let entries = SidebarNewItemOption.contextMenuEntries(in: env)
        let itemsByTitle = Dictionary(uniqueKeysWithValues: entries.flattenedItems.map { ($0.title, $0) })
        for option in SidebarNewItemOption.allCases {
            let item = itemsByTitle[option.title]
            XCTAssertEqual(item?.isEnabled, option.isAvailable(in: env), "\(option)")
            XCTAssertEqual(item?.tooltip, option.unavailableReason(in: env), "\(option)")
        }
    }

    func test_contextMenuEntries_newTabItemAction_isTheRealPerform() {
        env.isCommandBarPresented = false
        let item = SidebarNewItemOption.contextMenuEntries(in: env).first(titled: SidebarNewItemOption.newTab.title)
        item?.action?()
        XCTAssertTrue(env.isCommandBarPresented)
    }

    // MARK: - Ink measurement

    private static func hasInk(_ image: RenderedImage, in rect: CGRect) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where image.color(atX: x, y: y).a > 0.04 {
                return true
            }
        }
        return false
    }

    // A divider is the only thing that paints at the menu's own leading edge.
    private static func isDividerRow(_ image: RenderedImage, y: Int) -> Bool {
        image.color(atX: Int(SidebarNewItemMenuMetrics.containerPadding), y: y).a > 0.04
    }

    private static func dividerBands(_ image: RenderedImage) -> [Range<Int>] {
        bands(image) { isDividerRow(image, y: $0) }
    }

    private static func rowBands(_ image: RenderedImage, xRange: Range<Int>) -> [Range<Int>] {
        bands(image) { y in
            guard !isDividerRow(image, y: y) else { return false }
            for x in xRange where image.color(atX: x, y: y).a > 0.04 { return true }
            return false
        }
    }

    private static func bands(_ image: RenderedImage, matching predicate: (Int) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for y in 0..<Int(image.pointSize.height) {
            if predicate(y), start == nil { start = y }
            if !predicate(y), let began = start {
                result.append(began..<y)
                start = nil
            }
        }
        if let began = start { result.append(began..<Int(image.pointSize.height)) }
        return result
    }
}
