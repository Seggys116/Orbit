import Foundation
import XCTest
@testable import Orbit

// MARK: - Isolated BrowserStore tests (creation / deletion / reordering)

@MainActor
final class BrowserStoreSpacesTests: XCTestCase {

    private func makeStore() -> BrowserStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitTests-BrowserStoreSpaces-\(UUID().uuidString)", isDirectory: true)
        let stateStore = StateStore(rootDirectory: root, maxBackups: 0)
        return BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)
    }

    private func makeSpace(_ store: BrowserStore, name: String) -> SpaceID {
        store.createSpace(name: name, profileID: store.state.profiles[0].id)
    }

    func testFreshStoreBootstrapsExactlyOneSpaceAndActivatesIt() {
        let store = makeStore()
        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertEqual(store.activeSpace?.id, store.spaces[0].id)
    }

    func testCreateSpaceAddsItAndActivatesItByDefault() {
        let store = makeStore()
        let newID = makeSpace(store, name: "Work")
        XCTAssertEqual(store.spaces.count, 2)
        XCTAssertEqual(store.activeSpace?.id, newID, "createSpace(activate: true, the default) must switch to the new Space.")
    }

    func testDeleteSpaceRefusesToDeleteTheLastSpace() {
        let store = makeStore()
        let onlySpaceID = store.spaces[0].id
        store.deleteSpace(onlySpaceID)
        XCTAssertEqual(store.spaces.count, 1, "deleteSpace must never remove the last remaining Space.")
        XCTAssertEqual(store.spaces[0].id, onlySpaceID)
    }

    func testDeleteSpaceRemovesItAndFallsBackActiveSpace() {
        let store = makeStore()
        let first = store.spaces[0].id
        let second = makeSpace(store, name: "Work")
        store.switchToSpace(second)

        store.deleteSpace(second)

        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertEqual(store.activeSpace?.id, first, "Deleting the active Space must fall back to a Space that still exists.")
    }

    func testNextAndPreviousSpaceStepThroughSwitcherOrderAndWrap() {
        let store = makeStore()
        let a = store.spaces[0].id
        let b = makeSpace(store, name: "B")
        let c = makeSpace(store, name: "C")

        store.switchToSpace(a)
        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, b, "nextSpace did not step to the following Space in switcher order.")

        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, c)

        store.nextSpace()
        XCTAssertEqual(store.activeSpace?.id, a, "nextSpace must wrap around past the last Space to the first.")

        store.previousSpace()
        XCTAssertEqual(store.activeSpace?.id, c, "previousSpace must wrap around past the first Space to the last.")
    }

    func testReorderSpacesChangesSwitcherOrder() {
        let store = makeStore()
        let a = store.spaces[0].id
        let b = makeSpace(store, name: "B")
        let c = makeSpace(store, name: "C")

        store.reorderSpaces([c, a, b])

        XCTAssertEqual(store.spaces.map(\.id), [c, a, b], "reorderSpaces did not persist the new switcher order.")
    }

    func testMoveSpaceLeftAndRightAreNoOpsAtTheEdges() {
        let store = makeStore()
        let a = store.spaces[0].id
        let b = makeSpace(store, name: "B")

        store.moveSpaceLeft(a) // already first
        XCTAssertEqual(store.spaces.map(\.id), [a, b])

        store.moveSpaceRight(b) // already last
        XCTAssertEqual(store.spaces.map(\.id), [a, b])

        store.moveSpaceRight(a)
        XCTAssertEqual(store.spaces.map(\.id), [b, a])
    }
}

// MARK: - AppEnvironment.perform(_:) dispatch tests (D3's keyboard path)

@MainActor
final class AppEnvironmentPerformSpacesTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func withRestoredActiveSpace(_ body: () -> Void) {
        let originalID = env.activeSpace?.id
        defer { if let originalID { env.selectSpace(originalID) } }
        body()
    }

    func testPerformNextSpaceAdvancesAndPerformPreviousSpaceStepsBack() {
        guard env.spaces.count >= 2 else {
            return XCTFail("AppEnvironment.demo must seed at least two Spaces for this suite to mean anything.")
        }
        withRestoredActiveSpace {
            let ordered = env.spaces
            env.selectSpace(ordered[0].id)

            env.perform(.nextSpace)
            XCTAssertEqual(env.activeSpace?.id, ordered[1].id, "perform(.nextSpace) — what Cmd+Option+Right calls — did not advance the active Space.")

            env.perform(.previousSpace)
            XCTAssertEqual(env.activeSpace?.id, ordered[0].id, "perform(.previousSpace) — what Cmd+Option+Left calls — did not step back.")
        }
    }

    func testJumpToSpaceIndexSelectsTheSpaceAtThatPosition() {
        withRestoredActiveSpace {
            let ordered = env.spaces
            let lastIndex = ordered.count - 1
            env.jumpToSpace(index: lastIndex)
            XCTAssertEqual(env.activeSpace?.id, ordered[lastIndex].id, "jumpToSpace(index:) — what Ctrl+1...9 drive — selected the wrong Space.")
        }
    }

    func testJumpToSpaceIndexOutOfBoundsIsANoOp() {
        withRestoredActiveSpace {
            let before = env.activeSpace?.id
            env.jumpToSpace(index: env.spaces.count + 10)
            XCTAssertEqual(env.activeSpace?.id, before, "An out-of-range jumpToSpace(index:) must not change the active Space.")
        }
    }

    func testSelectSpaceIsANoOpForAnUnknownID() {
        withRestoredActiveSpace {
            let before = env.activeSpace?.id
            env.selectSpace(UUID())
            XCTAssertEqual(env.activeSpace?.id, before, "selectSpace with an id that isn't a real Space must not change the active Space.")
        }
    }
}
