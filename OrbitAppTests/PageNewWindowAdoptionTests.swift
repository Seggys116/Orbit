//  How a click or window.open becomes a disposition, and what the delegate does with an adopted or declined
//  request. End-to-end proof lives in PageLinkNavigationLiveTests.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PageNewWindowAdoptionTests: XCTestCase {

    // MARK: - Click and window.open dispositions

    private let noFeatures = NewContentDisposition.WebKitWindowFeatures()

    func testCmdClickOpensABackgroundTabAndCmdShiftClickAForegroundOne() {
        XCTAssertEqual(NewContentDisposition.forLinkClick(modifiers: [.command], buttonNumber: 1), .newBackgroundTab)
        XCTAssertEqual(NewContentDisposition.forLinkClick(modifiers: [.command, .shift], buttonNumber: 1), .newForegroundTab)
    }

    func testShiftClickOpensAWindow() {
        XCTAssertEqual(NewContentDisposition.forLinkClick(modifiers: [.shift], buttonNumber: 1), .newWindow)
    }

    func testMiddleClickOpensABackgroundTabAndShiftMiddleClickAForegroundOne() {
        for middle in [NewContentDisposition.webKitMiddleButtonNumber, NewContentDisposition.webKitMiddleButtonMask] {
            XCTAssertEqual(NewContentDisposition.forLinkClick(modifiers: [], buttonNumber: middle), .newBackgroundTab)
            XCTAssertEqual(NewContentDisposition.forLinkClick(modifiers: [.shift], buttonNumber: middle), .newForegroundTab)
        }
    }

    func testAPlainLeftClickIsAnOrdinaryNavigation() {
        XCTAssertNil(NewContentDisposition.forLinkClick(modifiers: [], buttonNumber: 1))
        XCTAssertNil(NewContentDisposition.forLinkClick(modifiers: [.capsLock], buttonNumber: 1), "caps lock is not a click modifier")
    }

    func testOptionAndControlClicksAreLeftToTheirOwnGestures() {
        XCTAssertNil(NewContentDisposition.forLinkClick(modifiers: [.option], buttonNumber: 1))
        XCTAssertNil(NewContentDisposition.forLinkClick(modifiers: [.command, .option], buttonNumber: 1))
        XCTAssertNil(NewContentDisposition.forLinkClick(modifiers: [.control], buttonNumber: 1))
    }

    func testWindowOpenWithNoFeaturesIsAForegroundTab() {
        XCTAssertEqual(
            NewContentDisposition.forNewWindow(modifiers: [], buttonNumber: 0, features: noFeatures),
            .newForegroundTab
        )
    }

    func testWindowOpenWithASizeOrPositionOrBareChromeIsAPopup() {
        for features in [
            NewContentDisposition.WebKitWindowFeatures(hasSize: true),
            NewContentDisposition.WebKitWindowFeatures(hasPosition: true),
            NewContentDisposition.WebKitWindowFeatures(hidesToolbars: true),
            NewContentDisposition.WebKitWindowFeatures(hidesMenuBar: true),
            NewContentDisposition.WebKitWindowFeatures(hidesStatusBar: true),
        ] {
            XCTAssertTrue(features.requestsPopup)
            XCTAssertEqual(NewContentDisposition.forNewWindow(modifiers: [], buttonNumber: 0, features: features), .popup)
        }
    }

    func testAClickGestureOutranksWindowFeatures() {
        let popup = NewContentDisposition.WebKitWindowFeatures(hasSize: true)
        XCTAssertEqual(
            NewContentDisposition.forNewWindow(modifiers: [.command], buttonNumber: 1, features: popup),
            .newBackgroundTab
        )
        XCTAssertEqual(
            NewContentDisposition.forNewWindow(modifiers: [.shift], buttonNumber: 1, features: noFeatures),
            .newWindow
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
            "A Cmd-click reaches the delegate with nothing built, so Swift has to open the tab itself."
        )
        XCTAssertEqual(env.tab(newTabID)?.url, target)
        XCTAssertEqual(env.tab(newTabID)?.spaceID, openerTab.spaceID)
        XCTAssertEqual(env.activeTabID, openerTabID)

        env.closeTab(newTabID)
    }
}
