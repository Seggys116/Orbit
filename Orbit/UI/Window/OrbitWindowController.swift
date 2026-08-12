import AppKit
import SwiftUI

@MainActor
final class OrbitWindowController: NSWindowController, NSWindowDelegate {

    private static var openControllers: [OrbitWindowController] = []

    #if DEBUG
    static func _test_register(_ controller: OrbitWindowController) {
        openControllers.append(controller)
    }
    #endif

    // MARK: - Session

    // Computed, not stored: a stored initial value would evaluate WindowSession.standard()
    // before adopt(_:) runs, touching the real (iCloud-synced) environment in Demo.
    var session: WindowSession {
        if let adoptedSession { return adoptedSession }
        let standard = WindowSession.standard(on: .processRoot)
        adoptedSession = standard
        return standard
    }

    private var adoptedSession: WindowSession?

    private var lastPushedWindowState: OrbitWindowState?

    // Must be called before configure()/installContentView(window:); the hosting
    // view captures session.environment at construction time.
    func adopt(_ session: WindowSession) {
        adoptedSession = session
    }

    static var frontmostEnvironment: AppEnvironment? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let controller = openControllers.first(where: { $0.window === window }) {
                return controller.session.environment
            }
        }
        return nil
    }

    static var openEnvironments: [AppEnvironment] {
        openControllers.map { $0.session.environment }
    }

    static func controller(for environment: AppEnvironment) -> OrbitWindowController? {
        openControllers.first { $0.session.environment === environment }
    }

    // false whenever neither keyWindow nor mainWindow exists (headless test host, or the app isn't frontmost) — that is not "some unrelated surface is on screen".
    static var keyWindowIsUnrelatedSurface: Bool {
        guard let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        return !openControllers.contains(where: { $0.window === keyWindow })
    }

    @discardableResult
    static func activateBrowserWindow() -> Bool {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 })
        where openControllers.contains(where: { $0.window === window }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        if let existing = openControllers.last(where: { $0.window?.isVisible == true })?.window {
            existing.makeKeyAndOrderFront(nil)
            return false
        }
        openNewWindow()
        return true
    }

    // MARK: - Factory

    @discardableResult
    static func openNewWindow(on host: AppEnvironment = .processRoot) -> OrbitWindowController {
        open(session: .standard(on: host))
    }

    @discardableResult
    static func openIncognitoWindow(on host: AppEnvironment = .processRoot) -> OrbitWindowController {
        open(session: .incognito(on: host))
    }

    private static func open(session: WindowSession) -> OrbitWindowController {
        let controller = OrbitWindowController(window: OrbitWindowController.makeWindow())
        controller.adopt(session)
        controller.configure()
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @discardableResult
    static func openTornOffWindow(
        adopting tabID: TabID,
        at screenPoint: NSPoint? = nil,
        on host: AppEnvironment = .processRoot
    ) -> OrbitWindowController? {
        guard let session = WindowSession.tornOff(on: host, adopting: tabID) else { return nil }
        let window = OrbitWindowController.makeWindow()
        if let screenPoint {
            OrbitWindowController.position(window, under: screenPoint)
        }
        let controller = OrbitWindowController(window: window)
        controller.adopt(session)
        controller.configure()
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private static func position(_ window: NSWindow, under screenPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size

        let horizontalOffset: CGFloat = 24
        let verticalOffset: CGFloat = 24
        // AppKit's window origin is its bottom-left corner: subtract the full height to
        // land near the top-left instead.
        var origin = NSPoint(
            x: screenPoint.x - horizontalOffset,
            y: screenPoint.y - size.height + verticalOffset
        )
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        window.setFrameOrigin(origin)
    }

    static func makeWindow() -> NSWindow {
        let window = OrbitBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 480)
        // Both must be set together: backgroundColor = .clear alone still composites opaque;
        // isOpaque = false alone blurs behind a colour nobody can see through.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
        return window
    }

    private func configure() {
        guard let window else { return }
        window.delegate = self
        // No-op for incognito/torn-off (WindowSession already registered them); only the
        // shared/standard environment, which can back multiple windows, needs registering here.
        session.environment.startEngineIfNeeded()
        installContentView(window: window)
        // After the engine start above: the bridge cannot push to C until its
        // symbols are resolved.
        if !OrbitChromiumTabsBridge.shared.isWindowRegistered(session.environment) {
            OrbitChromiumTabsBridge.shared.windowCreated(owner: session.environment, focused: false)
        }
        pushChromiumWindowState()
    }

    // chrome.windows' Window.state must read the real NSWindow: before this, a minimized,
    // zoomed or fullscreen window all reported as "normal".
    private func pushChromiumWindowState() {
        guard let window else { return }
        let state: OrbitWindowState
        if window.isMiniaturized {
            state = .minimized
        } else if window.styleMask.contains(.fullScreen) {
            state = .fullscreen
        } else if window.isZoomed {
            state = .maximized
        } else {
            state = .normal
        }
        guard state != lastPushedWindowState else { return }
        lastPushedWindowState = state
        OrbitChromiumTabsBridge.shared.windowStateChanged(owner: session.environment, state: state)
    }

    // Hidden, not removed: Cmd+W and Mission Control's window menu still need the real
    // buttons; WindowControlsView draws and handles everything actually visible.
    func installContentView(window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: OrbitWindowRootView(environment: session.environment))

        // safeAreaRegions = [] is only safe inside the OrbitWindowContentView wrapper below;
        // as the window's own contentView it would grow the frame every layout pass (infinite loop).
        hosting.safeAreaRegions = []

        // Empty, not .standardBounds: SwiftUI's own ideal size would otherwise become a
        // required Auto Layout constraint pinning the window open at that height.
        hosting.sizingOptions = []

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: contentSize))

        // Installed here in AppKit, not as a SwiftUI NSViewRepresentable: ImageRenderer can't
        // flatten one off-screen and paints an opaque fallback over every render-suite screenshot.
        let backdrop = OrbitAcrylicBackdropView(frame: container.bounds)
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)

        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        OrbitWindowController.openControllers.removeAll { $0 === self }
        // WindowSession.dispose() handles incognito/torn-off's own windowRemoved push; the shared
        // environment is never unregistered here, or its still-registered tabs would be orphaned.
        session.dispose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        OrbitChromiumTabsBridge.shared.windowFocusChanged(owner: session.environment)
    }

    func windowDidMiniaturize(_ notification: Notification) { pushChromiumWindowState() }

    func windowDidDeminiaturize(_ notification: Notification) { pushChromiumWindowState() }

    func windowDidEnterFullScreen(_ notification: Notification) { pushChromiumWindowState() }

    func windowDidExitFullScreen(_ notification: Notification) { pushChromiumWindowState() }

    // Zoom (green button) is implemented as a resize, so this hook also catches it; the
    // cached-state comparison in pushChromiumWindowState dedupes the live-resize storm.
    func windowDidResize(_ notification: Notification) { pushChromiumWindowState() }

    func windowDidResignKey(_ notification: Notification) {
        let orbitWindows = OrbitWindowController.openControllers.compactMap(\.window)
        guard !OrbitWindowController.isAttached(NSApp.keyWindow, toOneOf: orbitWindows) else { return }
        OrbitChromiumTabsBridge.shared.windowFocusChanged(owner: nil)
    }

    // A popover/sheet child window taking key status is not Orbit losing focus. Extension
    // action popups are hosted this way; reporting focus-lost broke chrome.tabs.query(currentWindow).
    static func isAttached(_ window: NSWindow?, toOneOf orbitWindows: [NSWindow]) -> Bool {
        var candidate = window
        while let current = candidate {
            if orbitWindows.contains(where: { $0 === current }) { return true }
            candidate = current.parent
        }
        return false
    }
}

