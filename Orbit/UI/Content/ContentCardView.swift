import AppKit
import SwiftUI
#if DEBUG
import OSLog
#endif

struct PaneCardChrome: ViewModifier {
    var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous))
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.75) : Color.white.opacity(OrbitMetrics.cardBorderOpacity),
                        lineWidth: isFocused ? 2 : OrbitMetrics.cardBorderWidth
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func paneCardChrome(isFocused: Bool) -> some View {
        modifier(PaneCardChrome(isFocused: isFocused))
    }

    func pageScrollerColorScheme(tab: Tab) -> some View {
        modifier(PageScrollerColorScheme(tab: tab))
    }
}

struct PageScrollerColorScheme: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab

    private var contents: (any WebContents)? { env.webContents[tab.id] }

    private var pageColor: ThemeColor? {
        if let live = env.themeColors[tab.id] { return live }
        return PaneHeaderColorResolver.shared.color(forTab: tab.id, url: tab.url)
    }

    private var documentColor: ThemeColor? {
        if let live = env.documentColors[tab.id] { return live }
        if let pulled = PaneHeaderColorResolver.shared.documentColor(forTab: tab.id) { return pulled }
        return pageColor
    }

    private var scheme: PageColorSchemeScript.Scheme? {
        guard let documentColor else { return nil }
        return PageColorSchemeScript.scheme(for: documentColor)
    }

    // Includes isLoading, else a reload at the same URL/colour won't resync.
    private var syncID: String {
        let loading = env.navigationStates[tab.id]?.isLoading == true
        return "\(tab.id.uuidString)#\(tab.url.absoluteString)#\(scheme?.rawValue ?? "unresolved")#\(loading)"
    }

    func body(content: Content) -> some View {
        content.task(id: syncID) { await sync() }
    }

    private func sync() async {
        guard let contents else { return }
        guard let scheme else {
            await PaneHeaderColorResolver.shared.sample(tab: tab.id, url: tab.url, contents: contents)
            return
        }
        await PageColorSchemeScript.apply(scheme, to: contents)
    }
}

struct ContentCardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var askOnPage = AskOnPageController.shared

    var body: some View {
        ZStack {
            if let activeTabID = env.activeTabID, let tab = env.tab(activeTabID) {
                if env.splitGroup(for: activeTabID) != nil {
                    SplitViewContainer(rootTabID: activeTabID)
                } else {
                    SingleTabContentView(tab: tab, isFocusedPane: true)
                }
            } else {
                NewTabPlaceholder()
                    .paneCardChrome(isFocused: false)
            }

            SplitDropZoneOverlay()

            LinkPreviewOverlayView()
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if env.isFindBarPresented {
                    FindBarView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if askOnPage.isPresented {
                    AskOnPagePanelView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .animation(OrbitMotion.standard, value: env.isFindBarPresented)
        .animation(OrbitMotion.standard, value: askOnPage.isPresented)
        .onChange(of: env.activeTabID) { _, newValue in askOnPage.tabDidChange(to: newValue) }
        #if DEBUG
        .background(contentCardFrameProbe)
        #endif
    }

    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "ContentCardSelfCheck")

    // Gated on DiagnosticChannel.contentCard (ORBIT_LOG_CONTENT_CARD=1).
    private var contentCardFrameProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    guard DiagnosticChannel.contentCard.isEnabled else { return }
                    ContentCardView.selfCheckLogger.info(
                        "[appear] contentCard frame=\(String(describing: proxy.frame(in: .global)), privacy: .public) cornerRadius=\(OrbitMetrics.cardCornerRadius) inset=\(OrbitMetrics.cardInset)"
                    )
                }
                .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                    guard DiagnosticChannel.contentCard.isEnabled else { return }
                    ContentCardView.selfCheckLogger.info(
                        "[change] contentCard frame=\(String(describing: newFrame), privacy: .public) cornerRadius=\(OrbitMetrics.cardCornerRadius) inset=\(OrbitMetrics.cardInset)"
                    )
                }
        }
    }
    #endif
}

