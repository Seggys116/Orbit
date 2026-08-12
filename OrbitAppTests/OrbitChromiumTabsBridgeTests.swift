//  No live engine needed: every dlsym'd call here is a safe no-op unloaded. The
//  bridge is a process-wide singleton with no reset, so use fresh UUID()/AnyObject values.

import XCTest
@testable import Orbit

@MainActor
final class OrbitChromiumTabsBridgeTests: XCTestCase {

    private final class Owner {}

    func test_tabIDIsStableForTheSameUUID() {
        let bridge = OrbitChromiumTabsBridge.shared
        let uuid = UUID()
        let first = bridge._test_tabID(for: uuid)
        let second = bridge._test_tabID(for: uuid)
        XCTAssertEqual(first, second, "the same tab UUID must always resolve to the same allocated id")
    }

    func test_tabIDsForDifferentUUIDsAreDistinct() {
        let bridge = OrbitChromiumTabsBridge.shared
        let first = bridge._test_tabID(for: UUID())
        let second = bridge._test_tabID(for: UUID())
        XCTAssertNotEqual(first, second)
    }

    func test_windowIDIsStableForTheSameOwner() {
        let bridge = OrbitChromiumTabsBridge.shared
        let owner = Owner()
        let first = bridge._test_windowID(for: owner)
        let second = bridge._test_windowID(for: owner)
        XCTAssertEqual(first, second, "the same window owner must always resolve to the same allocated id")
    }

    func test_tabCreatedPopulatesTheReverseLookups() {
        let bridge = OrbitChromiumTabsBridge.shared
        let tabUUID = UUID()
        let windowOwner = Owner()
        let handle = UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)!

        bridge.tabCreated(tabUUID: tabUUID, handle: handle, windowOwner: windowOwner, index: 0, active: true, pinned: false)

        let tabID = try? XCTUnwrap(bridge.existingTabID(for: tabUUID))
        XCTAssertNotNil(tabID, "tabCreated must have allocated an id for this UUID")
        guard let tabID else { return }
        XCTAssertEqual(bridge.tabUUID(for: tabID), tabUUID, "the reverse tabID -> UUID lookup must match what tabCreated was given")
        XCTAssertTrue(
            bridge.tabWindowOwner(for: tabID) === windowOwner,
            "the reverse tabID -> windowOwner lookup must be the exact object tabCreated was given"
        )
        XCTAssertFalse(
            bridge.isWindowRegistered(windowOwner),
            """
            tabCreated allocates a window id for its owner but never pushes windows.onCreated for it. \
            Reporting that owner as registered is what let OrbitWindowController.configure() skip its own \
            windowCreated call, leaving OrbitTabRegistry with tabs naming a window it had never been told about
            """
        )
        bridge.windowCreated(owner: windowOwner, focused: false)
        XCTAssertTrue(bridge.isWindowRegistered(windowOwner))
    }

    func test_tabRemovedForgetsTheReverseLookups() {
        let bridge = OrbitChromiumTabsBridge.shared
        let tabUUID = UUID()
        let windowOwner = Owner()
        let handle = UnsafeMutableRawPointer(bitPattern: 0xCAFE_F00D)!

        bridge.tabCreated(tabUUID: tabUUID, handle: handle, windowOwner: windowOwner, index: 0, active: true, pinned: false)
        guard let tabID = bridge.existingTabID(for: tabUUID) else {
            return XCTFail("tabCreated must have allocated an id")
        }

        bridge.tabRemoved(tabUUID: tabUUID, windowClosing: false)

        XCTAssertNil(bridge.existingTabID(for: tabUUID), "a removed tab must no longer resolve to an id")
        XCTAssertNil(bridge.tabUUID(for: tabID), "a removed tab's id must no longer resolve back to its UUID")
        XCTAssertNil(bridge.tabWindowOwner(for: tabID), "a removed tab's id must no longer resolve to a window owner")
    }

    func test_removingATabAndRecreatingItAllocatesAFreshID() {
        let bridge = OrbitChromiumTabsBridge.shared
        let tabUUID = UUID()
        let windowOwner = Owner()
        let handle = UnsafeMutableRawPointer(bitPattern: 0xF00D_CAFE)!

        bridge.tabCreated(tabUUID: tabUUID, handle: handle, windowOwner: windowOwner, index: 0, active: true, pinned: false)
        guard let firstID = bridge.existingTabID(for: tabUUID) else {
            return XCTFail("tabCreated must have allocated an id")
        }
        bridge.tabRemoved(tabUUID: tabUUID, windowClosing: false)
        bridge.tabCreated(tabUUID: tabUUID, handle: handle, windowOwner: windowOwner, index: 0, active: true, pinned: false)
        let secondID = bridge.existingTabID(for: tabUUID)

        XCTAssertNotEqual(
            secondID, firstID,
            "remove-then-recreate (tear-off's own contract, see AppEnvironment+TearOff.swift) must not silently reuse the old id"
        )
    }

    func test_windowCreatedAndRemovedRoundTripTheReverseLookup() {
        let bridge = OrbitChromiumTabsBridge.shared
        let owner = Owner()

        bridge.windowCreated(owner: owner, focused: false)
        let windowID = bridge._test_windowID(for: owner)
        XCTAssertTrue(bridge.windowOwner(for: windowID) === owner)
        XCTAssertTrue(bridge.isWindowRegistered(owner))

        bridge.windowRemoved(owner: owner)
        XCTAssertNil(bridge.windowOwner(for: windowID), "a removed window's id must no longer resolve back to its owner")
        XCTAssertFalse(bridge.isWindowRegistered(owner))
    }

    func test_tabWindowOwnerIsNilForAnIDThatWasNeverCreated() {
        let bridge = OrbitChromiumTabsBridge.shared
        // _test_tabID allocates without routing through tabCreated -- the "allocated
        // but not registered" state ChromiumTabsRouter.resolve(_:) must treat as unknown.
        let uuid = UUID()
        let id = bridge._test_tabID(for: uuid)
        XCTAssertNil(bridge.tabWindowOwner(for: id), "an id allocated outside tabCreated must not resolve to any window owner")
    }
}
