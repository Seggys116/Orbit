//  Real production SiteSearchStore via @testable import, not a double. Every store is built
//  over its own temporary file: parallel test processes share UserDefaults.standard.

import XCTest
@testable import Orbit

@MainActor
final class SiteSearchStoreTests: XCTestCase {

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitSiteSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    private func scratchFileURL(_ name: String = "site-search.json") -> URL {
        scratchRoot.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 6. First run seeds exactly the three sourced defaults

    func test_freshStore_seedsArcsThreeDocumentedDefaults() {
        let store = SiteSearchStore(fileURL: scratchFileURL())

        XCTAssertEqual(store.engines.count, 3, "Arc's Site Search settings capture shows exactly three rows; a fourth would not be sourced.")
        XCTAssertEqual(store.engines.map(\.name), ["Amazon", "Twitter", "YouTube"])
        XCTAssertEqual(store.engines.map(\.shortcut), ["a", "tw", "yt"])
        XCTAssertEqual(store.engines.map(\.urlTemplate), [
            "https://www.amazon.com/s?k=%s",
            "https://twitter.com/search?q=%s",
            "https://www.youtube.com/results?search_query=%s",
        ])
        XCTAssertEqual(store.triggerKey, .tab, "Tab is the only trigger key the Help Center documents, so it is the default.")
    }

    func test_seedingHappensOnceAndDoesNotResurrectDeletedEngines() throws {
        let url = scratchFileURL()
        let first = SiteSearchStore(fileURL: url)
        for engine in first.engines {
            first.deleteEngine(engine.id)
        }
        XCTAssertTrue(first.engines.isEmpty)
        try first.saveNow()

        let second = SiteSearchStore(fileURL: url)
        XCTAssertTrue(
            second.engines.isEmpty,
            "A user who deletes every site must not find all three seeded back on the next launch."
        )
    }

    // MARK: - 7. Create / update / delete, and real persistence

    func test_createUpdateDelete_roundTripThroughTheFile() throws {
        let url = scratchFileURL()
        let first = SiteSearchStore(fileURL: url)
        let seededCount = first.engines.count

        let created = first.createEngine(name: "Wikipedia", shortcut: "w", urlTemplate: "https://en.wikipedia.org/w/index.php?search=%s")
        XCTAssertEqual(first.engines.count, seededCount + 1)
        XCTAssertEqual(first.engine(created.id)?.name, "Wikipedia")

        first.updateEngine(created.id) { engine in
            engine.name = "Wikipedia (EN)"
            engine.shortcut = "wk"
        }
        XCTAssertEqual(first.engine(created.id)?.name, "Wikipedia (EN)")
        XCTAssertEqual(first.engine(created.id)?.shortcut, "wk")
        XCTAssertEqual(first.engine(created.id)?.urlTemplate, "https://en.wikipedia.org/w/index.php?search=%s", "Updating one field must not clear the others.")

        let amazonID = try XCTUnwrap(first.engines.first { $0.name == "Amazon" }?.id)
        first.deleteEngine(amazonID)
        XCTAssertNil(first.engine(amazonID))

        try first.saveNow()

        let second = SiteSearchStore(fileURL: url)
        XCTAssertEqual(second.engines.map(\.name), ["Twitter", "YouTube", "Wikipedia (EN)"])
        XCTAssertEqual(second.engine(created.id)?.shortcut, "wk")
        XCTAssertEqual(second.engine(created.id)?.urlTemplate, "https://en.wikipedia.org/w/index.php?search=%s")
        XCTAssertNil(second.engine(amazonID), "A deleted engine must stay deleted across a reload.")
    }

    func test_createEngine_trimsWhitespaceSoAShortcutStillMatchesWhatIsTyped() throws {
        let store = SiteSearchStore(fileURL: scratchFileURL())
        let created = store.createEngine(name: "  Hacker News  ", shortcut: " hn ", urlTemplate: " https://hn.algolia.com/?q=%s ")
        XCTAssertEqual(created.name, "Hacker News")
        XCTAssertEqual(created.shortcut, "hn")
        XCTAssertEqual(created.urlTemplate, "https://hn.algolia.com/?q=%s")
        XCTAssertEqual(
            SiteSearchMatcher.engine(forShortcut: "hn", in: store.engines)?.id, created.id,
            "A shortcut saved with stray whitespace must still resolve from what the user actually types."
        )
    }

    // MARK: - 8. The trigger-key setting persists

    func test_triggerKey_persistsAndReadsBack() throws {
        let url = scratchFileURL()
        let first = SiteSearchStore(fileURL: url)
        XCTAssertEqual(first.triggerKey, .tab)

        first.setTriggerKey(.spaceOrTab)
        XCTAssertEqual(first.triggerKey, .spaceOrTab)
        try first.saveNow()

        let second = SiteSearchStore(fileURL: url)
        XCTAssertEqual(second.triggerKey, .spaceOrTab, "The trigger-key setting must survive a relaunch.")
        XCTAssertTrue(second.state().triggerKey.acceptsSpace, "…and must still be honoured by the state the Command Bar reads.")

        second.setTriggerKey(.tab)
        try second.saveNow()
        XCTAssertEqual(SiteSearchStore(fileURL: url).triggerKey, .tab)
    }

    // MARK: - The state handed to the Command Bar

    func test_state_carriesTheStoredEnginesAndTheScopedOne() {
        let store = SiteSearchStore(fileURL: scratchFileURL())
        let youtube = store.engines.first { $0.name == "YouTube" }

        let unscoped = store.state()
        XCTAssertEqual(unscoped.engines.map(\.id), store.engines.map(\.id))
        XCTAssertNil(unscoped.active)
        XCTAssertEqual(unscoped.armedEngine(forTypedQuery: "yt")?.id, youtube?.id)

        let scoped = store.state(active: youtube)
        XCTAssertEqual(scoped.active?.id, youtube?.id)
        XCTAssertNil(scoped.armedEngine(forTypedQuery: "tw"), "Nothing arms the hint while the chip is already showing.")
    }

    // MARK: - The environment really owns one

    func test_appEnvironment_exposesASiteSearchStore() {
        let env = AppEnvironment.demo
        XCTAssertEqual(env.siteSearchStore.engines.count, 3, "A fresh environment must come up with the three seeded defaults available to the Command Bar.")
    }
}
