import XCTest
@testable import Orbit

@MainActor
final class SpacePagerContextMenuActionsTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
        let profileID = env.createDefaultProfileIfNeeded()
        // createSpace always activates, so the "not the active Space" scenario
        // each test needs is set up by switching back explicitly afterward.
        scratchSpaceID = env.createSpace(name: "R18 Scratch", icon: "sparkles", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
    }

    override func tearDown() {
        if let scratchSpaceID {
            env.deleteSpace(scratchSpaceID)
        }
        if let originalActiveSpaceID {
            env.selectSpace(originalActiveSpaceID)
        }
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - "New Folder"

    func testNewFolderAddsAnEmptyFolderToTheTargetedSpacesPinnedRoot() {
        let before = env.pinnedNodes(in: scratchSpaceID)
        XCTAssertTrue(before.isEmpty, "test precondition: scratch Space starts with no Pinned content")

        let folderID = env.createFolder(name: "New Folder", in: scratchSpaceID)

        let after = env.pinnedNodes(in: scratchSpaceID)
        XCTAssertEqual(after.count, 1)
        guard case .folder(let folder) = after.first else {
            return XCTFail("Expected the new node to be a folder.")
        }
        XCTAssertEqual(folder.id, folderID)
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertTrue(folder.children.isEmpty)
    }

    // MARK: - "Paste as New Tab" (the underlying `env.openTab` it targets)

    func testOpenTabForAPagerTargetedSpace_landsInThatSpacesTodaySection_evenWhenAnotherSpaceIsActive() {
        guard let firstDemoSpace = env.spaces.first(where: { $0.id != scratchSpaceID }) else {
            return XCTFail("AppEnvironment.demo must seed at least one other Space besides the scratch one.")
        }
        env.selectSpace(firstDemoSpace.id)
        XCTAssertEqual(env.activeSpace?.id, firstDemoSpace.id, "test precondition")

        let url = URL(string: "https://example.com/r18-paste-as-new-tab")!
        let tabID = env.openTab(url: url, in: scratchSpaceID)

        XCTAssertTrue(env.todayTabs(in: scratchSpaceID).contains { $0.id == tabID }, "The pasted tab must land in the targeted (non-active) Space's Today section.")
        XCTAssertFalse(env.todayTabs(in: firstDemoSpace.id).contains { $0.id == tabID }, "The pasted tab must not leak into whichever Space happens to be active.")
    }

    // MARK: - "setProfile" (the store call the removed Profile submenu used to make)

    func testSetProfileForSpace_reassignsOnlyTheTargetedSpace() {
        let originalProfileID = env.space(scratchSpaceID)?.profileID
        let newProfile = Profile(name: "R18 Scratch Profile")
        env.state.profiles.append(newProfile)
        defer { env.state.profiles.removeAll { $0.id == newProfile.id } }

        guard let untouchedSpace = env.spaces.first(where: { $0.id != scratchSpaceID }) else {
            return XCTFail("AppEnvironment.demo must seed at least one other Space.")
        }
        let untouchedSpaceOriginalProfileID = untouchedSpace.profileID

        env.store.setProfile(newProfile.id, forSpace: scratchSpaceID)

        XCTAssertEqual(env.space(scratchSpaceID)?.profileID, newProfile.id, "setProfile(_:forSpace:) did not reassign the targeted Space's profile.")
        XCTAssertNotEqual(env.space(scratchSpaceID)?.profileID, originalProfileID)
        XCTAssertEqual(env.space(untouchedSpace.id)?.profileID, untouchedSpaceOriginalProfileID, "setProfile(_:forSpace:) must never reassign a Space other than the one it was asked to.")
    }

    func testSetProfileWithAnUnknownProfileID_isANoOp() {
        let before = env.space(scratchSpaceID)?.profileID
        env.store.setProfile(ProfileID(), forSpace: scratchSpaceID)
        XCTAssertEqual(env.space(scratchSpaceID)?.profileID, before)
    }

    // MARK: - "Duplicate" (already-existing pager item — regression coverage)

    func testDuplicateSpace_copiesPinnedStructureWithFreshIdentitiesAndActivatesTheCopy() {
        let folderID = env.createFolder(name: "Docs", in: scratchSpaceID)
        _ = env.openTab(url: URL(string: "https://example.com/duplicate-me")!, in: scratchSpaceID, section: .pinned)

        guard let duplicateID = env.store.duplicateSpace(scratchSpaceID) else {
            return XCTFail("duplicateSpace returned nil.")
        }
        defer { env.deleteSpace(duplicateID) }

        XCTAssertNotEqual(duplicateID, scratchSpaceID)
        XCTAssertEqual(env.space(duplicateID)?.name, "R18 Scratch Copy")

        let originalPinned = env.pinnedNodes(in: scratchSpaceID)
        let duplicatePinned = env.pinnedNodes(in: duplicateID)
        XCTAssertEqual(originalPinned.count, duplicatePinned.count, "The duplicate must have the same Pinned structure as the original.")

        guard case .folder(let duplicateFolder) = duplicatePinned.first(where: { if case .folder = $0 { return true } else { return false } }) else {
            return XCTFail("Expected the duplicate to have its own Docs folder.")
        }
        XCTAssertNotEqual(duplicateFolder.id, folderID, "A duplicated Space's folder must get a brand-new identity, not share the original's.")
    }

    // MARK: - Mouse click-and-drag across the pager (ARC_INTERACTION.md §2.4)

    func testMouseDragPastThreshold_leftward_actuallyActivatesTheNextSpace() {
        let spaces = env.spaces
        guard spaces.count > 1, let startID = env.activeSpace?.id,
              let startIndex = spaces.firstIndex(where: { $0.id == startID }) else {
            return XCTFail("test precondition: needs more than one Space and an active one.")
        }
        let expectedID = spaces[(startIndex + 1) % spaces.count].id

        let committed = SpaceSwitcherPagerView.commitMouseDrag(
            translation: -(SpaceSwitcherPagerView.mouseDragCommitThreshold + 10),
            in: env
        )

        XCTAssertTrue(committed, "A drag well past the commit threshold must report that it committed.")
        XCTAssertEqual(
            env.activeSpace?.id, expectedID,
            "ARC_INTERACTION.md §2.4: dragging left across the pager must actually switch to the next Space. If this fails, un-painting the pager capsule took its hit target/gesture with it."
        )
        XCTAssertNotEqual(env.activeSpace?.id, startID, "The active Space must really have changed, not merely reported that it did.")
    }

    func testMouseDragPastThreshold_rightward_actuallyActivatesThePreviousSpace() {
        let spaces = env.spaces
        guard spaces.count > 1, let startID = env.activeSpace?.id,
              let startIndex = spaces.firstIndex(where: { $0.id == startID }) else {
            return XCTFail("test precondition: needs more than one Space and an active one.")
        }
        let expectedID = spaces[(startIndex - 1 + spaces.count) % spaces.count].id

        let committed = SpaceSwitcherPagerView.commitMouseDrag(
            translation: SpaceSwitcherPagerView.mouseDragCommitThreshold + 10,
            in: env
        )

        XCTAssertTrue(committed)
        XCTAssertEqual(env.activeSpace?.id, expectedID, "Dragging right across the pager must switch to the previous Space, not the next one.")
    }

    func testMouseDragShortOfThreshold_leavesTheActiveSpaceAlone() {
        guard env.spaces.count > 1, let startID = env.activeSpace?.id else {
            return XCTFail("test precondition: needs more than one Space and an active one.")
        }

        let committed = SpaceSwitcherPagerView.commitMouseDrag(
            translation: -(SpaceSwitcherPagerView.mouseDragCommitThreshold - 1),
            in: env
        )

        XCTAssertFalse(committed, "A drag short of the commit threshold must not commit.")
        XCTAssertEqual(env.activeSpace?.id, startID, "A sub-threshold drag must leave the active Space exactly as it was.")
    }
}
