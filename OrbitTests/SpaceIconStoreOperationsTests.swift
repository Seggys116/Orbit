import XCTest

@MainActor
final class SpaceIconStoreOperationsTests: XCTestCase {

    private func makeStore() -> BrowserStore {
        BrowserStore(stateStore: StateStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTests-SpaceIconOps-\(UUID().uuidString)")), autoArchiveInterval: nil)
    }

    // MARK: - createSpace(iconOverride:)

    func test_createSpace_withNoIconOverride_behavesExactlyAsBeforeThisTask() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Legacy", icon: "airplane", iconIsEmoji: false, profileID: profileID)
        let space = try! XCTUnwrap(store.space(id))

        XCTAssertEqual(space.icon, "airplane")
        XCTAssertFalse(space.iconIsEmoji)
        XCTAssertNil(space.iconKind, "omitting iconOverride must leave iconKind unset, exactly as every pre-existing caller of createSpace expects")
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.symbol("airplane"))
    }

    func test_createSpace_withIconOverrideNone_createsADotSpace() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Blank", iconOverride: SpaceIcon.none, profileID: profileID)
        let space = try! XCTUnwrap(store.space(id))

        XCTAssertEqual(space.resolvedIcon, SpaceIcon.none)
        XCTAssertEqual(space.iconKind, SpaceIconKind.none)
    }

    func test_createSpace_withIconOverrideImage_createsAnImageSpace() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let imageID = SpaceIconImageID()
        let id = store.createSpace(name: "Custom", iconOverride: SpaceIcon.image(imageID), profileID: profileID)
        let space = try! XCTUnwrap(store.space(id))

        XCTAssertEqual(space.resolvedIcon, SpaceIcon.image(imageID))
        XCTAssertEqual(space.iconImageID, imageID)
    }

    // MARK: - setIcon(_ icon: SpaceIcon, forSpace:)

    func test_setIconSpaceIcon_none_setsTheDot() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Work", icon: "briefcase", iconIsEmoji: false, profileID: profileID)

        store.setIcon(SpaceIcon.none, forSpace: id)

        XCTAssertEqual(store.space(id)?.resolvedIcon, SpaceIcon.none)
    }

    func test_setIconSpaceIcon_image_setsTheImage() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Work", profileID: profileID)
        let imageID = SpaceIconImageID()

        store.setIcon(SpaceIcon.image(imageID), forSpace: id)

        XCTAssertEqual(store.space(id)?.resolvedIcon, SpaceIcon.image(imageID))
    }

    func test_setIconSpaceIcon_symbolAfterImage_clearsTheStaleImageID() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Work", profileID: profileID)
        store.setIcon(SpaceIcon.image(SpaceIconImageID()), forSpace: id)

        store.setIcon(SpaceIcon.symbol("star"), forSpace: id)

        let space = try! XCTUnwrap(store.space(id))
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.symbol("star"))
        XCTAssertNil(space.iconImageID, "switching to a symbol must not leave a stale image id behind")
    }

    // MARK: - Legacy setIcon(_:isEmoji:forSpace:) still stamps iconKind

    func test_legacySetIcon_afterAnImageIcon_winsOverTheStaleImageKind() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Work", profileID: profileID)
        store.setIcon(SpaceIcon.image(SpaceIconImageID()), forSpace: id)

        store.setIcon("book", isEmoji: false, forSpace: id)

        let space = try! XCTUnwrap(store.space(id))
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.symbol("book"), "the legacy setter must stamp iconKind, not just icon/iconIsEmoji, or resolvedIcon keeps answering .image")
        XCTAssertNil(space.iconImageID)
    }

    func test_legacySetIcon_emoji_stampsEmojiKind() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Fun", profileID: profileID)

        store.setIcon("🎉", isEmoji: true, forSpace: id)

        let space = try! XCTUnwrap(store.space(id))
        XCTAssertEqual(space.resolvedIcon, SpaceIcon.emoji("🎉"))
        XCTAssertEqual(space.iconKind, SpaceIconKind.emoji)
    }

    // MARK: - Duplication carries the icon across

    func test_duplicateSpace_carriesTheDotAcross() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let id = store.createSpace(name: "Blank", iconOverride: SpaceIcon.none, profileID: profileID)

        let duplicateID = try! XCTUnwrap(store.duplicateSpace(id))

        XCTAssertEqual(store.space(duplicateID)?.resolvedIcon, SpaceIcon.none)
    }

    func test_duplicateSpace_carriesACustomImageAcross() {
        let store = makeStore()
        let profileID = store.state.profiles[0].id
        let imageID = SpaceIconImageID()
        let id = store.createSpace(name: "Custom", iconOverride: SpaceIcon.image(imageID), profileID: profileID)

        let duplicateID = try! XCTUnwrap(store.duplicateSpace(id))

        XCTAssertEqual(store.space(duplicateID)?.resolvedIcon, SpaceIcon.image(imageID))
    }
}
