// Tab and window identity the WebKit engine hands to chrome.tabs and chrome.windows.

import XCTest
@testable import Orbit

@MainActor
final class OrbitTabsBridgeTests: XCTestCase {

    private func makeEngine() throws -> WebKitEngine {
        let engine = WebKitEngine(storage: .ephemeral)
        try engine.start()
        return engine
    }

    private func makeContents(_ engine: WebKitEngine) throws -> WebKitWebContents {
        try XCTUnwrap(
            try engine.makeWebContents(session: engine.defaultSession, initialURL: nil) as? WebKitWebContents
        )
    }

    func test_tabIDIsStableForTheSameContents() throws {
        let engine = try makeEngine()
        let contents = try makeContents(engine)
        defer { contents.close() }
        let first = engine.numericID(for: contents)
        let second = engine.numericID(for: contents)
        XCTAssertEqual(first, second, "the same tab must always resolve to the same allocated id")
        XCTAssertNotNil(first)
    }

    func test_tabIDsForDifferentContentsAreDistinct() throws {
        let engine = try makeEngine()
        let first = try makeContents(engine)
        let second = try makeContents(engine)
        defer {
            first.close()
            second.close()
        }
        XCTAssertNotEqual(engine.numericID(for: first), engine.numericID(for: second))
    }

    func test_extensionWindowStateRoundTrips() throws {
        let engine = try makeEngine()
        engine.setExtensionWindowState(named: "fullscreen")
        XCTAssertEqual(engine.extensionWindowStateName, "fullscreen")
        engine.setExtensionWindowState(named: "minimized")
        XCTAssertEqual(engine.extensionWindowStateName, "minimized")
        engine.setExtensionWindowState(named: "normal")
        XCTAssertEqual(engine.extensionWindowStateName, "normal")
    }

    func test_closingATabForgetsItsIDAndReopeningAllocatesAFreshOne() throws {
        let engine = try makeEngine()
        let contents = try makeContents(engine)
        defer { contents.close() }
        let storeID = UUID()
        engine.bind(storeTabID: storeID, to: contents)
        let first = try XCTUnwrap(engine.numericID(for: contents))
        XCTAssertEqual(engine.numericID(for: storeID), first)
        XCTAssertEqual(engine.storeTabID(forNumericID: first), storeID)

        engine.noteTabClosed(contents)

        XCTAssertNil(engine.numericID(for: contents), "a closed tab must no longer resolve to an id")
        XCTAssertNil(engine.storeTabID(forNumericID: first), "a closed tab's id must no longer resolve back to its store tab")

        engine.noteTabOpened(contents)
        engine.bind(storeTabID: storeID, to: contents)
        let second = try XCTUnwrap(engine.numericID(for: contents))
        XCTAssertNotEqual(
            second, first,
            "close-then-reopen must not silently reuse the old id"
        )
    }

    func test_anAdditionalWindowOpensAndClosesWithoutReplacingTheBrowserWindow() throws {
        let engine = try makeEngine()
        let original = engine.extensionWindow
        let extra = engine.openAdditionalExtensionWindow()
        XCTAssertFalse(extra === original)
        engine.closeExtensionWindow(extra)
        XCTAssertTrue(engine.extensionWindow === original)
    }

    // MARK: - References the chrome wrapper resolves to WebKit's own tab ids

    private func orbitTabs(_ engine: WebKitEngine, _ method: String, _ args: [Any]) async throws -> [String: Any] {
        let result = await engine.performChromeAPI(extensionID: "", namespace: "orbitTabs", method: method, args: args)
        return try XCTUnwrap(try result.get() as? [String: Any], "orbitTabs.\(method) must answer with an object")
    }

    func test_aTabReferenceFollowsItsIndexAndTheLayoutGeneration() throws {
        let engine = try makeEngine()
        let first = try makeContents(engine)
        let second = try makeContents(engine)
        defer {
            first.close()
            second.close()
        }
        let before = try XCTUnwrap(engine.extensionTabReference(for: second))
        XCTAssertEqual(before["index"] as? Int, 1)
        XCTAssertEqual(before["number"] as? Int, engine.numericID(for: second).map(Int.init))

        engine.noteTabClosed(first)

        let after = try XCTUnwrap(engine.extensionTabReference(for: second))
        XCTAssertEqual(after["index"] as? Int, 0, "closing an earlier tab shifts the index WebKit reports")
        XCTAssertNotEqual(
            after["generation"] as? Int, before["generation"] as? Int,
            "a close must change the generation, or the wrapper would trust an index read before it"
        )
        XCTAssertNil(engine.extensionTabReference(for: first), "a closed tab has no place in the window")
    }

    func test_aMoveChangesTheLayoutGeneration() throws {
        let engine = try makeEngine()
        let contents = try makeContents(engine)
        defer { contents.close() }
        let before = try XCTUnwrap(engine.extensionTabReference(for: contents)?["generation"] as? Int)
        engine.noteTabMoved(contents, from: 0)
        let after = try XCTUnwrap(engine.extensionTabReference(for: contents)?["generation"] as? Int)
        XCTAssertNotEqual(before, after)
    }

