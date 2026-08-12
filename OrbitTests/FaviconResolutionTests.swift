import XCTest

final class FaviconResolutionTests: XCTestCase {

    // MARK: - Well-known locations

    func test_theEngineSuppliedURLIsTriedBeforeTheWellKnownPath() {
        let supplied = URL(string: "https://cdn.example.org/hashed-abc123.png")!
        let candidates = FaviconCache.wellKnownIconURLs(faviconURL: supplied, host: "example.org")

        XCTAssertEqual(candidates.first, supplied,
                       "The engine already resolved this one from the page itself; it must be tried first.")
        XCTAssertEqual(candidates.last?.absoluteString, "https://example.org/favicon.ico")
    }

    func test_aHostWithNoSuppliedURLStillGetsTheWellKnownPath() {
        let candidates = FaviconCache.wellKnownIconURLs(faviconURL: nil, host: "github.com")

        XCTAssertEqual(candidates.map(\.absoluteString), ["https://github.com/favicon.ico"],
                       "This is the whole point: an unloaded tab has no faviconURL and must still resolve a real icon.")
    }

    func test_theSameURLIsNotTriedTwice() {
        let supplied = URL(string: "https://github.com/favicon.ico")!
        let candidates = FaviconCache.wellKnownIconURLs(faviconURL: supplied, host: "github.com")

        XCTAssertEqual(candidates.count, 1, "The engine's URL and the derived one are the same request here.")
    }

    func test_aHostThatIsNotAHostnameIsNeverFetched() {
        let notHostnames = [
            "orbit://note/6E8B0A2C-0000-0000-0000-000000000001",
            "",
            "localhost",
            "a host with spaces.com",
        ]
        for candidate in notHostnames {
            XCTAssertTrue(
                FaviconCache.wellKnownIconURLs(faviconURL: nil, host: candidate).isEmpty,
                "\(candidate) is not a hostname; deriving https://\(candidate)/favicon.ico from it is nonsense."
            )
        }
    }

    // MARK: - The site's own declarations

    private let figmaHead = """
    <!doctype html><html><head>
    <link rel="icon" href="https://static.figma.com/app/icon/2/icon-128.png" sizes="128x128"/>
    <link rel="icon" href="https://static.figma.com/app/icon/2/icon-192.png" sizes="192x192"/>
    <link rel="icon" href="https://static.figma.com/app/icon/2/icon-256.png" sizes="256x256"/>
    <link rel="icon" href="https://static.figma.com/app/icon/2/favicon.png" type="image/png"/>
    <link rel="icon" href="https://static.figma.com/app/icon/2/favicon.svg" sizes="any" type="image/svg+xml"/>
    <link rel="icon" href="https://static.figma.com/app/icon/2/favicon.ico" type="image/vnd.microsoft.icon"/>
    </head><body></body></html>
    """

    func test_theLargestDeclaredIconWins() {
        let urls = FaviconCache.iconURLs(inHTML: figmaHead, relativeTo: URL(string: "https://www.figma.com/")!)

        XCTAssertEqual(urls.first?.absoluteString, "https://static.figma.com/app/icon/2/icon-256.png",
                       "A sidebar row draws at 12-17pt on a Retina display: downsampling 256px is sharp, upsampling 16px is mush.")
        XCTAssertEqual(urls.count, 6, "Every declared icon is a fallback candidate, not just the winner.")
    }

    private let notionHead = """
    <!doctype html><html><head>
    <link rel="icon" href="/front-static/favicon.ico" data-next-head=""/>
    <link rel="apple-touch-icon" href="/front-static/logo-ios.png" data-next-head=""/>
    </head><body></body></html>
    """

    func test_relativeHrefsAreResolvedAgainstTheSite() {
        let urls = FaviconCache.iconURLs(inHTML: notionHead, relativeTo: URL(string: "https://www.notion.so/")!)

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://www.notion.so/front-static/logo-ios.png",
            "https://www.notion.so/front-static/favicon.ico",
        ])
    }

    func test_anUnsizedAppleTouchIconOutranksAnUnsizedOrdinaryIcon() {
        let html = """
        <link rel="icon" href="/small.ico">
        <link rel="apple-touch-icon" href="/touch.png">
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.first?.absoluteString, "https://example.org/touch.png")
    }

    func test_sizesAnyIsNeitherParsedAsANumberNorDropped() {
        let html = """
        <link rel="icon" href="/favicon.ico?v=2" sizes="any"/>
        <link rel="icon" href="/static/favicon.svg?v=2" type="image/svg+xml"/>
        <link rel="apple-touch-icon" href="/static/apple-touch-icon.png?v=2" sizes="180x180"/>
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://linear.app/")!)

        XCTAssertEqual(urls.first?.absoluteString, "https://linear.app/static/apple-touch-icon.png?v=2")
        XCTAssertEqual(urls.count, 3, "The `sizes=\"any\"` entries are ranked last, not thrown away.")
    }

    func test_theLargestOfSeveralDeclaredSizesIsTheOneThatCounts() {
        let html = """
        <link rel="icon" href="/multi.ico" sizes="16x16 32x32 48x48">
        <link rel="icon" href="/single.png" sizes="32x32">
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.first?.absoluteString, "https://example.org/multi.ico")
    }

    func test_theSafariMaskIconIsExcluded() {
        let html = """
        <link rel="mask-icon" href="/pinned.svg" color="#000000">
        <link rel="icon" href="/real.png" sizes="32x32">
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.org/real.png"])
    }

    func test_nonIconLinkTagsAreIgnored() {
        let html = """
        <link rel="stylesheet" href="/app.css">
        <link rel="preconnect" href="https://fonts.example.org">
        <link rel="canonical" href="https://example.org/page">
        """
        XCTAssertTrue(FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!).isEmpty)
    }

    func test_everyQuotingStyleAndCasingIsRead() {
        let html = """
        <LINK REL="ICON" HREF="/double.png" SIZES="64x64">
        <link rel='icon' href='/single.png' sizes='48x48'>
        <link rel=icon href=/bare.png sizes=32x32>
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.org/double.png",
            "https://example.org/single.png",
            "https://example.org/bare.png",
        ])
    }

    func test_ampersandEntitiesInHrefsAreDecoded() {
        let html = #"<link rel="icon" href="/icon.png?v=2&amp;theme=dark">"#
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.first?.absoluteString, "https://example.org/icon.png?v=2&theme=dark")
    }

    func test_onlyHTTPSchemesAreEverFetched() {
        let html = """
        <link rel="icon" href="javascript:alert(1)">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="/real.png">
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.org/real.png"])
    }

    func test_theSameIconDeclaredTwiceIsFetchedOnce() {
        let html = """
        <link rel="icon" href="/icon.png" sizes="32x32">
        <link rel="shortcut icon" href="/icon.png">
        """
        let urls = FaviconCache.iconURLs(inHTML: html, relativeTo: URL(string: "https://example.org/")!)

        XCTAssertEqual(urls.count, 1)
    }

    func test_markupWithNoIconsAtAllYieldsNothingRatherThanAGuess() {
        XCTAssertTrue(
            FaviconCache.iconURLs(inHTML: "<html><head><title>x</title></head></html>",
                                  relativeTo: URL(string: "https://example.org/")!).isEmpty
        )
    }
}
