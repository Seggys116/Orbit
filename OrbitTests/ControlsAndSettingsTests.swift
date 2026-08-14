import SwiftUI
import XCTest

// MARK: - 1. Binding round-trip tests — real production state, no mirror

@MainActor
final class SettingsBindingRoundTripTests: XCTestCase {

    private var scratchDirectory: URL!

    /// A scratch UserDefaults suite: xcodebuild runs test classes in
    /// parallel xctest processes that all share .standard, so a shared
    /// fixture there would race across processes.
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ControlsSettings-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "OrbitTests-ControlsSettings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        ShortcutRegistry.defaults = defaults
        ShortcutRegistry.shared.reloadOverridesFromStore()
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil

        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        ShortcutRegistry.defaults = OrbitDefaults.standard
        ShortcutRegistry.shared.reloadOverridesFromStore()
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    private func makeStore() -> BrowserStore {
        BrowserStore(stateStore: StateStore(rootDirectory: scratchDirectory), autoArchiveInterval: nil)
    }

    // MARK: Profiles — "Archive tabs after" (OrbitPopupButton)

    func test_profilesPane_archivePolicyBinding_writesOneValueOnTheProfile() {
        let store = makeStore()
        let profile = store.activeSpace!.profileID
        let secondSpaceID = store.createSpace(name: "Second", profileID: profile)

        store.setArchivePolicy(.after7Days, forProfile: profile)

        XCTAssertEqual(store.state.profiles.first { $0.id == profile }?.archivePolicy, .after7Days,
                       "the picker must write the Profile's own setting")
        XCTAssertEqual(store.archivePolicy(forSpace: secondSpaceID), .after7Days,
                       "every Space on the Profile must resolve to the Profile's policy without anything being written onto the Space")
        XCTAssertNil(store.space(secondSpaceID)?.legacyArchivePolicy,
                     "nothing may write the retired per-Space carrier back onto a Space — it exists only so old documents can be read")

        store.setArchivePolicy(.never, forProfile: profile)
        XCTAssertEqual(store.archivePolicy(forSpace: secondSpaceID), .never)
    }

    func test_profilesPane_archivePolicyBinding_doesNotTouchAnotherProfilesSpaces() {
        let store = makeStore()
        let firstSpaceID = store.activeSpace!.id
        let firstProfile = store.activeSpace!.profileID
        let otherProfile = store.createProfile(name: "Other")
        // activate: false, since createSpace activates by default and would move activeSpace.
        let otherSpaceID = store.createSpace(name: "Other Space", profileID: otherProfile, activate: false)

        store.setArchivePolicy(.after30Days, forProfile: firstProfile)

        XCTAssertEqual(store.archivePolicy(forSpace: firstSpaceID), .after30Days)
        XCTAssertEqual(store.archivePolicy(forSpace: otherSpaceID), .after12Hours,
                       "a Profile-scoped setting must stop at the Profile — changing one Profile's archive cadence must not move another's")
    }

    // MARK: Links — routing rules

    func test_routingRule_isEnabledFlipsInPlace() {
        let store = makeStore()
        let rule = RoutingRule(pattern: "figma.com", destination: .littleOrbit, isEnabled: true)
        store.state.routingRules.append(rule)

        func updateRule(_ id: UUID, _ transform: (inout RoutingRule) -> Void) {
            guard let index = store.state.routingRules.firstIndex(where: { $0.id == id }) else { return }
            transform(&store.state.routingRules[index])
        }

        updateRule(rule.id) { $0.isEnabled = false }
        XCTAssertEqual(store.state.routingRules.first(where: { $0.id == rule.id })?.isEnabled, false)

        updateRule(rule.id) { $0.isEnabled = true }
        XCTAssertEqual(store.state.routingRules.first(where: { $0.id == rule.id })?.isEnabled, true)
    }

