import AppKit

/// What a drag destination is handed while a drag is over it. A test builds one over a pasteboard it controls, because no process can start a drag from another app.
final class StandInDraggingInfo: NSObject, NSDraggingInfo {
    var location: NSPoint
    var sourceMask: NSDragOperation
    let pasteboard: NSPasteboard
    weak var targetWindow: NSWindow?

    init(location: NSPoint, pasteboard: NSPasteboard, window: NSWindow, sourceMask: NSDragOperation = [.copy, .link, .generic]) {
        self.location = location
        self.pasteboard = pasteboard
        self.sourceMask = sourceMask
        targetWindow = window
    }

    var draggingDestinationWindow: NSWindow? { targetWindow }
    var draggingSourceOperationMask: NSDragOperation { sourceMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