struct SingleTabContentView: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab
    var isFocusedPane: Bool = false

    private var isInSplit: Bool { env.splitGroup(for: tab.id) != nil }

    @State private var toolbarSettings = ToolbarSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if toolbarSettings.isVisible {
                ToolbarView(tab: tab, paneCapabilities: .full)
            }
            paneContent
        }
        .paneCardChrome(isFocused: isInSplit && isFocusedPane)
        .overlay {
            if let preview = PeekState.shared.activePreview, preview.sourceTabID == tab.id {
                peekOverlay(preview)
            }
        }
        .commandBarAnchor(.pane(tab.id))
        // The whole chrome.webstorePrivate install flow -- download and unpack
        // progress, the consent decision, the outcome -- in one sheet, so it
        // reads as one dialog.
        .sheet(isPresented: Binding(
            get: { env.extensionInstallModalPhase(for: tab.id) != nil },
            set: { isPresented in
                if !isPresented {
                    env.dismissExtensionInstallModal(for: tab.id)
                }
            }
        )) {
            if let phase = env.extensionInstallModalPhase(for: tab.id) {
                ExtensionInstallModalView(
                    phase: phase,
                    subject: env.extensionInstallSubjects[tab.id],
                    onAnswerConsent: { granted in
                        env.resolveExtensionInstallConsent(for: tab.id, granted: granted)
                    },
                    onCancel: { env.dismissExtensionInstallModal(for: tab.id) },
                    onDismiss: { env.dismissExtensionInstallModal(for: tab.id) }
                )
                .animation(OrbitMotion.quick, value: phase)
            }
        }
    }

    @ViewBuilder
    private func peekOverlay(_ preview: PeekState.ActivePreview) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
                .onTapGesture { PeekState.shared.dismiss() }

            if let panel = env.extensionPoints.peekPanel?(preview.sourceTabID, preview.url) {
                panel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
    }

    @ViewBuilder
    private var paneContent: some View {
        ZStack {
            switch OrbitScheme.parse(tab.url) {
            case .note(let id):
                surface(env.extensionPoints.notesEditor?(id))
                    .id(OrbitScheme.documentSurfaceIdentity(kind: "note", id: id))
            case .easel(let id):
                surface(env.extensionPoints.easelCanvas?(id))
                    .id(OrbitScheme.documentSurfaceIdentity(kind: "easel", id: id))
            case .newTab:
                NewTabPlaceholder(tab: tab)
            case .viewSource, .web:
                webLayer
            }
        }
    }

    @ViewBuilder
    private var webLayer: some View {
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

struct NewTabPlaceholder: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab?

    var body: some View {
        Color(nsColor: .textBackgroundColor)
            .task(id: tab?.id) {
                guard let tab else { return }
                env.presentBlankPaneCommandBar(tab.id)
            }
    }
}

enum OrbitScheme {
    case note(UUID)
    case easel(UUID)
    case newTab
    case viewSource
    case web

    static func parse(_ url: URL) -> OrbitScheme {
        if url.scheme == "view-source" { return .viewSource }
        guard url.scheme == "orbit" else { return .web }
        switch url.host() {
        case "note": return UUID(uuidString: url.lastPathComponent).map(OrbitScheme.note) ?? .web
        case "easel": return UUID(uuidString: url.lastPathComponent).map(OrbitScheme.easel) ?? .web
        case "new-tab": return .newTab
        default: return .web
        }
    }

    /// Required as `.id(_:)` on the `.note`/`.easel` branch: without it,
    /// switching `tab` between two Notes is not seen by SwiftUI as a remount,
    /// and the editor silently keeps writing into the first document.
    static func documentSurfaceIdentity(kind: String, id: UUID) -> String {
        "\(kind):\(id.uuidString)"
    }
}

struct SplitDropZoneOverlay: View {
    @Environment(AppEnvironment.self) private var env

