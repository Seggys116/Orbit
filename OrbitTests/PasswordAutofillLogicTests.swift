import CoreGraphics
import XCTest

// The Foundation-only decisions behind password autofill (Orbit/Features/Passwords/PasswordAutofillLogic.swift):
// what a page message may claim, whether a frame may be filled, what is offered, what a sign-in leads to, and where a field lands on screen.

nonisolated private func url(_ string: String) -> URL { URL(string: string)! }

final class PasswordAutofillOriginTests: XCTestCase {

    func testOriginKeepsTheSchemeHostAndNonDefaultPort() {
        XCTAssertEqual(PasswordAutofillPolicy.origin(scheme: "https", host: "Example.COM", port: 0)?.absoluteString, "https://example.com")
        XCTAssertEqual(PasswordAutofillPolicy.origin(scheme: "https", host: "example.com", port: 443)?.absoluteString, "https://example.com")
        XCTAssertEqual(PasswordAutofillPolicy.origin(scheme: "http", host: "localhost", port: 8080)?.absoluteString, "http://localhost:8080")
    }

    func testOriginIsNilForAnythingButHTTPAndHTTPS() {
        XCTAssertNil(PasswordAutofillPolicy.origin(scheme: "file", host: "example.com", port: 0))
        XCTAssertNil(PasswordAutofillPolicy.origin(scheme: "orbit", host: "newtab", port: 0))
        XCTAssertNil(PasswordAutofillPolicy.origin(scheme: "chrome-extension", host: "abcdef", port: 0))
        XCTAssertNil(PasswordAutofillPolicy.origin(scheme: "https", host: "", port: 0))
    }

