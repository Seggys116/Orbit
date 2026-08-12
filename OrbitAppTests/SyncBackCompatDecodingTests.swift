//  Regression guard: a Tab field once encoded with encodeIfPresent but decoded with a
//  strict decode made every existing document unreadable on reload.

import XCTest

@testable import Orbit

@MainActor
final class SyncBackCompatDecodingTests: XCTestCase {

    private static let optionalKeysSyncDependsOn = ["isPersistent", "ephemeral"]

    // Hand-written rather than derived from the type, or the check below would be tautological.
    private static let expectedTopLevelKeys: Set<String> = [
        "schemaVersion", "profiles", "spaces", "tabs", "splitGroups",
        "boosts", "easels", "notes", "routingRules", "activeSpaceID", "activeTabBySpace",
    ]

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-SyncBackCompat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        scratch = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeDocument() -> (document: OrbitState, profile: Profile, space: Space, tab: Tab) {
        let profile = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var space = Space(name: "Work", profileID: profile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let tab = Tab(
            spaceID: space.id, section: .pinned,
            url: URL(string: "https://swift.org")!, title: "Swift.org",
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_200),
            createdAt: Date(timeIntervalSince1970: 1_700_000_150)
        )
        space.pinned = [.tab(tab.id)]

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.activeSpaceID = space.id
        return (document, profile, space, tab)
    }

    // MARK: - 1. The schema was not widened

    func testPersistedDocumentHasExactlyTheKeysItHadBeforeICloudSyncExisted() throws {
        let store = StateStore(rootDirectory: scratch, maxBackups: 1)
        let fixture = makeDocument()
        _ = try store.saveNow(fixture.document)

        let raw = try Self.readJSONObject(at: store.stateFileURL)
        let keys = Set(raw.keys)

        XCTAssertEqual(
            keys, Self.expectedTopLevelKeys,
            """
            The persisted document's top-level keys changed. Unexpected: \
            \(keys.subtracting(Self.expectedTopLevelKeys).sorted()); missing: \
            \(Self.expectedTopLevelKeys.subtracting(keys).sorted()). If a field was \
            genuinely added to OrbitState, it must be Optional (or have a hand-written \
            `init(from:)` in the shape of `SplitGroup.init(from:)`) so an existing \
            state.json still decodes, and a strip-and-reload test has to prove it.
            """
        )
    }

    // MARK: - 2. A document written before these keys existed still loads, and syncs

    func testADocumentWithoutIsPersistentOrEphemeralReloadsAndIsTreatedAsFullySyncable() throws {
        let store = StateStore(rootDirectory: scratch, maxBackups: 1)
        let fixture = makeDocument()
        _ = try store.saveNow(fixture.document)

        let before = try Self.readJSONObject(at: store.stateFileURL)
        XCTAssertTrue(
            Self.containsAnyKey(Self.optionalKeysSyncDependsOn, in: before),
            "None of \(Self.optionalKeysSyncDependsOn) was written at all, so removing them is a no-op and this test is vacuous."
        )

        try Self.stripKeys(Self.optionalKeysSyncDependsOn, fromFileAt: store.stateFileURL)

        let after = try Self.readJSONObject(at: store.stateFileURL)
        XCTAssertFalse(
            Self.containsAnyKey(Self.optionalKeysSyncDependsOn, in: after),
            "The strip did not take — \(Self.optionalKeysSyncDependsOn) is still in the file, so the reload below is testing the current shape, not the legacy one."
        )

        let reloaded = try store.load()

        let profile = try XCTUnwrap(
            reloaded.profiles.first(where: { $0.id == fixture.profile.id }),
            "A state.json written before `isPersistent` existed no longer decodes — every user's Profiles would be lost."
        )
        XCTAssertTrue(
            profile.isPersistent,
            "A Profile from a document that predates `isPersistent` decoded as non-persistent, so the sync layer would silently refuse to sync any of the user's real data."
        )

        let space = try XCTUnwrap(reloaded.spaces.first(where: { $0.id == fixture.space.id }))
        XCTAssertFalse(
            space.isEphemeral,
            "A Space from a document that predates `ephemeral` decoded as ephemeral, so it would never sync."
        )

        let names = CloudSyncEngine.syncableRecordNames(in: reloaded)
        XCTAssertTrue(names.contains(fixture.profile.id.uuidString), "The legacy Profile is not syncable after reload.")
        XCTAssertTrue(names.contains(fixture.space.id.uuidString), "The legacy Space is not syncable after reload.")
        XCTAssertTrue(names.contains(fixture.tab.id.uuidString), "The legacy pinned Tab is not syncable after reload.")
    }