    #if DEBUG
    // ImageRenderer draws a circle-slash artifact over .dropDestination
    // views; screenshot mode disables drag here to avoid it.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    var body: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear.allowsHitTesting(false)
        } else {
            realBody
        }
        #else
        realBody
        #endif
    }

    private var realBody: some View {
        GeometryReader { proxy in
            ZStack {
                // Equatable and blind to the highlight. Writing the highlight
                // used to rebuild this drop target mid-drag, so the release
                // never arrived and the pink preview stayed on the page.
                SplitDropCatcher(
                    size: proxy.size,
                    targetTabID: env.activeTabID,
                    isAtPaneLimit: isAtPaneLimit,
                    allowedOrientation: allowedOrientation
                )
                .equatable()

                if let zone = env.activeSplitDropZone {
                    highlight(for: zone.edge, size: proxy.size)
                }
            }
            .animation(OrbitMotion.quick, value: env.activeSplitDropZone)
            .onChange(of: env.activeSplitDropZone != nil) { _, showing in
                if showing {
                    SplitDropHighlightWatch.arm { env.activeSplitDropZone = nil }
                }
            }
            .onDisappear { SplitDropHighlightWatch.disarm() }
            .onChange(of: proxy.size, initial: true) { _, size in
                guard env.contentAreaSize != size else { return }
                env.contentAreaSize = size
            }
        }
        .allowsHitTesting(env.activeTabID != nil)
    }

    private var activeGroup: SplitGroup? { env.activeSplitGroup }

    private var allowedOrientation: SplitOrientation? { activeGroup?.axis }

    private var isAtPaneLimit: Bool {
        guard let activeGroup else { return false }
        return activeGroup.tabIDs.count >= SplitGroup.maximumPanes
    }

    private func highlight(for edge: SplitEdge, size: CGSize) -> some View {
        let existingPanes = max(1, activeGroup?.tabIDs.count ?? 1)
        let share = 1 / CGFloat(existingPanes + 1)
        let isSideBySide = (edge == .left || edge == .right)
        let width = size.width * (isSideBySide ? share : 1)
        let height = size.height * (isSideBySide ? 1 : share)
        let x: CGFloat = edge == .right ? size.width - width / 2 : (edge == .left ? width / 2 : size.width / 2)
        let y: CGFloat = edge == .bottom ? size.height - height / 2 : (edge == .top ? height / 2 : size.height / 2)
        return RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
            .padding(OrbitSplitPaneMetrics.paneGap)
            .frame(width: width, height: height)
            .position(x: x, y: y)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// Does not read the highlight. Its inputs stay equal while the preview
// changes, so the drop registration survives until the mouse is released.
private struct SplitDropCatcher: View, Equatable {
    var size: CGSize
    var targetTabID: TabID?
    var isAtPaneLimit: Bool
    var allowedOrientation: SplitOrientation?

    static func == (lhs: SplitDropCatcher, rhs: SplitDropCatcher) -> Bool {
        lhs.size == rhs.size
            && lhs.targetTabID == rhs.targetTabID
            && lhs.isAtPaneLimit == rhs.isAtPaneLimit
            && lhs.allowedOrientation == rhs.allowedOrientation
    }

    var body: some View {
        SplitDropCatcherBody(
            size: size,
            targetTabID: targetTabID,
            isAtPaneLimit: isAtPaneLimit,
            allowedOrientation: allowedOrientation
        )
    }
}

private struct SplitDropCatcherBody: View {
    @Environment(AppEnvironment.self) private var env
    var size: CGSize
    var targetTabID: TabID?
    var isAtPaneLimit: Bool
    var allowedOrientation: SplitOrientation?

    // No contentShape: a hit-testing rectangle here would take clicks and
    // scrolling away from the page. The drop delegate still hears the drag.
    var body: some View {
        Color.clear
            .sidebarPayloadDropDestination { items, location in
                defer { env.activeSplitDropZone = nil }
                guard !isAtPaneLimit else { return false }
                guard let item = items.first, let targetTabID else { return false }
                guard item.nodeID != targetTabID else { return false }
                guard env.splitGroup(for: targetTabID)?.tabIDs.contains(item.nodeID) != true else { return false }
                let edge = SplitDropZoneGeometry.edge(
                    at: location,
                    in: size,
                    allowedOrientation: allowedOrientation
                )
                env.createSplit(existingTabID: targetTabID, newTabID: item.nodeID, edge: edge)
                return true
            } isTargeted: { targeted in
                guard !targeted else { return }
                env.activeSplitDropZone = nil
            } onUpdate: { location in
                guard let targetTabID, !isAtPaneLimit else {
                    env.activeSplitDropZone = nil
                    return
                }
                let edge = SplitDropZoneGeometry.edge(
                    at: location,
                    in: size,
                    allowedOrientation: allowedOrientation
                )
                let zone = SplitDropZone(edge: edge, targetTabID: targetTabID)
                guard env.activeSplitDropZone != zone else { return }
                env.activeSplitDropZone = zone
            }
    }
}

private enum SplitDropHighlightWatch {
    private static var monitor: Any?

    static func arm(_ clear: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { event in
            let released = event.type != .keyDown || event.keyCode == 53
            guard released else { return event }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { clear() }
            }
            disarm()
            return event
        }
    }

    static func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }
}

