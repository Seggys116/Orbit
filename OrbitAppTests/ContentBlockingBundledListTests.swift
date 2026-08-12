import XCTest
@testable import Orbit

// Hosted by Orbit.app, so Bundle.main here is the shipping app bundle: this is
// what proves the list is actually in Copy Bundle Resources.
@MainActor
final class ContentBlockingBundledListTests: XCTestCase {

    private func unbreakDescriptor() throws -> FilterListDescriptor {
        try XCTUnwrap(FilterListCatalog.descriptor(id: FilterListCatalog.orbitUnbreakID))
    }

    func testTheUnbreakListIsCopiedIntoTheAppBundle() throws {
        let resource = try XCTUnwrap(unbreakDescriptor().bundledResource)
        let url = Bundle.main.url(forResource: resource.name, withExtension: resource.fileExtension)
        XCTAssertNotNil(
            url,
            "\(resource.name).\(resource.fileExtension) is not in \(Bundle.main.bundlePath)'s resources"
        )
    }

    func testTheBundledTextIsReadableAndCarriesTheLinearException() throws {
        let text = try XCTUnwrap(FilterListCatalog.bundledText(for: unbreakDescriptor()))
        XCTAssertTrue(text.contains("! Title: Orbit Unbreak"))
        XCTAssertTrue(text.contains("@@||linear.app/statsig-proxy/$first-party"))
    }

    func testTheStoreServesTheBundledListWithoutFetchingAndWithoutGoingStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentBlockingBundledListTests.\(UUID().uuidString)", isDirectory: true)
        // A year on, a fetched list would be long stale; a bundled one cannot be.
        let store = FilterListStore(
            directory: directory,
            now: { Date().addingTimeInterval(365 * 24 * 60 * 60) }
        )
        let descriptor = try unbreakDescriptor()

        for state in [await store.state(of: descriptor.id), await store.update(descriptor, force: true)] {
            guard case .cached(let entry) = state else {
                return XCTFail("expected .cached for the bundled list, got \(state)")
            }
            XCTAssertTrue(entry.sourceURLs.isEmpty)
            XCTAssertFalse(entry.contentHash.isEmpty)
            XCTAssertEqual(entry.declaredTitle, "Orbit Unbreak")
        }

        let cachedText = await store.cachedText(for: descriptor.id)
        let text = try XCTUnwrap(cachedText)
        XCTAssertTrue(text.contains("@@||linear.app/statsig-proxy/$first-party"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "a bundled list must not write anything into the fetched-list cache directory")
    }

    // loadFromCache never fetches, and an empty cache directory has nothing for
    // the remote lists: whatever compiles here came out of the app bundle.
    func testTheListCompilesOnAColdCacheWithNoNetworkFetch() async throws {
        let suite = "ContentBlockingBundledListTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let controller = ContentBlockingController(
            store: FilterListStore(directory: directory),
            defaults: defaults
        )
        XCTAssertTrue(controller.enabledListIDs.contains(FilterListCatalog.orbitUnbreakID),
                      "the unbreak list must be on for a fresh install")

        await controller.loadFromCache()

        XCTAssertEqual(controller.compiledRuleCount, 1)
        XCTAssertEqual(controller.compileStats.exceptionRules, 1)
        XCTAssertEqual(controller.compileStats.blockingRules, 0)
        guard case .cached = controller.listStates[FilterListCatalog.orbitUnbreakID] else {
            return XCTFail("expected .cached, got \(String(describing: controller.listStates[FilterListCatalog.orbitUnbreakID]))")
        }
    }
}
