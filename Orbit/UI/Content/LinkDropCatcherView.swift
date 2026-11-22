import AppKit
import UniformTypeIdentifiers

@MainActor
enum LinkDropAction {
    static func openInNewTab(_ url: URL, in spaceID: SpaceID, environment: AppEnvironment) {
        environment.openTab(url: url, in: spaceID)
    }

    /// Only an edge opens anything. The middle of the page is where a link dragged in is let go of, so dropping it there does nothing: a new tab is one click away for anyone who wants one.
    static func open(_ url: URL, zone: LinkDropZone, onto targetTabID: TabID, in environment: AppEnvironment) {
        guard let target = environment.tab(targetTabID), let edge = zone.splitEdge else { return }
        let newTabID = environment.openTab(url: url, in: target.spaceID, section: .today, activate: false)
        environment.createSplit(existingTabID: targetTabID, newTabID: newTabID, edge: edge)
        environment.activateTab(newTabID)
    }
}

/// Records where the last primary press landed and what the drag pasteboard held then, so a drag that began inside a page and a stale pasteboard can both be told apart from an external drag.
@MainActor
final class LinkDragOriginTracker {
    static let shared = LinkDragOriginTracker()

    private var monitor: Any?
    private(set) var window: NSWindow?
    private(set) var locationInWindow: NSPoint = .zero
    private(set) var dragChangeCount = NSPasteboard(name: .drag).changeCount

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.window = event.window
                self?.locationInWindow = event.locationInWindow
                self?.dragChangeCount = NSPasteboard(name: .drag).changeCount
            }
            return event
        }
    }
}

final class LinkDropCatcherView: NSView {
    var environment: AppEnvironment?
    var targetTabID: TabID?

    private let overlay = LinkDropOverlayView()
    private let forwarder = PageDragForwarder()
    private var cachedPayload: (changeCount: Int, payload: LinkDropPayload?)?

    private static let draggedTypes: [NSPasteboard.PasteboardType] = [
        .URL, .fileURL, .string,
        NSPasteboard.PasteboardType(UTType.url.identifier),
        NSPasteboard.PasteboardType(UTType.fileURL.identifier),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(Self.draggedTypes)
        LinkDragOriginTracker.shared.install()
    }

    private var dragBeganInThisPage: Bool {
        let tracker = LinkDragOriginTracker.shared
        guard let window, tracker.window === window else { return false }
        return bounds.contains(convert(tracker.locationInWindow, from: nil))
    }

    private func payload(in pasteboard: NSPasteboard) -> LinkDropPayload? {
        if let cachedPayload, cachedPayload.changeCount == pasteboard.changeCount { return cachedPayload.payload }
        let payload = LinkDropLogic.payload(from: pasteboard)
        cachedPayload = (pasteboard.changeCount, payload)
        return payload
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSEvent.pressedMouseButtons & 1 != 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        let pasteboard = NSPasteboard(name: .drag)
        let changed = pasteboard.changeCount != LinkDragOriginTracker.shared.dragChangeCount
        let claims = LinkDropLogic.claimsHit(
            eventType: NSApp.currentEvent?.type,
            primaryButtonDown: true,
            dragPasteboardChanged: changed,
            sidebarDragInFlight: SidebarDragSession.hasInFlightDrag,
            payload: changed ? payload(in: pasteboard) : nil,
            dragBeganInThisPage: dragBeganInThisPage
        )
        return claims ? self : nil
    }

    private func zone(for sender: NSDraggingInfo) -> LinkDropZone {
        let local = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: local.x, y: bounds.height - local.y)
        let group = targetTabID.flatMap { environment?.splitGroup(for: $0) }
        return LinkDropLogic.zone(
            at: point,
            in: bounds.size,
            splitAxis: group?.axis,
            splitAllowed: LinkDropLogic.splitAllowed(paneCountInGroup: group?.tabIDs.count)
        )
    }

    private func acceptedPayload(from sender: NSDraggingInfo) -> LinkDropPayload? {
        let candidate = payload(in: sender.draggingPasteboard)
        return LinkDropLogic.accepts(candidate, dragBeganInThisPage: dragBeganInThisPage) ? candidate : nil
    }

    private func refresh(with sender: NSDraggingInfo) -> NSDragOperation {
        // Anything that is not a link for this view to open is the page's: a file, an image, text.
        guard acceptedPayload(from: sender) != nil else {
            overlay.dismiss()
            return forwarder.offer(sender, from: self)
        }
        forwarder.withdraw(sender)
        let operation = LinkDropLogic.dragOperation(for: sender.draggingSourceOperationMask)
        guard environment != nil, targetTabID != nil, !operation.isEmpty else {
            overlay.dismiss()
            return []
        }
        // Outside the edges there is nothing to drop on, so the drag can be taken back out without opening anything.
        let landing = zone(for: sender)
        guard landing.splitEdge != nil else {
            overlay.dismiss()
            return []
        }
        overlay.present(landing)
        return operation
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { refresh(with: sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { refresh(with: sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        overlay.dismiss()
        forwarder.withdraw(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        overlay.dismiss()
        forwarder.end(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { forwarder.prepare(sender) ?? true }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        overlay.dismiss()
        forwarder.conclude(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { overlay.dismiss() }
        if let forwarded = forwarder.perform(sender) { return forwarded }
        guard let environment, let targetTabID, let payload = acceptedPayload(from: sender) else { return false }
        let landing = zone(for: sender)
        guard landing.splitEdge != nil else { return false }
        LinkDropAction.open(payload.url, zone: landing, onto: targetTabID, in: environment)
        return true
    }
}