    func testTokensAreAlphanumericAndBounded() {
        XCTAssertTrue(PasswordAutofillPolicy.isValidToken("f0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken("short"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken(String(repeating: "a", count: 65)))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken("has space inside"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken("quote'injected;alert(1)"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken(42))
        XCTAssertFalse(PasswordAutofillPolicy.isValidToken(nil))
    }

    func testRectAcceptsOnlyFinitePositiveBoxes() {
        let good: [String: Any] = ["x": 10, "y": 20.5, "w": 200, "h": 30]
        XCTAssertEqual(PasswordAutofillPolicy.rect(from: good), CGRect(x: 10, y: 20.5, width: 200, height: 30))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: ["x": 10, "y": 20, "w": 0, "h": 30]))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: ["x": 10, "y": 20, "w": 200]))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: ["x": Double.nan, "y": 20, "w": 200, "h": 30]))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: ["x": 1e12, "y": 20, "w": 200, "h": 30]))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: ["x": "10", "y": 20, "w": 200, "h": 30] as [String: Any]))
        XCTAssertNil(PasswordAutofillPolicy.rect(from: "not a rect"))
    }

    func testBoundedStringRefusesAnOverlongOrNonStringValue() {
        XCTAssertEqual(PasswordAutofillPolicy.boundedString("abc", limit: 3), "abc")
        XCTAssertNil(PasswordAutofillPolicy.boundedString("abcd", limit: 3))
        XCTAssertNil(PasswordAutofillPolicy.boundedString(12, limit: 3))
    }

    func testKindParsingRejectsUnknownNames() {
        XCTAssertEqual(PasswordAutofillPolicy.kind(from: "username"), .username)
        XCTAssertEqual(PasswordAutofillPolicy.kind(from: "currentPassword"), .currentPassword)
        XCTAssertEqual(PasswordAutofillPolicy.kind(from: "newPassword"), .newPassword)
        XCTAssertEqual(PasswordAutofillPolicy.kind(from: "oneTimeCode"), .oneTimeCode)
        XCTAssertNil(PasswordAutofillPolicy.kind(from: "otp"))
        XCTAssertNil(PasswordAutofillPolicy.kind(from: nil))
    }

    func testAOneTimeCodeIsShortAndOnlyLettersAndDigits() {
        XCTAssertTrue(PasswordAutofillPolicy.isValidOneTimeCode("123456"))
        XCTAssertTrue(PasswordAutofillPolicy.isValidOneTimeCode("AB12CD"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidOneTimeCode(""))
        XCTAssertFalse(PasswordAutofillPolicy.isValidOneTimeCode("12 34"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidOneTimeCode("1234'; alert(1)"))
        XCTAssertFalse(PasswordAutofillPolicy.isValidOneTimeCode("\u{0661}\u{0662}\u{0663}"), "digits outside ASCII are refused")
        XCTAssertFalse(PasswordAutofillPolicy.isValidOneTimeCode(String(repeating: "1", count: PasswordAutofillPolicy.maxOneTimeCodeLength + 1)))
    }
}

final class PasswordAutofillFillPolicyTests: XCTestCase {

    func testHTTPSAndLocalHTTPAreSecureForFilling() {
        XCTAssertTrue(PasswordAutofillPolicy.isSecureForFill(origin: url("https://example.com")))
        XCTAssertTrue(PasswordAutofillPolicy.isSecureForFill(origin: url("http://localhost:3000")))
        XCTAssertTrue(PasswordAutofillPolicy.isSecureForFill(origin: url("http://127.0.0.1:8080")))
        XCTAssertTrue(PasswordAutofillPolicy.isSecureForFill(origin: url("http://[::1]:8080")))
    }

    func testPlainHTTPElsewhereIsNotSecure() {
        XCTAssertFalse(PasswordAutofillPolicy.isSecureForFill(origin: url("http://example.com")))
        XCTAssertFalse(PasswordAutofillPolicy.isSecureForFill(origin: url("http://192.168.1.1")))
        XCTAssertFalse(PasswordAutofillPolicy.isSecureForFill(origin: url("http://localhost.example.com")))
        XCTAssertFalse(PasswordAutofillPolicy.isSecureForFill(origin: url("file:///tmp/login.html")))
    }

    func testAFrameOfAnotherSiteIsRefused() {
        let refusal = PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("https://evil.test"))
        XCTAssertEqual(refusal, .refusedSiteMismatch)
    }

    func testALookAlikeDomainIsAnotherSite() {
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("https://example.com.evil.test")),
            .refusedSiteMismatch
        )
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("https://notexample.com")),
            .refusedSiteMismatch
        )
    }

    func testATenantOfASharedSuffixIsAnotherSite() {
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://alice.github.io"), frameOrigin: url("https://evil.github.io")),
            .refusedSiteMismatch
        )
    }

    func testAnotherOriginOfTheSameSiteIsAllowed() {
        XCTAssertNil(PasswordAutofillPolicy.refusal(
            credentialOrigin: url("https://example.com"), frameOrigin: url("https://accounts.example.com")
        ))
    }

    func testAnHTTPSLoginIsNeverFilledIntoAnHTTPFrame() {
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("http://example.com")),
            .refusedInsecure
        )
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("http://www.example.com:8080")),
            .refusedInsecure
        )
    }

    func testAnHTTPSLoginIsNotFilledIntoLocalhostOverHTTPEither() {
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://localhost:8443"), frameOrigin: url("http://localhost:3000")),
            .refusedInsecure
        )
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://127.0.0.1:8443"), frameOrigin: url("http://127.0.0.1:3000")),
            .refusedInsecure
        )
    }

    func testAnHTTPLoginMayGoIntoAnHTTPFrameOfItsSiteOrIntoAnHTTPSOne() {
        XCTAssertNil(PasswordAutofillPolicy.refusal(credentialOrigin: url("http://example.com"), frameOrigin: url("http://example.com")))
        XCTAssertNil(PasswordAutofillPolicy.refusal(credentialOrigin: url("http://localhost:3000"), frameOrigin: url("http://localhost:4000")))
        XCTAssertNil(PasswordAutofillPolicy.refusal(credentialOrigin: url("http://example.com"), frameOrigin: url("https://example.com")))
    }

    func testTheSchemeRuleNeverOverridesASiteMismatch() {
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("http://example.com"), frameOrigin: url("http://evil.test")),
            .refusedSiteMismatch
        )
        XCTAssertEqual(
            PasswordAutofillPolicy.refusal(credentialOrigin: url("https://example.com"), frameOrigin: url("http://evil.test")),
            .refusedSiteMismatch
        )
    }

    func testCredentialsDeriveTheirSiteKeyFromTheirOrigin() {
        XCTAssertEqual(PasswordFillCredentials(origin: url("https://accounts.example.co.uk"), username: "a", password: "b").siteKey, "example.co.uk")
        XCTAssertEqual(PasswordFillCredentials(origin: url("http://127.0.0.1:8080"), username: "a", password: "b").siteKey, "127.0.0.1")
    }

    func testOnlyAnActualFillCountsAsFilled() {
        XCTAssertTrue(PasswordFillOutcome.filled(username: true, password: false).didFill)
        XCTAssertTrue(PasswordFillOutcome.filled(username: false, password: true).didFill)
        XCTAssertFalse(PasswordFillOutcome.filled(username: false, password: false).didFill)
        XCTAssertFalse(PasswordFillOutcome.refusedSiteMismatch.didFill)
        XCTAssertFalse(PasswordFillOutcome.unsupported.didFill)
    }
}

