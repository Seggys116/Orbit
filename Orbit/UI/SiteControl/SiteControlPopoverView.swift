import AppKit
import SwiftUI

struct SiteControlPopoverView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    // Every property and method below reads tab/tab.id, never env.activeTab: that would describe whichever pane is focused rather than the pane whose button was actually pressed (wrong in a split, wrong for a Little Orbit window).
    var tab: Tab

    @State private var developerModeEnabled = DeveloperModeSettings.isEnabled
    @State private var isAutoPeekEnabled = SiteControlPopoverView.isOpenLinksInModalEnabled
    @State private var boostsEditorSheet: BoostsEditorSheet?
    @State private var isExtensionsSheetPresented = false
    // EngineSession is not @Observable, so a write through it would not invalidate the view; caching here and reloading explicitly avoids a stale row until reopened.
    @State private var permissionRows: [PermissionRow] = []
    @State private var extensionActionEntries: [ExtensionActionEntry] = []
    // One slot for both action and options popovers together — opening either kind for any extension must close whatever the other one currently holds, or they stack.
    @State private var openExtensionPopup: OpenExtensionPopup?
    @State private var activeExtensionPopupModel: ExtensionActionPopupModel?
    @State private var cookiesClearState: ClearActionState = .idle
    @State private var cacheClearState: ClearActionState = .idle
    @State private var certificateDetailSheet: SiteCertificateDetailSheet?

    #if DEBUG
    // ImageRenderer cannot flatten an NSViewRepresentable click-catcher and paints a saturated yellow block instead; suppressed only during screenshot generation.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    private var host: String { tab.url.host() ?? "This site" }

    // Read fresh on every access, never cached: WebContents.currentCertificate() has no change notification.
    private var certificate: SiteCertificate? {
        env.webContents[tab.id]?.currentCertificate()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            actionIconRow
            if Self.isExtensionsSectionVisible(engine: env.engine) {
                Divider()
                extensionsRow
            }
            Divider()
            settingsSection
            Divider()
            secureFooter
        }
        .frame(width: 300)
        .onAppear {
            reloadPermissionRows()
            reloadExtensionActionEntries()
        }
        .onDisappear {
            closeExtensionPopup()
        }
        .onChange(of: isExtensionsSheetPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                reloadExtensionActionEntries()
            }
        }
        .sheet(item: $boostsEditorSheet) { sheet in
            // .environment(env) here is load-bearing: this popover is an NSPopover, and a .sheet it opens is a separate SwiftUI hosting context that does not automatically inherit @Environment(AppEnvironment.self) — its absence was a real crash.
            DismissableSheetChrome {
                sheet.view
                    .environment(env)
            }
        }
        .sheet(isPresented: $isExtensionsSheetPresented) {
            DismissableSheetChrome {
                ExtensionsSettingsPane()
                    .environment(env)
                    .padding(24)
                    .frame(width: 480, height: 420)
            }
        }
        .sheet(item: $certificateDetailSheet) { sheet in
            DismissableSheetChrome {
                SiteCertificateDetailView(certificate: sheet.certificate, host: sheet.host)
            }
        }
    }

    // Explicit .keyboardShortcut(.cancelAction) (Escape): a .sheet presented from a view inside a .popover is not guaranteed to honour Escape on its own.
    private struct DismissableSheetChrome<Content: View>: View {
        @Environment(\.dismiss) private var dismiss
        @ViewBuilder var content: () -> Content

        var body: some View {
            ZStack(alignment: .topTrailing) {
                content()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(10)
                .accessibilityLabel("Close")
            }
        }
    }

    struct BoostsEditorSheet: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    struct SiteCertificateDetailSheet: Identifiable {
        let id = UUID()
        let certificate: SiteCertificate
        let host: String
    }

    static func makeBoostsEditorSheet(for host: String, extensionPoints: UIExtensionPoints) -> BoostsEditorSheet? {
        guard let view = extensionPoints.boostsEditor?(host) else { return nil }
        return BoostsEditorSheet(view: view)
    }

    static var isOpenLinksInModalEnabled: Bool {
        PeekSettings.isAutomaticPeekEnabled
    }

    static func setOpenLinksInModal(_ enabled: Bool) {
        PeekSettings.isAutomaticPeekEnabled = enabled
    }

    private var header: some View {
        HStack(spacing: 10) {
            lockGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(securityLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
        .padding(.vertical, 14)
    }

    // nil, not EmptyView, for .local/.unknown: drawing nothing means the enclosing HStack loses its gap for that child, an accepted consequence rather than a sizing bug.
    private var securitySymbol: String? {
        switch env.webContents[tab.id]?.navigationState.security {
        case .secure: return "lock.fill"
        case .certificateError: return "lock.trianglebadge.exclamationmark.fill"
        case .insecure, .mixedContent: return "lock.slash"
        case .local, .unknown, nil: return nil
        }
    }

    // Exhaustive over SecurityLevel, not default:, so a new case is a compile error here rather than a silently swallowed one.
    private var securityColor: Color {
        switch env.webContents[tab.id]?.navigationState.security {
        case .secure: return .green
        case .certificateError: return .red
        case .insecure, .mixedContent: return .orange
        case .local, .unknown, nil: return .secondary
        }
    }

    private var securityLabel: String {
        switch env.webContents[tab.id]?.navigationState.security {
        case .secure: return "Connection is secure"
        case .certificateError: return "Certificate problem"
        case .insecure: return "Not secure"
        case .mixedContent: return "Partially secure"
        case .local: return "Local page"
        case .unknown, nil: return "Unknown"
        }
    }

    @ViewBuilder
    private var lockGlyph: some View {
        if let symbol = securitySymbol {
            if let certificate {
                Button {
                    certificateDetailSheet = SiteCertificateDetailSheet(certificate: certificate, host: host)
                } label: {
                    Image(systemName: symbol)
                        .foregroundStyle(securityColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View certificate for \(host)")
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(securityColor)
            }
        }
    }

    // MARK: - Action icon row

    // The same lookup CaptureController.present(tabID:fullPage:env:) performs, so this gate and that guard cannot disagree about what counts as "live".
    private var hasLiveContentsForActionRow: Bool {
        env.webContents[tab.id] != nil
    }

    private var actionIconRow: some View {
        HStack(spacing: OrbitMetrics.siteControlActionButtonGap) {
            shareIconButton
            iconActionButton(
                symbol: "bolt.circle",
                accessibilityLabel: "Boosts: \(activeBoostsSubtitle)",
                disabled: !hasLiveContentsForActionRow,
                unavailableReason: "No page is open to attach a Boost to."
            ) {
                boostsEditorSheet = Self.makeBoostsEditorSheet(for: host, extensionPoints: env.extensionPoints)
            }
            iconActionButton(
                symbol: "camera.viewfinder",
                accessibilityLabel: "Capture Page",
                disabled: !hasLiveContentsForActionRow,
                unavailableReason: "No page is open to capture."
            ) {
                env.extensionPoints.presentCaptureTool?(tab.id, false)
            }
            iconActionButton(
                symbol: "doc.on.doc",
                accessibilityLabel: "Capture Full Page",
                disabled: !hasLiveContentsForActionRow,
                unavailableReason: "No page is open to capture."
            ) {
                env.extensionPoints.presentCaptureTool?(tab.id, true)
            }
        }
        .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
        .padding(.vertical, 10)
    }

    private func iconActionButton(
        symbol: String,
        accessibilityLabel: String,
        disabled: Bool = false,
        unavailableReason: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OrbitMetrics.iconMedium, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: OrbitMetrics.siteControlActionButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: OrbitMetrics.siteControlActionButtonCornerRadius, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? (unavailableReason ?? "") : "")
        .accessibilityLabel(disabled ? "\(accessibilityLabel): unavailable" : accessibilityLabel)
    }

    // MARK: - Extensions section

    static func isExtensionsSectionVisible(engine: (any BrowserEngine)?) -> Bool {
        engine?.capabilities.contains(.extensions) ?? false
    }

    static func enabledExtensionCount(engine: (any BrowserEngine)?) -> Int {
        guard let engine else { return 0 }
        return engine.loadedExtensions(session: engine.defaultSession).filter(\.isEnabled).count
    }

    private var extensionsSubtitle: String {
        let count = Self.enabledExtensionCount(engine: env.engine)
        return count == 0 ? "No extensions enabled" : "\(count) extension\(count == 1 ? "" : "s") enabled"
    }

    struct ExtensionActionEntry: Identifiable {
        var id: String { extensionInfo.id }
        var extensionInfo: LoadedExtension
        var manifest: ChromeExtensionManifest
        var popupURL: URL
        var actionIconFileURL: URL?
        var optionsURL: URL?
        var optionsPresentation: ExtensionActionPopupSupport.OptionsPagePresentation
        var isPendingActivation: Bool
        // What chrome.action last set for the tab this row is being drawn for
        // -- badge, dynamically set icon, and the per-tab enabled bit.
        var actionState: ExtensionActionState = ExtensionActionState()

        var badgeText: String? { ExtensionActionPopupSupport.displayBadgeText(actionState.badgeText) }
        // chrome.action.setTitle overrides the manifest's default_title.
        var accessibleTitle: String {
            if !actionState.title.isEmpty { return actionState.title }
            return manifest.actionTitle ?? extensionInfo.name
        }
    }

    // MARK: - Extension popup identity and presentation (pure; drives, and is exercised directly by, the imperative methods below)

    struct OpenExtensionPopup: Equatable {
        enum Kind: Equatable { case action, options }
        var extensionID: String
        var kind: Kind
    }

    enum ExtensionPopupPresentation: Equatable {
        case pendingActivation
        case live(url: URL)
    }

    // The single decision of what a click on an extension's action or options icon should do — never a chrome-extension:// URL for one the engine has not loaded yet.
    static func presentation(for entry: ExtensionActionEntry, url: URL) -> ExtensionPopupPresentation {
        entry.isPendingActivation ? .pendingActivation : .live(url: url)
    }

    // Toggle semantics: requesting the popup that is already open closes it; requesting any other one replaces whatever was open, so only one is ever represented.
    static func nextOpenExtensionPopup(current: OpenExtensionPopup?, requesting target: OpenExtensionPopup) -> OpenExtensionPopup? {
        current == target ? nil : target
    }

    // session is the pane's own session, not engine.defaultSession: an Incognito window's tab and the default profile can disagree about persistence inside the same running engine.
    static func extensionActionEntries(
        engine: (any BrowserEngine)?,
        session: (any EngineSession)?,
        tabID: Int32? = nil
    ) -> [ExtensionActionEntry] {
        guard let engine, let session else { return [] }
        let sessionIsPersistent = session.isPersistent
        let actionStates = engine.extensionActionStates
        let installed = engine.loadedExtensions(session: session).filter { $0.isEnabled && $0.hasToolbarAction }
        return installed.compactMap { extensionInfo -> ExtensionActionEntry? in
            guard let manifest = try? ChromeExtensionManifest.read(fromDirectory: extensionInfo.directory) else {
                return nil
            }
            let actionState = actionStates.state(extensionID: extensionInfo.id, tabID: tabID)
            let popupPath = ExtensionActionPopupSupport.effectiveActionPopupPath(
                extensionID: extensionInfo.id,
                manifestPopupPath: manifest.actionPopupPath,
                engineReportedPopupURL: actionState.popupURLString
            )
            guard let popupURL = ExtensionActionPopupSupport.actionPopupURL(
                extensionID: extensionInfo.id,
                isEnabled: extensionInfo.isEnabled,
                hasToolbarAction: extensionInfo.hasToolbarAction,
                manifestKey: manifest.key,
                actionPopupPath: popupPath,
                sessionIsPersistent: sessionIsPersistent,
                directory: extensionInfo.directory,
                idIsEngineAssigned: extensionInfo.idIsEngineAssigned
            ) else { return nil }
            let optionsURL = ExtensionActionPopupSupport.optionsPageURL(
                extensionID: extensionInfo.id,
                isEnabled: extensionInfo.isEnabled,
                manifestKey: manifest.key,
                optionsPagePath: manifest.optionsPagePath,
                sessionIsPersistent: sessionIsPersistent,
                directory: extensionInfo.directory,
                idIsEngineAssigned: extensionInfo.idIsEngineAssigned
            )
            return ExtensionActionEntry(
                extensionInfo: extensionInfo,
                manifest: manifest,
                popupURL: popupURL,
                actionIconFileURL: ExtensionActionPopupSupport.actionIconFileURL(
                    extensionDirectory: extensionInfo.directory,
                    relativePath: manifest.actionIconRelativePath
                ),
                optionsURL: optionsURL,
                optionsPresentation: ExtensionActionPopupSupport.optionsPagePresentation(optionsOpenInTab: manifest.optionsOpenInTab),
                isPendingActivation: ExtensionActionPopupSupport.requiresRestartToActivate(isActivatedInRunningEngine: extensionInfo.isActivated),
                actionState: actionState
            )
        }
    }

    private func reloadExtensionActionEntries() {
        extensionActionEntries = Self.extensionActionEntries(
            engine: env.engine,
            session: env.webContents[tab.id]?.session,
            tabID: OrbitChromiumTabsBridge.shared.existingTabID(for: tab.id)
        )
    }

    @ViewBuilder
    private var extensionActionIconGrid: some View {
        if !extensionActionEntries.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(extensionActionEntries) { entry in
                    extensionActionIcon(entry)
                }
            }
            .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
            .padding(.top, 8)
        }
    }

    // orbitHoverPopover, not a plain SwiftUI .popover: a plain .popover nested here risks click-eating (its .transient default consumes the next outside click) and a detached environment that doesn't inherit @Environment(AppEnvironment.self).
    private func extensionActionIcon(_ entry: ExtensionActionEntry) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                presentExtensionPopup(for: entry, kind: .action, url: entry.popupURL)
            } label: {
                ZStack(alignment: .topTrailing) {
                    extensionActionIconImage(entry)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: OrbitMetrics.siteControlActionButtonCornerRadius, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        // Reflects chrome.action.disable() for this tab, using
                        // the same disabled-opacity token as OrbitButton.
                        .opacity(entry.actionState.isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)

                    if let badgeText = entry.badgeText {
                        extensionActionBadge(badgeText, state: entry.actionState)
                            .opacity(entry.actionState.isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!entry.actionState.isEnabled)
            .accessibilityLabel(entry.accessibleTitle)
            .help(entry.accessibleTitle)
            .orbitHoverPopover(isPresented: extensionPopupBinding(for: entry.id, kind: .action), preferredEdge: .minY) {
                extensionPopupContent(entry: entry, kind: .action)
            }

            if let optionsURL = entry.optionsURL {
                extensionOptionsAffordance(entry: entry, optionsURL: optionsURL)
            }
        }
    }

    private func extensionActionBadge(_ text: String, state: ExtensionActionState) -> some View {
        let fill = state.badgeBackgroundColor.isUnset
            ? OrbitControlColor.extensionBadgeFill(for: colorScheme)
            : Color(state.badgeBackgroundColor)
        let foreground = state.badgeTextColor.isUnset
            ? OrbitControlColor.extensionBadgeText
            : Color(state.badgeTextColor)
        return Text(text)
            .font(.system(size: OrbitControlMetrics.extensionBadgeFontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, OrbitControlMetrics.extensionBadgeHorizontalPadding)
            .frame(
                minWidth: OrbitControlMetrics.extensionBadgeMinimumWidth,
                minHeight: OrbitControlMetrics.extensionBadgeHeight
            )
            .background(
                RoundedRectangle(cornerRadius: OrbitControlMetrics.extensionBadgeCornerRadius, style: .continuous)
                    .fill(fill)
            )
            .fixedSize()
            .offset(x: 4, y: -4)
    }

    @ViewBuilder
    private func extensionActionIconImage(_ entry: ExtensionActionEntry) -> some View {
        // chrome.action.setIcon wins over anything on disk: the extension set
        // it for this exact tab, and the manifest icon is only the fallback.
        let dynamicImage = entry.actionState.iconPNG.flatMap { NSImage(data: $0) }
        let actionImage = dynamicImage ?? entry.actionIconFileURL.flatMap { NSImage(contentsOf: $0) }
        let extensionImage = entry.extensionInfo.iconURL.flatMap { NSImage(contentsOf: $0) }
        switch ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: actionImage != nil, hasExtensionIcon: extensionImage != nil) {
        case .actionIcon:
            Image(nsImage: actionImage!)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(7)
        case .extensionIcon:
            Image(nsImage: extensionImage!)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(7)
        case .genericGlyph:
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private func extensionOptionsAffordance(entry: ExtensionActionEntry, optionsURL: URL) -> some View {
        Group {
            switch entry.optionsPresentation {
            case .tab:
                Button {
                    env.siteControlPresentedTabID = nil
                    _ = env.openTab(url: optionsURL, in: tab.spaceID)
                } label: {
                    extensionOptionsGlyph
                }
                .buttonStyle(.plain)
            case .panel:
                Button {
                    presentExtensionPopup(for: entry, kind: .options, url: optionsURL)
                } label: {
                    extensionOptionsGlyph
                }
                .buttonStyle(.plain)
                .orbitHoverPopover(isPresented: extensionPopupBinding(for: entry.id, kind: .options), preferredEdge: .minY) {
                    extensionPopupContent(entry: entry, kind: .options)
                }
            }
        }
        .accessibilityLabel("\(entry.extensionInfo.name) options")
        .help("\(entry.extensionInfo.name) options")
    }

    private var extensionOptionsGlyph: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(Color.secondary))
            .offset(x: 3, y: 3)
    }

    @ViewBuilder
    private func extensionPopupContent(entry: ExtensionActionEntry, kind: OpenExtensionPopup.Kind) -> some View {
        if openExtensionPopup == OpenExtensionPopup(extensionID: entry.id, kind: kind) {
            if entry.isPendingActivation {
                ExtensionPendingActivationView(extensionName: entry.extensionInfo.name)
            } else if let model = activeExtensionPopupModel {
                ExtensionActionPopupView(model: model)
            }
        }
    }

    private func presentExtensionPopup(for entry: ExtensionActionEntry, kind: OpenExtensionPopup.Kind, url: URL) {
        let target = OpenExtensionPopup(extensionID: entry.id, kind: kind)
        let next = Self.nextOpenExtensionPopup(current: openExtensionPopup, requesting: target)
        closeExtensionPopup()
        guard next != nil else { return }

        switch Self.presentation(for: entry, url: url) {
        case .pendingActivation:
            openExtensionPopup = target
        case .live(let url):
            guard let engine = env.engine, let session = env.webContents[tab.id]?.session else { return }
            let model = ExtensionActionPopupModel(engine: engine, session: session, url: url)
            model.start()
            activeExtensionPopupModel = model
            openExtensionPopup = target
        }
    }

    private func closeExtensionPopup() {
        activeExtensionPopupModel?.teardown()
        activeExtensionPopupModel = nil
        openExtensionPopup = nil
    }

    private func extensionPopupBinding(for id: String, kind: OpenExtensionPopup.Kind) -> Binding<Bool> {
        let identity = OpenExtensionPopup(extensionID: id, kind: kind)
        return Binding(
            get: { openExtensionPopup == identity },
            set: { isPresented in
                guard !isPresented, openExtensionPopup == identity else { return }
                closeExtensionPopup()
            }
        )
    }

    // MARK: - Settings row content (sizing pass)

    private func settingsRowContent(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: OrbitMetrics.siteControlRowBadgeToTextGap) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: OrbitMetrics.siteControlRowBadgeDiameter, height: OrbitMetrics.siteControlRowBadgeDiameter)
                Image(systemName: symbol)
                    .font(.system(size: OrbitMetrics.siteControlRowBadgeGlyphSize, weight: .medium))
            }
            VStack(alignment: .leading, spacing: OrbitControlMetrics.settingsRowLabelSpacing) {
                Text(title)
                    .font(.system(size: OrbitMetrics.siteControlRowTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: OrbitMetrics.siteControlRowValueFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
        .frame(height: OrbitMetrics.siteControlRowPitch)
        .contentShape(Rectangle())
    }

    private var extensionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            extensionActionIconGrid
            Button {
                isExtensionsSheetPresented = true
            } label: {
                settingsRowContent(symbol: "puzzlepiece.extension", title: "Extensions", value: extensionsSubtitle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Extensions: \(extensionsSubtitle)")
        }
    }

    // MARK: - Settings section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: OrbitControlMetrics.sectionHeaderFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
                .padding(.bottom, 4)

            permissionSection

            settingsRowContent(symbol: "pip", title: "Picture-in-Picture", value: "Automatic")

            Button {
                isAutoPeekEnabled.toggle()
                Self.setOpenLinksInModal(isAutoPeekEnabled)
            } label: {
                settingsRowContent(
                    symbol: "macwindow.on.rectangle",
                    title: "Open Links in Modal",
                    value: isAutoPeekEnabled ? "While Pinned" : "Off"
                )
            }
            .buttonStyle(.plain)

            siteDataRows
            developerToolsRow

            Button {
                developerModeEnabled = DeveloperModeSettings.toggle()
            } label: {
                settingsRowContent(symbol: "hammer", title: "Developer Mode", value: developerModeEnabled ? "On" : "Off")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Developer Tools row

    // Gate and effect must agree: checking only the engine capability while the action reaches through env.webContents[tab.id] would let a Chromium engine with no active tab look enabled while pressing it silently does nothing.
    private var isDeveloperToolsAvailable: Bool {
        Self.isDeveloperToolsAvailable(capabilities: env.engineCapabilities) && env.webContents[tab.id] != nil
    }

    static func isDeveloperToolsAvailable(capabilities: EngineCapabilities) -> Bool {
        capabilities.contains(.developerTools)
    }

    private var developerToolsUnavailableReason: String {
        guard Self.isDeveloperToolsAvailable(capabilities: env.engineCapabilities) else {
            return EngineCapabilityCopy.developerToolsUnavailable
        }
        return "No page is open in this pane to inspect."
    }

    private var developerToolsRow: some View {
        let available = isDeveloperToolsAvailable
        return Button {
            env.webContents[tab.id]?.showDeveloperTools(inspectAt: nil)
        } label: {
            settingsRowContent(
                symbol: "chevron.left.forwardslash.chevron.right",
                title: "Developer Tools",
                value: available ? "Open" : "Unavailable"
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(available ? "" : developerToolsUnavailableReason)
        .accessibilityLabel(available ? "Developer Tools" : "Developer Tools: unavailable — \(developerToolsUnavailableReason)")
    }

    // MARK: - Site data: Clear Cookies / Clear Cache

    // Kept as two rows: cache clearing is session-wide while cookie clearing is
    // per-origin. `.done` means the call returned, not that anything was
    // verified as removed.
    private var siteDataRows: some View {
        Group {
            Button {
                clearCookiesForThisSite()
            } label: {
                settingsRowContent(symbol: "network", title: "Clear Cookies for This Site", value: cookiesClearState.label)
            }
            .buttonStyle(.plain)
            .disabled(env.webContents[tab.id]?.session == nil || cookiesClearState == .clearing)
            .accessibilityLabel("Clear Cookies for This Site, scoped to \(host) only")

            Button {
                clearCacheForEntireSession()
            } label: {
                settingsRowContent(symbol: "internaldrive", title: "Clear Cache (Entire Session)", value: cacheClearState.label)
            }
            .buttonStyle(.plain)
            .disabled(env.engine == nil || env.webContents[tab.id]?.session == nil || cacheClearState == .clearing)
            .accessibilityLabel("Clear Cache for the entire browsing session, not only this site — Chromium's cache has no per-site clear")
        }
    }

    enum ClearActionState: Equatable {
        case idle
        case clearing
        case done

        var label: String {
            switch self {
            case .idle: return "Clear"
            case .clearing: return "Clearing…"
            case .done: return "Cleared"
            }
        }
    }

    // internal, not private: the wiring test awaits this bounded duration instead of guessing one.
    static let clearActionFeedbackDuration: Duration = .seconds(1.5)

    private func clearCookiesForThisSite() {
        guard let session = env.webContents[tab.id]?.session else { return }
        let origin = tab.url
        cookiesClearState = .clearing
        Task { @MainActor in
            await session.deleteCookies(for: origin)
            cookiesClearState = .done
            try? await Task.sleep(for: Self.clearActionFeedbackDuration)
            if cookiesClearState == .done { cookiesClearState = .idle }
        }
    }

    private func clearCacheForEntireSession() {
        guard let engine = env.engine, let session = env.webContents[tab.id]?.session else { return }
        cacheClearState = .clearing
        Task { @MainActor in
            await engine.clearBrowsingData(.cache, session: session, since: nil)
            cacheClearState = .done
            try? await Task.sleep(for: Self.clearActionFeedbackDuration)
            if cacheClearState == .done { cacheClearState = .idle }
        }
    }

    // MARK: - Permission rows

    // EngineSession.contentSetting(_:for:)/setContentSetting(_:for:url:) read and write Chromium's OrbitPermissionStore directly — the same store an allowAlways/denyAlways prompt answer is recorded in. One store, not a shadow copy.

    struct PermissionRow: Identifiable, Equatable {
        var kind: PermissionKind
        var setting: ContentSetting

        var id: PermissionKind { kind }
        var title: String { kind.displayName }

        var valueLabel: String {
            switch setting {
            case .allow: return "Allowed"
            case .block: return "Blocked"
            case .ask, .unsupported: return ""
            }
        }
    }

    static let permissionDisplayOrder: [PermissionKind] = [
        .geolocation,
        .camera,
        .microphone,
        .notifications,
        .clipboardRead,
        .screenCapture,
        .midi,
        .sensors,
        .protectedMediaIdentifier,
        .fileSystemWrite,
    ]

    // Rows appear only for a stored .allow/.block; .ask means the site has never been answered.
    static func permissionRows(
        origin: URL?,
        session: (any EngineSession)?,
        manageable: Set<PermissionKind>
    ) -> [PermissionRow] {
        guard let origin, let session, ContentSettingOrigin.normalize(origin) != nil else { return [] }
        return permissionDisplayOrder.compactMap { kind in
            guard manageable.contains(kind) else { return nil }
            let setting = session.contentSetting(kind, for: origin)
            guard setting == .allow || setting == .block else { return nil }
            return PermissionRow(kind: kind, setting: setting)
        }
    }

    static func setPermission(
        _ setting: ContentSetting,
        kind: PermissionKind,
        origin: URL,
        session: any EngineSession
    ) {
        session.setContentSetting(setting, for: kind, url: origin)
    }

    static func makePermissionMenu(
        for row: PermissionRow,
        origin: URL,
        session: any EngineSession,
        onChange: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice: (ContentSetting, String) in [(.allow, "Allow"), (.block, "Block"), (.ask, "Ask")] {
            let item = ClosureMenuItem(title: choice.1) {
                setPermission(choice.0, kind: row.kind, origin: origin, session: session)
                onChange()
            }
            item.state = row.setting == choice.0 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private var permissionSection: some View {
        ForEach(permissionRows) { row in
            OrbitNSMenuButton {
                guard let session = env.webContents[tab.id]?.session else { return NSMenu() }
                return Self.makePermissionMenu(for: row, origin: tab.url, session: session) {
                    reloadPermissionRows()
                }
            } label: {
                settingsRowContent(symbol: Self.symbolName(for: row.kind), title: row.title, value: row.valueLabel)
            }
            .accessibilityLabel("\(row.title): \(row.valueLabel)")
        }
    }

    static func symbolName(for kind: PermissionKind) -> String {
        switch kind {
        case .geolocation: return "location.fill"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .notifications: return "bell.fill"
        case .clipboardRead: return "doc.on.clipboard"
        case .screenCapture: return "rectangle.on.rectangle"
        case .midi: return "pianokeys"
        case .sensors: return "gyroscope"
        case .protectedMediaIdentifier: return "play.rectangle.fill"
        case .fileSystemWrite: return "folder.fill"
        }
    }

    private func reloadPermissionRows() {
        permissionRows = Self.permissionRows(
            origin: tab.url,
            session: env.webContents[tab.id]?.session,
            manageable: env.engine?.manageableContentSettings ?? []
        )
    }

    private var secureFooter: some View {
        HStack(spacing: 0) {
            HStack(spacing: OrbitMetrics.siteControlFooterGlyphToTextGap) {
                lockGlyph
                    .font(.system(size: OrbitMetrics.siteControlFooterGlyphSize))
                Text(env.webContents[tab.id]?.navigationState.security == .secure ? "Secure" : securityLabel)
                    .font(.system(size: OrbitMetrics.siteControlFooterLabelFontSize, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, OrbitMetrics.siteControlFooterPillHorizontalPadding)
            .frame(height: OrbitMetrics.siteControlFooterPillHeight)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrbitMetrics.siteControlRowHorizontalMargin)
        .padding(.vertical, 10)
    }

    private var activeBoostsSubtitle: String {
        let count = env.boostStore.boosts(forHost: host).filter(\.isEnabled).count
        return count == 0 ? "No active Boosts" : "\(count) active Boost\(count == 1 ? "" : "s")"
    }

    // MARK: - Share (audit defect C)

    // NSSharingServicePicker.show(relativeTo:of:preferredEdge:) needs a real, non-zero-rect NSView to hang the presentation off — SharePickerClickCatchingView below is that anchor.
    private var shareIconButton: some View {
        let url = tab.url
        let isAvailable = hasLiveContentsForActionRow
        return Image(systemName: "square.and.arrow.up")
            .font(.system(size: OrbitMetrics.iconMedium, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: OrbitMetrics.siteControlActionButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.siteControlActionButtonCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay {
                #if DEBUG
                if isAvailable, !screenshotModeRepresentableDisabled {
                    SharePickerCatcher(urls: [url])
                }
                #else
                if isAvailable {
                    SharePickerCatcher(urls: [url])
                }
                #endif
            }
            .accessibilityLabel(isAvailable ? "Share" : "Share: unavailable")
            .help(isAvailable ? "" : "No page is open to share.")
    }
}

private final class SharePickerClickCatchingView: NSView, OrbitClickCatching, NSSharingServicePickerDelegate {
    var urls: [URL] = []

    private var activePicker: NSSharingServicePicker?

    override func mouseDown(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        activePicker = picker
        // bounds, not .zero: this view's own bounds are the Share button's real on-screen rect.
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        activePicker = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }
}

private struct SharePickerCatcher: NSViewRepresentable {
    var urls: [URL]

    func makeNSView(context: Context) -> SharePickerClickCatchingView {
        let view = SharePickerClickCatchingView()
        view.urls = urls
        return view
    }

    func updateNSView(_ nsView: SharePickerClickCatchingView, context: Context) {
        nsView.urls = urls
    }
}
