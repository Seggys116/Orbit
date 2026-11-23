//  SwiftUI writes a dragged item's type identifier to the drag pasteboard in lower case, and AppKit offers a drag only to a view
//  registered for a type that appears on it as the same string. These tests use the spelling a real sidebar drag carries, which
//  the earlier tests did not: they wrote the identifier as declared, so a page target registered for that spelling passed them
//  while a real drag was never offered to it.

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

@MainActor
final class SidebarDragPasteboardTypeTests: XCTestCase {

    private let declared = UTType.orbitSidebarNode.identifier
    private var written: String { declared.lowercased() }

    override func tearDown() {
        NSPasteboard(name: .drag).clearContents()
        super.tearDown()
    }

    func test_theTypeAsSwiftUIWritesItIsOneOfTheSpellings() {
        XCTAssertNotEqual(declared, written, "the declared identifier is already lower case, so this spelling cannot differ and the test proves nothing")
        XCTAssertTrue(SidebarDragPasteboardType.spellings.contains(NSPasteboard.PasteboardType(written)))
        XCTAssertTrue(SidebarDragPasteboardType.spellings.contains(NSPasteboard.PasteboardType(declared)))
    }

    func test_aPasteboardListingEitherSpellingOffersTheSidebarTab_andOneListingNeitherDoesNot() {
        XCTAssertTrue(SidebarDragPasteboardType.isOffered(in: [NSPasteboard.PasteboardType(written)]))
        XCTAssertTrue(SidebarDragPasteboardType.isOffered(in: [NSPasteboard.PasteboardType(declared)]))
        XCTAssertFalse(SidebarDragPasteboardType.isOffered(in: [.fileURL, .string]))
    }

    func test_theSplitTargetIsRegisteredForTheSpellingARealDragCarries() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let catcher = SplitPaneDropCatcherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let host = NSView(frame: catcher.frame)
        host.addSubview(catcher)
        window.contentView = host
        window.orderFront(nil)

        let registered = Set(catcher.registeredDraggedTypes.map(\.rawValue))
        XCTAssertTrue(registered.contains(written), "A drag whose pasteboard lists \(written) is never offered to the split target; registered for \(registered)")
    }

    // The pasteboard of a real sidebar drag also lists a file promise, which on its own reads as a file from another app.
    func test_aRealDragsTypesAreTakenForTheSidebarsEvenWithAFilePromiseOnThem() {
        let types = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url", written, "com.apple.pasteboard.NSFilePromiseID"].map { NSPasteboard.PasteboardType($0) }
        XCTAssertTrue(SplitPaneDropCatcherView.isSidebarDrag(types: types, recordMatchesPasteboard: false))
    }

    func test_theTabCanBeReadBackFromTheSpellingARealDragCarries() throws {
        let payload = SidebarDragPayload(nodeID: UUID(), kind: .todayTab, spaceID: UUID())
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(payload), forType: NSPasteboard.PasteboardType(written))
        pasteboard.writeObjects([item])

        let read = SidebarDragPayload.decodeSynchronously()
        XCTAssertEqual(read.first?.nodeID, payload.nodeID, "The dragged tab could not be read from the drag pasteboard")
    }
}
