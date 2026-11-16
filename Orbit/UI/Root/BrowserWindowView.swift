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

struct HoverRevealSidebarLayer: View {
    @Environment(AppEnvironment.self) private var env
    var onHoverChanged: (Bool) -> Void
    var onDismissIntent: () -> Void = {}

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var hotZoneWidth: CGFloat {
        env.isSidebarHoverRevealed ? env.effectiveSidebarWidth : OrbitMetrics.sidebarHoverEdgeWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            hoverEdgeDetector
                .frame(width: hotZoneWidth)
                .frame(maxHeight: .infinity, alignment: .leading)

            // Always mounted, never inserted/removed: an if-gated insertion would rebuild and lay out the SidebarView subtree while the panel is moving.
            HoverRevealedFloatingPanel(isRevealed: env.isSidebarHoverRevealed)
        }
    }

    @ViewBuilder
    private var hoverEdgeDetector: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear.allowsHitTesting(false)
        } else {
            HoverEdgeDetector(hotZoneWidth: hotZoneWidth, onHoverChanged: onHoverChanged, onDismissIntent: onDismissIntent)
        }
        #else
        HoverEdgeDetector(hotZoneWidth: hotZoneWidth, onHoverChanged: onHoverChanged, onDismissIntent: onDismissIntent)
        #endif
    }
}

struct HoverRevealedFloatingPanel: View {
    @Environment(AppEnvironment.self) private var env

    var isRevealed: Bool = true

    private var hiddenOffset: CGFloat {
        -(OrbitHoverPanelMetrics.edgeInset
            + env.effectiveSidebarWidth
            + OrbitHoverPanelMetrics.shadowRadius
            + OrbitHoverPanelMetrics.shadowXOffset
            + 4)
    }

