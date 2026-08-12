import XCTest

final class ChromeWebStoreLocatorTests: XCTestCase {

    private let ublockOriginLiteID = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    // MARK: - Current host, with a slug

    func test_extensionID_acceptsTheCurrentHostSlugPlusIDForm() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ublockOriginLiteID)"
        )
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    func test_extensionID_acceptsTheCurrentHostFormWithATrailingQueryString() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ublockOriginLiteID)?hl=en"
        )
        XCTAssertEqual(id, ublockOriginLiteID, "A trailing ?hl=en must not prevent the id from being read out of the path.")
    }

    func test_extensionID_acceptsTheCurrentHostFormWithATrailingRelatedSegment() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ublockOriginLiteID)/related"
        )
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    func test_extensionID_acceptsTheCurrentHostFormWithATrailingReviewsSegment() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(ublockOriginLiteID)/reviews"
        )
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    // MARK: - Current host, no slug (this is `detailURL(forExtensionID:)`'s own output shape)

    func test_extensionID_acceptsTheCurrentHostWithNoSlug() throws {
        let id = try ChromeWebStoreLocator.extensionID(from: "https://chromewebstore.google.com/detail/\(ublockOriginLiteID)")
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    // MARK: - Legacy host

    func test_extensionID_acceptsTheLegacyHostSlugPlusIDForm() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chrome.google.com/webstore/detail/ublock-origin-lite/\(ublockOriginLiteID)"
        )
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    func test_extensionID_acceptsTheLegacyHostWithNoSlug() throws {
        let id = try ChromeWebStoreLocator.extensionID(from: "https://chrome.google.com/webstore/detail/\(ublockOriginLiteID)")
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    func test_extensionID_acceptsTheLegacyHostFormWithATrailingQueryString() throws {
        let id = try ChromeWebStoreLocator.extensionID(
            from: "https://chrome.google.com/webstore/detail/ublock-origin-lite/\(ublockOriginLiteID)?hl=en-GB"
        )
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    // MARK: - Scheme-less paste

    func test_extensionID_acceptsAKnownHostURLWithNoScheme() throws {
        let id = try ChromeWebStoreLocator.extensionID(from: "chromewebstore.google.com/detail/ublock-origin-lite/\(ublockOriginLiteID)")
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    // MARK: - A bare id

    func test_extensionID_acceptsABareID() throws {
        let id = try ChromeWebStoreLocator.extensionID(from: ublockOriginLiteID)
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    func test_extensionID_trimsWhitespaceAroundABareID() throws {
        let id = try ChromeWebStoreLocator.extensionID(from: "  \(ublockOriginLiteID)  \n")
        XCTAssertEqual(id, ublockOriginLiteID)
    }

    // MARK: - Rejections: not a URL this file recognises

    func test_extensionID_rejectsANonWebStoreURL() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "https://example.com/detail/foo/\(ublockOriginLiteID)")
        ) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsEmptyInput() {
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: "")) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsWhitespaceOnlyInput() {
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: "   \n\t  ")) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsAWebStoreHostMissingTheDetailSegment() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "https://chromewebstore.google.com/category/extensions")
        ) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsTheLegacyHostMissingTheWebstoreSegment() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "https://chrome.google.com/detail/\(ublockOriginLiteID)")
        ) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsANonHTTPScheme() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "ftp://chromewebstore.google.com/detail/\(ublockOriginLiteID)")
        ) { error in
            guard case ChromeWebStoreError.unrecognizedInput = error else {
                return XCTFail("Expected .unrecognizedInput, got \(error)")
            }
        }
    }

    // MARK: - Rejections: looks like an id attempt, but isn't a valid one

    func test_extensionID_rejectsAUUID() {
        let uuid = UUID().uuidString
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: uuid)) { error in
            guard case ChromeWebStoreError.invalidExtensionID(let text) = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
            XCTAssertEqual(text, uuid)
        }
    }

    func test_extensionID_rejectsAnIDWithACharacterOutsideAThroughP() {
        let bad = String(ublockOriginLiteID.dropLast()) + "X"
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: bad)) { error in
            guard case ChromeWebStoreError.invalidExtensionID(let text) = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
            XCTAssertEqual(text, bad)
        }
    }

    func test_extensionID_rejectsATooShortID() {
        let short = String(ublockOriginLiteID.dropLast())
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: short)) { error in
            guard case ChromeWebStoreError.invalidExtensionID = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsATooLongID() {
        let long = ublockOriginLiteID + "a"
        XCTAssertThrowsError(try ChromeWebStoreLocator.extensionID(from: long)) { error in
            guard case ChromeWebStoreError.invalidExtensionID = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
        }
    }

    func test_extensionID_rejectsACurrentHostSingleSegmentThatIsNotAValidID() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "https://chromewebstore.google.com/detail/not-an-id")
        ) { error in
            guard case ChromeWebStoreError.invalidExtensionID(let text) = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
            XCTAssertEqual(text, "not-an-id")
        }
    }

    func test_extensionID_rejectsALegacyHostSlugPlusInvalidID() {
        XCTAssertThrowsError(
            try ChromeWebStoreLocator.extensionID(from: "https://chrome.google.com/webstore/detail/ublock-origin-lite/not-an-id")
        ) { error in
            guard case ChromeWebStoreError.invalidExtensionID(let text) = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
            XCTAssertEqual(text, "not-an-id")
        }
    }

    // MARK: - detailURL(forExtensionID:)

    func test_detailURL_buildsTheCurrentHostSlugLessDetailPage() throws {
        let url = try ChromeWebStoreLocator.detailURL(forExtensionID: ublockOriginLiteID)
        XCTAssertEqual(url.absoluteString, "https://chromewebstore.google.com/detail/\(ublockOriginLiteID)")
    }

    func test_detailURL_rejectsAnInvalidID() {
        XCTAssertThrowsError(try ChromeWebStoreLocator.detailURL(forExtensionID: "not-a-valid-id")) { error in
            guard case ChromeWebStoreError.invalidExtensionID(let text) = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
            XCTAssertEqual(text, "not-a-valid-id")
        }
    }

    func test_detailURLRoundTripsThroughExtensionID() throws {
        let url = try ChromeWebStoreLocator.detailURL(forExtensionID: ublockOriginLiteID)
        let roundTripped = try ChromeWebStoreLocator.extensionID(from: url.absoluteString)
        XCTAssertEqual(roundTripped, ublockOriginLiteID)
    }

    func test_detailURLRoundTripsForBoundaryAlphabetIDs() throws {
        for id in [String(repeating: "a", count: 32), String(repeating: "p", count: 32)] {
            let url = try ChromeWebStoreLocator.detailURL(forExtensionID: id)
            let roundTripped = try ChromeWebStoreLocator.extensionID(from: url.absoluteString)
            XCTAssertEqual(roundTripped, id)
        }
    }
}