final class PasswordAutofillOfferTests: XCTestCase {

    func testLoginsAreOfferedOnlyOnSignInFieldsOfASecureFrame() {
        for kind in [PasswordFieldKind.username, .currentPassword] {
            XCTAssertTrue(PasswordAutofillPolicy.offersLogins(kind: kind, frameOrigin: url("https://example.com")))
            XCTAssertTrue(PasswordAutofillPolicy.offersLogins(kind: kind, frameOrigin: url("http://localhost:3000")), "http on this Mac is secure")
            XCTAssertFalse(PasswordAutofillPolicy.offersLogins(kind: kind, frameOrigin: url("http://example.com")), "never on a plain http page")
        }
        XCTAssertFalse(PasswordAutofillPolicy.offersLogins(kind: .newPassword, frameOrigin: url("https://example.com")))
        XCTAssertFalse(PasswordAutofillPolicy.offersLogins(kind: .oneTimeCode, frameOrigin: url("https://example.com")))
    }

    func testOneTimeCodesAreOfferedOnlyOnACodeFieldOfASecureFrame() {
        XCTAssertTrue(PasswordAutofillPolicy.offersOneTimeCodes(kind: .oneTimeCode, frameOrigin: url("https://example.com")))
        XCTAssertFalse(PasswordAutofillPolicy.offersOneTimeCodes(kind: .oneTimeCode, frameOrigin: url("http://example.com")))
        XCTAssertFalse(PasswordAutofillPolicy.offersOneTimeCodes(kind: .username, frameOrigin: url("https://example.com")))
    }
}

final class PasswordAutofillMultiStepTests: XCTestCase {

    private let origin = url("https://example.com")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAUsernameOnlyStepIsRememberedAndNeverASubmission() {
        XCTAssertNil(PasswordAutofillPolicy.mergedSubmission(
            origin: origin, username: "alice", password: "", isNewPassword: false, step: .username, memory: nil, now: now
        ))
        let memory = PasswordAutofillPolicy.stepMemory(origin: origin, username: "  alice ", now: now)
        XCTAssertEqual(memory?.username, "alice")
        XCTAssertEqual(memory?.siteKey, "example.com")
    }

    func testAnEmptyUsernameStepRemembersNothing() {
        XCTAssertNil(PasswordAutofillPolicy.stepMemory(origin: origin, username: "   ", now: now))
    }