    var body: some View {
        SidebarView(paintsOwnBackground: true, backgroundOpacity: OrbitAcrylic.panelTintOpacity)
            .frame(width: env.effectiveSidebarWidth)
            .frame(maxHeight: .infinity, alignment: .leading)
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
        // Clamp: OrbitMotion.standard overshoots 0...1 mid-spring, which would hand the sidebar more width than the user sized it to.
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

    // env.sidebarWidth is the user's own width; the Library widens the sidebar past it without touching it, so layout and hit-testing read the effective width.
    private var dockedSidebarColumnWidth: CGFloat {
        env.effectiveSidebarWidth + OrbitMetrics.sidebarResizeHandleWidth
    }

    var skipOnboarding: Bool = false

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    @State private var showNewSpaceFlow = false
    // Whether opening the New Space panel un-hid the sidebar, so dismissing it restores the user's own visibility setting.
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
                            .frame(width: env.effectiveSidebarWidth)
                            .orbitRightClickBackdropMenu { sidebarBackgroundMenuEntries }
                            .overlay { newSpaceFlowPanel }
                        resizeHandle
                    }
                    .overlay(alignment: .topLeading) { PositionedWindowControls() }
                    .transition(.sidebarCollapse(width: dockedSidebarColumnWidth))
                    .zIndex(1)
                }

                contentColumn
            }

            if !env.isSidebarVisible {
                HoverRevealSidebarLayer(onHoverChanged: handleHoverEdge, onDismissIntent: handleDismissIntent)
            }
        }
        .coordinateSpace(.named(OrbitWindowCoordinateSpace.name))
        .overlay {
            if env.isCommandBarPresented {
                commandBarOverlay
            }
        }
        .orbitAnimation(OrbitMotion.standard, value: env.isSidebarVisible)
        // No ambient .animation(value: env.isSidebarHoverRevealed): every mutation already runs in an explicit withAnimation in handleHoverEdge, and an ambient one could desynchronize the panel from its content.
        .orbitAnimation(OrbitMotion.standard, value: env.isCommandBarPresented)
        .onChange(of: env.isSidebarVisible) { _, isVisible in
            guard isVisible else {
                env.libraryModeSidebarWasHidden()
                return
            }
            hoverHideTask?.cancel()
            hoverHideTask = nil
            hoverPhase = .hidden
            env.isSidebarHoverRevealed = false
        }
        .onChange(of: env.activeTabID) { _, newID in
            // A click on a real page takes the new-tab spotlight with it; a blank pane keeps the bar because that pane presents it.
            guard env.isCommandBarPresented, let newID, env.blankPaneMode(for: newID) == nil else { return }
            env.dismissCommandBar()
        }
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
            // Covers Escape, a click away and anything else that dismisses the sheet unanswered; a no-op once the buttons have answered, since resolving removes the request.
            .onDisappear { env.resolveExtensionPermissionsConsent(request, granted: false) }
        }
    }

    // Presented here, not on SingleTabContentView: that view already carries the install sheet, and two .sheet modifiers on one view drop whichever arrives second.
    private var permissionsConsentBinding: Binding<ExtensionPermissionsConsentRequest?> {
        Binding(
            get: { env.activeTabID.flatMap { env.pendingExtensionPermissionsConsent[$0] } },
            // Every dismissal is answered by the content's own onDisappear, which knows which request went away; this setter does not.
            set: { _ in }
        )
    }


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
            withOrbitAnimation(OrbitMotion.standard) { env.isSidebarVisible = true }
        }
        withOrbitAnimation(OrbitMotion.quick) { showNewSpaceFlow = true }
    }

    private func dismissNewSpaceFlow() {
        withOrbitAnimation(OrbitMotion.quick) { showNewSpaceFlow = false }
        if newSpaceFlowUnhidTheSidebar {
            newSpaceFlowUnhidTheSidebar = false
            withOrbitAnimation(OrbitMotion.standard) { env.isSidebarVisible = false }
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

    // The window's one Space background: gradient stops are in unit space, so a second copy would resolve to different colors and seam (SidebarView.paintsOwnBackground is the one exception, for the hover-revealed panel).
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
        // Applied to the whole Group, not per-branch, so the swipe crossfade, themed background and no-Space fallback are tinted identically.
        .opacity(OrbitAcrylic.windowTintOpacity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // Docked, the handle already takes its share of cardInset. Hidden, the leading edge is the window and keeps the full inset.
    private var contentCardLeadingInset: CGFloat {
        BorderlessSettings.shared.contentCardLeadingInset(isSidebarVisible: env.isSidebarVisible)
    }

    private var contentColumn: some View {
        let cardInset = BorderlessSettings.shared.cardInset
        return VStack(spacing: 0) {
            ContentCardView()
                .commandBarAnchor(.contentRegion)
                .environment(\.paneCardFlushEdges, BorderlessSettings.shared.flushEdges(isSidebarVisible: env.isSidebarVisible))
                .padding(EdgeInsets(
                    top: cardInset,
                    leading: contentCardLeadingInset,
                    bottom: cardInset,
                    trailing: cardInset
                ))
                #if DEBUG
                .background(contentCardFrameProbe)
                #endif
        }
    }

    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "ContentColumnSelfCheck")

    private var contentCardFrameProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { logColumnFrame(card: proxy.frame(in: .global), label: "card-appear") }
                .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                    logColumnFrame(card: newFrame, label: "card-change")
                }
        }
    }

    private func logColumnFrame(card: CGRect, label: String) {
        guard DiagnosticChannel.contentColumn.isEnabled else { return }
        BrowserWindowView.selfCheckLogger.info("""
        [\(label, privacy: .public)] card=\(String(describing: card), privacy: .public) \
        sidebarVisible=\(env.isSidebarVisible) sidebarWidth=\(env.effectiveSidebarWidth)
        """)
    }
    #endif

    private func handleDismissIntent() {
        guard hoverPhase == .hiding else { return }
        hoverHideTask?.cancel()
        hoverHideTask = nil
        hoverPhase = .hidden
        withOrbitAnimation(OrbitMotion.standard) {
            env.isSidebarHoverRevealed = false
        }
    }

    private func handleHoverEdge(_ hovering: Bool) {
        hoverHideTask?.cancel()
        hoverHideTask = nil

        let next = hoverPhase.hoverChanged(hovering)
        guard next != hoverPhase else { return }
        hoverPhase = next

        switch next {
        case .peeking:
            withAnimation(
                OrbitMotion.resolved(OrbitMotion.standard, reduceMotion: OrbitMotion.prefersReducedMotion),
                completionCriteria: .logicallyComplete
            ) {
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
                withOrbitAnimation(OrbitMotion.standard) {
                    env.isSidebarHoverRevealed = false
                }
            }

        case .hidden:
            break
        }
    }


    private var commandBarOverlay: some View {
        CommandBarOverlay(
            anchors: commandBarAnchors,
            passthroughLeadingWidth: commandBarSidebarPassthrough
        )
    }

    private var commandBarSidebarPassthrough: CGFloat {
        if env.isSidebarVisible {
            return env.effectiveSidebarWidth + OrbitMetrics.sidebarResizeHandleWidth
        }
        if env.isSidebarHoverRevealed {
            return env.effectiveSidebarWidth
        }
        return 0
    }


    private var sidebarBackgroundMenuEntries: [OrbitContextMenuEntry] {
        [
            .item(OrbitContextMenuItem(title: "New Space…") { presentNewSpaceFlow() }),
            .item(OrbitContextMenuItem(title: "Manage Spaces…") { env.openLibrary(section: .spaces) })
        ]
    }

    // Inert while the Library is open: the handle resizes the user's own width, which the Library's wider column hides, so dragging would jump on release.
    @ViewBuilder
    private var resizeHandle: some View {
        #if DEBUG
        if screenshotModeDragDisabled || env.isLibraryMode {
            Color.clear
                .frame(width: OrbitMetrics.sidebarResizeHandleWidth)
                .allowsHitTesting(false)
        } else {
            SidebarResizeHandle()
        }
        #else
        if env.isLibraryMode {
            Color.clear
                .frame(width: OrbitMetrics.sidebarResizeHandleWidth)
                .allowsHitTesting(false)
        } else {
            SidebarResizeHandle()
        }
        #endif
    }


    private func runArchiveSweepLoop() async {
        while !Task.isCancelled {
            env.runArchiveSweep()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
