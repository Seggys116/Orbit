import AppKit
import XCTest
@testable import Orbit

final class SidebarTearOffPasteboardOrderingTests: XCTestCase {

    private final class InertDraggingSource: NSObject, NSDraggingSource {
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .move
        }
    }

    @MainActor
    func test_beginDraggingSession_bumpsChangeCount() {
        let pasteboard = NSPasteboard(name: .drag)
        let beforeAnything = pasteboard.changeCount

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let capturedInsideOnDragClosureAnalogue = pasteboard.changeCount
        XCTAssertEqual(
            capturedInsideOnDragClosureAnalogue, beforeAnything,
            "nothing between window setup and this read should have touched the drag pasteboard"
        )

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("SidebarTearOffPasteboardOrderingTests", forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 10, height: 10), contents: nil)

        guard let mouseDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("could not construct a synthetic mouseDown NSEvent to drive beginDraggingSession")
            return
        }

        let source = InertDraggingSource()
        _ = view.beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: source)

        let afterSessionBegan = pasteboard.changeCount

        XCTContext.runActivity(named: "measured changeCount ordering: before=\(beforeAnything) capturedPreCall=\(capturedInsideOnDragClosureAnalogue) afterBeginDraggingSession=\(afterSessionBegan)") { _ in }

        XCTAssertNotEqual(
            afterSessionBegan, capturedInsideOnDragClosureAnalogue,
            "beginDraggingSession(with:event:source:) must bump NSPasteboard(name: .drag).changeCount as part of starting — " +
            "if this ever passes as equal, AppKit no longer writes the drag pasteboard synchronously at session start, and the " +
            "lazy-baseline fix in SidebarTearOffDetector.begin(_:)/SidebarDragSession.begin(_:) should be re-examined against " +
            "whatever the new ordering turns out to be."
        )
        XCTAssertEqual(
            afterSessionBegan, capturedInsideOnDragClosureAnalogue + 1,
            "measured delta was not exactly +1 — re-check this test's own header numbers against whatever this run actually produced"
        )
    }
}
