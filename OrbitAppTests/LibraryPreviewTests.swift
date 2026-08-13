import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class LibraryPreviewTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LibraryPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        LibraryRouter.shared.selectedSection = .downloads
        LibraryRouter.shared.selection = nil
    }

    override func tearDown() {
        LibraryRouter.shared.selectedSection = .downloads
        LibraryRouter.shared.selection = nil
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Downloads

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testCompletedDownloadResolvesToItsRealFileAndAMissingFileResolvesToNothing

    func testCompletedDownloadResolvesToItsRealFileAndAMissingFileResolvesToNothing() throws {
        let fileURL = scratchDirectory.appendingPathComponent("orbit-preview-fixture.txt")
        try "Real bytes, written by this test.".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "test precondition: fixture file was not written")

        let present = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/orbit-preview-fixture.txt")!,
            destinationURL: fileURL,
            suggestedFileName: "orbit-preview-fixture.txt"
        )
        env.downloadStore.updateProgress(id: present.id, progress: DownloadProgress(receivedBytes: 33, totalBytes: 33, state: .completed))

        let resolvedPresent = LibraryPreviewContent.resolve(.download(present.id), env: env)
        XCTAssertEqual(
            resolvedPresent,
            .file(fileURL),
            "Selecting a completed download whose file is on disk must preview that exact file, so QuickLook renders the real download."
        )

        let neverWritten = scratchDirectory
            .appendingPathComponent("directory-that-was-never-created", isDirectory: true)
            .appendingPathComponent("ghost.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverWritten.path), "test precondition: this path must not exist")

        let missing = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/ghost.txt")!,
            destinationURL: neverWritten,
            suggestedFileName: "ghost.txt"
        )
        env.downloadStore.updateProgress(id: missing.id, progress: DownloadProgress(receivedBytes: 10, totalBytes: 10, state: .completed))

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.download(missing.id), env: env),
            LibraryPreviewContent.none,
            "A download whose file is not on disk has nothing to preview and must resolve to nothing drawn."
        )
    }

    // MARK: - Archived tabs

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testArchivedTabResolvesToALiveWebPreviewOfItsRealURL

    func testArchivedTabResolvesToALiveWebPreviewOfItsRealURL() throws {
        let spaceID = try XCTUnwrap(env.activeSpace?.id ?? env.spaces.first?.id, "demo environment has no space to open a tab in")
        let url = URL(string: "https://news.ycombinator.com/item?id=42")!

        let tabID = env.openTab(url: url, in: spaceID, section: .today)
        env.archiveTab(tabID)
        XCTAssertTrue(
            env.archivedTabs().contains(where: { $0.id == tabID }),
            "test precondition: the tab was not actually archived"
        )

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.archivedTab(tabID), env: env),
            .liveWeb(url),
            "Selecting an archived tab must preview a live web view of that tab's real URL."
        )

        env.restoreFromArchive(tabID, section: .today)
        XCTAssertEqual(
            LibraryPreviewContent.resolve(.archivedTab(tabID), env: env),
            LibraryPreviewContent.none,
            "A tab restored out of the archive must no longer drive the Archived Tabs preview."
        )
    }

    // MARK: - Notes

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testNoteResolvesToItsRealDecodedBody

    func testNoteResolvesToItsRealDecodedBody() throws {
        let text = "Orbit Library preview — the real note body, not a summary of it."
        let note = env.noteStore.createNote(title: "Preview fixture")
        let encoded = try XCTUnwrap(NotesEditorView.encode(NSAttributedString(string: text)), "NotesEditorView.encode returned nil")
        env.noteStore.setBody(encoded, forNote: note.id)

        guard case .note(let resolved) = LibraryPreviewContent.resolve(.note(note.id), env: env) else {
            XCTFail("Selecting a note with a real body must resolve to the note case.")
            return
        }
        XCTAssertEqual(
            resolved.string,
            text,
            "The previewed note body must be the note's real text, decoded from what the editor persisted."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testNoteWithNoBodyResolvesToNothing

    func testNoteWithNoBodyResolvesToNothing() {
        let note = env.noteStore.createNote(title: "Empty fixture")

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.note(note.id), env: env),
            LibraryPreviewContent.none,
            "A note with an empty body must draw nothing rather than an empty framed pane."
        )
    }

    // MARK: - Easels

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testEaselResolvesToItsRealItems

    func testEaselResolvesToItsRealItems() throws {
        let easel = env.easelStore.createEasel(title: "Preview fixture")
        let items = [
            EaselItem(frame: CGRect(x: 0, y: 0, width: 200, height: 120), content: .text("First")),
            EaselItem(frame: CGRect(x: 240, y: 60, width: 180, height: 90), content: .text("Second")),
            EaselItem(frame: CGRect(x: 40, y: 200, width: 300, height: 140), content: .link(url: URL(string: "https://example.com")!, title: "Third")),
        ]
        env.easelStore.updateEasel(easel.id) { $0.items = items }

        guard case .easel(let resolved) = LibraryPreviewContent.resolve(.easel(easel.id), env: env) else {
            XCTFail("Selecting an easel with items must resolve to the easel case.")
            return
        }
        XCTAssertEqual(resolved.count, items.count, "The preview must carry every one of the easel's real items.")
        XCTAssertEqual(Set(resolved.map(\.id)), Set(items.map(\.id)), "The previewed items must be the easel's own items.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testEmptyEaselResolvesToNothing

    func testEmptyEaselResolvesToNothing() {
        let easel = env.easelStore.createEasel(title: "Empty fixture")

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.easel(easel.id), env: env),
            LibraryPreviewContent.none,
            "An easel with no items must draw nothing."
        )
    }

    // MARK: - Media

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testPlayingTabResolvesToItsRealMediaState

    func testPlayingTabResolvesToItsRealMediaState() throws {
        let spaceID = try XCTUnwrap(env.activeSpace?.id ?? env.spaces.first?.id)
        let tabID = env.openTab(url: URL(string: "https://music.example.com/album")!, in: spaceID, section: .today)
        let state = MediaState(
            isAudible: true,
            nowPlayingTitle: "A Real Track Title",
            nowPlayingArtist: "A Real Artist",
            isPlaying: true
        )
        env.mediaStates[tabID] = state

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.media(tabID), env: env),
            .media(tabID, state),
            "Selecting a playing tab must preview that tab with its real now-playing metadata."
        )

        env.mediaStates[tabID] = nil
        XCTAssertEqual(
            LibraryPreviewContent.resolve(.media(tabID), env: env),
            LibraryPreviewContent.none,
            "A tab that has stopped playing must no longer drive the Media preview."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTheMediaSectionListsAPausedTabAndDrawsNothingForATabWithNoMedia

    func testTheMediaSectionListsAPausedTabAndDrawsNothingForATabWithNoMedia() async throws {
        let spaceID = try XCTUnwrap(env.activeSpace?.id ?? env.spaces.first?.id)
        let tabID = env.openTab(url: URL(string: "https://music.example.com/album")!, in: spaceID, section: .today)

        env.mediaStates[tabID] = MediaState(
            hasVideo: true,
            hasActiveMediaSession: true,
            nowPlayingTitle: "A Real Track Title",
            nowPlayingArtist: "A Real Artist",
            isPlaying: false
        )
        let paused = await renderForScreenshot(
            LibraryMediaView(searchQuery: "").environment(env),
            size: CGSize(width: 520, height: 220)
        ).boundingBoxOfContent()
        XCTAssertNotNil(
            paused,
            "A paused tab drew nothing: the Library's Media section drops the tab you paused."
        )

        env.mediaStates[tabID] = MediaState()
        let stopped = await renderForScreenshot(
            LibraryMediaView(searchQuery: "").environment(env),
            size: CGSize(width: 521, height: 221)
        ).boundingBoxOfContent()
        XCTAssertNil(stopped, "Nothing is loaded in any tab, so the Media section must draw nothing at all.")
    }

    // MARK: - Boosts

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testBoostHostResolvesToALiveWebPreviewOfThatHost

    func testBoostHostResolvesToALiveWebPreviewOfThatHost() {
        let boost = env.boostStore.createBoost(name: "Avatar Twitter", host: "twitter.com")
        XCTAssertEqual(boost.host, "twitter.com", "test precondition")

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.boostHost("twitter.com"), env: env),
            .liveWeb(URL(string: "https://twitter.com")!),
            "Selecting a Boost host must preview that host live, so the Boost is visibly applied."
        )

        XCTAssertEqual(
            LibraryPreviewContent.resolve(.boostHost("no-boosts-here.example"), env: env),
            LibraryPreviewContent.none,
            "A host with no Boosts is not a row in this section and must not resolve to a preview."
        )
    }

    // MARK: - Live web session lifecycle

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testLiveWebSessionOpensExactlyOneTabAndClosesThePreviousOne

    func testLiveWebSessionOpensExactlyOneTabAndClosesThePreviousOne() {
        var opened: [URL] = []
        var closed: [TabID] = []
        var issued: [URL: TabID] = [:]

        let session = LibraryLiveWebSession(
            open: { url in
                opened.append(url)
                let id = TabID()
                issued[url] = id
                return id
            },
            close: { closed.append($0) }
        )

        let a = URL(string: "https://a.example.com")!
        let b = URL(string: "https://b.example.com")!

        session.show(a)
        XCTAssertEqual(opened, [a], "show(A) must open exactly one tab, for A.")
        XCTAssertEqual(closed, [], "show(A) must not close anything — nothing was open.")
        XCTAssertEqual(session.tabID, issued[a], "The session must hold the tab it just opened.")

        let tabForA = session.tabID

        session.show(a)
        XCTAssertEqual(opened, [a], "Re-selecting the same row must not open a second tab.")
        XCTAssertEqual(closed, [], "Re-selecting the same row must not tear down the web view it is already showing.")
        XCTAssertEqual(session.tabID, tabForA, "Re-selecting the same row must keep the same tab.")

        session.show(b)
        XCTAssertEqual(opened, [a, b], "show(B) must open a tab for B.")
        XCTAssertEqual(closed, [tabForA], "show(B) must close A's tab before opening B's.")
        XCTAssertEqual(session.tabID, issued[b], "The session must now hold B's tab.")

        let tabForB = session.tabID

        session.show(nil)
        XCTAssertEqual(opened, [a, b], "show(nil) must not open anything.")
        XCTAssertEqual(closed, [tabForA, tabForB], "show(nil) must close B's tab.")
        XCTAssertNil(session.tabID, "show(nil) must clear the session's tab.")

        session.teardown()
        XCTAssertEqual(closed, [tabForA, tabForB], "Tearing down an empty session must not close a tab twice.")
    }

    // MARK: - Which sections get a preview column

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testSpacesHasNoPreviewColumnAndEveryOtherSectionDoes

    func testSpacesHasNoPreviewColumnAndEveryOtherSectionDoes() {
        XCTAssertFalse(
            LibrarySection.spaces.supportsPreview,
            "Spaces must have no preview column: Arc's Spaces preview is unsourced, and inventing one is not parity."
        )

        for section in LibrarySection.allCases where section != .spaces {
            XCTAssertTrue(
                section.supportsPreview,
                "\(section.rawValue) must show the preview column — it has real content to preview."
            )
        }
    }

    // MARK: - Router

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testChangingSectionClearsTheSelection

    func testChangingSectionClearsTheSelection() {
        LibraryRouter.shared.selectedSection = .downloads
        let id = UUID()
        LibraryRouter.shared.select(.download(id))
        XCTAssertEqual(LibraryRouter.shared.selection, .download(id), "test precondition: the row was not selected")

        LibraryRouter.shared.selectedSection = .archivedTabs
        XCTAssertNil(
            LibraryRouter.shared.selection,
            "Switching Library sections must clear the selection, otherwise a stale row drives the new section's preview."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testSelectingTheSameRowTwiceClearsTheSelection

    func testSelectingTheSameRowTwiceClearsTheSelection() {
        let id = UUID()

        LibraryRouter.shared.select(.note(id))
        XCTAssertEqual(LibraryRouter.shared.selection, .note(id), "First click must select the row.")

        LibraryRouter.shared.select(.note(id))
        XCTAssertNil(LibraryRouter.shared.selection, "Clicking the already-selected row must clear the selection.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testEverySelectionKnowsItsOwnSection

    func testEverySelectionKnowsItsOwnSection() {
        XCTAssertEqual(LibrarySelection.download(UUID()).section, .downloads)
        XCTAssertEqual(LibrarySelection.archivedTab(TabID()).section, .archivedTabs)
        XCTAssertEqual(LibrarySelection.boostHost("example.com").section, .boosts)
        XCTAssertEqual(LibrarySelection.note(UUID()).section, .easelsAndNotes)
        XCTAssertEqual(LibrarySelection.easel(UUID()).section, .easelsAndNotes)
        XCTAssertEqual(LibrarySelection.media(TabID()).section, .media)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testNoSelectionResolvesToNothing

    func testNoSelectionResolvesToNothing() {
        XCTAssertEqual(
            LibraryPreviewContent.resolve(nil, env: env),
            LibraryPreviewContent.none,
            "With no row selected the preview column must draw nothing."
        )
    }
}
