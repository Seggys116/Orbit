import AppKit
import SwiftUI

@MainActor
final class LittleOrbitWindowController: NSWindowController, NSWindowDelegate {

    private static var openWindows: [TabID: LittleOrbitWindowController] = [:]

    private static var lastOpenedFrame: NSRect?

    static let defaultSize = NSSize(width: 900, height: 680)
    static let minimumSize = NSSize(width: 640, height: 480)
    static let frameAutosaveName = "LittleOrbitWindow"

    let tabID: TabID
    let addressBarModel = LittleOrbitAddressBarModel()
    private var autoCloseTimer: Timer?

    // Once true, windowWillClose must not tear the tab down: closeDetachedTab would
    // delete it from state.tabs while its id already sits in a Space's today list.
    private var hasRelinquishedTab = false

    private init(tabID: TabID, window: NSWindow) {
        self.tabID = tabID
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    static func open(url: URL?) -> LittleOrbitWindowController {
        let target = url ?? URL(string: "orbit://new-tab")!
        return open(tabID: AppEnvironment.processRoot.makeDetachedTab(url: target))
    }

    /// A `window.open()` the engine has already built the WebContents for --
    /// hosted around that live contents rather than materialising a second
    /// one, which is what keeps `window.opener` and the in-flight navigation.
    @discardableResult
    static func open(adopting contents: any WebContents, url: URL) -> LittleOrbitWindowController {
        open(tabID: AppEnvironment.processRoot.adoptPageCreatedDetachedTab(contents, url: url))
    }

    @discardableResult
    private static func open(tabID: TabID) -> LittleOrbitWindowController {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = minimumSize
        // Hidden, not removed: Cmd+W and Mission Control's window menu still need the
        // real buttons. WindowControlsView draws the visible three dots separately.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()

        let hadSiblingWindow = !openWindows.isEmpty
        window.setFrameAutosaveName(frameAutosaveName)
        if hadSiblingWindow, let lastOpenedFrame {
            _ = window.cascadeTopLeft(from: lastOpenedFrame.origin)
        }

        let controller = LittleOrbitWindowController(tabID: tabID, window: window)
        window.delegate = controller
        controller.installContentView(window: window)
        openWindows[tabID] = controller
        lastOpenedFrame = window.frame
        controller.scheduleAutoClose()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    static var frontmostController: LittleOrbitWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return openWindows.values.first { $0.window === keyWindow }
    }

    func relinquishTab() {
        hasRelinquishedTab = true
    }

    func installContentView(window: NSWindow) {
        let hosting = NSHostingView(
            rootView: LittleOrbitView(tabID: tabID, addressBarModel: addressBarModel)
                .orbitEnvironment(AppEnvironment.processRoot)
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: contentSize))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
    }

    static func openFromExternalActivation(url: URL) {
        open(url: url)
    }

    func presentAddressCommandBar() {
        let tab = AppEnvironment.processRoot.tab(tabID)
        var isBlank = false
        if let tab, case .newTab = OrbitScheme.parse(tab.url) { isBlank = true }
        addressBarModel.text = isBlank ? "" : (tab?.url.absoluteString ?? "")
        addressBarModel.isPresented = true
    }

    private func scheduleAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = LittleOrbitWindowController.makeAutoCloseTimer { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }

    static func makeAutoCloseTimer(onFire: @escaping @Sendable () -> Void) -> Timer? {
        guard let interval = LittleOrbitSettings.archiveInterval.seconds else { return nil }
        return Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in onFire() }
    }

    func windowWillClose(_ notification: Notification) {
        autoCloseTimer?.invalidate()
        LittleOrbitWindowController.openWindows.removeValue(forKey: tabID)
        guard !hasRelinquishedTab else { return }
        AppEnvironment.processRoot.closeDetachedTab(tabID)
    }
}

private struct LittleOrbitView: View {
    @Environment(AppEnvironment.self) private var env
    var tabID: TabID
    var addressBarModel: LittleOrbitAddressBarModel

    private var tab: Tab? { env.tab(tabID) }

    private var windowControlsTopInset: CGFloat {
        (OrbitToolbarMetrics.totalHeight - OrbitWindowControlMetrics.diameter) / 2
    }

    var body: some View {
        ZStack {
            paneCard
                .overlay(alignment: .topLeading) { windowControlsOverlay }

            if addressBarModel.isPresented {
                LittleOrbitAddressBarOverlay(model: addressBarModel, tabID: tabID)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(OrbitMotion.standard, value: addressBarModel.isPresented)
        .frame(minWidth: LittleOrbitWindowController.minimumSize.width, minHeight: LittleOrbitWindowController.minimumSize.height)
    }

    private var windowControlsOverlay: some View {
        WindowControlsView()
            .padding(.leading, OrbitMetrics.cardInset + OrbitWindowControlMetrics.leadingInset)
            .padding(.top, OrbitMetrics.cardInset + windowControlsTopInset)
    }

    @ViewBuilder
    private var paneCard: some View {
        if let tab {
            VStack(spacing: 0) {
                ToolbarView(tab: tab, paneCapabilities: .littleOrbitWindow)
                paneContent(for: tab)
            }
            .paneCardChrome(isFocused: false)
            .padding(OrbitMetrics.cardInset)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // .id(_:) is load-bearing: this window never remounts paneCard when its tab is
    // navigated from one document to another, so without it the old document's editor
    // keeps running against the new one's id instead of being torn down.
    @ViewBuilder
    private func paneContent(for tab: Tab) -> some View {
        switch OrbitScheme.parse(tab.url) {
        case .note(let id):
            surface(env.extensionPoints.notesEditor?(id))
                .id(OrbitScheme.documentSurfaceIdentity(kind: "note", id: id))
        case .easel(let id):
            surface(env.extensionPoints.easelCanvas?(id))
                .id(OrbitScheme.documentSurfaceIdentity(kind: "easel", id: id))
        case .newTab:
            blankPane(tab)
        case .viewSource, .web:
            webLayer(tab)
        }
    }

    private func blankPane(_ tab: Tab) -> some View {
        Color(nsColor: .textBackgroundColor)
            .task(id: tab.id) {
                addressBarModel.text = ""
                addressBarModel.isPresented = true
            }
    }

    @ViewBuilder
    private func webLayer(_ tab: Tab) -> some View {
        if env.crashedTabs.contains(tab.id) {
            CrashedTabView { env.webContents[tab.id]?.reload(ignoringCache: false) }
        } else if let problem = env.certificateProblems[tab.id] {
            CertificateInterstitialView(tabID: tab.id, problem: problem)
        } else if let error = env.tabErrors[tab.id] {
            ErrorPageView(error: error) { env.webContents[tab.id]?.reload(ignoringCache: false) }
        } else if let contents = env.webContents[tab.id] {
            WebContentsHostView(contents: contents, environment: env)
                .id(tab.id)
                .pageScrollerColorScheme(tab: tab)
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    @ViewBuilder
    private func surface(_ view: AnyView?) -> some View {
        if let view {
            view
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}
