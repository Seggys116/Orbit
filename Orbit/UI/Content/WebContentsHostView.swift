import AppKit
import SwiftUI
#if DEBUG
import OSLog
#endif

private final class WebContentsHostContainerView: NSView {
    // Re-runs the embed on window join/leave: SwiftUI builds a representable's view
    // detached and installs it later, so joining a window is the first reliable signal this container is really on-screen.
    var windowDidChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?()
    }
}

// hitTest always returns nil so this overlay never swallows a page click.
private final class PageOverlayHostingView<Content: View>: NSHostingView<Content> {
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

    @State private var hostID = UUID()

    @Environment(\.controlActiveState) private var controlActiveState

    private var presentation: WebContentsPresentation { .shared }

    // Composed here, not in ContentCardView, so every surface a tab can appear in gets
    // the docked inspector, but only via the host that owns the engine view -- keeping it in one place when a tab is on screen twice.
    var body: some View {
        ZStack {
            if presentation.isOwner(hostID, of: contents) {
                if let session = DevToolsDockState.shared.session(for: contents) {
                    DevToolsDockedPane(
                        page: contents,
                        session: session,
                        environment: environment,
                        hostID: hostID
                    )
                } else {
                    LiveWebContentsHostView(contents: contents, environment: environment, hostID: hostID)
                }
            } else {
                FrozenWebContentsView(image: presentation.frozenFrame(for: contents))
            }
        }
        .onAppear { presentation.claim(hostID, of: contents) }
        .onDisappear { presentation.unregister(hostID, for: contents) }
        // A rematerialised WebContents is a different object behind the same pane.
        .onChange(of: ObjectIdentifier(contents)) { previous, _ in
            presentation.unregister(hostID, forContentsKey: previous)
            presentation.claim(hostID, of: contents)
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { presentation.claim(hostID, of: contents) }
        }
    }
}

struct LiveWebContentsHostView: NSViewRepresentable {
    var contents: any WebContents

    var environment: AppEnvironment?

    // Re-checked on every embed: two windows can update in an order SwiftUI does not define.
    var hostID: UUID

    func makeNSView(context: Context) -> NSView {
        let container = WebContentsHostContainerView()
        container.wantsLayer = true
        // Not embedded here: SwiftUI can build a representable's NSView then discard it,
        // and embedding from makeNSView could move the engine view into a container that's never installed. updateNSView/viewDidMoveToWindow only run for the container SwiftUI keeps.
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
        embedIfEntitled(in: nsView)
    }

    // A container that has lost its window must never re-adopt: by then the
    // pane replacing it may already hold the engine view, and taking it back
    // into a windowless container is the very move this file stopped making.
    private func onWindowChange(of container: NSView) {
        guard container.window != nil else {
            if contents.view.superview === container { contents.setVisible(false) }
            return
        }
        embedIfEntitled(in: container)
    }

    private func embedIfEntitled(in container: NSView) {
        guard WebContentsPresentation.shared.isOwner(hostID, of: contents) else {
            if contents.view.superview === container {
                contents.view.removeFromSuperview()
                contents.setVisible(false)
            }
            return
        }
        if contents.view.superview === container {
            #if DEBUG
            LiveWebContentsHostView.logSelfCheck(webView: contents.view, container: container, label: "update-already-matched")
            #endif
            // Only while this container has no window: that's the one state WebContentsViewCocoa
            // reads as hidden despite the pane holding the view to show it. Once there's a window, content::'s own answer is the true one.
            if container.window == nil { contents.setVisible(true) }
            installOverlayIfNeeded(in: container)
            return
        }
        for subview in container.subviews where !(subview is PageOverlayHostingView<PageOverlays>) {
            subview.removeFromSuperview()
        }
        embed(contents.view, in: container)
        installOverlayIfNeeded(in: container)
    }

    // positioned: .above — embed(_:in:) re-adds the engine view above it otherwise.
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
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func embed(_ webView: NSView, in container: NSView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        // After addSubview, never before: AppKit delivers the engine view's
        // own viewDidMoveToWindow synchronously inside it, and that is the
        // call that answers HIDDEN for a container with no window yet.
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

    // superview is the field to check first for a blank pane (two-host collision).
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