    func test_numberAtRefusesAnIndexReadUnderAnOlderLayout() async throws {
        let engine = try makeEngine()
        let first = try makeContents(engine)
        let second = try makeContents(engine)
        defer {
            first.close()
            second.close()
        }
        let secondNumber = try XCTUnwrap(engine.numericID(for: second).map(Int.init))
        let generation = try XCTUnwrap(engine.extensionTabReference(for: second)?["generation"] as? Int)

        let current = try await orbitTabs(engine, "numberAt", [1, generation])
        XCTAssertEqual(current["number"] as? Int, secondNumber)
        XCTAssertNil(current["stale"])

        engine.noteTabClosed(first)

        let stale = try await orbitTabs(engine, "numberAt", [1, generation])
        XCTAssertEqual(stale["stale"] as? Bool, true, "an index read before the close must not be trusted")
        XCTAssertNil(stale["number"], "a stale index must never be answered with whatever tab sits there now")

        let currentGeneration = try XCTUnwrap(stale["generation"] as? Int)
        let fresh = try await orbitTabs(engine, "numberAt", [0, currentGeneration])
        XCTAssertEqual(fresh["number"] as? Int, secondNumber)

        let outOfRange = try await orbitTabs(engine, "numberAt", [5, currentGeneration])
        XCTAssertNil(outOfRange["number"])
        XCTAssertNil(outOfRange["stale"])
    }

    func test_locateReportsAnOpenTabsCurrentPlaceAndNothingForAClosedOne() async throws {
        let engine = try makeEngine()
        let first = try makeContents(engine)
        let second = try makeContents(engine)
        defer {
            first.close()
            second.close()
        }
        let firstNumber = try XCTUnwrap(engine.numericID(for: first).map(Int.init))
        let secondNumber = try XCTUnwrap(engine.numericID(for: second).map(Int.init))

        engine.noteTabClosed(first)

        let open = try await orbitTabs(engine, "locate", [secondNumber])
        let reference = try XCTUnwrap(open["reference"] as? [String: Any])
        XCTAssertEqual(reference["index"] as? Int, 0)
        XCTAssertEqual(reference["generation"] as? Int, open["generation"] as? Int)

        let closed = try await orbitTabs(engine, "locate", [firstNumber])
        XCTAssertNil(closed["reference"], "a closed tab must not resolve to the tab now in its old slot")
    }

    func test_eventsAndRepliesCarryAReferenceNotOrbitsOwnNumber() throws {
        let engine = try makeEngine()
        let contents = try makeContents(engine)
        defer { contents.close() }
        let value = try XCTUnwrap(engine.extensionTabIDValue(for: contents) as? [String: Any])
        let reference = try XCTUnwrap(value["__orbitTabID"] as? [String: Any])
        XCTAssertEqual(reference["number"] as? Int, engine.numericID(for: contents).map(Int.init))

        engine.noteTabClosed(contents)
        XCTAssertEqual(engine.extensionTabIDValue(for: contents) as? Int, -1, "an unregistered tab is TAB_ID_NONE")
    }

    func test_aStoreTabThatWasNeverOpenedHasNoNumericID() throws {
        let engine = try makeEngine()
        XCTAssertNil(engine.numericID(for: UUID()))
        XCTAssertNil(engine.storeTabID(forNumericID: 1))
    }

    // MARK: - One extension window per Orbit window

    private struct TwoWindows {
        let engine: WebKitEngine
        let environment: AppEnvironment
        let other: AppEnvironment
        let otherSpaceID: SpaceID
        let firstTab: TabID
        let secondTab: TabID

        var first: WebKitWebContents { environment.webContents[firstTab] as! WebKitWebContents }
        var second: WebKitWebContents { other.webContents[secondTab] as! WebKitWebContents }

        func tearDown() {
            other.closeTab(secondTab)
            other.disposeWindowSession()
            engine.noteWindowClosed(environment: other)
            environment.closeTab(firstTab)
            environment.store.deleteSpace(otherSpaceID)
        }
    }

    private func makeTwoWindows() throws -> TwoWindows {
        let engine = try makeEngine()
        let environment = LiveEnvironmentTestCase.makeEnvironmentWithNoOpenTabs()
        environment._test_engineOverride = engine
        let spaceID = try XCTUnwrap(environment.activeSpace?.id)
        let firstTab = environment.openTab(url: URL(string: "about:blank")!, in: spaceID)
        let otherSpaceID = environment.store.createSpace(
            name: "Tabs Bridge Other Window", icon: "square.on.square", iconIsEmoji: false,
            theme: WindowSession.incognitoTheme, profileID: environment.state.profiles[0].id, activate: false
        )
        let other = AppEnvironment.makeWindowScoped(sharing: environment, activeSpaceID: otherSpaceID, isTornOff: true)
        let secondTab = other.openTab(url: URL(string: "about:blank")!, in: otherSpaceID)
        return TwoWindows(
            engine: engine, environment: environment, other: other, otherSpaceID: otherSpaceID,
            firstTab: firstTab, secondTab: secondTab
        )
    }

