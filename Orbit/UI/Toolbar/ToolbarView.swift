// SwiftUI lets the more deeply nested view win overlapping gestures, so headerDoubleClickObserver never steals a click meant for a descendant control.

import AppKit
import SwiftUI
#if DEBUG
import OSLog
#endif

let trailingGlyphScale: CGFloat = 1.25
let siteControlGlyphScale: CGFloat = 0.92
let splitViewGlyphScale: CGFloat = 1.06
let splitCloseGlyphScale: CGFloat = 0.9

enum OrbitToolbarMetrics {
    static let height: CGFloat = 24

    static let topPadding: CGFloat = (height * 0.13).rounded()
    static let bottomPadding: CGFloat = (height * 0.13).rounded()
    static let totalHeight: CGFloat = topPadding + height + bottomPadding

    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 18

    static let headerIconSize: CGFloat = 22

    static let navIconSize: CGFloat = headerIconSize
    static let navGlyphSize: CGFloat = 14
    static let navIconSpacing: CGFloat = 6
    static let trailingIconSpacing: CGFloat = 10

    static let trailingIconSize: CGFloat = headerIconSize
    static let trailingGlyphSize: CGFloat = (OrbitMetrics.trafficLightDiameter * trailingGlyphScale).rounded()

    static let siteControlGlyphSize: CGFloat = trailingGlyphSize * siteControlGlyphScale
    static let splitViewGlyphSize: CGFloat = trailingGlyphSize * splitViewGlyphScale
    static let splitCloseGlyphSize: CGFloat = trailingGlyphSize * splitCloseGlyphScale

    static let securityGlyphSize: CGFloat = 11

    // Applied to the address group itself, never conditionally to a child: ToolbarAddressCopyControl renders EmptyView() with no glyph, SwiftUI collapses that branch, and any padding attached to it collapses too.
    static let addressGroupHorizontalInset: CGFloat = 10

    // Fixed, not derived from glyph + padding: the leading control's glyph swaps between link/doc.on.doc/checkmark at different widths, and a padding-derived box would resize under the pointer and shove the domain text sideways mid-hover.
    static let addressCopyPillSize: CGFloat = headerIconSize

    static let addressPillGap: CGFloat = 2

    static let siteProfileNameMaxWidth: CGFloat = 96

    // Room the address row needs before the Site Profile dropdown joins it; below this the URL keeps the space and the profile stays reachable from the right-click menu.
    static let siteProfileDropdownMinimumAddressWidth: CGFloat = 200

    static func fitsSiteProfileDropdown(regionWidth: CGFloat, sideReserve: CGFloat) -> Bool {
        guard regionWidth.isFinite else { return true }
        return regionWidth - 2 * sideReserve >= siteProfileDropdownMinimumAddressWidth
    }

    static let navClusterWidth: CGFloat = navIconSize * 3 + navIconSpacing * 2
    static let trailingClusterWidth: CGFloat = trailingIconSize * 2 + trailingIconSpacing
    static let splitCloseClusterWidth: CGFloat = trailingIconSize + trailingIconSpacing

    static let openInOrbitClusterWidth: CGFloat = trailingIconSize + trailingIconSpacing

    static let addressSideReserve: CGFloat = addressSideReserve(withSidebarToggle: false)

    static let sidebarToggleClusterWidth: CGFloat = navIconSize + navIconSpacing

    // The width the address indicator is guaranteed to keep, however tight the pane gets; clampedAddressSideReserve(in:) gives up reserve rather than let the region shrink past this.
    static let minimumAddressWidth: CGFloat = trailingIconSize

    static func addressSideReserve(withSidebarToggle: Bool, withSplitClose: Bool = false, withOpenInOrbit: Bool = false) -> CGFloat {
        let leading = navClusterWidth + (withSidebarToggle ? sidebarToggleClusterWidth : 0)
        let trailing = trailingClusterWidth + (withSplitClose ? splitCloseClusterWidth : 0) + (withOpenInOrbit ? openInOrbitClusterWidth : 0)
        return max(leading, trailing)
    }

