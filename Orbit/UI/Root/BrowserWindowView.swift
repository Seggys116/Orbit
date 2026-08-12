import AppKit
import SwiftUI
#if DEBUG
import OSLog
#endif

enum OrbitHoverPanelMetrics {
    static let edgeInset: CGFloat = OrbitMetrics.cardInset / 2
    static let cornerRadius: CGFloat = OrbitMetrics.cardCornerRadius
    static let shadowRadius: CGFloat = 14
    static let shadowOpacity: Double = 0.32
    static let shadowXOffset: CGFloat = 6
    static let contactShadowRadius: CGFloat = 3
    static let contactShadowOpacity: Double = 0.22
}

struct PositionedWindowControls: View {
    var body: some View {
        WindowControlsView()
            .padding(.leading, OrbitWindowControlMetrics.leadingInset)
            .padding(.top, OrbitWindowControlMetrics.topInset)
    }
}

struct SidebarTopRowDoubleClickCatcher: View {
    var body: some View {
        Color.clear
            .frame(height: OrbitMetrics.sidebarTopRowHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { OrbitTitleBarDoubleClick.handle(on: NSApp.keyWindow) }
    }
}

struct HoverRevealSidebarLayer: View {
    @Environment(AppEnvironment.self) private var env
    var onHoverChanged: (Bool) -> Void

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var hotZoneWidth: CGFloat {
        env.isSidebarHoverRevealed ? env.sidebarWidth : OrbitMetrics.sidebarHoverEdgeWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            hoverEdgeDetector
                .frame(width: hotZoneWidth)
                .frame(maxHeight: .infinity, alignment: .leading)

            // Always mounted, never inserted/removed: an if-gated insertion would rebuild
            // and lay out the SidebarView subtree while the panel is already moving.
            HoverRevealedFloatingPanel(isRevealed: env.isSidebarHoverRevealed)
        }
    }

    @ViewBuilder
    private var hoverEdgeDetector: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear.allowsHitTesting(false)
        } else {
            HoverEdgeDetector(hotZoneWidth: hotZoneWidth, onHoverChanged: onHoverChanged)
        }
        #else
        HoverEdgeDetector(hotZoneWidth: hotZoneWidth, onHoverChanged: onHoverChanged)
        #endif
    }
}

struct HoverRevealedFloatingPanel: View {
    @Environment(AppEnvironment.self) private var env

    var isRevealed: Bool = true

    private var hiddenOffset: CGFloat {
        -(OrbitHoverPanelMetrics.edgeInset
            + env.sidebarWidth
            + OrbitHoverPanelMetrics.shadowRadius
            + OrbitHoverPanelMetrics.shadowXOffset
            + 4)
    }

    var body: some View {
        SidebarView(paintsOwnBackground: true, backgroundOpacity: OrbitAcrylic.panelTintOpacity)
            .frame(width: env.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .leading)
            // Attached before .compositingGroup() below so it stays a real ancestor of
            // SidebarTopRow's own controls for gesture-priority purposes.
            .background(alignment: .top) { SidebarTopRowDoubleClickCatcher() }
            .overlay(alignment: .topLeading) { PositionedWindowControls() }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: OrbitHoverPanelMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OrbitHoverPanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(OrbitAcrylic.panelEdgeHighlight, lineWidth: OrbitAcrylic.panelEdgeHighlightWidth)
            }
            .compositingGroup()
            .shadow(
                color: .black.opacity(OrbitHoverPanelMetrics.shadowOpacity),
                radius: OrbitHoverPanelMetrics.shadowRadius,
                x: OrbitHoverPanelMetrics.shadowXOffset,
                y: 0
            )
            .shadow(
                color: .black.opacity(OrbitHoverPanelMetrics.contactShadowOpacity),
                radius: OrbitHoverPanelMetrics.contactShadowRadius,
                x: 1,
                y: 1
            )
            .padding(.top, OrbitHoverPanelMetrics.edgeInset)
            .padding(.leading, OrbitHoverPanelMetrics.edgeInset)
            .padding(.bottom, OrbitHoverPanelMetrics.edgeInset)
            .offset(x: isRevealed ? 0 : hiddenOffset)
            .opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)
    }
}

struct SidebarCollapseModifier: ViewModifier, Animatable {
    var progress: Double
    let fullWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Clamp: OrbitMotion.standard overshoots 0...1 mid-spring, and an unclamped
        // overshoot would hand the sidebar more width than the user sized it to.
        let clamped = min(max(progress, 0), 1)
        content
            .frame(width: fullWidth, alignment: .leading)
            .frame(width: fullWidth * clamped, alignment: .trailing)
            .clipped()
            .opacity(clamped)
    }
}

