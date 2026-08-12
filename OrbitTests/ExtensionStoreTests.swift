import XCTest

@MainActor
final class ExtensionStoreTests: XCTestCase {

    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionStoreRoot-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(root)
        return root
    }

    @discardableResult
    private func makeSourceExtension(
        name: String = "Fixture Extension",
        version: String = "1.0",
        extraFiles: [String: String] = [:],
        manifestKey: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)

        var manifest: [String: Any] = ["name": name, "version": version, "manifest_version": 3]
        if let manifestKey {
            manifest["key"] = manifestKey
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        try data.write(to: directory.appendingPathComponent("manifest.json"))

        for (fileName, contents) in extraFiles {
            try contents.data(using: .utf8)!.write(to: directory.appendingPathComponent(fileName))
        }
        return directory
    }

    private let fixedPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    // MARK: - Install

    func test_installCopiesTheTreeAndRecordsIt() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension(name: "Copy Test", version: "1.2.3", extraFiles: ["content.js": "console.log(1)"])

        let loaded = try store.install(unpackedAt: source, publicKey: nil)

        XCTAssertEqual(loaded.name, "Copy Test")
        XCTAssertEqual(loaded.version, "1.2.3")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: loaded.directory.appendingPathComponent("manifest.json").path),
            "The copied manifest.json is missing from the install destination."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: loaded.directory.appendingPathComponent("content.js").path),
            "A real file from the source extension did not make it into the copy."
        )
        XCTAssertEqual(store.installed().map(\.id), [loaded.id])
    }

    func test_reinstallingTheSameID_replacesRatherThanMerges() throws {
        let store = ExtensionStore(root: makeRoot())

        let sourceV1 = try makeSourceExtension(name: "Versioned", version: "1.0", extraFiles: ["old-only.txt": "v1"])
        let first = try store.install(unpackedAt: sourceV1, publicKey: fixedPublicKey)

        let sourceV2 = try makeSourceExtension(name: "Versioned", version: "2.0", extraFiles: ["new-only.txt": "v2"])
        let second = try store.install(unpackedAt: sourceV2, publicKey: fixedPublicKey)

        XCTAssertEqual(first.id, second.id, "The same public key must derive the same id regardless of the source path.")
        XCTAssertEqual(store.installed().count, 1, "A reinstall must replace the existing record, not add a second one.")
        XCTAssertEqual(store.installed().first?.version, "2.0")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: second.directory.appendingPathComponent("old-only.txt").path),
            "A file the extension shipped in v1 and no longer ships in v2 survived the reinstall — that is a merge, not a replace."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.appendingPathComponent("new-only.txt").path))
    }

    // MARK: - Id derivation precedence: argument, then manifest `key`, then path

    func test_manifestKeyIsUsedForTheID_whenNoPublicKeyArgumentIsGiven() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension(manifestKey: fixedPublicKey)
        let expectedID = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: fixedPublicKey))

        let loaded = try store.install(unpackedAt: source, publicKey: nil)

        XCTAssertEqual(
            loaded.id, expectedID,
            "install ignored the `key` in the source's own manifest.json and derived a path-based id. Chromium reads the copied manifest's key and would run this extension under \(expectedID), so the store would be recording an id nothing is running under."
        )
        XCTAssertEqual(
            loaded.directory.lastPathComponent, expectedID,
            "The install directory name must BE the id — that is what markActivated(ids:) reads back via lastPathComponent."
        )
    }

    func test_sameManifestKeyFromTwoDifferentSourcePaths_yieldsTheSameID() throws {
        let store = ExtensionStore(root: makeRoot())
        let first = try store.install(unpackedAt: try makeSourceExtension(manifestKey: fixedPublicKey), publicKey: nil)
        let second = try store.install(unpackedAt: try makeSourceExtension(manifestKey: fixedPublicKey), publicKey: nil)

        XCTAssertEqual(first.id, second.id, "A keyed extension's id must not depend on the source path it was imported from.")
        XCTAssertEqual(store.installed().count, 1, "Two installs of the same keyed extension must be one record, not two.")
    }

    func test_publicKeyArgumentWinsOverADifferingManifestKey() throws {
        let store = ExtensionStore(root: makeRoot())
        let argumentKey = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
        let source = try makeSourceExtension(manifestKey: fixedPublicKey)

        let expectedFromArgument = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: argumentKey))
        let idFromManifest = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: fixedPublicKey))
        XCTAssertNotEqual(expectedFromArgument, idFromManifest, "Fixture sanity: the two keys must derive different ids for this test to mean anything.")

        let loaded = try store.install(unpackedAt: source, publicKey: argumentKey)

        XCTAssertEqual(loaded.id, expectedFromArgument, "The explicit publicKey argument must take precedence over the manifest's own key.")
    }

    func test_keylessExtension_fallsBackToAPathDerivedID_andIsFlaggedAsSuch() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension()

        let loaded = try store.install(unpackedAt: source, publicKey: nil)

        // Chromium hashes the path it loads from -- this store's copy, not the source
        // it was imported from -- so this asserts the destination's id.
        XCTAssertEqual(
            loaded.id, ChromeExtensionID.id(forUnpackedPath: loaded.directory),
            "With no key available from either source, the id must be the one Chromium derives from the install directory the extension is loaded out of."
        )
        XCTAssertNotEqual(
            loaded.id, ChromeExtensionID.id(forUnpackedPath: source),
            "Deriving it from the import source instead would record an id nothing is running under."
        )
        XCTAssertTrue(ChromeExtensionID.isValid(loaded.id))
    }

    // MARK: - Remove / setEnabled on an unknown id

    func test_removeUnknownID_throwsNotInstalled() {
        let store = ExtensionStore(root: makeRoot())
        let unknownID = "abcdefghijklmnopabcdefghijklmnop"

        XCTAssertThrowsError(try store.remove(id: unknownID)) { error in
            XCTAssertEqual(error as? ExtensionStoreError, .notInstalled(unknownID))
        }
    }

    func test_setEnabledUnknownID_throwsNotInstalled() {
        let store = ExtensionStore(root: makeRoot())
        let unknownID = "abcdefghijklmnopabcdefghijklmnop"

        XCTAssertThrowsError(try store.setEnabled(false, id: unknownID)) { error in
            XCTAssertEqual(error as? ExtensionStoreError, .notInstalled(unknownID))
        }
    }

    // MARK: - Disabled extensions

    func test_disabledExtension_staysInInstalled_butIsAbsentFromEnabledDirectories() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension()
        let loaded = try store.install(unpackedAt: source, publicKey: nil)

        try store.setEnabled(false, id: loaded.id)

        XCTAssertEqual(store.installed().count, 1, "Disabling must not remove the record from installed().")
        XCTAssertEqual(store.installed().first?.isEnabled, false)
        XCTAssertTrue(store.enabledDirectories().isEmpty, "A disabled extension must not appear in enabledDirectories().")
    }

    // MARK: - Persistence

    func test_installedJSONRoundTripsAcrossAFreshStoreOnTheSameDirectory() throws {
        let root = makeRoot()
        let store1 = ExtensionStore(root: root)
        let source = try makeSourceExtension(name: "Round Trip", version: "9.9")
        let loaded = try store1.install(unpackedAt: source, publicKey: nil)

        let store2 = ExtensionStore(root: root)
        let reloaded = store2.installed()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, loaded.id)
        XCTAssertEqual(reloaded.first?.name, "Round Trip")
        XCTAssertEqual(reloaded.first?.version, "9.9")
        XCTAssertEqual(reloaded.first?.isEnabled, true)
    }

    func test_recordWhoseDirectoryHasVanished_isPrunedOnReload() throws {
        let root = makeRoot()
        let store1 = ExtensionStore(root: root)
        let source = try makeSourceExtension()
        let loaded = try store1.install(unpackedAt: source, publicKey: nil)

        try FileManager.default.removeItem(at: loaded.directory)

        let store2 = ExtensionStore(root: root)
        XCTAssertTrue(
            store2.installed().isEmpty,
            "A record whose copied directory no longer exists must be dropped on reload, not kept around as a dangling entry."
        )
    }

    // MARK: - Restart semantics: hasPendingChanges

    func test_hasPendingChanges_isFalseBeforeMarkActivatedHasEverBeenCalled() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension()
        _ = try store.install(unpackedAt: source, publicKey: nil)

        XCTAssertFalse(store.hasPendingChanges)
    }

    func test_hasPendingChanges_isFalseImmediatelyAfterMarkActivatedWithTheCurrentEnabledSet() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension()
        let loaded = try store.install(unpackedAt: source, publicKey: nil)

        store.markActivated(ids: [loaded.id])

        XCTAssertFalse(store.hasPendingChanges)
    }

    func test_hasPendingChanges_isTrueAfterAnyChangeToTheEnabledSet_andFalseAgainOnceItMatchesTheActivatedSetOnceMore() throws {
        let store = ExtensionStore(root: makeRoot())
        let source = try makeSourceExtension()
        let loaded = try store.install(unpackedAt: source, publicKey: nil)
        store.markActivated(ids: [loaded.id])
        XCTAssertFalse(store.hasPendingChanges, "Sanity check on the fixture before the real assertions below.")

        try store.setEnabled(false, id: loaded.id)
        XCTAssertTrue(store.hasPendingChanges, "Disabling an activated extension changed the enabled set and must be flagged as pending a restart.")

        try store.setEnabled(true, id: loaded.id)
        XCTAssertFalse(store.hasPendingChanges, "Re-enabling back to exactly the activated set must clear the pending flag.")

        let secondSource = try makeSourceExtension(name: "Second Extension", version: "1.0")
        _ = try store.install(unpackedAt: secondSource, publicKey: nil)
        XCTAssertTrue(store.hasPendingChanges, "Installing a new, enabled extension changed the enabled set and must be flagged as pending.")
    }
}