    func testAPasswordOnlyStepBorrowsTheRememberedUsername() {
        let memory = PasswordAutofillPolicy.stepMemory(origin: origin, username: "alice", now: now)
        let submission = PasswordAutofillPolicy.mergedSubmission(
            origin: url("https://accounts.example.com"), username: "", password: "s3cret", isNewPassword: false,
            step: .password, memory: memory, now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(submission?.username, "alice")
        XCTAssertEqual(submission?.password, "s3cret")
    }

    func testAStaleOrForeignMemoryIsNotBorrowed() {
        let memory = PasswordAutofillPolicy.stepMemory(origin: origin, username: "alice", now: now)
        let stale = PasswordAutofillPolicy.mergedSubmission(
            origin: origin, username: "", password: "pw", isNewPassword: false, step: .password,
            memory: memory, now: now.addingTimeInterval(PasswordAutofillPolicy.stepLifetime + 1)
        )
        XCTAssertEqual(stale?.username, "")
        let foreign = PasswordAutofillPolicy.mergedSubmission(
            origin: url("https://other.test"), username: "", password: "pw", isNewPassword: false, step: .password,
            memory: memory, now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(foreign?.username, "")
    }

    func testAFullStepKeepsTheTypedUsernameAndNeedsAPassword() {
        let kept = PasswordAutofillPolicy.mergedSubmission(
            origin: origin, username: " bob ", password: "pw", isNewPassword: true, step: .full, memory: nil, now: now
        )
        XCTAssertEqual(kept?.username, "bob")
        XCTAssertEqual(kept?.isNewPassword, true)
        XCTAssertNil(PasswordAutofillPolicy.mergedSubmission(
            origin: origin, username: "bob", password: "", isNewPassword: false, step: .full, memory: nil, now: now
        ))
    }

    func testAPreferredUsernameIsOnlyOfferedOnTheSameSiteInTime() {
        let memory = PasswordAutofillPolicy.stepMemory(origin: origin, username: "alice", now: now)
        XCTAssertEqual(PasswordAutofillPolicy.preferredUsername(for: url("https://login.example.com"), memory: memory, now: now), "alice")
        XCTAssertNil(PasswordAutofillPolicy.preferredUsername(for: url("https://other.test"), memory: memory, now: now))
        XCTAssertNil(PasswordAutofillPolicy.preferredUsername(for: origin, memory: nil, now: now))
    }
}

final class PasswordAutofillPromptWordingTests: XCTestCase {

    func testThePromptNamesTheOriginItIsAbout() {
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("https://example.com"), "example.com")
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("https://www.example.com"), "www.example.com")
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("https://accounts.example.com:8443"), "accounts.example.com:8443")
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("https://example.com:443"), "example.com")
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("http://localhost:3000"), "localhost:3000")
        XCTAssertEqual(PasswordAutofillPolicy.displayOrigin("not an origin"), "not an origin")
    }

    func testASubmissionNeverDescribesItsPassword() {
        let submission = PasswordSubmission(origin: url("https://example.com"), username: "alice", password: "hunter2-secret", isNewPassword: false)
        XCTAssertFalse(String(describing: submission).contains("hunter2-secret"))
        let credentials = PasswordFillCredentials(origin: url("https://example.com"), username: "alice", password: "hunter2-secret")
        XCTAssertFalse(String(describing: credentials).contains("hunter2-secret"))
    }
}

final class PasswordFieldGeometryTests: XCTestCase {

    /// A 1000 x 600 point page view whose bottom-left corner is at (100, 50) on screen.
    private let view = CGRect(x: 100, y: 50, width: 1000, height: 600)

    func testAFieldAtTheTopLeftOfThePageSitsAtTheTopLeftOfTheView() throws {
        let rect = try XCTUnwrap(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 0, y: 0, width: 200, height: 30), zoom: 1, viewFrameOnScreen: view
        ))
        XCTAssertEqual(rect, CGRect(x: 100, y: 620, width: 200, height: 30))
    }

    func testPageOffsetAndSizeScaleWithThePageZoom() throws {
        let rect = try XCTUnwrap(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 40, y: 100, width: 200, height: 30), zoom: 1.5, viewFrameOnScreen: view
        ))
        XCTAssertEqual(rect.minX, 100 + 40 * 1.5, accuracy: 0.001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rect.height, 45, accuracy: 0.001)
        // Top edge is 100 CSS pixels (150 points) below the view's top, which is y = 650.
        XCTAssertEqual(rect.maxY, 650 - 150, accuracy: 0.001)
    }

    func testAZoomedOutPageShrinksTheField() throws {
        let rect = try XCTUnwrap(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 100, y: 100, width: 200, height: 40), zoom: 0.5, viewFrameOnScreen: view
        ))
        XCTAssertEqual(rect, CGRect(x: 150, y: 580, width: 100, height: 20))
    }

    func testAScrolledPageIsAlreadyInTheViewportBoxItGets() throws {
        // The page reports the box relative to the visible viewport, so a field scrolled 400 px up and still partly showing has a negative y.
        let rect = try XCTUnwrap(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 10, y: -10, width: 200, height: 30), zoom: 1, viewFrameOnScreen: view
        ))
        XCTAssertEqual(rect.maxY, 660, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 630, accuracy: 0.001)
    }

    func testAFieldWhollyOutsideTheViewHasNoScreenRect() {
        XCTAssertNil(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 10, y: -100, width: 200, height: 30), zoom: 1, viewFrameOnScreen: view
        ))
        XCTAssertNil(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 10, y: 700, width: 200, height: 30), zoom: 1, viewFrameOnScreen: view
        ))
        XCTAssertNil(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 1200, y: 10, width: 200, height: 30), zoom: 1, viewFrameOnScreen: view
        ))
    }

    func testANonsenseZoomFallsBackToOne() throws {
        let rect = try XCTUnwrap(PasswordFieldGeometry.screenRect(
            cssRect: CGRect(x: 0, y: 0, width: 200, height: 30), zoom: 0, viewFrameOnScreen: view
        ))
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
    }
}