    func test_eachOrbitWindowIsItsOwnExtensionWindowWithItsOwnTabs() throws {
        let windows = try makeTwoWindows()
        defer { windows.tearDown() }
        let engine = windows.engine

        let one = engine.extensionWindow(of: windows.first)
        let two = engine.extensionWindow(of: windows.second)
        XCTAssertFalse(one === two, "two Orbit windows must not share one extension window")
        XCTAssertTrue(one.environment === windows.environment)
        XCTAssertTrue(two.environment === windows.other)
        XCTAssertEqual(engine.extensionTabs(in: one).map(\.id), [windows.first.id])
        XCTAssertEqual(engine.extensionTabs(in: two).map(\.id), [windows.second.id])
        XCTAssertEqual(
            engine.extensionTabReference(for: windows.second)?["index"] as? Int, 0,
            "an index counts within its own window"
        )
        XCTAssertEqual(engine.extensionTabReference(for: windows.second)?["window"] as? Int, two.number)
        XCTAssertNotEqual(
            engine.extensionTabReference(for: windows.first)?["window"] as? Int,
            engine.extensionTabReference(for: windows.second)?["window"] as? Int
        )
    }

    func test_numberAtWithAKnownWindowNamesThatWindowsTab() async throws {
        let windows = try makeTwoWindows()
        defer { windows.tearDown() }
        let engine = windows.engine
        let two = engine.extensionWindow(of: windows.second)
        let generation = try XCTUnwrap(engine.extensionTabReference(for: windows.second)?["generation"] as? Int)

        let reply = try await orbitTabs(engine, "numberAt", [0, generation, "", two.number])
        XCTAssertEqual(reply["number"] as? Int, engine.numericID(for: windows.second).map(Int.init))
        XCTAssertEqual(reply["window"] as? Int, two.number)

        let ambiguous = try await orbitTabs(engine, "numberAt", [0, generation, "", -1])
        XCTAssertEqual(
            ambiguous["stale"] as? Bool, true,
            "index 0 exists in both windows with the same URL, so without the window it cannot be answered"
        )
        XCTAssertNil(ambiguous["number"])
    }

    func test_closingAWindowScopedEnvironmentClosesItsExtensionWindow() throws {
        let windows = try makeTwoWindows()
        let engine = windows.engine
        let two = engine.extensionWindow(of: windows.second)
        XCTAssertTrue(engine.extensionWindows.contains { $0 === two })

        windows.tearDown()

        XCTAssertFalse(engine.extensionWindows.contains { $0 === two }, "a closed Orbit window must leave chrome.windows")
        XCTAssertTrue(engine.extensionWindows.contains { $0.environment === windows.environment }, "the shared window stays")
    }

    func test_focusFollowsTheOrbitWindowAndNilMeansNoWindow() throws {
        let windows = try makeTwoWindows()
        defer { windows.tearDown() }
        let engine = windows.engine
        let two = engine.extensionWindow(of: windows.second)

        engine.noteWindowFocused(environment: windows.other)
        XCTAssertTrue(engine.focusedExtensionWindow === two)
        engine.noteWindowFocused(environment: windows.environment)
        XCTAssertTrue(engine.focusedExtensionWindow === engine.extensionWindow(of: windows.first))
        engine.noteWindowFocused(environment: nil)
        XCTAssertNil(engine.focusedExtensionWindow)
    }

    func test_aTabMovedToAnotherWindowKeepsItsIdentity() throws {
        let windows = try makeTwoWindows()
        let engine = windows.engine
        let environment = windows.environment
        let spaceID = try XCTUnwrap(environment.activeSpace?.id)
        let movedTab = environment.openTab(url: URL(string: "about:blank")!, in: spaceID)
        let moved = try XCTUnwrap(environment.webContents[movedTab] as? WebKitWebContents)
        defer {
            windows.other.closeTab(movedTab)
            windows.tearDown()
        }
        let number = engine.numericID(for: moved)
        let generation = engine.extensionTabReference(for: moved)?["generation"] as? Int

        environment.store.moveTab(movedTab, toSpace: windows.otherSpaceID, section: .today)
        windows.other.adoptWebContents(for: movedTab, from: environment)

        XCTAssertEqual(engine.numericID(for: moved), number, "a tab torn off to another window is still the same tab")
        XCTAssertTrue(engine.extensionWindow(of: moved).environment === windows.other)
        XCTAssertTrue(engine.extensionTabs(in: engine.extensionWindow(of: windows.second)).contains { $0 === moved })
        XCTAssertFalse(engine.extensionTabs(in: engine.extensionWindow(of: windows.first)).contains { $0 === moved })
        XCTAssertNotEqual(engine.extensionTabReference(for: moved)?["generation"] as? Int, generation)
    }
}