struct OrbitWindowRootView: View {
    let environment: AppEnvironment

    var body: some View {
        RootView().orbitEnvironment(environment)
    }
}

final class OrbitAcrylicBackdropView: NSVisualEffectView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // NSVisualEffectView answers hit tests with itself by default; nil lets a click
    // fall through to OrbitWindowContentView instead of being swallowed here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class OrbitBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Removing this wrapper looks safe and is not: see installContentView(window:) for the
// growth loop that returns the moment NSHostingView becomes the contentView itself.
final class OrbitWindowContentView: NSView {

    // MARK: - Click recovery

    // NSHostingView.hitTest swallows NSViewRepresentable mouseDown when AppKit's walk resolves
    // to a SwiftUI container; recover by asking the tree directly for the topmost click-catcher.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let resolved = super.hitTest(point)
        guard OrbitWindowContentView.isSwiftUIContainer(resolved) else { return resolved }
        return OrbitWindowContentView.topmostClickCatcher(in: self, atPointInWindow: convert(point, to: nil)) ?? resolved
    }

    // NSHostingView<...> and _NSGraphicsView are SwiftUI internals with no public symbol
    // to reference, hence the name match.
    static func isSwiftUIContainer(_ view: NSView?) -> Bool {
        guard let view else { return false }
        let name = "\(type(of: view))"
        return name.hasPrefix("NSHostingView") || name == "_NSGraphicsView"
    }

    static func topmostClickCatcher(in root: NSView, atPointInWindow pointInWindow: NSPoint) -> NSView? {
        for subview in root.subviews.reversed() {
            if let found = topmostClickCatcher(in: subview, atPointInWindow: pointInWindow) { return found }
        }
        // isHidden/alphaValue guard needed: this walk calls hitTest directly on the catcher,
        // bypassing AppKit's own skip of hidden/transparent subviews during a normal walk.
        guard isClickCatcher(root), !root.isHidden, root.alphaValue > 0 else { return nil }
        // hitTest takes a point in the catcher's own superview's space; see
        // ClickCatcherHitTesting.swift for why comparing it to bounds directly is wrong.
        guard let superview = root.superview else { return nil }
        return root.hitTest(superview.convert(pointInWindow, from: nil))
    }

    // Conformance, not a name-suffix test: a suffix check missed two of the five real
    // catchers and is not inherited by subclasses.
    static func isClickCatcher(_ view: NSView) -> Bool {
        view is OrbitClickCatching
    }
}