    // MARK: - 3. A real user's accumulated Incognito residue reloads — and is excluded

    func testAccumulatedIncognitoResidueInAnExistingDocumentIsNeverSyncable() throws {
        let store = StateStore(rootDirectory: scratch, maxBackups: 1)
        let fixture = makeDocument()

        let residueProfile = Profile(
            name: "Incognito", isPersistent: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        var residueSpace = Space(
            name: "Incognito", icon: "eyeglasses", iconIsEmoji: false,
            profileID: residueProfile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_510)
        )
        let residueTab = Tab(
            spaceID: residueSpace.id, section: .today,
            url: URL(string: "https://example.com/a-private-page")!, title: "Private",
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_600),
            createdAt: Date(timeIntervalSince1970: 1_700_000_550)
        )
        residueSpace.today = [residueTab.id]

        var document = fixture.document
        document.profiles.append(residueProfile)
        document.spaces.append(residueSpace)
        document.tabs[residueTab.id] = residueTab

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: store.stateFileURL, options: .atomic)

        let raw = try Self.readJSONObject(at: store.stateFileURL)
        let profileDicts = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        XCTAssertTrue(
            profileDicts.contains { ($0["isPersistent"] as? Bool) == false },
            "The hand-written fixture does not actually contain a non-persistent Profile, so this test proves nothing."
        )

        let reloaded = try store.load()
        XCTAssertTrue(
            reloaded.profiles.contains(where: { $0.id == residueProfile.id }),
            "The premise is gone: StateStore.load() no longer returns the Incognito residue this test is about."
        )

        let names = CloudSyncEngine.syncableRecordNames(in: reloaded)
        XCTAssertFalse(
            names.contains(residueProfile.id.uuidString),
            "PRIVACY LEAK: an Incognito Profile sitting in an existing user's state.json would be pushed to iCloud."
        )
        XCTAssertFalse(
            names.contains(residueSpace.id.uuidString),
            "PRIVACY LEAK: an Incognito Space sitting in an existing user's state.json would be pushed to iCloud."
        )
        XCTAssertFalse(
            names.contains(residueTab.id.uuidString),
            "PRIVACY LEAK: a page browsed in an Incognito window would be pushed to iCloud."
        )
        XCTAssertTrue(
            names.contains(fixture.space.id.uuidString),
            "The user's real Space stopped being syncable, so the filter is simply refusing everything."
        )
    }

    // MARK: - JSON helpers

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "state.json's top level is not a JSON object.")
    }

    private static func containsAnyKey(_ keys: [String], in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            if keys.contains(where: { dictionary[$0] != nil }) { return true }
            return dictionary.values.contains { containsAnyKey(keys, in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsAnyKey(keys, in: $0) }
        }
        return false
    }

    private static func stripKeys(_ keys: [String], fromFileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let stripped = strippingKeys(keys, from: object)
        let rewritten = try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
        try rewritten.write(to: url, options: .atomic)
    }

    private static func strippingKeys(_ keys: [String], from object: Any) -> Any {
        if var dictionary = object as? [String: Any] {
            for key in keys { dictionary.removeValue(forKey: key) }
            for (key, value) in dictionary {
                dictionary[key] = strippingKeys(keys, from: value)
            }
            return dictionary
        }
        if let array = object as? [Any] {
            return array.map { strippingKeys(keys, from: $0) }
        }
        return object
    }
}
