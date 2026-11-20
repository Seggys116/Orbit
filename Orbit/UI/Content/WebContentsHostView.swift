import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
import OSLog
#endif

private final class WebContentsHostContainerView: NSView {
    // Re-runs the embed on window join/leave: SwiftUI builds a representable's view detached, so joining a window is the first reliable on-screen signal.
    var windowDidChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?()
    }

    // Hidden slots keep their old size, so a window resize does not lay out pages nobody can see.
    override func layout() {
        super.layout()
        for slot in subviews.compactMap({ $0 as? PageSlotView }) where !slot.isHidden && slot.frame != bounds {
            slot.frame = bounds
        }
    }
}

/// One page a pane has shown. The page, and a docked inspector beside it, sit inside, so hiding the slot hides both.
/// Hidden slots stay in the window: showing the page again is an unhide, not a window re-join that restarts compositing.
private final class PageSlotView: NSView {
    // Hidden pages kept per pane beyond the one on screen. A tab inside this window is un-hidden on switch; an older one is re-embedded and re-composited, which is the slow, variable swap.
    static let warmPageLimit = 8

    private static var showClock: UInt64 = 0

    let contentsID: UUID
    weak var contents: (any WebContents)?
    private(set) var lastShown: UInt64 = 0

    init(contents: any WebContents, frame: NSRect) {
        contentsID = contents.id
        self.contents = contents
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func markShown() {
        Self.showClock &+= 1
        lastShown = Self.showClock
    }

    /// Whether the page is still in this slot, directly or in its inspector dock host. Anything else that shows the
    /// page moves the view out, since a view has one superview.
    func holds(_ page: any WebContents) -> Bool {
        let superview = page.view.superview
        if superview === self { return true }
        if let host = superview as? InspectorDockHost, host.superview === self { return true }
        return false
    }
}

// hitTest always returns nil so this overlay never swallows a page click.
private final class PageOverlayHostingView<Content: View>: NSHostingView<Content> {
    deinit {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    func pointerInOwnSpace() -> CGPoint {
        guard let window else { return .zero }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(inWindow, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// Built in AppKit — @Environment(AppEnvironment.self) crashes here.
struct PageOverlays: View {
    var contentsID: UUID
    var environment: AppEnvironment?
    var pointerInOverlay: () -> CGPoint

    var body: some View {
        ZStack {
            if let environment {
                LinkPreviewOverlayView(pointerInOverlay: pointerInOverlay)
                    .environment(environment)
            }

            LinkHoverStatusView(contentsID: contentsID)
        }
    }
}

struct WebContentsHostView: View {
    var contents: any WebContents

    var environment: AppEnvironment?

    @State private var host = WebContentsPresentationHost()

    private var hostID: UUID { host.id }

    @Environment(\.controlActiveState) private var controlActiveState

    private var presentation: WebContentsPresentation { .shared }

    @ViewBuilder
    private func inspectSplit<Page: View>(@ViewBuilder page: @escaping () -> Page) -> some View {
        if let session = OrbitDevToolsStore.shared.session(for: contents), session.isPresented {
            if session.dock == .undocked {
                OrbitDeviceViewport(model: session.device, page: page)
            } else {
                OrbitInspectSplit(session: session) { OrbitDeviceViewport(model: session.device, page: page) }
            }
        } else {
            page()
        }
    }

    // Composed here, not in ContentCardView, so every surface gets the docked inspector only via the host that owns the engine view, even when a tab is on screen twice.
    var body: some View {
        inspectSplit {
            ZStack {
                // Unclaimed: the frame between this host being built (or switching pages) and its claim shows the page, not a dimmed grey freeze.
                if presentation.isOwner(hostID, of: contents) || presentation.isUnclaimed(contents) {
                    if let session = DevToolsDockState.shared.session(for: contents) {
                        DevToolsDockedPane(
                            page: contents,
                            session: session,
                            environment: environment,
                            hostID: hostID
                        )
                    } else {
                        LiveWebContentsHostView(
                            contents: contents,
                            environment: environment,
                            hostID: hostID,
                            presentationRequest: presentation.presentationRequest(for: contents)
                        )
                    }
                } else {
                    FrozenWebContentsView(image: presentation.frozenFrame(for: contents))
                }
            }
        }
        .onAppear { presentation.claim(hostID, of: contents) }
        .onDisappear { presentation.unregister(hostID, for: contents) }
        // A rematerialised WebContents is a different object behind the same pane.
        .onChange(of: contents.id) { previous, _ in
            presentation.unregister(hostID, forContentsKey: previous)
            presentation.claim(hostID, of: contents)
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { presentation.claim(hostID, of: contents) }
        }
        // A reload or reselect in this window brings the page back to this pane, even if another host had taken it.
        .onChange(of: presentation.presentationRequest(for: contents)) { _, _ in
            if controlActiveState == .key { presentation.claim(hostID, of: contents) }
        }
    }
}

struct LiveWebContentsHostView: NSViewRepresentable {
    var contents: any WebContents

    var environment: AppEnvironment?

    // Re-checked on every embed: two windows can update in an order SwiftUI does not define.
    var hostID: UUID

    // Changes when the user reloads or reselects the page, so the embed below re-asserts it is shown.
    var presentationRequest: Int = 0

    final class Coordinator {
        var lastPresentationRequest = 0
        var lastContentsID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = WebContentsHostContainerView()
        container.wantsLayer = true
        paintPlaceholderBackground(on: container)
        // Not embedded here: SwiftUI can discard a built NSView, and embedding from makeNSView could move the engine view into a container never installed.
        container.windowDidChange = { [weak container] in
            guard let container else { return }
            onWindowChange(of: container)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WebContentsHostContainerView)?.windowDidChange = { [weak nsView] in
            guard let nsView else { return }
            onWindowChange(of: nsView)
        }
        paintPlaceholderBackground(on: nsView)
        embedIfEntitled(in: nsView)
        let coordinator = context.coordinator
        if coordinator.lastContentsID != contents.id {
            // The pane switched pages; the embed above has just shown the incoming one.
            coordinator.lastContentsID = contents.id
            coordinator.lastPresentationRequest = presentationRequest
        } else if coordinator.lastPresentationRequest != presentationRequest {
            coordinator.lastPresentationRequest = presentationRequest
            reassertVisible(in: nsView)
        }
    }

    /// A page left hidden or marked occluded paints nothing, and a reload of it changes nothing on screen.
    private func reassertVisible(in container: NSView) {
        guard WebContentsPresentation.shared.isOwner(hostID, of: contents),
              let slot = pageSlot(for: contents, in: container), slot.holds(contents) else { return }
        if slot.isHidden { reveal(slot, in: container) }
        contents.view.isHidden = false
        contents.setVisible(true)
        contents.view.needsDisplay = true
    }

    /// What shows for the frame or two between the engine view joining the window and its first paint. Without a
    /// colour of its own that is the window's tinted backdrop, which reads as a grey flash on every tab swap.
    /// The page's own background colour makes the swap read as the page arriving rather than a screen in between.
    private func paintPlaceholderBackground(on container: NSView) {
        let color = placeholderColor(in: container)
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = color.cgColor
        }
    }

    private func placeholderColor(in container: NSView) -> NSColor {
        guard let environment, let tabID = environment.tabID(for: contents) else { return .textBackgroundColor }
        let resolver = PaneHeaderColorResolver.shared
        let known = environment.documentColors[tabID]
            ?? resolver.documentColor(forTab: tabID)
            ?? environment.themeColors[tabID]
        return known?.nsColor ?? .textBackgroundColor
    }

    // A container that has lost its window must never re-adopt: the replacing pane may already hold the engine view.
    private func onWindowChange(of container: NSView) {
        guard container.window != nil else {
            // Warm pages leave the window with the container; only pages still in it are told, never one another pane holds.
            for slot in pageSlots(in: container) {
                if let page = slot.contents, slot.holds(page) { page.setVisible(false) }
            }
            return
        }
        embedIfEntitled(in: container)
    }

    private func embedIfEntitled(in container: NSView) {
        // Element fullscreen: WebKit moved the page into its own window and restores it on exit; taking it now would end the fullscreen.
        guard !contents.mediaState.isFullscreen else { return }
        dropSlotsNoLongerHeld(in: container)
        let presentation = WebContentsPresentation.shared
        guard presentation.isOwner(hostID, of: contents) else {
            // Unclaimed is the moment between this pane switching to the page and its claim: keep the screen as it is until then.
            if !presentation.isUnclaimed(contents) { releasePage(from: container) }
            return
        }
        let slot: PageSlotView
        // The page sits in an InspectorDockHost inside its slot; treating that as "not embedded" rebuilt the host on every SwiftUI update.
        if let held = pageSlot(for: contents, in: container) {
            slot = held
            if held.isHidden {
                reveal(held, in: container)
            } else if container.window == nil {
                // Only while this container has no window: WebContentsViewCocoa reads that state as hidden despite the pane holding the view to show it.
                contents.setVisible(true)
            }
            #if DEBUG
            LiveWebContentsHostView.logSelfCheck(webView: contents.view, container: container, label: "update-already-matched")
            #endif
        } else {
            slot = addSlot(for: contents, in: container)
            embed(contents.view, in: slot, container: container)
        }
        slot.markShown()
        concealPages(otherThan: slot, in: container)
        evictColdPages(in: container)
        installDropCatcherIfNeeded(in: container)
        installLinkDropCatcherIfNeeded(in: container)
        installOverlayIfNeeded(in: container)
    }

    // MARK: - Page slots

    private func pageSlots(in container: NSView) -> [PageSlotView] {
        container.subviews.compactMap { $0 as? PageSlotView }
    }

    private func pageSlot(for page: any WebContents, in container: NSView) -> PageSlotView? {
        pageSlots(in: container).first { $0.contentsID == page.id && $0.contents === page }
    }

    /// Forgets slots whose page is gone, closed or now shown by another host. A page that moved is not touched:
    /// its new host has already made it visible there.
    private func dropSlotsNoLongerHeld(in container: NSView) {
        for slot in pageSlots(in: container) {
            guard let page = slot.contents, !page.isClosed, page.id == slot.contentsID else {
                slot.removeFromSuperview()
                continue
            }
            // WebKit left a placeholder here while the page is fullscreen and puts the page back on exit.
            if page.mediaState.isFullscreen { continue }
            if !slot.holds(page) { slot.removeFromSuperview() }
        }
    }

    // Below the drop catchers and page overlay, which must stay above whichever page is showing.
    private func addSlot(for page: any WebContents, in container: NSView) -> PageSlotView {
        let slot = PageSlotView(contents: page, frame: container.bounds)
        if let chrome = container.subviews.first(where: { !($0 is PageSlotView) }) {
            container.addSubview(slot, positioned: .below, relativeTo: chrome)
        } else {
            container.addSubview(slot)
        }
        return slot
    }

    // No layout pass: the page is already laid out in this window, and only a size change since it was hidden needs work.
    private func reveal(_ slot: PageSlotView, in container: NSView) {
        slot.autoresizingMask = [.width, .height]
        if slot.frame != container.bounds { slot.frame = container.bounds }
        slot.isHidden = false
        contents.view.isHidden = false
        contents.setVisible(true)
    }

    private func concealPages(otherThan shown: PageSlotView, in container: NSView) {
        // A fullscreen page's slot holds only WebKit's placeholder, so it is hidden too but the page is not told.
        for slot in pageSlots(in: container) where slot !== shown && !slot.isHidden {
            guard let page = slot.contents else { continue }
            // Hiding the first responder hands focus to the next key view; leaving it with the window matches the page being removed.
            if let window = container.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: slot) {
                window.makeFirstResponder(nil)
            }
            slot.autoresizingMask = []
            slot.isHidden = true
            if slot.holds(page) { page.setVisible(false) }
        }
    }

    private func evictColdPages(in container: NSView) {
        let warm = pageSlots(in: container)
            .filter { $0.isHidden && !($0.contents?.mediaState.isFullscreen ?? false) }
            .sorted { $0.lastShown > $1.lastShown }
        for slot in warm.dropFirst(PageSlotView.warmPageLimit) {
            let page = slot.contents
            let held = page.map { slot.holds($0) } ?? false
            slot.removeFromSuperview()
            // After the removal, as releasePage does: the page is windowless now and must not keep compositing.
            if held { page?.setVisible(false) }
        }
    }

    // Above the web view, under the click-through page overlay; SwiftUI's drop destination sits behind WebKit.
    private func installDropCatcherIfNeeded(in container: NSView) {
        let catcher = container.subviews.compactMap { $0 as? SplitPaneDropCatcherView }.first
            ?? SplitPaneDropCatcherView(frame: container.bounds)
        catcher.environment = environment
        catcher.targetTabID = environment?.tabID(for: contents)
        guard catcher.superview !== container else { return }
        catcher.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(catcher)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: container.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // External link drags: the engine view registers for URL drags itself, so this sits above it and only claims a hit while such a drag is over the page.
    private func installLinkDropCatcherIfNeeded(in container: NSView) {
        let catcher = container.subviews.compactMap { $0 as? LinkDropCatcherView }.first
            ?? LinkDropCatcherView(frame: container.bounds)
        catcher.environment = environment
        catcher.targetTabID = environment?.tabID(for: contents)
        guard catcher.superview !== container else { return }
        catcher.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(catcher)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: container.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // positioned: .above — kept explicitly topmost over every page slot and both drop catchers.
    private func installOverlayIfNeeded(in container: NSView) {
        let existing = container.subviews.compactMap { $0 as? PageOverlayHostingView<PageOverlays> }.first
        let overlay = existing ?? PageOverlayHostingView(
            rootView: PageOverlays(contentsID: contents.id, environment: environment, pointerInOverlay: { .zero })
        )
        overlay.rootView = PageOverlays(
            contentsID: contents.id,
            environment: environment,
            pointerInOverlay: { [weak overlay] in overlay?.pointerInOwnSpace() ?? .zero }
        )

        guard overlay.superview !== container || container.subviews.last !== overlay else { return }

        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Reordering keeps the existing constraints; re-activating adds four duplicates per re-embed.
        let needsConstraints = overlay.superview !== container
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        guard needsConstraints else { return }
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // Another host owns the page and is taking it; its slot, warm or showing, goes with it.
    private func releasePage(from container: NSView) {
        guard let slot = pageSlot(for: contents, in: container) else { return }
        let holdsPage = slot.holds(contents)
        slot.removeFromSuperview()
        if holdsPage { contents.setVisible(false) }
    }

    private func embed(_ webView: NSView, in slot: NSView, container: NSView) {
        // Moved out of a hidden slot in this same window, the view gets no unhide of its own and WebKit keeps the page hidden.
        let leavesHiddenTree = webView.window != nil && webView.isHiddenOrHasHiddenAncestor
        webView.isHidden = false
        if let dockable = contents as? any InspectorDockableContents {
            dockable.embedForInspectorDocking(in: slot)
        } else {
            webView.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                webView.topAnchor.constraint(equalTo: slot.topAnchor),
                webView.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            ])
        }
        if leavesHiddenTree, let window = webView.window, !webView.isHiddenOrHasHiddenAncestor,
           window.firstResponder !== webView {
            webView.isHidden = true
            webView.isHidden = false
        }
        container.layoutSubtreeIfNeeded()
        // After addSubview, never before: AppKit delivers the engine view's viewDidMoveToWindow synchronously inside it, which answers HIDDEN for a windowless container.
        contents.setVisible(true)
        #if DEBUG
        LiveWebContentsHostView.logSelfCheck(webView: webView, container: container, label: "immediate")
        if DiagnosticChannel.webContentsAttachment.isEnabled {
            DispatchQueue.main.async {
                LiveWebContentsHostView.logSelfCheck(webView: webView, container: container, label: "next-runloop-turn")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                LiveWebContentsHostView.logSelfCheck(webView: webView, container: container, label: "settled+1.5s")
            }
        }
        #endif
    }

    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "WebContentsSelfCheck")

    private static func logSelfCheck(webView: NSView, container: NSView, label: String) {
        guard DiagnosticChannel.webContentsAttachment.isEnabled else { return }
        let inWindow = webView.window != nil
        let nonZeroFrame = webView.frame.width > 0 && webView.frame.height > 0
        selfCheckLogger.info("""
        [\(label, privacy: .public)] webContentsView frame=\(String(describing: webView.frame), privacy: .public) \
        hidden=\(webView.isHidden) nonZeroFrame=\(nonZeroFrame) \
        superview=\(String(describing: type(of: webView.superview as Any)), privacy: .public) \
        superviewIsThisContainer=\(webView.superview === container) \
        window=\(String(describing: webView.window), privacy: .public) inWindow=\(inWindow) \
        containerFrame=\(String(describing: container.frame), privacy: .public) \
        containerWindow=\(String(describing: container.window), privacy: .public)
        """)
    }
    #endif
}

final class SplitPaneDropCatcherView: NSView {
    var environment: AppEnvironment?
    var targetTabID: TabID?

    private var dragType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([dragType])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let current = NSApp.currentEvent
        let age = current.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? 0
        guard bounds.contains(point),
              Self.claimsHit(duringEvent: current?.type, eventAge: age, dragInFlight: sidebarDragIsActive),
              Self.dragCarriesSidebarTab(NSPasteboard(name: .drag).types ?? []) else { return nil }
        return self
    }

    /// A record left from an earlier sidebar drag says nothing about the drag under the pointer now. Only a drag that carries a sidebar tab may be taken here; a file, an image or a link dragged in from another app must reach the page.
    static func dragCarriesSidebarTab(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier))
    }