    static let contentDividerThickness: CGFloat = 1
    static let contentDividerOpacity: Double = 0.12


    static let hoverHighlightCornerRadius: CGFloat = 6

    static let hoverFillOpacityOnDarkHeader: Double = OrbitControlMetrics.controlHoverFillOpacityDark
    static let hoverFillOpacityOnLightHeader: Double = OrbitControlMetrics.controlHoverFillOpacityLight

    // Takes the already-decided glyph polarity rather than the background colour, so this cannot re-derive it by a different rule than the glyphs themselves were chosen by.
    static func hoverFillOpacity(glyphsAreDark: Bool) -> Double {
        glyphsAreDark ? hoverFillOpacityOnLightHeader : hoverFillOpacityOnDarkHeader
    }

    static let addressCopyCheckmarkLingerDuration: Double = 1.3
}

enum ToolbarSecurityGlyph {
    static func symbol(for security: SecurityLevel) -> String? {
        switch security {
        case .secure: "link"
        case .insecure, .mixedContent: "lock.slash"
        case .certificateError: "exclamationmark.triangle.fill"
        case .local, .unknown: nil
        }
    }

    static func isWarning(_ security: SecurityLevel) -> Bool {
        switch security {
        case .insecure, .mixedContent, .certificateError: true
        case .secure, .local, .unknown: false
        }
    }

    static func warningColor(for security: SecurityLevel) -> Color {
        security == .certificateError ? .red : .orange
    }
}

struct ToolbarTrailingGlyph: View {
    var symbol: String
    var glyphSize: CGFloat

    static let siteControl = ToolbarTrailingGlyph(
        symbol: "switch.2",
        glyphSize: OrbitToolbarMetrics.siteControlGlyphSize
    )
    static let splitView = ToolbarTrailingGlyph(
        symbol: "square.split.2x1",
        glyphSize: OrbitToolbarMetrics.splitViewGlyphSize
    )
    static let splitClose = ToolbarTrailingGlyph(
        symbol: "xmark",
        glyphSize: OrbitToolbarMetrics.splitCloseGlyphSize
    )
    static let openInOrbit = ToolbarTrailingGlyph(
        symbol: "arrow.up.forward.app",
        glyphSize: OrbitToolbarMetrics.trailingGlyphSize
    )

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyphSize, weight: .medium))
            .frame(width: OrbitToolbarMetrics.trailingIconSize, height: OrbitToolbarMetrics.trailingIconSize)
    }
}

// Three presets, not inferred flags: inferring split capability let a click create a SplitGroup with no container, stealing the main window's active tab via the shared processRoot; env.isSidebarVisible reflects only the main window's sidebar, so it can't gate a toggle elsewhere.
struct ToolbarPaneCapabilities: Equatable {
    var allowsSplit: Bool = true

    var allowsSidebarToggle: Bool = true

    var leadingInset: CGFloat = 0

    var showsOpenInOrbit: Bool = false

    static let full = ToolbarPaneCapabilities()

    static let singlePageWindow = ToolbarPaneCapabilities(allowsSplit: false, allowsSidebarToggle: false)

    static let littleOrbitWindow = ToolbarPaneCapabilities(
        allowsSplit: false,
        allowsSidebarToggle: false,
        leadingInset: OrbitMetrics.trafficLightLeadingInset + OrbitWindowControlMetrics.clusterWidth,
        showsOpenInOrbit: true
    )
}

