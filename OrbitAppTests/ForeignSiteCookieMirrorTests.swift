import WebKit
import XCTest
@testable import Orbit

@MainActor
final class ForeignSiteCookieMirrorTests: LiveEnvironmentTestCase {

    private func cookie(_ name: String, _ value: String, domain: String = ".google.com") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: domain, .path: "/",
            .expires: Date(timeIntervalSince1970: 2_000_000_000), .secure: "TRUE",
        ])!
    }

    private func values(_ cookies: [HTTPCookie]) -> [String: String] {
        Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Plans

    func testBringingASiteInReplacesWhateverThePageStoreHeldForIt() {
        let plan = ForeignSiteCookieMirror.mirrorPlan(
            source: [cookie("SID", "space")],
            existing: [cookie("NID", "stale"), cookie("SID", "old")]
        )
        XCTAssertEqual(plan.set.map(\.name), ["SID"])
        XCTAssertEqual(plan.delete.map(\.name), ["NID"], "A leftover cookie must not survive and stop the Space's accounts showing.")
    }

    func testASignInDuringTheVisitGoesBackToTheSpace() {
        let base = ForeignSiteCookieMirror.keyed([cookie("SID", "a")])
        let plan = ForeignSiteCookieMirror.returnPlan(
            base: base,
            visited: [cookie("SID", "a"), cookie("LSID", "new-account")],
            current: [cookie("SID", "a")]
        )
        XCTAssertEqual(plan.set.map(\.name), ["LSID"])
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testACookieTheSpaceRotatedMeanwhileIsNotOverwritten() {
        let base = ForeignSiteCookieMirror.keyed([cookie("PSIDTS", "1")])
        let plan = ForeignSiteCookieMirror.returnPlan(
            base: base, visited: [cookie("PSIDTS", "2-popup")], current: [cookie("PSIDTS", "2-space")]
        )
        XCTAssertTrue(plan.set.isEmpty)
    }

    func testASignOutDuringTheVisitRemovesTheCookieFromTheSpaceOnlyIfTheSpaceStillHadIt() {
        let base = ForeignSiteCookieMirror.keyed([cookie("SID", "a"), cookie("HSID", "h")])
        let plan = ForeignSiteCookieMirror.returnPlan(
            base: base, visited: [], current: [cookie("SID", "a"), cookie("HSID", "rotated")]
        )
        XCTAssertEqual(plan.delete.map(\.name), ["SID"])
    }

    func testAVisitThatChangedNothingSendsNothingBack() {
        let cookies = [cookie("SID", "a"), cookie("NID", "n")]
        let plan = ForeignSiteCookieMirror.returnPlan(base: ForeignSiteCookieMirror.keyed(cookies), visited: cookies, current: cookies)
        XCTAssertTrue(plan.set.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    // MARK: - Real WebKit stores

    func testAPopupFromAProfiledSiteSeesTheSpacesGoogleAccountsAndReturnsItsSignIn() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let suffix = UUID().uuidString
            let space = try XCTUnwrap(try engine.session(identifier: "mirror-space-\(suffix)", persistent: false) as? WebKitSession)
            let page = try XCTUnwrap(try engine.session(identifier: "mirror-page-\(suffix)", persistent: false) as? WebKitSession)
            defer {
                engine.forgetSession(identifier: space.identifier)
                engine.forgetSession(identifier: page.identifier)
            }
            await space.dataStore.httpCookieStore.setCookie(self.cookie("SID", "space-account"))
            await space.dataStore.httpCookieStore.setCookie(self.cookie("PSIDTS", "1"))
            await page.dataStore.httpCookieStore.setCookie(self.cookie("NID", "left-from-an-earlier-popup"))
            await page.dataStore.httpCookieStore.setCookie(self.cookie("session", "work", domain: "github.com"))

            let mirror = ForeignSiteCookieMirror(pageStore: page, spaceStore: space, ownSite: "github.com")
            await mirror.willNavigate(to: URL(string: "https://github.com/login")!)
            XCTAssertNil(mirror.visitingSite)
            await mirror.willNavigate(to: URL(string: "https://accounts.google.com/o/oauth2/auth")!)
            XCTAssertEqual(mirror.visitingSite, "google.com")

            let seen = self.values(await page.cookies(forSite: "google.com"))
            XCTAssertEqual(seen, ["SID": "space-account", "PSIDTS": "1"], "The popup must see exactly the Space's Google sign-in.")

            await page.dataStore.httpCookieStore.setCookie(self.cookie("LSID", "second-account"))
            await space.dataStore.httpCookieStore.setCookie(self.cookie("PSIDTS", "2"))
            await mirror.willNavigate(to: URL(string: "https://github.com/session/callback")!)
            XCTAssertNil(mirror.visitingSite)

            let spaceNow = self.values(await space.cookies(forSite: "google.com"))
            XCTAssertEqual(spaceNow["LSID"], "second-account", "An account signed in from the popup belongs to the Space.")
            XCTAssertEqual(spaceNow["PSIDTS"], "2", "The Space's own newer cookie must win.")
            XCTAssertEqual(spaceNow["SID"], "space-account")
            let ownSite = self.values(await page.cookies(forSite: "github.com"))
            XCTAssertEqual(ownSite, ["session": "work"], "The profile's own site is never touched.")
        }
    }

    func testClosingThePopupMidVisitStillReturnsItsChanges() throws {
        try WebKitLiveEngineHost.runLive(timeout: 60) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let suffix = UUID().uuidString
            let space = try XCTUnwrap(try engine.session(identifier: "mirror-space-\(suffix)", persistent: false) as? WebKitSession)
            let page = try XCTUnwrap(try engine.session(identifier: "mirror-page-\(suffix)", persistent: false) as? WebKitSession)
            defer {
                engine.forgetSession(identifier: space.identifier)
                engine.forgetSession(identifier: page.identifier)
            }
            let mirror = ForeignSiteCookieMirror(pageStore: page, spaceStore: space, ownSite: "github.com")
            await mirror.willNavigate(to: URL(string: "https://accounts.google.com/")!)
            await page.dataStore.httpCookieStore.setCookie(self.cookie("SID", "signed-in-in-popup"))
            await mirror.finish()
            let returned = self.values(await space.cookies(forSite: "google.com"))
            XCTAssertEqual(returned["SID"], "signed-in-in-popup")
        }
    }
}