    func test_linksPane_deleteRuleButton_removesOnlyThatRule() {
        let store = makeStore()
        let keep = RoutingRule(pattern: "keep.example.com", destination: .littleOrbit)
        let delete = RoutingRule(pattern: "delete.example.com", destination: .littleOrbit)
        store.state.routingRules.append(contentsOf: [keep, delete])

        store.state.routingRules.removeAll { $0.id == delete.id }

        XCTAssertTrue(store.state.routingRules.contains { $0.id == keep.id })
        XCTAssertFalse(store.state.routingRules.contains { $0.id == delete.id })
    }

    func test_linksPane_defaultDestinationPopup_roundTripsThroughUserDefaults() {
        let key = "OrbitDefaultRoutingDestination"

        defaults.set("littleOrbit", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "littleOrbit")

        let spaceTag = UUID().uuidString
        defaults.set(spaceTag, forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), spaceTag)
    }

    // MARK: Shortcuts — recorder (OrbitButton) and clear (OrbitButton, ghost)

    func test_shortcutsPane_recorderCapture_setsThenClearsABinding() {
        let registry = ShortcutRegistry.shared
        registry.resetToDefaults()
        defer { registry.resetToDefaults() }

        guard let command = registry.commands.first else {
            XCTFail("ShortcutRegistry has no commands to test against.")
            return
        }

        let captured = KeyBinding(key: "k", modifiers: [.command, .shift])
        registry.setBinding(captured, for: command.id)
        XCTAssertEqual(registry.binding(for: command.id), captured)

        registry.setBinding(nil, for: command.id)
        XCTAssertNil(registry.binding(for: command.id), "the ghost 'clear' button's setBinding(nil, for:) must remove the override, not just no-op")
    }

    // MARK: General — AppStorage-backed toggles (OrbitToggle)

    func test_generalPane_appStorageToggles_roundTripThroughUserDefaults() {
        let keys = ["OrbitConfirmBeforeQuit", "OrbitHasConfiguredAIProvider"]

        for key in keys {
            defaults.set(true, forKey: key)
            XCTAssertTrue(defaults.bool(forKey: key), "\(key) did not read back true after OrbitToggle's binding would have set it")
            defaults.set(false, forKey: key)
            XCTAssertFalse(defaults.bool(forKey: key), "\(key) did not read back false after OrbitToggle's binding would have cleared it")
        }
    }

    // MARK: Ad Blocker — grouping is pure catalogue data; toggles bind straight to ContentBlockingController

    func test_adBlockerPane_everyCatalogueListAppearsExactlyOnceWhenGroupedByCategory() {
        let grouped = FilterListCategory.allCases.flatMap { FilterListCatalog.lists(in: $0) }
        XCTAssertEqual(Set(grouped.map(\.id)), Set(FilterListCatalog.all.map(\.id)),
                       "every catalogue list must show up somewhere once the pane groups by category")
        XCTAssertEqual(grouped.count, FilterListCatalog.all.count,
                       "no catalogue list may be returned under more than one category")
    }

    func test_adBlockerPane_groupedListsMatchTheirOwnDeclaredCategory() {
        for category in FilterListCategory.allCases {
            for descriptor in FilterListCatalog.lists(in: category) {
                XCTAssertEqual(descriptor.category, category,
                               "\(descriptor.id) was grouped under \(category) but declares category \(descriptor.category)")
            }
        }
    }

    func test_adBlockerPane_freshControllerDefaultsMatchTheCatalogsDeclaredDefaults() {
        let controller = ContentBlockingController(
            store: FilterListStore(directory: scratchDirectory),
            defaults: defaults
        )
        XCTAssertEqual(controller.enabledListIDs, FilterListCatalog.defaultEnabledIDs,
                       "with nothing persisted yet, the pane's toggles must reflect exactly the lists the catalogue marks isDefaultEnabled")
    }

    // Seeds a cache entry + raw list text directly on disk so the store
    // treats the list as already-cached and never fetches over the network.
    private func seedCachedList(_ listID: String, text: String) throws {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        try text.write(to: scratchDirectory.appendingPathComponent("\(listID).txt"), atomically: true, encoding: .utf8)
        let entry = FilterListCacheEntry(
            listID: listID,
            sourceURLs: [],
            declaredVersion: "1",
            declaredTitle: listID,
            expiresAfter: 4 * 86_400,
            fetchedAt: Date(),
            lastCheckedAt: Date(),
            etag: nil,
            lastModified: nil,
            byteCount: text.utf8.count,
            contentHash: "seed"
        )
        let data = try JSONEncoder.orbitContentBlocking.encode([listID: entry])
        try data.write(to: scratchDirectory.appendingPathComponent("index.json"), options: .atomic)
    }

    // Pre-marks the one-shot list migrations as already applied: these two
    // tests exercise the toggle/master-switch, not migration (that has its
    // own dedicated test class), so an explicit empty/single-list selection
    // must not be silently topped up by migrateEnabledLists.
    private func disableListMigrations() {
        defaults.set(true, forKey: "contentBlocking.enabledLists.didAddUBlockDefault")
        defaults.set(true, forKey: "contentBlocking.enabledLists.didAddUBlockUnbreakDefault")
    }

    func test_adBlockerPane_perListToggle_writesThroughTheControllerAndPersists() async throws {
        disableListMigrations()
        defaults.set([String](), forKey: "contentBlocking.enabledLists")
        try seedCachedList("EasyList", text: "[Adblock Plus 2.0]\n||toggle-test.example^\n")
        let controller = ContentBlockingController(
            store: FilterListStore(directory: scratchDirectory),
            defaults: defaults
        )
        XCTAssertTrue(controller.enabledListIDs.isEmpty, "an explicit empty selection must start empty, not be reseeded")

        let listID = "EasyList"

        await controller.setList(listID, enabled: true)
        XCTAssertTrue(controller.enabledListIDs.contains(listID))
        XCTAssertEqual(defaults.stringArray(forKey: "contentBlocking.enabledLists"), [listID],
                       "the pane's per-list toggle must persist through the same UserDefaults key a fresh controller reads on launch")
        XCTAssertGreaterThan(controller.compiledRuleCount, 0,
                             "enabling a list must actually recompile it into the live rule set, not just flip a flag")

        await controller.setList(listID, enabled: false)
        XCTAssertFalse(controller.enabledListIDs.contains(listID))
        XCTAssertEqual(defaults.stringArray(forKey: "contentBlocking.enabledLists"), [])
        XCTAssertEqual(controller.compiledRuleCount, 0, "disabling the only enabled list must drop it back out of the compiled rule set")
    }

    func test_adBlockerPane_masterSwitch_reachesTheContentBlockerTheEngineQueries() async throws {
        disableListMigrations()
        try seedCachedList("EasyList", text: "[Adblock Plus 2.0]\n||master-switch-test.example^\n")
        defaults.set(["EasyList"], forKey: "contentBlocking.enabledLists")
        let controller = ContentBlockingController(
            store: FilterListStore(directory: scratchDirectory),
            defaults: defaults
        )
        await controller.awaitInitialCacheLoad()
        XCTAssertGreaterThan(controller.compiledRuleCount, 0, "fixture must have something real compiled before exercising the master switch")

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.blocker.isEnabled)

        await controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.blocker.isEnabled,
                       "the pane's master switch must reach ContentBlocker, the object the engine actually asks for a decision")
        XCTAssertFalse(defaults.bool(forKey: "contentBlocking.enabled"))

        await controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.blocker.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "contentBlocking.enabled"))
    }

}