    // A drop target is only wanted while a drag is moving over the page. A click, a release or a scroll is never part of a drag, so it passes through to the page even if a drag record has been left behind; claiming it would leave every pane of a split unclickable until the next drag.
    // Only a fresh event can be a click or a key press in the page. While a drag runs, the app keeps reporting the event that started it as current, so an old one says nothing about what is happening now. A modifier change is never a click: holding Command mid-drag must not hand the drag back to the page.
    static let freshEventWindow: TimeInterval = 0.25

    static func claimsHit(duringEvent type: NSEvent.EventType?, eventAge: TimeInterval = 0, dragInFlight: Bool) -> Bool {
        guard dragInFlight else { return false }
        guard eventAge < freshEventWindow else { return true }
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .scrollWheel, .mouseMoved, .keyDown, .keyUp:
            return false
        default:
            return true
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private var sidebarDragIsActive: Bool {
        SidebarDragSession.hasInFlightDrag
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard refreshHighlight(with: sender) else { return [] }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard refreshHighlight(with: sender) else { return [] }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearHighlightIfMine()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearHighlightIfMine()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearHighlightIfMine() }
        guard let environment, let targetTabID, let payload = payload(),
              let dragged = draggedTabID(payload, in: environment),
              accepts(dragged, onto: targetTabID, in: environment) else { return false }
        environment.createSplit(existingTabID: targetTabID, newTabID: dragged, edge: edge(for: sender))
        SidebarDragSession.end()
        return true
    }

