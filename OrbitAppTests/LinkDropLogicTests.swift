//  Dragging a link into the window: which zone a point falls in, which pasteboards carry an openable link, and when the drop catcher takes the drag instead of the page.

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

@MainActor
final class LinkDropLogicTests: XCTestCase {

    private var pasteboards: [NSPasteboard] = []
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        scratchDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        scratchDirectories.removeAll()
        super.tearDown()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LinkDropLogicTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func scratchFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        let file = directory.appendingPathComponent(name)
        try contents.write(to: file)
        return file
    }

    private let size = CGSize(width: 1000, height: 600)

    // MARK: - Zones

    func test_pointNearLeftEdge_isLeftZone() {
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 10, y: 300), in: size, splitAxis: nil, splitAllowed: true), .left)
    }

    func test_pointNearRightEdge_isRightZone() {
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 990, y: 300), in: size, splitAxis: nil, splitAllowed: true), .right)
    }

    func test_pointInMiddle_isCenterZone() {
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 500, y: 300), in: size, splitAxis: nil, splitAllowed: true), .center)
    }

    func test_edgeBandBoundary_isInclusiveInsideAndExclusiveOutside() {
        let band = LinkDropLogic.edgeBand(forLength: size.width)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: band, y: 1), in: size, splitAxis: nil, splitAllowed: true), .left)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: band + 1, y: 1), in: size, splitAxis: nil, splitAllowed: true), .center)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: size.width - band, y: 1), in: size, splitAxis: nil, splitAllowed: true), .right)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: size.width - band - 1, y: 1), in: size, splitAxis: nil, splitAllowed: true), .center)
    }

    func test_edgeBand_scalesWithWidthAndNeverExceedsFortyPercent() {
        XCTAssertEqual(LinkDropLogic.edgeBand(forLength: 1000), 220, accuracy: 0.001)
        XCTAssertEqual(LinkDropLogic.edgeBand(forLength: 200), LinkDropLogic.minimumEdgeBand, accuracy: 0.001)
        XCTAssertEqual(LinkDropLogic.edgeBand(forLength: 100), 40, accuracy: 0.001)
        XCTAssertEqual(LinkDropLogic.edgeBand(forLength: 0), 0)
    }

    func test_splitNotAllowed_offersCenterEverywhere() {
        for x in [0, 10, 500, 990, 1000] as [CGFloat] {
            XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: x, y: 300), in: size, splitAxis: nil, splitAllowed: false), .center)
        }
    }

    func test_emptySize_isCenter() {
        XCTAssertEqual(LinkDropLogic.zone(at: .zero, in: .zero, splitAxis: nil, splitAllowed: true), .center)
    }

    func test_verticalSplitGroup_usesTopAndBottomBands() {
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 5, y: 5), in: size, splitAxis: .vertical, splitAllowed: true), .top)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 5, y: 595), in: size, splitAxis: .vertical, splitAllowed: true), .bottom)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 5, y: 300), in: size, splitAxis: .vertical, splitAllowed: true), .center)
    }

    func test_horizontalSplitGroup_usesLeftAndRightBands() {
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 5, y: 300), in: size, splitAxis: .horizontal, splitAllowed: true), .left)
        XCTAssertEqual(LinkDropLogic.zone(at: CGPoint(x: 500, y: 5), in: size, splitAxis: .horizontal, splitAllowed: true), .center)
    }

    func test_splitAllowed_respectsMaximumPaneCount() {
        XCTAssertTrue(LinkDropLogic.splitAllowed(paneCountInGroup: nil))
        XCTAssertTrue(LinkDropLogic.splitAllowed(paneCountInGroup: SplitGroup.maximumPanes - 1))
        XCTAssertFalse(LinkDropLogic.splitAllowed(paneCountInGroup: SplitGroup.maximumPanes))
    }

    func test_zoneSplitEdgeAndTitles() {
        XCTAssertNil(LinkDropZone.center.splitEdge)
        XCTAssertEqual(LinkDropZone.left.splitEdge, .left)
        XCTAssertEqual(LinkDropZone.right.splitEdge, .right)
        XCTAssertEqual(LinkDropZone.top.splitEdge, .top)
        XCTAssertEqual(LinkDropZone.bottom.splitEdge, .bottom)
        XCTAssertEqual(LinkDropZone.center.title, "Open in New Tab")
        XCTAssertEqual(LinkDropZone.left.title, "Open in Split View")
        XCTAssertEqual(LinkDropZone.right.title, "Open in Split View")
    }

    func test_highlightRect_coversTheHalfTheLinkWouldOccupy() {
        let inset = LinkDropLogic.highlightInset
        XCTAssertEqual(
            LinkDropLogic.highlightRect(for: .left, in: size),
            CGRect(x: 0, y: 0, width: 500, height: 600).insetBy(dx: inset, dy: inset)
        )
        XCTAssertEqual(
            LinkDropLogic.highlightRect(for: .right, in: size),
            CGRect(x: 500, y: 0, width: 500, height: 600).insetBy(dx: inset, dy: inset)
        )
        XCTAssertEqual(
            LinkDropLogic.highlightRect(for: .center, in: size),
            CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        )
        XCTAssertEqual(
            LinkDropLogic.highlightRect(for: .bottom, in: size),
            CGRect(x: 0, y: 300, width: 1000, height: 300).insetBy(dx: inset, dy: inset)
        )
    }

    // MARK: - Pasteboard extraction

    func test_webURLOnPasteboard_isExplicitLink() throws {
        let pasteboard = makePasteboard()
        let url = try XCTUnwrap(URL(string: "https://example.com/a?b=1"))
        pasteboard.writeObjects([url as NSURL])
        XCTAssertEqual(LinkDropLogic.payload(from: pasteboard), LinkDropPayload(url: url, isExplicitLink: true))
    }

    func test_plainTextURL_isAcceptedButNotExplicit() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("  https://example.com/path\n", forType: .string)
        let payload = try XCTUnwrap(LinkDropLogic.payload(from: pasteboard))
        XCTAssertEqual(payload.url.absoluteString, "https://example.com/path")
        XCTAssertFalse(payload.isExplicitLink)
    }

    func test_plainTextWwwHost_getsHTTPS() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("www.example.com", forType: .string)
        XCTAssertEqual(LinkDropLogic.payload(from: pasteboard)?.url.absoluteString, "https://www.example.com")
    }

    func test_plainTextThatIsNotAURL_isRejected() {
        for text in ["hello world", "see https://example.com now", "file.txt", "", "   ", "javascript:alert(1)", "mailto:a@b.com", "https://"] {
            let pasteboard = makePasteboard()
            pasteboard.setString(text, forType: .string)
            XCTAssertNil(LinkDropLogic.payload(from: pasteboard), text)
        }
    }

    func test_nonWebURLScheme_isRejected() throws {
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([try XCTUnwrap(URL(string: "mailto:a@b.com")) as NSURL])
        XCTAssertNil(LinkDropLogic.payload(from: pasteboard))
    }

    func test_ordinaryFileURL_isRejectedSoUploadsReachThePage() throws {
        let file = try scratchFile(named: "photo.png", contents: Data([0x89, 0x50]))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertNil(LinkDropLogic.payload(from: pasteboard))
    }

    func test_fileURLWithURLTextFallback_isStillRejected() throws {
        let file = try scratchFile(named: "doc.pdf", contents: Data([0x25]))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("https://example.com", forType: .string)
        XCTAssertNil(LinkDropLogic.payload(from: pasteboard))
    }

    func test_weblocFile_resolvesToItsURL() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.org/x"], format: .xml, options: 0)
        let file = try scratchFile(named: "Example.webloc", contents: plist)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(LinkDropLogic.payload(from: pasteboard), LinkDropPayload(url: URL(string: "https://example.org/x")!, isExplicitLink: true))
    }

    func test_binaryWeblocFile_resolvesToItsURL() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.org/bin"], format: .binary, options: 0)
        let file = try scratchFile(named: "Binary.webloc", contents: plist)
        XCTAssertEqual(LinkDropLogic.linkTarget(inFileAt: file)?.absoluteString, "https://example.org/bin")
    }

    func test_internetShortcutFile_resolvesToItsURL() throws {
        let contents = "[InternetShortcut]\r\nURL=https://example.net/page\r\nIconIndex=0\r\n"
        let file = try scratchFile(named: "Site.url", contents: Data(contents.utf8))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(LinkDropLogic.payload(from: pasteboard)?.url.absoluteString, "https://example.net/page")
    }

    func test_weblocWithoutAnOpenableURL_isRejected() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "ftp://example.org"], format: .xml, options: 0)
        let file = try scratchFile(named: "Bad.webloc", contents: plist)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertNil(LinkDropLogic.payload(from: pasteboard))
    }

    func test_emptyPasteboard_hasNoPayload() {
        XCTAssertNil(LinkDropLogic.payload(from: makePasteboard()))
    }

    // MARK: - Accept or pass through

    private let link = LinkDropPayload(url: URL(string: "https://example.com")!, isExplicitLink: true)
    private let text = LinkDropPayload(url: URL(string: "https://example.com")!, isExplicitLink: false)

    func test_noPayload_passesThrough() {
        XCTAssertFalse(LinkDropLogic.accepts(nil, dragBeganInThisPage: false))
        XCTAssertFalse(LinkDropLogic.accepts(nil, dragBeganInThisPage: true))
    }

    func test_externalDrag_acceptsLinksAndURLText() {
        XCTAssertTrue(LinkDropLogic.accepts(link, dragBeganInThisPage: false))
        XCTAssertTrue(LinkDropLogic.accepts(text, dragBeganInThisPage: false))
    }

    func test_dragFromThisPage_acceptsLinksButLeavesSelectedTextToThePage() {
        XCTAssertTrue(LinkDropLogic.accepts(link, dragBeganInThisPage: true))
        XCTAssertFalse(LinkDropLogic.accepts(text, dragBeganInThisPage: true))
    }

    private func claims(
        event: NSEvent.EventType? = .leftMouseDragged,
        down: Bool = true,
        changed: Bool = true,
        sidebar: Bool = false,
        payload: LinkDropPayload? = nil,
        fromPage: Bool = false
    ) -> Bool {
        LinkDropLogic.claimsHit(
            eventType: event,
            primaryButtonDown: down,
            dragPasteboardChanged: changed,
            sidebarDragInFlight: sidebar,
            payload: payload,
            dragBeganInThisPage: fromPage
        )
    }

    func test_claimsHit_whenALinkDragIsOverThePage() {
        XCTAssertTrue(claims(payload: link))
        XCTAssertTrue(claims(event: nil, payload: link))
    }

    func test_claimsHit_neverForClicksScrollsOrKeys() {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel, .mouseMoved, .keyDown] {
            XCTAssertFalse(claims(event: type, payload: link), "\(type)")
        }
    }

    func test_claimsHit_notWithoutButtonDownOrWithAStalePasteboard() {
        XCTAssertFalse(claims(down: false, payload: link))
        XCTAssertFalse(claims(changed: false, payload: link))
    }

    func test_claimsHit_notWhileASidebarRowIsBeingDragged() {
        XCTAssertFalse(claims(sidebar: true, payload: link))
    }

    func test_claimsHit_notForNonLinkDragsSoUploadsAndPageDragsStayWithThePage() {
        XCTAssertFalse(claims(payload: nil))
        XCTAssertFalse(claims(payload: text, fromPage: true))
    }

    func test_dragOperation_prefersCopyThenLinkThenGeneric() {
        XCTAssertEqual(LinkDropLogic.dragOperation(for: [.copy, .move]), .copy)
        XCTAssertEqual(LinkDropLogic.dragOperation(for: [.link, .generic]), .link)
        XCTAssertEqual(LinkDropLogic.dragOperation(for: .generic), .generic)
        XCTAssertEqual(LinkDropLogic.dragOperation(for: .move), [])
        XCTAssertEqual(LinkDropLogic.dragOperation(for: []), [])
    }
    // An image dragged from another app carries its own address beside the picture; the page must get it, not a new tab.
    func test_anImageCarryingItsAddress_isLeftToThePage() throws {
        let pasteboard = makePasteboard()
        let url = try XCTUnwrap(URL(string: "https://example.com/photo.png"))
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: NSPasteboard.PasteboardType("public.url"))
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.writeObjects([item])
        XCTAssertNil(LinkDropLogic.payload(from: pasteboard))
    }

    func test_aFilePromise_isLeftToThePage() {
        XCTAssertTrue(LinkDropLogic.offersContentForPage(types: [NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")]))
        XCTAssertTrue(LinkDropLogic.offersContentForPage(types: [.tiff]))
        XCTAssertFalse(LinkDropLogic.offersContentForPage(types: [.string, NSPasteboard.PasteboardType("public.url")]))
    }

    func test_theSplitCatcherOnlyTakesADragThatCarriesASidebarTab() {
        let sidebarType = NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)
        XCTAssertTrue(SplitPaneDropCatcherView.dragCarriesSidebarTab([.string, sidebarType]))
        XCTAssertFalse(SplitPaneDropCatcherView.dragCarriesSidebarTab([.fileURL, .tiff]))
        XCTAssertFalse(SplitPaneDropCatcherView.dragCarriesSidebarTab([]))
    }
}
