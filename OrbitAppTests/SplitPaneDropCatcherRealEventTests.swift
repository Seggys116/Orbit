import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

// The page's split drop target is chosen by a hit test that reads the app's current event. These tests feed it a real mouseMoved
// event taken from the event queue, which is what the app reports while a sidebar drag moves over the page, instead of calling
// the drop methods directly the way the older tests do.
@MainActor
final class SplitPaneDropCatcherRealEventTests: XCTestCase {

    private final class PageStandIn: NSView {}

    private func makeWindow() -> (window: NSWindow, catcher: SplitPaneDropCatcherView, page: PageStandIn) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let page = PageStandIn(frame: host.bounds)
        let catcher = SplitPaneDropCatcherView(frame: host.bounds)
        host.addSubview(page)
        host.addSubview(catcher)
        window.contentView = host
        return (window, catcher, page)
    }

    private func writeSidebarDragPasteboard(_ payload: SidebarDragPayload) throws {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(payload), forType: NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier))
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    private func nextMovedEvent(in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        let moved = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        NSApp.postEvent(moved, atStart: true)
        return try XCTUnwrap(NSApp.nextEvent(matching: .mouseMoved, until: .distantPast, inMode: .default, dequeue: true), "The posted mouseMoved never came back from the queue.")
    }

    func test_aSidebarDragMovingOverThePage_isTakenByTheDropTarget_whenTheAppReportsMouseMoved() throws {
        let (window, catcher, page) = makeWindow()
        defer { SidebarDragSession.end(); window.close() }
        let point = NSPoint(x: 500, y: 200)
        try writeSidebarDragPasteboard(SidebarDragPayload(nodeID: UUID(), kind: .todayTab, spaceID: UUID()))
        SidebarDragSession.begin(SidebarDragPayload(nodeID: UUID(), kind: .todayTab, spaceID: UUID()))
        // the record learns the drag pasteboard's change count one main-queue hop after it begins
        RunLoop.main.run(mode: .default, before: Date())
        XCTAssertNotNil(SidebarDragSession.current, "Precondition: the sidebar's drag record matches the drag pasteboard.")
        _ = try nextMovedEvent(in: window, at: point)
        XCTAssertEqual(NSApp.currentEvent?.type, .mouseMoved, "Precondition: the app's current event is the mouseMoved a drag reports.")
        XCTAssertTrue(SidebarDragSession.hasInFlightDrag, "Precondition: the sidebar drag is still in flight.")

        let hit = window.contentView?.hitTest(point)
        XCTAssertTrue(hit === catcher, "Hit \(String(describing: hit.map { type(of: $0) })) instead of the drop target, so the page would take the drop and no split would open.")
        XCTAssertFalse(hit === page)
    }

    func test_withNoSidebarDragInFlight_aMouseMovedOverThePageReachesThePage() throws {
        let (window, _, page) = makeWindow()
        defer { window.close() }
        SidebarDragSession.discardStaleRecord()
        let point = NSPoint(x: 500, y: 200)
        _ = try nextMovedEvent(in: window, at: point)
        XCTAssertTrue(window.contentView?.hitTest(point) === page, "With no drag in flight the page must get the pointer.")
    }
}