    private func refreshHighlight(with sender: NSDraggingInfo) -> Bool {
        guard let environment, let targetTabID, let payload = payload(),
              let dragged = draggedTabID(payload, in: environment),
              accepts(dragged, onto: targetTabID, in: environment) else {
            clearHighlightIfMine()
            return false
        }
        let zone = SplitDropZone(edge: edge(for: sender), targetTabID: targetTabID)
        guard environment.activeSplitDropZone != zone else { return true }
        environment.activeSplitDropZone = zone
        return true
    }

    private func accepts(_ dragged: TabID, onto target: TabID, in environment: AppEnvironment) -> Bool {
        guard dragged != target else { return false }
        if let group = environment.splitGroup(for: target) {
            if group.tabIDs.contains(dragged) { return false }
            if group.tabIDs.count >= SplitGroup.maximumPanes { return false }
        }
        return environment.tab(dragged) != nil
    }

    private func edge(for sender: NSDraggingInfo) -> SplitEdge {
        let point = convert(sender.draggingLocation, from: nil)
        let location = CGPoint(x: point.x, y: bounds.height - point.y)
        let axis = targetTabID.flatMap { environment?.splitGroup(for: $0)?.axis }
        return SplitDropZoneGeometry.edge(at: location, in: bounds.size, allowedOrientation: axis)
    }

    private func payload() -> SidebarDragPayload? {
        if let current = SidebarDragSession.current { return current }
        return SidebarDragPayload.decodeSynchronously().first
    }

    private func draggedTabID(_ payload: SidebarDragPayload, in environment: AppEnvironment) -> TabID? {
        switch payload.kind {
        case .favorite:
            return environment.resolvedTab(forFavorite: payload.nodeID, in: payload.spaceID)
        case .todayTab, .pinnedNode:
            return payload.nodeID
        }
    }

    private func clearHighlightIfMine() {
        guard let environment, environment.activeSplitDropZone?.targetTabID == targetTabID else { return }
        environment.activeSplitDropZone = nil
    }
}