extension AnyTransition {
    static func sidebarCollapse(width: CGFloat) -> AnyTransition {
        .modifier(
            active: SidebarCollapseModifier(progress: 0, fullWidth: width),
            identity: SidebarCollapseModifier(progress: 1, fullWidth: width)
        )
    }
}

struct BrowserWindowView: View {
    @Environment(AppEnvironment.self) private var env

    private var dockedSidebarColumnWidth: CGFloat {
        env.sidebarWidth + OrbitMetrics.sidebarResizeHandleWidth
    }

    var skipOnboarding: Bool = false

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    @State private var showNewSpaceFlow = false
    // Whether opening the New Space panel is what un-hid the sidebar, so dismissing
    // it restores the user's own sidebar visibility setting rather than leaving it changed.
    @State private var newSpaceFlowUnhidTheSidebar = false
    @State private var hoverHideTask: Task<Void, Never>?
    @State private var spaceSwipeBlend: SpaceSwipeBlend?
    @State private var hoverPhase: SidebarHoverPhase = .hidden
    @State private var commandBarAnchors: [CommandBarAnchorID: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .leading) {
            backgroundBleed

            HStack(spacing: 0) {
                if env.isSidebarVisible {
                    HStack(spacing: 0) {
                        SpaceSwitchingSidebarContainer()
                            .frame(width: env.sidebarWidth)
                            .contextMenu { sidebarBackgroundMenu }
                            .background(alignment: .top) { SidebarTopRowDoubleClickCatcher() }
                            .overlay { newSpaceFlowPanel }
                        resizeHandle
                    }
                    .overlay(alignment: .topLeading) { PositionedWindowControls() }
                    .transition(.sidebarCollapse(width: dockedSidebarColumnWidth))
                }

                contentColumn
            }

            if !env.isSidebarVisible {
                HoverRevealSidebarLayer(onHoverChanged: handleHoverEdge)
            }
        }
        .coordinateSpace(.named(OrbitWindowCoordinateSpace.name))
        .overlay {
            if env.isCommandBarPresented {
                commandBarOverlay
            }
        }
        .animation(OrbitMotion.standard, value: env.isSidebarVisible)
        // No ambient .animation(value: env.isSidebarHoverRevealed): every mutation of it
        // already happens inside an explicit withAnimation in handleHoverEdge, and an
        // ambient modifier here could desynchronize the panel's transition from its content.
        .animation(OrbitMotion.standard, value: env.isCommandBarPresented)
        .onPreferenceChange(SpaceSwipeBlendKey.self) { blend in
            spaceSwipeBlend = blend
        }
        .onPreferenceChange(CommandBarAnchorsKey.self) { anchors in
            commandBarAnchors = anchors
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitPresentNewSpaceFlow)) { _ in presentNewSpaceFlow() }
        .task { await runArchiveSweepLoop() }
        .modifier(OnboardingModifier(skip: skipOnboarding || env.isDemo))
        .sheet(item: permissionsConsentBinding) { request in
            ExtensionPermissionsConsentSheetView(
                request: request,
                iconURL: env.extensionStore.installed().first { $0.id == request.extensionID }?.iconURL
            ) { granted in
                env.resolveExtensionPermissionsConsent(request, granted: granted)
            }
            // Escape, a click away, and anything else that takes the sheet off
            // screen without an answer. A no-op once the buttons above have
            // answered, since resolving removes the request.
            .onDisappear { env.resolveExtensionPermissionsConsent(request, granted: false) }
        }
    }

    // MARK: - Extension permissions consent

    // Presented here, not on SingleTabContentView: that view already carries the install
    // sheet, and two .sheet modifiers on one view drop whichever arrives second. Also the right scope: process-wide, routed to the frontmost window's active tab.
    private var permissionsConsentBinding: Binding<ExtensionPermissionsConsentRequest?> {
        Binding(
            get: { env.activeTabID.flatMap { env.pendingExtensionPermissionsConsent[$0] } },
            // Every dismissal is answered by the content's own onDisappear,
            // which knows which request went away; this setter does not.
            set: { _ in }
        )
    }

    // MARK: - New Space (a sidebar-column panel, not a sheet)

    @ViewBuilder
    private var newSpaceFlowPanel: some View {
        if showNewSpaceFlow {
            NewSpaceFlowView(onDismiss: dismissNewSpaceFlow)
                .transition(.opacity)
        }
    }

    private func presentNewSpaceFlow() {
        if !env.isSidebarVisible {
            newSpaceFlowUnhidTheSidebar = true
            withAnimation(OrbitMotion.standard) { env.isSidebarVisible = true }
        }
        withAnimation(OrbitMotion.quick) { showNewSpaceFlow = true }
    }

    private func dismissNewSpaceFlow() {
        withAnimation(OrbitMotion.quick) { showNewSpaceFlow = false }
        if newSpaceFlowUnhidTheSidebar {
            newSpaceFlowUnhidTheSidebar = false
            withAnimation(OrbitMotion.standard) { env.isSidebarVisible = false }
        }
    }

    private struct OnboardingModifier: ViewModifier {
        let skip: Bool
        func body(content: Content) -> some View {
            if skip {
                content
            } else {
                content.onAppear { OnboardingWindowController.showIfNeeded() }
            }
        }
    }

    // MARK: Background

    // The window's one and only Space background: gradient stops are in unit space, so a second copy would resolve to different colors and seam.
    // SidebarView.paintsOwnBackground is the single sanctioned exception, for the hover-revealed floating panel.
    private var backgroundBleed: some View {
        Group {
            if let blend = spaceSwipeBlend {
                ZStack {
                    SpaceGradientBlendView(theme: blend.currentTheme, opacity: 1, blur: blend.currentBlur)
                    if let incomingTheme = blend.incomingTheme {
                        SpaceGradientBlendView(
                            theme: incomingTheme,
                            opacity: blend.incomingWeight,
                            blur: blend.incomingBlur
                        )
                    }
                }
            } else if let space = env.activeSpace {
                ThemeBackgroundView(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        // Applied to the whole Group, not per-branch, so the swipe crossfade, the
        // ordinary themed background and the no-Space fallback are all tinted identically.
        .opacity(OrbitAcrylic.windowTintOpacity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: Content column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            ContentCardView()
                .commandBarAnchor(.contentRegion)
                .padding(OrbitMetrics.cardInset)
                #if DEBUG
                .background(contentCardFrameProbe)
                #endif
        }
    }

    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "ContentColumnSelfCheck")

    /// Confirms structurally — no Screen Recording permission in this
    /// environment — that the content card sits flush with this column's
    /// own edges (leading/trailing/top/bottom insets applied as expected).
    private var contentCardFrameProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { logColumnFrame(card: proxy.frame(in: .global), label: "card-appear") }
                .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                    logColumnFrame(card: newFrame, label: "card-change")
                }
        }
    }

    /// Gated on `DiagnosticChannel.contentColumn` (`ORBIT_LOG_CONTENT_COLUMN=1`) to avoid console noise in `OrbitDemo`, a DEBUG build the user browses in.
    private func logColumnFrame(card: CGRect, label: String) {
        guard DiagnosticChannel.contentColumn.isEnabled else { return }
        BrowserWindowView.selfCheckLogger.info("""
        [\(label, privacy: .public)] card=\(String(describing: card), privacy: .public) \
        sidebarVisible=\(env.isSidebarVisible) sidebarWidth=\(env.sidebarWidth)
        """)
    }
    #endif

    private func handleHoverEdge(_ hovering: Bool) {
        hoverHideTask?.cancel()
        hoverHideTask = nil

        let next = hoverPhase.hoverChanged(hovering)
        guard next != hoverPhase else { return }
        hoverPhase = next

        switch next {
        case .peeking:
            withAnimation(OrbitMotion.standard, completionCriteria: .logicallyComplete) {
                env.isSidebarHoverRevealed = true
            } completion: {
                hoverPhase = hoverPhase.revealAnimationCompleted()
            }

        case .revealed:
            break

        case .hiding:
            hoverHideTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(OrbitMetrics.sidebarAutoHideDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let resolved = hoverPhase.hideDelayElapsed()
                guard resolved != hoverPhase else { return }
                hoverPhase = resolved
                withAnimation(OrbitMotion.standard) {
                    env.isSidebarHoverRevealed = false
                }
            }

        case .hidden:
            break
        }
    }

    // MARK: Command Bar

    private var commandBarOverlay: some View {
        CommandBarOverlay(anchors: commandBarAnchors)
    }

    // MARK: Sidebar background context menu

    private var sidebarBackgroundMenu: some View {
        Group {
            Button("New Space…") { presentNewSpaceFlow() }
            Button("Manage Spaces…") { LibraryWindowController.show(section: .spaces) }
        }
    }

    // MARK: Sidebar resize handle

    @ViewBuilder
    private var resizeHandle: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear
                .frame(width: OrbitMetrics.sidebarResizeHandleWidth)
                .allowsHitTesting(false)
        } else {
            SidebarResizeHandle()
        }
        #else
        SidebarResizeHandle()
        #endif
    }

    // MARK: Archive sweep

    private func runArchiveSweepLoop() async {
        while !Task.isCancelled {
            env.runArchiveSweep()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
