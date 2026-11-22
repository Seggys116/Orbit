import AppKit

/// A drop target laid over the page that is handed a drag it has no use for (a file, an image, text that is not a link) passes the whole drag on to the view under it, so a site's upload zone sees the same drag it would see in any browser.
@MainActor
final class PageDragForwarder {
    private weak var target: NSView?

    var isForwarding: Bool { target != nil }

    /// The view under `overlay`, in the same container, that registered for what is being dragged and is under the pointer.
    static func pageView(beneath overlay: NSView, atWindowPoint point: NSPoint, accepting types: [NSPasteboard.PasteboardType]) -> NSView? {
        guard let container = overlay.superview else { return nil }
        let wanted = Set(types)
        let local = container.convert(point, from: nil)
        for sibling in container.subviews.reversed() where sibling !== overlay && !sibling.isHidden && sibling.alphaValue > 0 {
            guard !(sibling is SplitPaneDropCatcherView), !(sibling is LinkDropCatcherView), let hit = sibling.hitTest(local) else { continue }
            var view: NSView? = hit
            while let current = view, current !== container {
                if !wanted.isDisjoint(with: current.registeredDraggedTypes) { return current }
                view = current.superview
            }
        }
        return nil
    }

    /// Offers the drag to the page: entering it the first time, and moving within it after that.
    func offer(_ sender: NSDraggingInfo, from overlay: NSView) -> NSDragOperation {
        guard let found = Self.pageView(beneath: overlay, atWindowPoint: sender.draggingLocation, accepting: sender.draggingPasteboard.types ?? []) else {
            withdraw(sender)
            return []
        }
        if found === target { return found.draggingUpdated(sender) }
        withdraw(sender)
        target = found
        return found.draggingEntered(sender)
    }

    /// The overlay is taking the drag itself, or the drag left: the page is told it has gone.
    func withdraw(_ sender: NSDraggingInfo?) {
        guard let target else { return }
        self.target = nil
        target.draggingExited(sender)
    }

    func prepare(_ sender: NSDraggingInfo) -> Bool? {
        target.map { $0.prepareForDragOperation(sender) }
    }

    func perform(_ sender: NSDraggingInfo) -> Bool? {
        target.map { $0.performDragOperation(sender) }
    }

    func conclude(_ sender: NSDraggingInfo?) {
        guard let target else { return }
        self.target = nil
        target.concludeDragOperation(sender)
    }

    func end(_ sender: NSDraggingInfo) {
        guard let target else { return }
        self.target = nil
        target.draggingEnded(sender)
    }
}
