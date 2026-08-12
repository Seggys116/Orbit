// Regression: Incognito used to persist a permanent Profile/Space every Cmd+Shift+N.
// Assertions go through a real saveNow + reload, not in-memory (filtering hides a row
// without stopping the write). Exercises BrowserStore directly: this bundle is host-less.

import XCTest

@MainActor
final class IncognitoEphemeralStateTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-Incognito-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStateStore() -> StateStore {
        StateStore(rootDirectory: scratchDirectory)
    }

    // MARK: - Reproducing `openIncognitoWindow()`

    private static var incognitoTheme: SpaceTheme {
        SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.13)],
            grain: 0.4,
            prefersDarkContent: true
        )
    }

    @discardableResult
    private func openIncognitoSession(on store: BrowserStore) -> (profileID: ProfileID, spaceID: SpaceID) {
        let profile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        store.state.profiles.append(profile)
        let spaceID = store.createSpace(
            name: "Incognito",
            icon: "eyeglasses",
            iconIsEmoji: false,
            theme: Self.incognitoTheme,
            profileID: profile.id
        )
        return (profile.id, spaceID)
    }

    // MARK: - The load-bearing test

    func test_incognitoSession_addsNoProfileAndNoSpaceToThePersistedDocument() throws {
        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        let profilesBefore = store.state.profiles.map(\.id)
        let spacesBefore = store.state.spaces.map(\.id)
        XCTAssertEqual(profilesBefore.count, 1, "bootstrap should seed exactly one Profile")
        XCTAssertEqual(spacesBefore.count, 1, "bootstrap should seed exactly one Space")

        openIncognitoSession(on: store)

        XCTAssertEqual(store.state.profiles.count, 2, "the live session needs its Profile in memory")
        XCTAssertEqual(store.state.spaces.count, 2, "the live session needs its Space in memory")

        try store.saveNow()
        let reloaded = try makeStateStore().load()

        XCTAssertEqual(
            reloaded.profiles.map(\.id), profilesBefore,
            """
            The saved document gained a Profile from an Incognito window. \
            refs/ARC_SPEC.md defines Incognito as a window mode, not a saved \
            entity — every Cmd+Shift+N used to deposit one of these in \
            state.json permanently.
            """
        )
        XCTAssertEqual(
            reloaded.spaces.map(\.id), spacesBefore,
            """
            The saved document gained a Space from an Incognito window. Same \
            defect as the Profile above: the user accumulates one junk Space \
            per Cmd+Shift+N, restored on every launch, forever.
            """
        )
        XCTAssertFalse(
            reloaded.profiles.contains { !$0.isPersistent },
            "No non-persistent Profile may ever appear in a document read back off disk."
        )
    }

    func test_incognitoTabs_areNotPersisted() throws {
        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        let tabsBefore = store.state.tabs.count

        let session = openIncognitoSession(on: store)
        store.openTab(url: URL(string: "https://private.example.com/secret")!, in: session.spaceID)
        XCTAssertEqual(store.state.tabs.count, tabsBefore + 1, "the tab must exist in memory for the window to show it")

        try store.saveNow()
        let reloaded = try makeStateStore().load()

        XCTAssertEqual(reloaded.tabs.count, tabsBefore, "an Incognito tab was written to disk")
        XCTAssertFalse(
            reloaded.tabs.values.contains { $0.url.absoluteString.contains("private.example.com") },
            "the URL visited in an Incognito window was written to state.json"
        )
    }

    func test_activeSpaceID_fallsBackToARealSpaceWhenTheIncognitoSpaceIsStripped() throws {
        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        let realSpaceID = try XCTUnwrap(store.state.spaces.first?.id)

        let session = openIncognitoSession(on: store)
        XCTAssertEqual(store.state.activeSpaceID, session.spaceID, "createSpace(activate:) should have switched to it")

        try store.saveNow()
        let reloaded = try makeStateStore().load()

        XCTAssertEqual(
            reloaded.activeSpaceID, realSpaceID,
            "the saved activeSpaceID must resolve to a Space that is actually in the saved document"
        )
    }

    // MARK: - The migration: users who already have junk on disk

    // Writes document straight to state.json, bypassing StateStore.saveNow
    // entirely: saveNow now strips ephemeral entities, so it cannot be used
    // to seed a state file containing them.
    private func writeRawStateFile(_ document: OrbitState, to store: StateStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        try encoder.encode(document).write(to: store.stateFileURL, options: .atomic)
    }

    private func documentWithIncognitoResidue(incognitoCount: Int) -> OrbitState {
        var document = OrbitState()
        let personal = Profile(name: "Personal")
        document.profiles = [personal]
        let realSpace = Space(name: "Personal", icon: "circle.grid.2x2", profileID: personal.id, order: 0)
        document.spaces = [realSpace]
        document.activeSpaceID = realSpace.id

        for index in 0..<incognitoCount {
            let profile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
            document.profiles.append(profile)
            let space = Space(
                name: "Incognito",
                icon: "eyeglasses",
                iconIsEmoji: false,
                theme: Self.incognitoTheme,
                profileID: profile.id,
                order: index + 1
            )
            document.spaces.append(space)
            document.activeSpaceID = space.id
        }
        return document
    }

    func test_existingIncognitoResidue_isRemovedOnLoad() throws {
        let seedStore = makeStateStore()
        try writeRawStateFile(documentWithIncognitoResidue(incognitoCount: 3), to: seedStore)

        let onDiskBefore = try makeStateStore().load()
        XCTAssertEqual(onDiskBefore.profiles.count, 4)
        XCTAssertEqual(onDiskBefore.spaces.count, 4)

        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)

        XCTAssertEqual(
            store.state.profiles.count, 1,
            """
            Three previous Cmd+Shift+N presses left three Profiles in this \
            user's state.json and loading it kept them. Fixing only the code \
            that creates them is the exact non-fix RetiredSpaceIconMigrationTests \
            documents for the sparkles icon: it helps nobody who already has \
            the junk.
            """
        )
        XCTAssertEqual(store.state.spaces.count, 1, "the three junk Incognito Spaces survived the load")
        XCTAssertEqual(store.state.spaces.first?.name, "Personal", "the user's real Space must be the one that survived")
        XCTAssertEqual(
            store.state.activeSpaceID, store.state.spaces.first?.id,
            "activeSpaceID pointed at a removed Space and was not repaired"
        )
    }

    func test_removedResidue_staysRemovedOnDisk() throws {
        try writeRawStateFile(documentWithIncognitoResidue(incognitoCount: 2), to: makeStateStore())

        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        try store.saveNow()

        let reloaded = try makeStateStore().load()
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.spaces.count, 1)
        XCTAssertFalse(reloaded.profiles.contains { !$0.isPersistent })
    }

    // MARK: - What the cleanup must NOT touch

    func test_aRealSpaceSittingOnTheIncognitoProfile_isReassignedNotDeleted() throws {
        var document = documentWithIncognitoResidue(incognitoCount: 1)
        let incognitoProfileID = try XCTUnwrap(document.profiles.first { !$0.isPersistent }?.id)
        let personalProfileID = try XCTUnwrap(document.profiles.first { $0.isPersistent }?.id)
        let precious = Space(
            name: "Thesis",
            icon: "book",
            iconIsEmoji: false,
            profileID: incognitoProfileID,
            order: 9
        )
        document.spaces.append(precious)
        try writeRawStateFile(document, to: makeStateStore())

        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)

        let survivor = store.state.spaces.first { $0.name == "Thesis" }
        XCTAssertNotNil(
            survivor,
            """
            A Space named by the user, sitting on the Incognito Profile, was \
            deleted by the Incognito cleanup. Deleting someone's real Space is \
            far worse than leaving junk behind — only entities positively \
            identifiable as Incognito-created may ever be removed.
            """
        )
        XCTAssertEqual(
            survivor?.profileID, personalProfileID,
            "the surviving Space must be reassigned to a real Profile, not left pointing at a removed one"
        )
        XCTAssertEqual(store.state.spaces.filter { $0.name == "Incognito" }.count, 0)
    }

    func test_aRenamedIncognitoSpace_isKept() throws {
        var document = documentWithIncognitoResidue(incognitoCount: 1)
        let index = try XCTUnwrap(document.spaces.firstIndex { $0.name == "Incognito" })
        document.spaces[index].name = "Job hunting"
        try writeRawStateFile(document, to: makeStateStore())

        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)

        XCTAssertTrue(
            store.state.spaces.contains { $0.name == "Job hunting" },
            "a renamed Space is ambiguous, and ambiguous means keep"
        )
    }

    func test_aUserCreatedProfileNamedIncognito_isLeftAlone() throws {
        var document = OrbitState()
        let personal = Profile(name: "Personal")
        let lookalike = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: true)
        document.profiles = [personal, lookalike]
        let realSpace = Space(name: "Personal", profileID: personal.id, order: 0)
        let lookalikeSpace = Space(name: "Incognito", icon: "eyeglasses", profileID: lookalike.id, order: 1)
        document.spaces = [realSpace, lookalikeSpace]
        document.activeSpaceID = realSpace.id
        try writeRawStateFile(document, to: makeStateStore())

        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)

        XCTAssertEqual(store.state.profiles.count, 2, "a persistent Profile must never be removed, whatever it is called")
        XCTAssertEqual(store.state.spaces.count, 2)
        XCTAssertEqual(store.state.spaces.map(\.profileID).sorted(by: { $0.uuidString < $1.uuidString }),
                       [personal.id, lookalike.id].sorted(by: { $0.uuidString < $1.uuidString }))
    }

    func test_documentWithoutResidue_isUnchanged() throws {
        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        let before = store.state
        try store.saveNow()

        let secondLaunch = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        XCTAssertEqual(secondLaunch.state.profiles.map(\.id), before.profiles.map(\.id))
        XCTAssertEqual(secondLaunch.state.spaces.map(\.id), before.spaces.map(\.id))
        XCTAssertEqual(secondLaunch.state.activeSpaceID, before.activeSpaceID)
    }

    // MARK: - The marker itself

    func test_createSpace_marksASpaceOnANonPersistentProfileAsEphemeral() {
        let store = BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
        let session = openIncognitoSession(on: store)

        XCTAssertTrue(
            store.space(session.spaceID)?.isEphemeral == true,
            "a Space created against a non-persistent Profile must be marked ephemeral at creation time"
        )
        XCTAssertFalse(
            store.state.spaces.first { $0.id != session.spaceID }?.isEphemeral ?? true,
            "an ordinary Space must never be marked ephemeral"
        )
    }
}