struct ToolbarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var toolbarSettings = ToolbarSettings.shared

    @State private var developerModeSettings = DeveloperModeSettings.shared

    var tab: Tab

    var paneCapabilities: ToolbarPaneCapabilities = .full

    private var contents: (any WebContents)? {
        env.webContents[tab.id]
    }

    // Reads tab.id's mirror, never env.activeTabID's, so a two-pane split can show back enabled in one pane and disabled in the other. Field by field rather than a whole NavigationState, so a progress tick or title change does not re-run this body.
    private var navigation: NavigationBox? {
        env.navigationBox(for: tab.id)
    }

    private var isLoading: Bool { navigation?.isLoading ?? false }
    private var canGoBack: Bool { navigation?.canGoBack ?? false }
    private var canGoForward: Bool { navigation?.canGoForward ?? false }
    private var security: SecurityLevel { navigation?.security ?? NavigationState.empty.security }


    // Resolution order: document surface colour, env.themeColors, PaneHeaderColorResolver's pulled colour, env.documentColors, neutralBackground; the document colour is first because env.themeColors is never cleared on navigation and would leave a stale pushed colour.
    private var headerBackground: ThemeColor {
        rawPageColor?.composited(over: neutralBackground) ?? neutralBackground
    }

    private var rawPageColor: ThemeColor? {
        if OrbitInternalPageChrome.isDocumentPage(tab.url) {
            return OrbitInternalPageChrome.surfaceColor(
                for: OrbitInternalPageChrome.documentColorScheme(system: colorScheme)
            )
        }
        if let live = env.themeColors[tab.id] { return live }
        if let resolved = PaneHeaderColorResolver.shared.color(forTab: tab.id, url: tab.url) {
            return resolved
        }
        if let document = env.documentColors[tab.id] { return document }
        return PaneHeaderColorResolver.shared.documentColor(forTab: tab.id)
    }

    // Must never fall back to the Space's own theme: this bar's colour says something about the page, and a Space theme is the same colour on every tab in it, so it would dress a page-derived signal in a colour that isn't one.
    private var neutralBackground: ThemeColor {
        colorScheme == .dark
            ? ThemeColor(red: 0.16, green: 0.155, blue: 0.18)
            : ThemeColor(red: 0.945, green: 0.945, blue: 0.955)
    }

    // Derived from headerBackground itself, never system appearance: a dark page under a light appearance still needs light glyphs, and a mismatch is the near-black-on-near-black case PaneHeaderColorResolver guards against.
    private var headerForeground: Color {
        Self.color(PaneHeaderColorResolver.foregroundColor(for: headerBackground))
    }

    private var headerForegroundDimmed: Color {
        Self.color(PaneHeaderColorResolver.dimmedForegroundColor(for: headerBackground))
    }

    private var headerHoverFill: Color {
        headerForeground.opacity(
            OrbitToolbarMetrics.hoverFillOpacity(
                glyphsAreDark: PaneHeaderColorResolver.hasDarkForeground(on: headerBackground)
            )
        )
    }

    private var spaceTheme: SpaceTheme? {
        env.space(tab.spaceID)?.theme ?? env.activeSpace?.theme
    }

    private func adoptMenuTheme() {
        OrbitMenuThemeSource.shared.adopt(environment: env, spaceID: tab.spaceID)
    }

    private static func color(_ theme: ThemeColor) -> Color {
        Color(.sRGB, red: theme.red, green: theme.green, blue: theme.blue, opacity: theme.alpha)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0).frame(height: OrbitToolbarMetrics.topPadding)

            ZStack {
                // Full row first; when it cannot fit the pane the secondary trailing buttons fold into an overflow menu.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        navigationCluster
                        // minLength: 0, not positive: a nonzero minimum inflates the header's minimum width and overflows narrow split panes, sliding the cluster row past the rounded edges.
                        Spacer(minLength: 0)
                        trailingCluster
                    }
                    HStack(spacing: 0) {
                        navigationCluster
                        Spacer(minLength: 0)
                        compactTrailingCluster
                    }
                }

                centredAddressRegion
            }
            .padding(.leading, OrbitToolbarMetrics.leadingPadding + paneCapabilities.leadingInset)
            .padding(.trailing, OrbitToolbarMetrics.trailingPadding)
            .frame(height: OrbitToolbarMetrics.height)

            Spacer(minLength: 0).frame(height: OrbitToolbarMetrics.bottomPadding)
        }
        .frame(height: OrbitToolbarMetrics.totalHeight)
        .frame(maxWidth: .infinity)
        .background(
            Color(.sRGB, red: headerBackground.red, green: headerBackground.green, blue: headerBackground.blue, opacity: headerBackground.alpha)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(headerForeground.opacity(OrbitToolbarMetrics.contentDividerOpacity))
                .frame(height: OrbitToolbarMetrics.contentDividerThickness)
                .allowsHitTesting(false)
        }
        .orbitRightClickMenu { () -> [OrbitContextMenuEntry] in
            adoptMenuTheme()
            return ToolbarContextMenu(tab: tab, settings: toolbarSettings, developerModeSettings: developerModeSettings).entries(in: env)
        }
        .background(headerDoubleClickObserver)
        .animation(
            OrbitThemeMotion.animation(reduceMotion: reduceMotion, token: OrbitMotion.fade),
            value: headerBackground
        )
        .task(id: sampleTaskID) { await sampleHeaderColorIfNeeded() }
        #if DEBUG
        .background(frameProbe)
        .background(colourProbe)
        .background(hitTestProbe)
        #endif
    }


    // isLoading matters because a reload keeps the same URL and engine; attached/detached matters because a pane can lay out before materializeWebContents registers its WebContents, so a .task that saw nil would never re-run.
    private var sampleTaskID: String {
        "\(tab.id.uuidString)#\(tab.url.absoluteString)#\(contents == nil ? "detached" : "attached")#\(isLoading)"
    }

    private func sampleHeaderColorIfNeeded() async {
        guard env.themeColors[tab.id] == nil else { return }
        // Document pages resolve at rawPageColor's step 1 and never reach step 2; sampling their blank stray WebContents would cache a garbage colour that leaks into PageScrollerColorScheme via the shared resolver.
        guard !OrbitInternalPageChrome.isDocumentPage(tab.url) else { return }
        guard let contents else { return }
        await PaneHeaderColorResolver.shared.sample(tab: tab.id, url: tab.url, contents: contents)
    }

    // Focuses this pane's split first: a Button captures its tap before it bubbles to SplitViewContainer's pane-level gesture, and several actions below key off activeTabID rather than a tab id directly.
    private func focusPaneIfNeeded() {
        guard env.splitGroup(for: tab.id) != nil, env.activeTabID != tab.id else { return }
        env.focusSplitPane(index: tab.splitIndex)
    }


    private var showsSidebarToggle: Bool {
        paneCapabilities.allowsSidebarToggle && !env.isSidebarVisible && tab.splitIndex == 0
    }

    private var navigationCluster: some View {
        HStack(spacing: OrbitToolbarMetrics.navIconSpacing) {
            if showsSidebarToggle {
                sidebarToggleButton
            }
            navButton("chevron.left", direction: .back, enabled: canGoBack)
            navButton("chevron.right", direction: .forward, enabled: canGoForward)
            ToolbarReloadButton(isLoading: isLoading, foreground: headerForeground, hoverFill: headerHoverFill) {
                focusPaneIfNeeded()
                if isLoading { contents?.stopLoading() } else { env.reloadTab(tab.id, ignoringCache: false) }
            }
        }
    }

    // No focusPaneIfNeeded(): this acts on window-wide sidebar state, not this pane's tab.
    private var sidebarToggleButton: some View {
        iconButton("sidebar.left") {
            env.perform(.toggleSidebar)
        }
        .orbitTooltip("Show/Hide Sidebar (\u{2318}S)")
    }

    private func navButton(_ symbol: String, direction: ToolbarNavDirection, enabled: Bool) -> some View {
        ToolbarNavButton(
            symbol: symbol,
            direction: direction,
            isEnabled: enabled,
            foreground: headerForeground,
            dimmedForeground: headerForegroundDimmed,
            history: { contents?.sessionHistory() ?? [] },
            onNavigate: {
                focusPaneIfNeeded()
                if direction == .back { contents?.goBack() } else { contents?.goForward() }
            },
            onNavigateInNewTab: { url in
                guard let spaceID = env.tab(tab.id)?.spaceID ?? env.activeSpace?.id else { return }
                _ = env.openTab(url: url, in: spaceID)
            },
            onSelectHistory: { offset in
                focusPaneIfNeeded()
                contents?.go(offset: offset)
            }
        )
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius,
            isActive: enabled
        )
    }

    // enabled is honoured inside the action closure, not via .disabled(_:): that only gates a SwiftUI Button's own gesture recognition and has no effect on an NSViewRepresentable overlay's raw mouseDown.
    private func iconButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        OrbitNSActionButton(action: { if enabled { action() } }) {
            Image(systemName: symbol)
                .font(.system(size: OrbitToolbarMetrics.navGlyphSize, weight: .medium))
                .frame(width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
        }
        .foregroundStyle(enabled ? headerForeground : headerForegroundDimmed)
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius,
            isActive: enabled
        )
    }


    // OR'd with developerModeSettings.isEnabled: Arc also forces the full URL on in Developer Mode, a second and independent reason from toolbarSettings.showsFullURL, and neither flag may be folded into the other.
    private var addressText: String? {
        ToolbarAddressText.text(
            for: tab.url,
            showsFullURL: toolbarSettings.showsFullURL || developerModeSettings.isEnabled
        )
    }

    private var hasLoadedPage: Bool { addressText != nil }

    // Explicit exclusion here, not left to fall out of SecurityLevel's .local/.unknown-to-no-glyph rule: a future change to that rule must not silently make the copy control reachable on an orbit://note/<uuid> URL.
    private var showsAddressLeadingControl: Bool {
        hasLoadedPage && !OrbitInternalPageChrome.isDocumentPage(tab.url)
    }

    private var domainText: String { addressText ?? ToolbarAddressText.placeholder }

    private var centredAddressRegion: some View {
        GeometryReader { proxy in
            let reserve = clampedAddressSideReserve(in: proxy.size.width)
            centredAddressRow(
                showsSiteProfileDropdown: OrbitToolbarMetrics.fitsSiteProfileDropdown(regionWidth: proxy.size.width, sideReserve: reserve)
            )
            .padding(.horizontal, reserve)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func clampedAddressSideReserve(in width: CGFloat) -> CGFloat {
        let desired = OrbitToolbarMetrics.addressSideReserve(
            withSidebarToggle: showsSidebarToggle,
            withSplitClose: showsSplitClose,
            withOpenInOrbit: paneCapabilities.showsOpenInOrbit
        )
        guard width.isFinite, width > 0 else { return desired }
        return min(desired, max(0, (width - OrbitToolbarMetrics.minimumAddressWidth) / 2))
    }

    private func centredAddressRow(showsSiteProfileDropdown: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if showsAddressLeadingControl {
                    addressLeadingControl
                }
                addressField
                if showsSiteProfileDropdown, hasLoadedPage, !OrbitInternalPageChrome.isDocumentPage(tab.url),
                   env.store.siteProfileDropdownSiteKey(forTab: tab.id) != nil {
                    siteProfileDropdown
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var siteProfileDropdown: some View {
        let name = env.store.boundSiteProfile(forTab: tab.id)?.name
            ?? env.store.siteProfileDropdownSiteKey(forTab: tab.id).map { env.store.defaultSiteProfileName(forSiteKey: $0) }
            ?? SiteProfile.defaultName
        return OrbitMenuButton(entries: {
            focusPaneIfNeeded()
            adoptMenuTheme()
            return ToolbarContextMenu.siteProfileDropdownEntries(forTab: tab.id, in: env)
        }) {
            HStack(spacing: 4) {
                Text(name)
                    .font(OrbitFont.addressIndicator)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: OrbitToolbarMetrics.siteProfileNameMaxWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(headerForeground.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: OrbitToolbarMetrics.addressCopyPillSize)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
        )
        .layoutPriority(1)
        .padding(.leading, OrbitToolbarMetrics.addressPillGap)
        .orbitTooltip("Site Profile: \(name)")
        .accessibilityLabel("Site Profile: \(name)")
    }

    private var addressLeadingControl: some View {
        ToolbarAddressCopyControl(
            security: security,
            url: tab.url,
            foreground: headerForeground
        )
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius,
            isActive: hasSecurityGlyph
        )
        .padding(.trailing, hasSecurityGlyph ? OrbitToolbarMetrics.addressPillGap : 0)
    }

    private var hasSecurityGlyph: Bool {
        ToolbarSecurityGlyph.symbol(for: security) != nil
    }

    private var addressField: some View {
        OrbitNSActionButton {
            focusPaneIfNeeded()
            openAddressBar()
        } label: {
            Text(domainText)
                .font(OrbitFont.addressIndicator)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(headerForeground.opacity(hasLoadedPage ? 0.85 : 0.45))
                .padding(.horizontal, OrbitToolbarMetrics.addressGroupHorizontalInset)
                .frame(height: OrbitToolbarMetrics.addressCopyPillSize)
                .contentShape(Rectangle())
        }
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
        )
        .orbitTooltip("Search or Enter URL (\u{2318}L)")
    }

    // Document pages route to .blankPane(tab.id), not .editURL(tab.url), so orbit://note/<uuid> is never shown for editing; blankPaneMode(for:) is the one decision this click and Cmd+L share.
    private func openAddressBar() {
        env.perform(.addressBarCommandBar)
    }


    // Keyed by tab id, not a bare Bool, since a Bool can't say which pane's popover is open; the setter only clears the id when it is still this pane's own, so two panes can't race.
    private var siteControlPopoverBinding: Binding<Bool> {
        Binding(
            get: { env.siteControlPresentedTabID == tab.id },
            set: { isPresented in
                if isPresented {
                    env.siteControlPresentedTabID = tab.id
                } else if env.siteControlPresentedTabID == tab.id {
                    env.siteControlPresentedTabID = nil
                }
            }
        )
    }

    private var siteControlButton: some View {
        trailingIconButton(.siteControl) {
            focusPaneIfNeeded()
            env.siteControlPresentedTabID = tab.id
        }
        .popover(isPresented: siteControlPopoverBinding, arrowEdge: .bottom) {
            SiteControlPopoverView(tab: tab)
                .environment(\.orbitSpaceTheme, spaceTheme)
        }
    }

    private var hasSecondaryTrailingControls: Bool {
        paneCapabilities.allowsSplit || paneCapabilities.showsOpenInOrbit
    }

    // Narrow fallback: the split, close-pane and open-in-Orbit buttons fold into one overflow menu so the cluster never collides with the navigation cluster or the address.
    private func overflowEntries() -> [OrbitContextMenuEntry] {
        adoptMenuTheme()
        var entries: [OrbitContextMenuEntry] = []
        if paneCapabilities.allowsSplit {
            entries += SplitLayoutOption.menuEntries(forPaneOf: tab, in: env)
            if showsSplitClose {
                entries.append(.divider())
                entries.append(.item(OrbitContextMenuItem(title: "Close This Pane", systemImage: "xmark") {
                    env.closeSplitPane(tab.id)
                }))
            }
        }
        if paneCapabilities.showsOpenInOrbit {
            if !entries.isEmpty { entries.append(.divider()) }
            entries.append(.item(OrbitContextMenuItem(title: "Open in Orbit", systemImage: "arrow.up.forward.app", shortcut: "\u{2318}O") {
                env.perform(.openIntoMainWindow)
            }))
        }
        return entries
    }

    private var compactTrailingCluster: some View {
        HStack(spacing: OrbitToolbarMetrics.trailingIconSpacing) {
            siteControlButton
            if hasSecondaryTrailingControls {
                OrbitMenuButton(entries: overflowEntries) {
                    ToolbarTrailingGlyph(symbol: "ellipsis", glyphSize: OrbitToolbarMetrics.trailingGlyphSize)
                        .foregroundStyle(headerForeground)
                }
                .frame(width: OrbitToolbarMetrics.trailingIconSize, height: OrbitToolbarMetrics.trailingIconSize)
                .orbitHoverHighlight(
                    fill: headerHoverFill,
                    cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
                )
                .orbitTooltip("More")
                .accessibilityLabel("More")
            }
        }
    }

    private var trailingCluster: some View {
        HStack(spacing: OrbitToolbarMetrics.trailingIconSpacing) {
            siteControlButton
            if paneCapabilities.allowsSplit {
                OrbitMenuButton(entries: {
                    adoptMenuTheme()
                    return SplitLayoutOption.menuEntries(forPaneOf: tab, in: env)
                }) {
                    trailingIconGlyph(.splitView)
                }
                .frame(width: OrbitToolbarMetrics.trailingIconSize, height: OrbitToolbarMetrics.trailingIconSize)
                .orbitHoverHighlight(
                    fill: headerHoverFill,
                    cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
                )
                .orbitTooltip("Split View Options")
                SplitPaneCloseControl(tab: tab, foreground: headerForeground)
            }
            if paneCapabilities.showsOpenInOrbit {
                trailingIconButton(.openInOrbit) {
                    env.perform(.openIntoMainWindow)
                }
                .orbitTooltip("Open in Orbit (\u{2318}O)")
            }
        }
    }

    private var showsSplitClose: Bool {
        paneCapabilities.allowsSplit && SplitPaneCloseControl.isApplicable(to: tab, in: env)
    }

    private func trailingIconButton(_ glyph: ToolbarTrailingGlyph, action: @escaping () -> Void) -> some View {
        OrbitNSActionButton(action: action) {
            trailingIconGlyph(glyph)
        }
        .orbitHoverHighlight(
            fill: headerHoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
        )
    }

    private func trailingIconGlyph(_ glyph: ToolbarTrailingGlyph) -> some View {
        glyph.foregroundStyle(headerForeground)
    }


    #if DEBUG
    private static let selfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "ToolbarSelfCheck")

    private var frameProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { logSelfCheck(frame: proxy.frame(in: .global), label: "appear") }
                .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                    logSelfCheck(frame: newFrame, label: "change")
                }
        }
    }

    // Gated on DiagnosticChannel.toolbarColour (ORBIT_LOG_TOOLBAR_COLOUR=1), not just #if DEBUG: OrbitDemo is itself a DEBUG build and would otherwise log every navigation.
    private var colourProbe: some View {
        Color.clear.onChange(of: headerBackground, initial: true) { _, background in
            guard DiagnosticChannel.toolbarColour.isEnabled else { return }
            ToolbarView.selfCheckLogger.info("""
            [colour] url=\(self.tab.url.absoluteString, privacy: .public) \
            declared=\(String(describing: self.env.themeColors[self.tab.id]), privacy: .public) \
            live=\(String(describing: PaneHeaderColorResolver.shared.color(forTab: self.tab.id, url: self.tab.url)), privacy: .public) \
            hint=\(String(describing: PaneHeaderColorResolver.shared.cachedColor(for: self.tab.url)), privacy: .public) \
            contents=\(self.contents == nil ? "none" : "attached", privacy: .public) \
            painted=\(String(describing: background), privacy: .public) \
            glyphs=\(String(describing: PaneHeaderColorResolver.foreground(for: background)), privacy: .public)
            """)
        }
    }

    private var hitTestProbe: some View {
        HeaderHitTestProbe(tabID: tab.id)
    }

    private func logSelfCheck(frame: CGRect, label: String) {
        guard DiagnosticChannel.toolbarFrame.isEnabled else { return }
        ToolbarView.selfCheckLogger.info(
            "[\(label, privacy: .public)] tab=\(self.tab.id.uuidString, privacy: .public) toolbar frame=\(String(describing: frame), privacy: .public)"
        )
    }
    #endif


    private var headerDoubleClickObserver: some View {
        HeaderDoubleClickObserver(onDoubleClick: { OrbitTitleBarDoubleClick.handle(on: NSApp.keyWindow) })
    }
}