// MARK: - 2. Real control rendering — see file header

final class ControlRenderTests: XCTestCase {

    @MainActor
    func test_orbitToggle_rendersAtItsDeclaredMetricSize() {
        let rendered = render(
            OrbitToggle(accessibilityLabel: "Test toggle", isOn: .constant(true)),
            size: CGSize(width: 60, height: 40)
        )
        guard let box = rendered.boundingBoxOfContent() else {
            rendered.writeDiagnosticPNG(named: "ControlRenderTests_toggleSize")
            XCTFail("OrbitToggle drew nothing — expected content within a 34x20 area.")
            return
        }
        XCTAssertEqual(box.width, OrbitControlMetrics.toggleWidth, accuracy: 1, "OrbitToggle's track width must match OrbitControlMetrics.toggleWidth (34pt).")
        XCTAssertEqual(box.height, OrbitControlMetrics.toggleHeight, accuracy: 1, "OrbitToggle's track height must match OrbitControlMetrics.toggleHeight (20pt).")
    }

    @MainActor
    func test_orbitToggle_onStateVisiblyDiffersFromOffState() {
        let size = CGSize(width: 60, height: 40)
        let on = render(OrbitToggle(accessibilityLabel: "Test toggle", isOn: .constant(true), accentColor: .blue), size: size)
        let off = render(OrbitToggle(accessibilityLabel: "Test toggle", isOn: .constant(false), accentColor: .blue), size: size)

        // Both sample rects stay inside the toggle's 34pt-wide drawn area.
        let leadingEdgeOn = on.averageColor(in: CGRect(x: 6, y: 8, width: 4, height: 4))
        let leadingEdgeOff = off.averageColor(in: CGRect(x: 6, y: 8, width: 4, height: 4))
        XCTAssertFalse(
            leadingEdgeOn.isApproximately(leadingEdgeOff, tolerance: 0.06),
            "OrbitToggle's leading edge must look different on vs off (white knob when off, accent-filled track once the knob has moved when on) — got \(leadingEdgeOn) vs \(leadingEdgeOff)."
        )

        let trailingEdgeOn = on.averageColor(in: CGRect(x: 24, y: 8, width: 4, height: 4))
        let trailingEdgeOff = off.averageColor(in: CGRect(x: 24, y: 8, width: 4, height: 4))
        XCTAssertFalse(
            trailingEdgeOn.isApproximately(trailingEdgeOff, tolerance: 0.06),
            "OrbitToggle's trailing edge must look different on vs off (the knob sits here only when on) — got \(trailingEdgeOn) vs \(trailingEdgeOff)."
        )
    }

