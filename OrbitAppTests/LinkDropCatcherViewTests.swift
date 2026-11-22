//  The view that takes a link dragged into the page: which drags it accepts, what its overlay shows, and what a drop opens.
//  Its hit test is not covered here: it only claims a drag while the primary mouse button is physically down, and that state
//  cannot be set from inside the process, so the drop methods are driven with a stand-in NSDraggingInfo instead.

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

@MainActor
final class LinkDropCatcherViewTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!
    private var targetTabID: TabID!
    private var window: NSWindow?
    private var pasteboards: [NSPasteboard] = []

    private static let linkText = "https://example.com/dropped"
    // window coordinates of a 600 by 400 page: the edge bands are 132 wide, so 20 is the left edge, 580 the right and 300 the middle
    private let leftEdge = NSPoint(x: 20, y: 200)
    private let rightEdge = NSPoint(x: 580, y: 200)
    private let middle = NSPoint(x: 300, y: 200)

    override func setUp() {
        super.setUp()
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Link Drop Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
        targetTabID = env.openTab(url: URL(string: "https://example.com/target")!, in: spaceID, section: .today, activate: true)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        if let spaceID { env.deleteSpace(spaceID) }
        spaceID = nil
        targetTabID = nil
        super.tearDown()
    }

    private func makeCatcher(frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 400), withEnvironment: Bool = true) -> LinkDropCatcherView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let catcher = LinkDropCatcherView(frame: frame)
        if withEnvironment {
            catcher.environment = env
            catcher.targetTabID = targetTabID
        }
        host.addSubview(catcher)
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        return catcher
    }

    private func overlayView(of catcher: LinkDropCatcherView) throws -> LinkDropOverlayView {
        try XCTUnwrap(catcher.subviews.compactMap { $0 as? LinkDropOverlayView }.first, "The drop catcher has no overlay.")
    }

    private func makePasteboard(urlType link: String? = nil, text: String? = nil, fileURL: String? = nil) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LinkDropCatcherViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        let item = NSPasteboardItem()
        if let link { item.setString(link, forType: NSPasteboard.PasteboardType(UTType.url.identifier)) }
        if let text { item.setString(text, forType: .string) }
        if let fileURL { item.setString(fileURL, forType: NSPasteboard.PasteboardType(UTType.fileURL.identifier)) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    private func info(_ catcher: LinkDropCatcherView, at point: NSPoint, over pasteboard: NSPasteboard, mask: NSDragOperation = [.copy, .link, .generic]) throws -> StandInDraggingInfo {
        StandInDraggingInfo(location: point, pasteboard: pasteboard, window: try XCTUnwrap(catcher.window), sourceMask: mask)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    private func pressInThePage(at point: NSPoint) throws {
        let window = try XCTUnwrap(self.window)
        NSApp.sendEvent(try mouseEvent(.leftMouseDown, at: point, in: window))
        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: point, in: window))
    }

    // MARK: - Registration and the overlay

    func test_theCatcherRegistersForLinksFilesAndText() {
        let catcher = makeCatcher()
        let registered = Set(catcher.registeredDraggedTypes.map(\.rawValue))
        for type in [NSPasteboard.PasteboardType.URL, .fileURL, .string] {
            XCTAssertTrue(registered.contains(type.rawValue), "A drag carrying \(type.rawValue) can never reach the catcher: registered \(registered)")
        }
    }

    func test_theOverlayNeverTakesAHit_evenWhileShowingAZone() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let pasteboard = makePasteboard(urlType: Self.linkText)
        XCTAssertFalse(catcher.draggingEntered(try info(catcher, at: leftEdge, over: pasteboard)).isEmpty, "Precondition: the overlay is showing.")
        XCTAssertFalse(overlay.isHidden, "Precondition: the overlay is showing.")
        XCTAssertNil(overlay.hitTest(NSPoint(x: 300, y: 200)), "The overlay must never take a click or a drop from the page and the catcher beneath it.")
    }

    func test_anExternalLinkOverTheLeftEdge_isAcceptedAsACopy_andShowsTheOverlay() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        XCTAssertTrue(overlay.isHidden, "Precondition: nothing is showing before a drag arrives.")

        let operation = catcher.draggingEntered(try info(catcher, at: leftEdge, over: makePasteboard(urlType: Self.linkText)))

        XCTAssertEqual(operation, .copy, "A link dragged in from outside is offered as a copy.")
        XCTAssertFalse(overlay.isHidden, "The overlay must show the split zone under the pointer.")
    }

    func test_aLinkInTheMiddle_isNotTakenAndShowsNothing() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)

        let operation = catcher.draggingEntered(try info(catcher, at: middle, over: makePasteboard(urlType: Self.linkText)))

        XCTAssertEqual(operation, [], "The middle of the page is where a link is let go of, so it must not be taken there.")
        XCTAssertTrue(overlay.isHidden, "Nothing may be highlighted in the middle of the page.")
    }

    func test_movingALinkFromAnEdgeToTheMiddle_withdrawsTheDrop_andBackToTheRightEdgeOffersItAgain() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let pasteboard = makePasteboard(urlType: Self.linkText)
        let dragInfo = try info(catcher, at: leftEdge, over: pasteboard)

        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy)
        XCTAssertFalse(overlay.isHidden)

        dragInfo.location = middle
        XCTAssertEqual(catcher.draggingUpdated(dragInfo), [], "Leaving the edge band must take the drop back.")
        XCTAssertTrue(waitUntil { overlay.isHidden }, "The overlay stayed on screen after the pointer left the edge band.")

        dragInfo.location = rightEdge
        XCTAssertEqual(catcher.draggingUpdated(dragInfo), .copy, "Reaching the right edge band must offer the drop again.")
        XCTAssertFalse(overlay.isHidden)
    }

    func test_exitingTheDrag_hidesTheOverlay() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let dragInfo = try info(catcher, at: leftEdge, over: makePasteboard(urlType: Self.linkText))
        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy)
        XCTAssertFalse(overlay.isHidden)

        catcher.draggingExited(dragInfo)

        XCTAssertTrue(waitUntil { overlay.isHidden }, "The overlay stayed on screen after the drag left the page.")
    }

    func test_endingTheDrag_hidesTheOverlay() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(urlType: Self.linkText))
        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy)
        XCTAssertFalse(overlay.isHidden)

        catcher.draggingEnded(dragInfo)

        XCTAssertTrue(waitUntil { overlay.isHidden }, "The overlay stayed on screen after the drag ended.")
    }

    func test_aSourceThatOnlyAllowsMove_isNotTaken() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let dragInfo = try info(catcher, at: leftEdge, over: makePasteboard(urlType: Self.linkText), mask: [.move])

        XCTAssertEqual(catcher.draggingEntered(dragInfo), [], "A link is only ever copied, linked or opened, never moved out of its source.")
        XCTAssertTrue(overlay.isHidden)
    }

    func test_aFileThatIsNotALink_isNotTaken() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let dragInfo = try info(catcher, at: leftEdge, over: makePasteboard(fileURL: "file:///tmp/picture.png"))

        XCTAssertEqual(catcher.draggingEntered(dragInfo), [], "A picture file dragged in belongs to the page, not to a split.")
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(catcher.performDragOperation(dragInfo))
    }

    func test_plainTextThatIsALink_fromOutsideThePage_isTaken() throws {
        let catcher = makeCatcher()
        let operation = catcher.draggingEntered(try info(catcher, at: leftEdge, over: makePasteboard(text: Self.linkText)))
        XCTAssertEqual(operation, .copy, "A link selected as text in another app is a link drop.")
    }

    // MARK: - Dropping

    func test_droppingALinkOnTheRightEdge_opensItInANewSplitPaneOnTheRight() throws {
        let catcher = makeCatcher()
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(urlType: Self.linkText))
        XCTAssertNil(env.splitGroup(for: targetTabID), "Precondition: the page is not split.")

        XCTAssertTrue(catcher.performDragOperation(dragInfo), "The drop on an edge must be taken.")

        let group = try XCTUnwrap(env.splitGroup(for: targetTabID), "No split was made for the page the link was dropped on.")
        XCTAssertEqual(group.axis, .horizontal)
        XCTAssertEqual(group.tabIDs.count, 2)
        XCTAssertEqual(group.tabIDs.first, targetTabID, "A right-edge drop keeps the page first.")
        let opened = try XCTUnwrap(group.tabIDs.last)
        XCTAssertEqual(env.tab(opened)?.url, URL(string: Self.linkText), "The new pane must open the dropped link.")
        XCTAssertEqual(env.activeTabID, opened, "The tab the link opened in becomes the active one.")
    }

    func test_droppingALinkOnTheLeftEdge_opensItInANewSplitPaneOnTheLeft() throws {
        let catcher = makeCatcher()
        let dragInfo = try info(catcher, at: leftEdge, over: makePasteboard(urlType: Self.linkText))

        XCTAssertTrue(catcher.performDragOperation(dragInfo))

        let group = try XCTUnwrap(env.splitGroup(for: targetTabID))
        XCTAssertEqual(group.tabIDs.count, 2)
        XCTAssertEqual(group.tabIDs.last, targetTabID, "A left-edge drop puts the new pane before the page.")
        let opened = try XCTUnwrap(group.tabIDs.first)
        XCTAssertEqual(env.tab(opened)?.url, URL(string: Self.linkText))
    }

    func test_droppingALinkInTheMiddle_opensNothing() throws {
        let catcher = makeCatcher()
        let tabsBefore = env.state.tabs.count
        let dragInfo = try info(catcher, at: middle, over: makePasteboard(urlType: Self.linkText))

        XCTAssertFalse(catcher.performDragOperation(dragInfo), "A drop in the middle of the page is refused.")

        XCTAssertEqual(env.state.tabs.count, tabsBefore, "A drop in the middle of the page opened a tab.")
        XCTAssertNil(env.splitGroup(for: targetTabID))
    }

    func test_droppingAFileThatIsNotALink_opensNothing() throws {
        let catcher = makeCatcher()
        let tabsBefore = env.state.tabs.count
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(fileURL: "file:///tmp/picture.png"))

        XCTAssertFalse(catcher.performDragOperation(dragInfo))

        XCTAssertEqual(env.state.tabs.count, tabsBefore)
        XCTAssertNil(env.splitGroup(for: targetTabID))
    }

    func test_aCatcherWithNoEnvironment_refusesEveryDrag() throws {
        let catcher = makeCatcher(withEnvironment: false)
        let tabsBefore = env.state.tabs.count
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(urlType: Self.linkText))

        XCTAssertEqual(catcher.draggingEntered(dragInfo), [])
        XCTAssertFalse(catcher.performDragOperation(dragInfo))
        XCTAssertEqual(env.state.tabs.count, tabsBefore)
    }

    func test_afterADrop_theOverlayIsHidden() throws {
        let catcher = makeCatcher()
        let overlay = try overlayView(of: catcher)
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(urlType: Self.linkText))
        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy)
        XCTAssertFalse(overlay.isHidden)

        XCTAssertTrue(catcher.performDragOperation(dragInfo))

        XCTAssertTrue(waitUntil { overlay.isHidden }, "The overlay stayed on screen after the drop.")
    }

    func test_inAVerticalSplit_theTopEdgeIsTaken_andTheSidesAreNot() throws {
        let second = env.openTab(url: URL(string: "https://example.com/second")!, in: spaceID, section: .today, activate: false)
        env.createSplit(existingTabID: targetTabID, newTabID: second, edge: .bottom)
        XCTAssertEqual(env.splitGroup(for: targetTabID)?.axis, .vertical, "Precondition: the group is stacked.")
        let catcher = makeCatcher()
        let pasteboard = makePasteboard(urlType: Self.linkText)
        // window coordinates have the origin at the bottom, so y near 400 is the top of the page
        let top = NSPoint(x: 300, y: 390)

        XCTAssertEqual(catcher.draggingEntered(try info(catcher, at: leftEdge, over: pasteboard)), [], "A side drop on a stacked group would flip the whole group's axis.")
        XCTAssertEqual(catcher.draggingEntered(try info(catcher, at: top, over: pasteboard)), .copy, "The top edge of a stacked group takes a link.")
    }

    // MARK: - The drag origin tracker

    func test_theOriginTracker_recordsARealLeftMouseDown_andItsDragPasteboardChangeCount() throws {
        let catcher = makeCatcher()
        let window = try XCTUnwrap(catcher.window)
        let drag = NSPasteboard(name: .drag)
        drag.clearContents()
        drag.setString("marker", forType: .string)
        let point = NSPoint(x: 210, y: 120)

        NSApp.sendEvent(try mouseEvent(.leftMouseDown, at: point, in: window))

        let tracker = LinkDragOriginTracker.shared
        XCTAssertTrue(tracker.window === window, "The tracker did not record the window a real mouse press landed in.")
        XCTAssertEqual(tracker.locationInWindow, point)
        XCTAssertEqual(tracker.dragChangeCount, drag.changeCount, "The tracker must record the drag pasteboard as it was at the press.")

        drag.clearContents()
        drag.setString("later", forType: .string)
        XCTAssertNotEqual(tracker.dragChangeCount, drag.changeCount, "The recorded change count is a snapshot; a later drag must look different from it.")

        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: NSPoint(x: 40, y: 40), in: window))
        XCTAssertEqual(tracker.locationInWindow, point, "A release is not a press and must not move the recorded origin.")
    }

    func test_aTextOnlyDragThatBeganInThisPage_isLeftToThePage() throws {
        let catcher = makeCatcher()
        try pressInThePage(at: NSPoint(x: 300, y: 200))
        let tabsBefore = env.state.tabs.count
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(text: Self.linkText))

        XCTAssertEqual(catcher.draggingEntered(dragInfo), [], "Text selected in this page and dragged within it must keep going to the page's fields and editors.")
        XCTAssertFalse(catcher.performDragOperation(dragInfo))
        XCTAssertEqual(env.state.tabs.count, tabsBefore)
        XCTAssertNil(env.splitGroup(for: targetTabID))
    }

    func test_anExplicitLinkThatBeganInThisPage_isStillTaken() throws {
        let catcher = makeCatcher()
        try pressInThePage(at: NSPoint(x: 300, y: 200))
        let dragInfo = try info(catcher, at: rightEdge, over: makePasteboard(urlType: Self.linkText))

        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy, "A link dragged out of this page's own link is a real link drop.")
        XCTAssertTrue(catcher.performDragOperation(dragInfo))
        XCTAssertEqual(env.splitGroup(for: targetTabID)?.tabIDs.count, 2)
    }

    func test_aTextDragWhosePressLandedOutsideThisCatcher_isTaken() throws {
        let catcher = makeCatcher(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        try pressInThePage(at: NSPoint(x: 500, y: 200))
        let dragInfo = try info(catcher, at: leftEdge, over: makePasteboard(text: Self.linkText))

        XCTAssertEqual(catcher.draggingEntered(dragInfo), .copy, "A press outside this catcher's frame says nothing about a drag that began in it.")
    }
}