#if DEBUG
// Mounted as a .background(), so its own NSView is laid out at exactly the header's frame.
private struct HeaderHitTestProbe: NSViewRepresentable {
    var tabID: TabID

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.tabID = tabID
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.tabID = tabID
    }

    final class ProbeView: NSView {
        var tabID: TabID?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // stdout is block-buffered when output is redirected to a file, which is exactly how this probe gets read, so print(_:) would sit unflushed until the app quit.
        private func emit(_ line: String) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orbit-hit-test-probe.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            } else {
                try? Data((line + "\n").utf8).write(to: url)
            }
        }

        private func dumpTree(_ view: NSView, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            emit("[TREE] \(indent)\(type(of: view)) windowFrame=\(view.convert(view.bounds, to: nil)) hidden=\(view.isHidden) alpha=\(view.alphaValue) dragWindow=\(view.mouseDownCanMoveWindow)")
            for subview in view.subviews { dumpTree(subview, depth: depth + 1) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Deferred: SwiftUI is still mid-layout when this fires, so sibling controls' NSViews may not be positioned yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.probe()
            }
        }

        private func firstHostingView(from view: NSView) -> NSView? {
            var node: NSView? = view.superview
            while let current = node {
                if "\(type(of: current))".hasPrefix("NSHostingView") { return current }
                node = current.superview
            }
            return nil
        }

        private func probe() {
            guard DiagnosticChannel.toolbarHitTest.isEnabled else { return }
            guard let window, let contentView = window.contentView else { return }
            // Started where AppKit starts it: NSWindow.sendEvent(_:) hit-tests from the theme frame, not the content view.
            let themeFrame = contentView.superview ?? contentView
            let band = OrbitToolbarMetrics.topPadding + OrbitToolbarMetrics.height / 2
            let step = OrbitToolbarMetrics.navIconSize + OrbitToolbarMetrics.navIconSpacing
            var points: [(String, NSPoint)] = []
            for (index, name) in ["nav0", "nav1", "nav2", "nav3"].enumerated() {
                let x = OrbitToolbarMetrics.leadingPadding + OrbitToolbarMetrics.navIconSize / 2 + step * CGFloat(index)
                points.append((name, NSPoint(x: x, y: band)))
            }
            points.append(("address", NSPoint(x: bounds.midX, y: band)))
            points.append(("bare-chrome", NSPoint(x: bounds.maxX - 120, y: band)))

            emit("[HIT-TEST PROBE] tab=\(tabID?.uuidString.prefix(8) ?? "?") headerFrameInWindow=\(convert(bounds, to: nil)) windowContentLayoutRect=\(window.contentLayoutRect) windowFrame=\(window.frame)")
            for (name, pointInSelf) in points {
                // Converted through the window, not assumed: this view is flipped (SwiftUI-hosted) and the window is not.
                let pointInWindow = convert(pointInSelf, to: nil)
                var chain: [String] = []
                var node = themeFrame.hitTest(pointInWindow)
                while let current = node {
                    chain.append("\(type(of: current))[dragWindow=\(current.mouseDownCanMoveWindow)]")
                    node = current.superview
                }
                emit("[HIT-TEST PROBE]   \(name) atWindow=\(pointInWindow) -> \(chain.isEmpty ? "NOTHING" : chain.joined(separator: " < "))")
            }
            guard DiagnosticChannel.toolbarViewTree.isEnabled else { return }

            if let first = points.first {
                let pointInWindow = convert(first.1, to: nil)
                if let hosting = firstHostingView(from: self) {
                    let pointInHosting = hosting.convert(pointInWindow, from: nil)
                    emit("[SIBLINGS] hosting=\(type(of: hosting)) point=\(pointInWindow) inHosting=\(pointInHosting) subviews=\(hosting.subviews.count)")
                    for (index, subview) in hosting.subviews.enumerated().reversed() {
                        let contains = subview.frame.contains(pointInHosting)
                        let resolved = subview.hitTest(pointInHosting)
                        emit("[SIBLINGS]   [\(index)] \(type(of: subview)) frame=\(subview.frame) containsPoint=\(contains) hitTest=\(resolved.map { "\(type(of: $0))" } ?? "nil")")
                    }
                }
            }
            dumpTree(themeFrame, depth: 0)
        }
    }
}
#endif

private struct HeaderDoubleClickObserver: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class ObserverView: NSView {
        var onDoubleClick: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount == 2, let window = self.window, event.window === window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(locationInView) {
                    self.onDoubleClick?()
                }
                // Never consumed.
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
