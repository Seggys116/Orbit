import Foundation
import XCTest

final class LinkPreviewFetcherSchemeAndResponseTests: XCTestCase {

    func test_validateScheme_acceptsHTTPAndHTTPS() throws {
        XCTAssertNoThrow(try LinkPreviewFetcher.validateScheme(URL(string: "https://example.com")!))
        XCTAssertNoThrow(try LinkPreviewFetcher.validateScheme(URL(string: "http://example.com")!))
    }

    func test_validateScheme_refusesEveryOtherScheme() {
        for urlString in ["file:///etc/passwd", "mailto:a@example.com", "orbit://new-tab", "ftp://example.com/x"] {
            let url = URL(string: urlString)!
            XCTAssertThrowsError(try LinkPreviewFetcher.validateScheme(url)) { error in
                XCTAssertEqual(error as? LinkPreviewFetchError, .unsupportedScheme, "\(urlString) must be refused")
            }
        }
    }

    private func response(status: Int, contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPURLResponse(
            url: URL(string: "https://example.com/a")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func test_validateResponse_acceptsA200WithAnHTMLContentType() throws {
        XCTAssertNoThrow(try LinkPreviewFetcher.validateResponse(response(status: 200, contentType: "text/html; charset=utf-8")))
    }

    func test_validateResponse_refusesANonSuccessStatus() {
        XCTAssertThrowsError(try LinkPreviewFetcher.validateResponse(response(status: 404, contentType: "text/html"))) { error in
            XCTAssertEqual(error as? LinkPreviewFetchError, .http(status: 404))
        }
    }

    func test_validateResponse_refusesANonHTMLContentType() {
        XCTAssertThrowsError(try LinkPreviewFetcher.validateResponse(response(status: 200, contentType: "application/pdf"))) { error in
            XCTAssertEqual(error as? LinkPreviewFetchError, .unsupportedContentType("application/pdf"))
        }
    }

    func test_validateResponse_refusesAMissingContentType() {
        XCTAssertThrowsError(try LinkPreviewFetcher.validateResponse(response(status: 200, contentType: nil))) { error in
            XCTAssertEqual(error as? LinkPreviewFetchError, .unsupportedContentType("(none)"))
        }
    }
}

final class LinkPreviewFetcherImageExtractionTests: XCTestCase {

    private let pageURL = URL(string: "https://ourescapeclause.com/things-to-do-in-oaxaca")!

    func test_extractImageURL_readsAnAbsoluteOGImage() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://ourescapeclause.com/images/oaxaca-hero.jpg">
        </head></html>
        """
        XCTAssertEqual(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            URL(string: "https://ourescapeclause.com/images/oaxaca-hero.jpg")
        )
    }

    func test_extractImageURL_resolvesARootRelativePathAgainstThePageURL() {
        let html = #"<meta property="og:image" content="/images/oaxaca-hero.jpg">"#
        XCTAssertEqual(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            URL(string: "https://ourescapeclause.com/images/oaxaca-hero.jpg")
        )
    }

    func test_extractImageURL_handlesBothAttributeOrdersAndBothQuoteStyles() {
        let contentFirst = #"<meta content='/images/oaxaca-hero.jpg' property='og:image'>"#
        XCTAssertEqual(
            LinkPreviewFetcher.extractImageURL(fromHTML: contentFirst, pageURL: pageURL),
            URL(string: "https://ourescapeclause.com/images/oaxaca-hero.jpg")
        )
    }

    func test_extractImageURL_fallsBackToTwitterImageWhenOGImageIsAbsent() {
        let html = #"<meta name="twitter:image" content="https://cdn.example.com/oaxaca.jpg">"#
        XCTAssertEqual(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            URL(string: "https://cdn.example.com/oaxaca.jpg")
        )
    }

    func test_extractImageURL_prefersOGImageOverTwitterImageWhenBothArePresent() {
        let html = """
        <meta property="og:image" content="https://example.com/og.jpg">
        <meta name="twitter:image" content="https://example.com/twitter.jpg">
        """
        XCTAssertEqual(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            URL(string: "https://example.com/og.jpg")
        )
    }

    func test_extractImageURL_isNilWhenNeitherIsPresent_neverGuessesAFavicon() {
        let html = """
        <html><head>
        <link rel="icon" href="/favicon.ico">
        <meta property="og:title" content="A Page With No Image">
        </head></html>
        """
        XCTAssertNil(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            "A missing og:image must never be papered over with a favicon or a placeholder"
        )
    }

    func test_extractImageURL_isNilForAnUnparseableValue() {
        let html = #"<meta property="og:image" content="not a url at all with spaces and no scheme \\ | >">"#
        XCTAssertNil(
            LinkPreviewFetcher.extractImageURL(fromHTML: html, pageURL: pageURL),
            "A <meta> whose content attribute never closes must yield no image URL, not a resolved one built from the truncated tag"
        )
    }
}

final class LinkPreviewFetcherTitleAndDescriptionTests: XCTestCase {

    func test_extractTitle_prefersOGTitle() {
        let html = """
        <title>Fallback Title</title>
        <meta property="og:title" content="13 Out-Of-This-World Things to Do in Oaxaca">
        """
        XCTAssertEqual(LinkPreviewFetcher.extractTitle(fromHTML: html), "13 Out-Of-This-World Things to Do in Oaxaca")
    }

    func test_extractTitle_fallsBackToTheDocumentTitleTag() {
        let html = "<html><head><title>Plain Document Title</title></head></html>"
        XCTAssertEqual(LinkPreviewFetcher.extractTitle(fromHTML: html), "Plain Document Title")
    }

    func test_extractTitle_isNilWithNeitherPresent() {
        XCTAssertNil(LinkPreviewFetcher.extractTitle(fromHTML: "<html><body>no title anywhere</body></html>"))
    }

    func test_extractDescription_readsOGDescriptionOnly_noNameDescriptionFallback() {
        let html = """
        <meta name="description" content="Generic SEO boilerplate nobody wrote for a reader.">
        """
        XCTAssertNil(
            LinkPreviewFetcher.extractDescription(fromHTML: html),
            "A bare meta description is not trusted as og:description's fallback — see this file's own header"
        )
    }

    func test_extractDescription_readsOGDescriptionWhenPresent() {
        let html = #"<meta property="og:description" content="Delicious food, colorful streets, and ruins.">"#
        XCTAssertEqual(LinkPreviewFetcher.extractDescription(fromHTML: html), "Delicious food, colorful streets, and ruins.")
    }
}

final class LinkPreviewFetcherReadableTextTests: XCTestCase {

    func test_readableText_stripsScriptAndStyleWithTheirContents() {
        let html = """
        <html><head><style>.hero { color: red; }</style></head>
        <body>
        <script>trackVisit({secret: "leak-me"});</script>
        <p>Visible paragraph text.</p>
        </body></html>
        """
        let text = LinkPreviewFetcher.readableText(fromHTML: html)
        XCTAssertTrue(text.contains("Visible paragraph text."))
        XCTAssertFalse(text.contains("leak-me"), "A <script> body must never reach the text sent to a model")
        XCTAssertFalse(text.contains("color: red"))
    }

    func test_readableText_stripsHTMLComments() {
        let html = "<p>Before.</p><!-- an internal editorial note --><p>After.</p>"
        let text = LinkPreviewFetcher.readableText(fromHTML: html)
        XCTAssertFalse(text.contains("editorial note"))
        XCTAssertTrue(text.contains("Before."))
        XCTAssertTrue(text.contains("After."))
    }

    func test_readableText_stripsRemainingTagsButKeepsTheirText() {
        let html = "<div><h1>Oaxaca</h1><p>City in <em>southern</em> Mexico.</p></div>"
        let text = LinkPreviewFetcher.readableText(fromHTML: html)
        XCTAssertFalse(text.contains("<"))
        XCTAssertTrue(text.contains("Oaxaca"))
        XCTAssertTrue(text.contains("City in southern Mexico."))
    }

    func test_readableText_decodesNamedAndNumericEntities() {
        let html = "<p>Mezcal &amp; Mole &mdash; a chef&#39;s tasting at caf&#233;.</p>"
        let text = LinkPreviewFetcher.readableText(fromHTML: html)
        XCTAssertTrue(text.contains("Mezcal & Mole"))
        XCTAssertTrue(text.contains("\u{2014}"), "&mdash; must decode to an em dash")
        XCTAssertTrue(text.contains("chef's"))
        XCTAssertTrue(text.contains("café"))
    }

    func test_readableText_doesNotDoubleDecodeADoubleEncodedAmpersand() {
        let text = LinkPreviewFetcher.decodeHTMLEntities("Ships &amp;lt; 5 tons")
        XCTAssertEqual(text, "Ships &lt; 5 tons")
    }

    func test_readableText_collapsesWhitespaceAndNewlines() {
        let html = "<p>Line one.\n\n\n   Line   two.</p>"
        let text = LinkPreviewFetcher.readableText(fromHTML: html)
        XCTAssertEqual(text, "Line one. Line two.")
    }

    func test_truncate_recordsTheUntruncatedTotalAlongsideTheCutText() {
        let long = String(repeating: "a", count: 1_000)
        let (cut, total) = LinkPreviewFetcher.truncate(long, budget: 400)
        XCTAssertEqual(cut.count, 400)
        XCTAssertEqual(total, 1_000)
    }

    func test_truncate_leavesShortTextUntouched() {
        let (text, total) = LinkPreviewFetcher.truncate("short", budget: 400)
        XCTAssertEqual(text, "short")
        XCTAssertEqual(total, 5)
    }

    func test_metaContent_handlesBothAttributeOrdersAndBothQuoteStyles() {
        let propertyFirstDoubleQuoted = #"<meta property="og:title" content="A Title">"#
        let contentFirstSingleQuoted = #"<meta content='A Title' property='og:title'>"#
        XCTAssertEqual(LinkPreviewFetcher.metaContent(properties: ["og:title"], in: propertyFirstDoubleQuoted), "A Title")
        XCTAssertEqual(LinkPreviewFetcher.metaContent(properties: ["og:title"], in: contentFirstSingleQuoted), "A Title")
    }
}
