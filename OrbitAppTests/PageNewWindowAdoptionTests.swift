//  content::WebContentsDelegate's OpenURLFromTab/AddNewContents base implementations drop the
//  pending WebContents unless overridden; end-to-end proof lives in PageLinkNavigationLiveTests.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PageNewWindowAdoptionTests: XCTestCase {

    // MARK: - The overrides themselves

    private static var embedderRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chromium/Embedder", isDirectory: true)
    }

    private func embedderSource(_ relativePath: String) throws -> String {
        let url = Self.embedderRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testOrbitWebContentsHostOverridesBothOfContentsNewWindowRoutes() throws {
        let header = try embedderSource("browser/orbit_web_contents_host.h")
        let implementation = try embedderSource("browser/orbit_web_contents_host.mm")

        for override in ["OpenURLFromTab", "AddNewContents"] {
            XCTAssertTrue(
                header.contains(override),
                """
                OrbitWebContentsHost does not declare \(override). content::'s \
                own base-class implementation returns nullptr and drops the \
                request, which is a browser that silently refuses to follow a \
                link -- see this file's header.
                """
            )
            XCTAssertTrue(
                implementation.contains("OrbitWebContentsHost::\(override)"),
                "OrbitWebContentsHost declares \(override) but never defines it."
            )
        }

        XCTAssertTrue(
            implementation.contains("RequestNewContent("),
            """
            Neither override reaches RequestNewContent, so nothing a page opens \
            in a second tab can ever reach Swift.
            """
        )
    }

    func testTheNewContentCallbackIsDeclaredOnBothSidesOfTheCABI() throws {
        let api = try embedderSource("bridge/orbit_bridge_api.h")
        XCTAssertTrue(
            api.contains("OrbitSetNewContentRequestCallback"),
            "orbit_bridge_api.h no longer exports the new-content callback the two overrides answer through."
        )

        let bridgeSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Orbit/Engine/Chromium/OrbitChromiumBridge.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            bridgeSource.contains("\"OrbitSetNewContentRequestCallback\""),
            """
            OrbitChromiumBridge never looks the symbol up, so the engine would \
            keep dropping every target=_blank / window.open() / Cmd-click with \
            no Swift-side sign that anything was asked for.
            """
        )
    }

    // MARK: - PendingWebContents' ownership contract

    func testPendingWebContentsHandsOverOwnershipExactlyOnce() {
        let made = MockWebContents()
        var buildCount = 0
        let pending = PendingWebContents(
            request: NewContentRequest(
                url: URL(string: "https://example.com/opened")!,
                disposition: .newForegroundTab,
                isUserGesture: true
            )
        ) {
            buildCount += 1
            return made
        }

        XCTAssertFalse(pending.isAdopted, "Nothing is built until the delegate commits.")
        XCTAssertTrue(pending.adopt() === made)
        XCTAssertTrue(pending.isAdopted)
        XCTAssertNil(pending.adopt(), "A second adopt() must not hand the same engine WebContents to a second owner.")
        XCTAssertEqual(buildCount, 1)
    }

    func testPendingWebContentsNeverBuildsAnythingForADelegateThatDeclines() {
        var buildCount = 0
        let pending = PendingWebContents(
            request: NewContentRequest(
                url: URL(string: "https://example.com/opened")!,
                disposition: .newForegroundTab,
                isUserGesture: true
            )
        ) {
            buildCount += 1
            return MockWebContents()
        }
        XCTAssertEqual(buildCount, 0)
        XCTAssertFalse(pending.isAdopted, "isAdopted is what tells the engine whether to destroy its copy.")
    }

    // MARK: - AppEnvironment's own half

    private func makeEnvironmentWithOpener() throws -> (AppEnvironment, TabID, MockWebContents) {
        let env = AppEnvironment.demo
        let openerTabID = try XCTUnwrap(env.activeTabID, "The demo environment has no active tab to open from.")
        let opener = MockWebContents()
        env._test_attachWebContents(opener, for: openerTabID)
        return (env, openerTabID, opener)
    }

    private func pending(
        _ disposition: NewContentDisposition,
        url: URL = URL(string: "https://example.com/opened")!
    ) -> (PendingWebContents, MockWebContents) {
        let opened = MockWebContents()
        let pending = PendingWebContents(
            request: NewContentRequest(url: url, disposition: disposition, isUserGesture: true)
        ) { opened }
        return (pending, opened)
    }

    func testForegroundAdoptionMakesARealTabOwningTheEnginesOwnWebContents() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let openerTab = try XCTUnwrap(env.tab(openerTabID))
        let tabsBefore = Set(env.state.tabs.keys)

        let (request, opened) = pending(.newForegroundTab)
        XCTAssertTrue(env.webContents(opener, requestsAdoptionOf: request))
        XCTAssertTrue(request.isAdopted, "The engine's WebContents is destroyed unless adopt() is called.")

        let newTabIDs = Set(env.state.tabs.keys).subtracting(tabsBefore)
        let newTabID = try XCTUnwrap(newTabIDs.first, "No tab was created for the adopted WebContents.")
        XCTAssertEqual(newTabIDs.count, 1)
        XCTAssertTrue(
            env.webContents[newTabID] === opened,
            """
            The new tab is not backed by the WebContents the engine already \
            built and started navigating. Opening a fresh one at the same URL \
            instead drops window.opener, the shared session storage namespace \
            and the load already in flight.
            """
        )
        XCTAssertEqual(env.tab(newTabID)?.spaceID, openerTab.spaceID, "A popup belongs in the Space that opened it.")
        XCTAssertEqual(env.activeTabID, newTabID, "A foreground request must activate the tab it made.")
        XCTAssertNil(
            opened.navigationState.url,
            "The adopted contents was re-loaded, which restarts the navigation the engine already began."
        )

        env.closeTab(newTabID)
    }

    func testBackgroundAdoptionLeavesTheOpenerActive() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        env.activateTab(openerTabID)
        let tabsBefore = Set(env.state.tabs.keys)

        let (request, opened) = pending(.newBackgroundTab)
        XCTAssertTrue(env.webContents(opener, requestsAdoptionOf: request))

        let newTabID = try XCTUnwrap(Set(env.state.tabs.keys).subtracting(tabsBefore).first)
        XCTAssertTrue(env.webContents[newTabID] === opened)
        XCTAssertEqual(env.activeTabID, openerTabID, "A background request must not steal the active tab.")

        env.closeTab(newTabID)
    }

    func testAnOpenerWithNoTabIsRefusedWithoutEverBuildingTheContents() throws {
        let (env, openerTabID, _) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        // Never attached to any tab: the delegate has no Space to open into
        // and no opener to inherit one from.
        let strayOpener = MockWebContents()
        let tabsBefore = Set(env.state.tabs.keys)

        let (request, _) = pending(.newForegroundTab)
        XCTAssertFalse(env.webContents(strayOpener, requestsAdoptionOf: request))
        XCTAssertFalse(
            request.isAdopted,
            "A refusal must leave the engine free to destroy its copy; adopting first and then declining double-frees it."
        )
        XCTAssertEqual(Set(env.state.tabs.keys), tabsBefore)
    }

    func testADownloadDispositionIsRefusedRatherThanTurnedIntoATab() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let tabsBefore = Set(env.state.tabs.keys)

        let (request, _) = pending(.download)
        XCTAssertFalse(env.webContents(opener, requestsAdoptionOf: request))
        XCTAssertFalse(request.isAdopted)
        XCTAssertEqual(Set(env.state.tabs.keys), tabsBefore)
    }

    // MARK: - The other route: nothing built yet

    func testAnOpenURLFromTabRequestOpensATabAtTheRequestedURL() throws {
        let (env, openerTabID, opener) = try makeEnvironmentWithOpener()
        defer { env._test_detachWebContents(for: openerTabID) }
        let openerTab = try XCTUnwrap(env.tab(openerTabID))
        let tabsBefore = Set(env.state.tabs.keys)
        let target = URL(string: "https://example.com/cmd-clicked")!

        let handled = env.webContents(
            opener,
            requestsNewContent: NewContentRequest(url: target, disposition: .newBackgroundTab, isUserGesture: true)
        )
        XCTAssertTrue(handled)

        let newTabID = try XCTUnwrap(
            Set(env.state.tabs.keys).subtracting(tabsBefore).first,
            "A Cmd-click reaches OpenURLFromTab with nothing built, so Swift has to open the tab itself."
        )
        XCTAssertEqual(env.tab(newTabID)?.url, target)
        XCTAssertEqual(env.tab(newTabID)?.spaceID, openerTab.spaceID)
        XCTAssertEqual(env.activeTabID, openerTabID)

        env.closeTab(newTabID)
    }

    // MARK: - The disposition mapping the C ABI carries

    func testWindowOpenDispositionsMapOntoOrbitsOwn() {
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 1), .currentTab)
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 3), .newForegroundTab)
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 4), .newBackgroundTab)
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 5), .popup)
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 6), .newWindow)
        XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: 7), .download)
        // Anything with no distinct Orbit surface opens as an ordinary tab
        // rather than being dropped, which is what the defect did.
        for raw in [Int32(0), 2, 8, 9, 10, 11, 12, 99] {
            XCTAssertEqual(NewContentDisposition(chromiumWindowOpenDisposition: raw), .newForegroundTab)
        }
    }
}