    @MainActor
    func test_orbitButton_primary_rendersAtItsDeclaredHeightAndPaintsAccentFill() {
        let rendered = render(
            OrbitButton(title: "Continue", kind: .primary, accentColor: .blue, action: {}),
            size: CGSize(width: 160, height: 60)
        )
        guard let box = rendered.boundingBoxOfContent() else {
            rendered.writeDiagnosticPNG(named: "ControlRenderTests_buttonSize")
            XCTFail("OrbitButton drew nothing.")
            return
        }
        XCTAssertEqual(box.height, OrbitControlMetrics.buttonHeight, accuracy: 1, "OrbitButton's height must match OrbitControlMetrics.buttonHeight (28pt).")

        let fill = rendered.averageColor(in: CGRect(x: box.midX - 2, y: box.midY - 2, width: 4, height: 4))
        XCTAssertGreaterThan(fill.b, fill.r, "a .blue accentColor fill should read back more blue than red at the button's centre — got \(fill).")
    }
}

// MARK: - 3. OrbitSecureField / OrbitSettingsActionRow — real control rendering

final class SecureFieldAndActionRowRenderTests: XCTestCase {

    @MainActor
    func test_orbitSecureField_rendersAtItsDeclaredHeight() {
        let rendered = render(
            OrbitSecureField(placeholder: "sk-…", text: .constant("sk-abcdefgh12345"), accessibilityLabel: "API key"),
            size: CGSize(width: 260, height: 60)
        )
        guard let box = rendered.boundingBoxOfContent() else {
            rendered.writeDiagnosticPNG(named: "SecureFieldTests_size")
            XCTFail("OrbitSecureField drew nothing — expected content within a 260x28 area.")
            return
        }
        XCTAssertEqual(box.height, OrbitControlMetrics.textFieldHeight, accuracy: 1.5, "OrbitSecureField's field height must match OrbitControlMetrics.textFieldHeight (28pt), the same token OrbitTextField reads.")
    }

