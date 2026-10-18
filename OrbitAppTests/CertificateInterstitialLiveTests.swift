//  The certificate interstitial driven against a real TLS origin Chromium
//  refuses; assertions are on browser behaviour (navigation, pixels, facts), not Swift bookkeeping.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class CertificateInterstitialLiveTests: XCTestCase {

    // The page the bad-certificate origin serves. #112233 is what the
    // compositor must actually paint once, and only once, the user proceeds.
    private static let securedPage = """
    <html><head><title>Orbit Cert Secured Page</title></head>\
    <body style="margin:0;background:#112233"></body></html>
    """

    private static let plainPage = """
    <html><head><title>Orbit Cert Plain Page</title></head>\
    <body style="margin:0;background:#227744"></body></html>
    """

    // MARK: - Interstitial facts

    func testExpiredSelfSignedCertificateShowsInterstitialCarryingTheRealCertificateFacts() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (problem: CertificateProblem, expectedIssuer: String, expectedSubject: String,
                   expectedNotAfter: Date, title: String, hadError: Bool) in
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }
            let fixture = try await Fixture.make(loading: server.baseURL)
            defer { fixture.tearDown() }

            let problem = try await Self.waitForInterstitial(fixture)
            // Read before answering: the point is that nothing loaded while
            // the question was open.
            let title = (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? ""
            let hadError = fixture.env.tabErrors[fixture.tabID] != nil
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: false)
            return (problem, server.certificate.issuerCommonName, server.certificate.subjectCommonName,
                    server.certificate.notAfter, title, hadError)
        }

        XCTAssertEqual(observed.problem.host, "127.0.0.1")
        XCTAssertEqual(observed.problem.issuer, observed.expectedIssuer, "interstitial issuer did not come from the served certificate")
        XCTAssertEqual(observed.problem.subject, observed.expectedSubject, "interstitial subject did not come from the served certificate")
        let validUntil = try XCTUnwrap(observed.problem.validUntil, "the interstitial was given no expiry to show")
        XCTAssertEqual(
            validUntil.timeIntervalSince1970, observed.expectedNotAfter.timeIntervalSince1970, accuracy: 1,
            "interstitial expiry did not come from the served certificate"
        )
        XCTAssertLessThan(validUntil, Date(), "the served certificate was supposed to be long expired")
        // The certificate is both untrusted and expired, so net:: has both
        // -202 (authority) and -201 (date) available and prefers the former; either is a genuine relay.
        XCTAssertTrue(
            [-202, -201].contains(observed.problem.errorCode),
            "expected a net:: certificate error code, got \(observed.problem.errorCode)"
        )
        XCTAssertEqual(
            observed.problem.reason,
            CertificateProblemReason.describe(errorCode: observed.problem.errorCode, engineName: ""),
            "the reason line did not come from the relayed error code"
        )
        XCTAssertTrue(observed.problem.isOverridable, "a plain untrusted-authority error is overridable")
        XCTAssertEqual(observed.title, "", "the blocked page committed while the interstitial was still open")
        XCTAssertFalse(observed.hadError, "the generic error page took over from the interstitial")
    }

    // MARK: - Proceed Anyway

    func testProceedAnywayActuallyLoadsAndPaintsThePage() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (title: String, red: Int, green: Int, blue: Int, problemCleared: Bool)? in
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }
            let fixture = try await Fixture.make(loading: server.baseURL)
            defer { fixture.tearDown() }

            _ = try await Self.waitForInterstitial(fixture)
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: true)
            try await Self.waitForTitle("Orbit Cert Secured Page", fixture)

            // capturePreview reads the compositor's latest surface, which can
            // lag one or two frames behind the DOM commit above.
            try await Task.sleep(for: .milliseconds(400))
            guard let image = await fixture.contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)),
                  let sample = ImagePixelSampler.sample(image)
            else { return nil }
            return (
                (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? "",
                sample.pixel.red,
                sample.pixel.green,
                sample.pixel.blue,
                fixture.env.certificateProblems[fixture.tabID] == nil
            )
        }

        let result = try XCTUnwrap(observed, "capturePreview returned nil, or its image could not be read back as a bitmap")
        XCTAssertEqual(result.title, "Orbit Cert Secured Page")
        XCTAssertTrue(result.problemCleared, "the interstitial stayed up over a page that had loaded")
        // #112233 == (17, 34, 51); a few units of tolerance for colour management.
        XCTAssertEqual(result.red, 17, accuracy: 12, "the proceeded-to page was not the one actually painted")
        XCTAssertEqual(result.green, 34, accuracy: 12, "the proceeded-to page was not the one actually painted")
        XCTAssertEqual(result.blue, 51, accuracy: 12, "the proceeded-to page was not the one actually painted")
    }

    // MARK: - The certificate behind the lock

    func testProceededPageExposesTheCertificateTheServerActuallyServed() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (certificate: SiteCertificate?, facts: LiveHTTPSTestServer.CertificateFacts, before: SiteCertificate?) in
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }
            let fixture = try await Fixture.make(loading: server.baseURL)
            defer { fixture.tearDown() }

            _ = try await Self.waitForInterstitial(fixture)
            let before = fixture.contents.currentCertificate()
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: true)
            try await Self.waitForTitle("Orbit Cert Secured Page", fixture)
            return (fixture.contents.currentCertificate(), server.certificate, before)
        }

        XCTAssertNil(observed.before, "no certificate belongs to a page that never loaded")
        let certificate = try XCTUnwrap(observed.certificate, "a page served over TLS reported no certificate")
        XCTAssertEqual(certificate.subject, observed.facts.subjectCommonName)
        XCTAssertEqual(certificate.issuer, observed.facts.issuerCommonName)
        XCTAssertEqual(
            try XCTUnwrap(certificate.validUntil).timeIntervalSince1970, observed.facts.notAfter.timeIntervalSince1970, accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(certificate.validFrom).timeIntervalSince1970, observed.facts.notBefore.timeIntervalSince1970, accuracy: 1
        )
        let serial = try XCTUnwrap(certificate.serialNumber)
        XCTAssertFalse(serial.isEmpty)
        XCTAssertNotNil(serial.range(of: "^[0-9A-F]+$", options: .regularExpression), "the serial must be upper-case hex, got \(serial)")
    }

    func testAPlainHTTPPageHasNoCertificate() throws {
        let certificate = try WebKitLiveEngineHost.runLive(timeout: 60) { () -> SiteCertificate? in
            let plain = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.plainPage),
            ])
            defer { plain.stop() }
            let fixture = try await Fixture.make(loading: plain.baseURL)
            defer { fixture.tearDown() }
            try await Self.waitForTitle("Orbit Cert Plain Page", fixture)
            return fixture.contents.currentCertificate()
        }
        XCTAssertNil(certificate)
    }

    func testARefusedCertificateIsNotAskedAgainForTheSameNavigation() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> (stillShowing: Bool, askedAgain: Bool) in
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }
            let fixture = try await Fixture.make(loading: server.baseURL)
            defer { fixture.tearDown() }

            _ = try await Self.waitForInterstitial(fixture)
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: false)
            // WebKit repeats a failed trust challenge; the refusal has to stand for the whole navigation.
            try await Task.sleep(for: .seconds(3))
            return (fixture.env.certificateProblems[fixture.tabID] != nil, fixture.env.pendingCertificateDecisions[fixture.tabID] != nil)
        }
        XCTAssertFalse(observed.stillShowing, "the interstitial reopened after the user refused")
        XCTAssertFalse(observed.askedAgain, "a second decision was queued for the navigation the user already refused")
    }

    // MARK: - Go Back

    func testGoBackReturnsToThePreviousPageAndNeverLoadsTheBlockedOne() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (title: String, red: Int, green: Int, blue: Int, problemCleared: Bool, hadError: Bool)? in
            let plain = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.plainPage),
            ])
            defer { plain.stop() }
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }

            let fixture = try await Fixture.make(loading: plain.baseURL)
            defer { fixture.tearDown() }
            try await Self.waitForTitle("Orbit Cert Plain Page", fixture)

            fixture.contents.load(server.baseURL)
            _ = try await Self.waitForInterstitial(fixture)
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: false)

            try await Self.waitForTitle("Orbit Cert Plain Page", fixture)
            try await Task.sleep(for: .milliseconds(400))
            guard let image = await fixture.contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)),
                  let sample = ImagePixelSampler.sample(image)
            else { return nil }
            return (
                (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? "",
                sample.pixel.red,
                sample.pixel.green,
                sample.pixel.blue,
                fixture.env.certificateProblems[fixture.tabID] == nil,
                fixture.env.tabErrors[fixture.tabID] != nil
            )
        }

        let result = try XCTUnwrap(observed, "capturePreview returned nil, or its image could not be read back as a bitmap")
        XCTAssertEqual(result.title, "Orbit Cert Plain Page", "Go Back did not return to the previous page")
        XCTAssertTrue(result.problemCleared)
        XCTAssertFalse(result.hadError, "the refused navigation left a generic error page behind")
        // #227744 == (34, 119, 68).
        XCTAssertEqual(result.red, 34, accuracy: 12, "the previous page was not the one actually painted after Go Back")
        XCTAssertEqual(result.green, 119, accuracy: 12, "the previous page was not the one actually painted after Go Back")
        XCTAssertEqual(result.blue, 68, accuracy: 12, "the previous page was not the one actually painted after Go Back")
    }

    // MARK: - Subresources

    func testSubresourceCertificateErrorIsBlockedWithNoInterstitial() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (fetchFailed: Bool, fetchSucceeded: Bool, sawInterstitial: Bool, mainFrameTitle: String) in
            let server = try LiveHTTPSTestServer(routes: ["/sub": .init(contentType: "text/plain", body: "subresource")])
            defer { server.stop() }
            let page = """
            <html><head><title>Orbit Cert Plain Page</title></head><body style="margin:0;background:#227744">
            <script>
            window.__orbitSubFailed = false;
            window.__orbitSubSucceeded = false;
            fetch("\(server.baseURL.absoluteString)/sub")
              .then(function (r) { return r.text(); })
              .then(function () { window.__orbitSubSucceeded = true; })
              .catch(function () { window.__orbitSubFailed = true; });
            </script></body></html>
            """
            let plain = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: page),
            ])
            defer { plain.stop() }

            let fixture = try await Fixture.make(loading: plain.baseURL)
            defer { fixture.tearDown() }
            try await Self.waitForTitle("Orbit Cert Plain Page", fixture)

            // The interstitial would appear within this window if it were
            // going to: it takes well under a second on the main-frame tests above.
            var sawInterstitial = false
            let deadline = ContinuousClock.now + .seconds(8)
            var fetchFailed = false
            var fetchSucceeded = false
            while ContinuousClock.now < deadline {
                if fixture.env.certificateProblems[fixture.tabID] != nil { sawInterstitial = true; break }
                fetchFailed = ((try? await fixture.contents.evaluateJavaScript("window.__orbitSubFailed")) as? Bool) ?? false
                fetchSucceeded = ((try? await fixture.contents.evaluateJavaScript("window.__orbitSubSucceeded")) as? Bool) ?? false
                if fetchFailed || fetchSucceeded { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let title = (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? ""
            if sawInterstitial { fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: false) }
            return (fetchFailed, fetchSucceeded, sawInterstitial, title)
        }

        XCTAssertFalse(observed.sawInterstitial, "a subresource certificate error must never be offered as a user decision")
        XCTAssertTrue(observed.fetchFailed, "the subresource over a bad certificate was not blocked")
        XCTAssertFalse(observed.fetchSucceeded, "the subresource over a bad certificate loaded anyway")
        XCTAssertEqual(observed.mainFrameTitle, "Orbit Cert Plain Page", "the main frame should be unaffected")
    }

    // MARK: - Fail closed

    func testUnansweredCertificateDecisionLeavesTheNavigationBlocked() throws {
        let observed = try WebKitLiveEngineHost.runLive(timeout: 90) {
            () -> (titleWhileUnanswered: String, stillPending: Bool, titleAfterTabDied: String, committedAfterDeath: Bool) in
            let server = try LiveHTTPSTestServer(routes: ["/": .init(body: Self.securedPage)])
            defer { server.stop() }
            let fixture = try await Fixture.make(loading: server.baseURL)
            defer { fixture.tearDown() }

            _ = try await Self.waitForInterstitial(fixture)
            // Answer nothing at all for long enough that any "eventually
            // proceeds" behaviour would have shown itself.
            try await Task.sleep(for: .seconds(5))
            let titleWhileUnanswered = (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? ""
            let stillPending = fixture.env.pendingCertificateDecisions[fixture.tabID] != nil

            // The tab dies with the question still open; a late "proceed"
            // arriving afterwards must reach nothing.
            fixture.contents.close()
            fixture.env.resolveCertificateDecision(for: fixture.tabID, proceed: true)
            try await Task.sleep(for: .milliseconds(500))
            let titleAfterTabDied = (try? await fixture.contents.evaluateJavaScript("document.title")) as? String ?? ""
            return (titleWhileUnanswered, stillPending, titleAfterTabDied,
                    fixture.contents.navigationState.title == "Orbit Cert Secured Page")
        }

        XCTAssertEqual(observed.titleWhileUnanswered, "", "the blocked navigation proceeded without an answer")
        XCTAssertTrue(observed.stillPending, "the decision resolved itself instead of waiting for the user")
        XCTAssertEqual(observed.titleAfterTabDied, "", "the blocked page loaded after the tab was destroyed")
        XCTAssertFalse(observed.committedAfterDeath, "a late proceed reached a destroyed tab")
    }

    // MARK: - Fixture

    private struct Fixture {
        var env: AppEnvironment
        var contents: WebKitWebContents
        var tabID: TabID
        var window: NSWindow

        static func make(loading url: URL) async throws -> Fixture {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            let window = NSWindow(
                contentRect: contents.view.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = contents.view
            window.orderFront(nil)

            let env = AppEnvironment.demo
            let spaceID = env.state.spaces.first?.id
                ?? env.createSpace(
                    name: "Certificate Test Space", icon: "circle", iconIsEmoji: false,
                    theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded()
                )
            let tab = Tab(spaceID: spaceID, section: .today, url: url, title: "")
            env.state.tabs[tab.id] = tab
            env._test_attachWebContents(contents, for: tab.id)
            contents.delegate = env

            contents.load(url)
            return Fixture(env: env, contents: contents, tabID: tab.id, window: window)
        }

        func tearDown() {
            window.orderOut(nil)
            // Resumed, never dropped: an abandoned continuation would strand
            // its task and the engine would still be waiting on an answer.
            if env.pendingCertificateDecisions[tabID] != nil {
                env.resolveCertificateDecision(for: tabID, proceed: false)
            }
            env._test_detachWebContents(for: tabID)
            env.state.tabs.removeValue(forKey: tabID)
            contents.close()
        }
    }

    private static func waitForInterstitial(
        _ fixture: Fixture,
        timeout: Duration = .seconds(20)
    ) async throws -> CertificateProblem {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let problem = fixture.env.certificateProblems[fixture.tabID] { return problem }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw EngineError(
            code: .engineUnavailable,
            underlyingDescription: "no certificate interstitial appeared; tabError=\(String(describing: fixture.env.tabErrors[fixture.tabID]))"
        )
    }

    private static func waitForTitle(
        _ expected: String,
        _ fixture: Fixture,
        timeout: Duration = .seconds(20)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if ((try? await fixture.contents.evaluateJavaScript("document.title")) as? String) == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EngineError(code: .engineUnavailable, underlyingDescription: "document.title never became \(expected.debugDescription)")
    }
}