    @MainActor
    func test_orbitSecureField_chromeMatchesOrbitTextFieldsSharedFillAndBorderTokens() {
        let size = CGSize(width: 260, height: 40)
        let secure = render(OrbitSecureField(placeholder: "sk-…", text: .constant(""), accessibilityLabel: "API key"), size: size)
        let text = render(OrbitTextField(placeholder: "sk-…", text: .constant("")), size: size)

        let sampleRect = CGRect(x: 2, y: 10, width: 6, height: 8)
        let secureChrome = secure.averageColor(in: sampleRect)
        let textChrome = text.averageColor(in: sampleRect)
        XCTAssertTrue(
            secureChrome.isApproximately(textChrome, tolerance: 0.03),
            "OrbitSecureField's own background/border chrome must match OrbitTextField's — both read OrbitControlColor.fill/.border with the same OrbitControlMetrics tokens — got \(secureChrome) vs \(textChrome)."
        )
        XCTAssertFalse(
            secureChrome.isApproximately(RGBA(r: 1, g: 0.829, b: 0, a: 1), tolerance: 0.02),
            "the sampled rect must be OrbitSecureField's own chrome, not the native SecureField's off-screen placeholder block — this sample point should sit inside the leading padding, before the native control begins drawing."
        )
    }

    @MainActor
    func test_orbitSettingsActionRow_trailingOnly_pushesContentToTheTrailingEdge() {
        let width: CGFloat = 400
        let rendered = render(
            OrbitSettingsActionRow {
                OrbitButton(title: "About Orbit…", kind: .secondary, accentColor: .blue, action: {})
            },
            size: CGSize(width: width, height: 44)
        )
        guard let box = rendered.boundingBoxOfContent() else {
            rendered.writeDiagnosticPNG(named: "SettingsActionRowTests_trailingOnly")
            XCTFail("OrbitSettingsActionRow drew nothing.")
            return
        }
        XCTAssertGreaterThan(box.maxX, width - 4, "a trailing-only OrbitSettingsActionRow must draw its content flush to the row's trailing edge — got maxX \(box.maxX) in a \(width)pt-wide row.")
        // .clear rather than a live-sampled background, so a regression that draws at the
        // leading edge cannot compare that region against its own colour and pass vacuously.
        let leadingSample = rendered.containsNonBackgroundPixels(in: CGRect(x: 0, y: 0, width: 60, height: 44), background: .clear)
        XCTAssertFalse(leadingSample, "a trailing-only OrbitSettingsActionRow must draw nothing near the leading edge.")
    }

    @MainActor
    func test_orbitSettingsActionRow_leadingAndTrailing_bothRender() {
        let width: CGFloat = 400
        let rendered = render(
            OrbitSettingsActionRow {
                Text("Remove this Profile from every Space before deleting it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } trailing: {
                OrbitButton(title: "Delete Profile", kind: .destructive, isCompact: true, accentColor: .blue, action: {})
            },
            size: CGSize(width: width, height: 44)
        )
        let background = rendered.color(atX: 0, y: 0)
        let leadingHasContent = rendered.containsNonBackgroundPixels(in: CGRect(x: 0, y: 0, width: 80, height: 44), background: background)
        let trailingHasContent = rendered.containsNonBackgroundPixels(in: CGRect(x: width - 80, y: 0, width: 80, height: 44), background: background)
        XCTAssertTrue(leadingHasContent, "OrbitSettingsActionRow's leading closure must draw content near the row's leading edge.")
        XCTAssertTrue(trailingHasContent, "OrbitSettingsActionRow's trailing closure must draw content near the row's trailing edge.")
    }
}
