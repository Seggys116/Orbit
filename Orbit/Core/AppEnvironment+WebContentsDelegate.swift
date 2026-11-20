import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WebKit

// MARK: - Per-tab navigation mirror

// One per tab with live web contents. Each field is its own Observation key and update(from:) writes
// only fields that changed, so a view reading canGoBack is not invalidated by a progress tick, and a
// view reading one tab is not invalidated by another tab at all.
@MainActor
@Observable
final class NavigationBox {
    private(set) var url: URL?
    private(set) var title: String
    private(set) var canGoBack: Bool
    private(set) var canGoForward: Bool
    private(set) var isLoading: Bool
    private(set) var progress: Double
    private(set) var security: SecurityLevel

    init(_ state: NavigationState) {
        url = state.url
        title = state.title
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
        isLoading = state.isLoading
        progress = state.progress
        security = state.security
    }

    // Reads every field, so a view reading this depends on all of them; views should read the fields they show.
    var state: NavigationState {
        NavigationState(
            url: url,
            title: title,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
            progress: progress,
            security: security
        )
    }

    // Observable setters notify even for an identical value, hence the comparisons.
    func update(from state: NavigationState) {
        if url != state.url { url = state.url }
        if title != state.title { title = state.title }
        if canGoBack != state.canGoBack { canGoBack = state.canGoBack }
        if canGoForward != state.canGoForward { canGoForward = state.canGoForward }
        if isLoading != state.isLoading { isLoading = state.isLoading }
        if progress != state.progress { progress = state.progress }
        if security != state.security { security = state.security }
    }
}

extension AppEnvironment {

    func navigationBox(for tabID: TabID) -> NavigationBox? {
        navigationBoxes[tabID]
    }

    func navigationState(for tabID: TabID) -> NavigationState? {
        navigationBoxes[tabID]?.state
    }

    /// Progress while the tab is loading, nil otherwise. Reads progress only while loading, so an idle
    /// row is not invalidated by a progress value nobody draws.
    func navigationLoadingProgress(for tabID: TabID) -> Double? {
        guard let box = navigationBoxes[tabID], box.isLoading else { return nil }
        return box.progress
    }

    func setNavigationState(_ state: NavigationState, for tabID: TabID) {
        if let box = navigationBoxes[tabID] {
            box.update(from: state)
        } else {
            navigationBoxes[tabID] = NavigationBox(state)
        }
    }

    func removeNavigationState(for tabID: TabID) {
        guard navigationBoxes[tabID] != nil else { return }
        navigationBoxes.removeValue(forKey: tabID)
    }

    func removeAllNavigationStates() {
        guard !navigationBoxes.isEmpty else { return }
        navigationBoxes.removeAll()
    }

    /// Value snapshot for non-UI callers and tests. Reading it in a view depends on every tab's every
    /// field; views read navigationBox(for:) instead. Assigning reconciles: boxes survive for kept keys
    /// and are updated in place, so a whole-dictionary write still invalidates only what changed.
    var navigationStates: [TabID: NavigationState] {
        get { navigationBoxes.mapValues { $0.state } }
        set {
            for tabID in navigationBoxes.keys where newValue[tabID] == nil {
                removeNavigationState(for: tabID)
            }
            for (tabID, state) in newValue {
                setNavigationState(state, for: tabID)
            }
        }
    }
}

// WebContents.id is NOT Tab.id — every callback below must resolve the
// actual TabID via AppEnvironment.tabID(for:) instead of trusting contents.id.
extension AppEnvironment: WebContentsDelegate {

    // MARK: Navigation lifecycle

    func webContentsDidChangeNavigationState(_ contents: WebContents) {
        guard let tabID = tabID(for: contents) else { return }
        // A load in a background tab must re-apply its colour scheme when the tab is next shown.
        if contents.navigationState.isLoading { PageColorSchemeScript.forgetSettled(for: contents.id) }
        setNavigationState(contents.navigationState, for: tabID)
        guard let existing = state.tabs[tabID] else { return }
        var tab = existing
        if let url = contents.navigationState.url, url != tab.url {
            // The icon belongs to the site the page came from; kept across a move to another host it was shown, and cached, as the new site's.
            if url.host()?.lowercased() != tab.url.host()?.lowercased() { tab.faviconURL = nil }
            tab.url = url
        }
        if !contents.navigationState.title.isEmpty {
            tab.title = contents.navigationState.title
            // Backfills a pin that raced the engine and captured no title — the only place it can still land, since pin(_:) never revisits pinnedTitle; gated on hasNavigatedAwayFromPinnedURL so it only applies while the tab is still on its pinned origin.
            if tab.section == .pinned, tab.pinnedTitle == nil, !tab.hasNavigatedAwayFromPinnedURL {
                tab.pinnedTitle = tab.title
            }
        }
        // Load progress alone fires this many times a second; writing an identical Tab back would reschedule the autosave debounce every time and starve it.
        guard tab != existing else { return }
        state.tabs[tabID] = tab
    }

    func webContents(
        _ contents: WebContents,
        shouldAllowNavigationTo url: URL,
        kind: NavigationKind,
        isMainFrame: Bool
    ) -> Bool {
        guard isMainFrame, kind == .linkActivated else { return true }

        // Read once and passed down so both modifier-driven checks below see
        // the same snapshot, and so each is callable from a test with explicit flags.
        let modifiers = NSEvent.modifierFlags

        if shouldOpenInLittleOrbit(modifiers: modifiers) {
            LittleOrbitWindowController.openFromExternalActivation(url: url)
            return false
        }
        if let sourceTabID = tabID(for: contents), shouldPeek(sourceTabID: sourceTabID, modifiers: modifiers, destination: url) {
            openPeek(sourceTabID: sourceTabID, url: url)
            return false
        }
        guard let rule = matchingRoutingRule(for: url) else { return true }
        let sourceTabID = tabID(for: contents) ?? UUID()
        return !applyRoutingRule(rule, url: url, sourceTabID: sourceTabID)
    }

    // Takes modifiers explicitly rather than reading NSEvent.modifierFlags
    // itself so a test can drive the decision with a real modifier set.
    func shouldPeek(sourceTabID: TabID, modifiers: NSEvent.ModifierFlags, destination: URL? = nil) -> Bool {
        guard let tab = state.tabs[sourceTabID] else { return false }
        switch tab.section {
        case .favorite, .pinned:
            if let destination, SiteIdentity.areSameSite(tab.url, destination) { return false }
            return PeekSettings.isAutomaticPeekEnabled
        case .today:
            return PeekSettings.isShiftClickPeekEnabled && modifiers.contains(.shift)
        case .archived:
            return false
        }
    }

    private func openPeek(sourceTabID: TabID, url: URL) {
        PeekState.shared.present(sourceTabID: sourceTabID, url: url)
        _ = extensionPoints.peekPanel?(sourceTabID, url)
    }

    func shouldOpenInLittleOrbit(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard LittleOrbitSettings.opensOnModifierClick else { return false }
        return modifiers.contains(.option) && modifiers.contains(.command)
    }

    func webContents(_ contents: WebContents, didCommitNavigationTo url: URL, kind: NavigationKind) {
        // Before the tabID guard, deliberately: whether Orbit can resolve
        // this tab has no bearing on whether the page should be boosted.
        BoostRuntime.shared.pageDidCommit(url: url, contents: contents, env: self)
        // The first committed page ends the launch window: deferred list refreshes, extensions and sync can start.
        LaunchGate.shared.pageDidCommit()

        guard let tabID = tabID(for: contents) else { return }
        TidyTabTitlesCoordinator.shared.navigationDidCommit(tabID: tabID, committedURL: url, env: self)
        tabErrors.removeValue(forKey: tabID)
        crashedTabs.remove(tabID)
        certificateProblems.removeValue(forKey: tabID)
        refusedCertificateTabIDs.remove(tabID)
        applyStoredZoomFactor(to: contents, tabID: tabID, url: url)
        applyStoredMuteState(to: contents, tabID: tabID)
        store.noteTabAccessed(tabID)
        guard let tab = state.tabs[tabID] else { return }
        // A page coming back (woken, gone back to, reloaded) is not a new visit: counting it made the page the person left
        // look like the one they last visited, and put it first in the Command Bar.
        let wasQuiet = quietLoadTabIDs.remove(tabID) != nil
        guard !wasQuiet, kind != .backForward, kind != .reload, kind != .restored else { return }
        // No title here: the committed page has not named itself yet, and the tab still holds the title of the page just left. It is filled in as the page loads.
        recordVisit(url: url, title: "", profileID: space(tab.spaceID)?.profileID ?? state.profiles.first?.id ?? UUID(), spaceID: tab.spaceID, wasTyped: kind == .typed)
    }

    func webContents(_ contents: WebContents, didFinishLoading url: URL, statusCode: Int) {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return }
        quietLoadTabIDs.remove(tabID)
        noteHistoryTitle(contents.navigationState.title, for: url, spaceID: tab.spaceID)
    }

    func webContents(_ contents: WebContents, didFailLoading error: EngineError) {
        guard let tabID = tabID(for: contents) else { return }
        // The refused certificate failure is the interstitial's own outcome, not a fresh problem
        // to show a "Try Again" page for. Consumed once — a later, unrelated failure still surfaces normally.
        if error.code == .certificateInvalid || error.code == .cancelled,
           refusedCertificateTabIDs.remove(tabID) != nil {
            unwindRefusedCertificateNavigation(for: tabID)
            return
        }
        guard error.code != .cancelled else { return }
        // Still on the interstitial: it, not a generic error page, is what
        // this tab is showing and what is waiting to be answered.
        guard certificateProblems[tabID] == nil else { return }
        tabErrors[tabID] = error
    }

    // MARK: Chrome

    func webContents(_ contents: WebContents, didChangeTitle title: String) {
        guard let tabID = tabID(for: contents), var tab = state.tabs[tabID] else { return }
        noteHistoryTitle(title, for: contents.navigationState.url ?? tab.url, spaceID: tab.spaceID)
        guard tab.title != title else { return }
        tab.title = title
        state.tabs[tabID] = tab
    }

    func webContents(_ contents: WebContents, hasCachedFaviconForHost host: String) -> Bool {
        faviconCache.hasImage(forHost: host)
    }

    func webContents(_ contents: WebContents, didChangeFavicon image: NSImage?, url: URL?) {
        guard let tabID = tabID(for: contents), var tab = state.tabs[tabID] else { return }
        if tab.faviconURL != url {
            tab.faviconURL = url
            state.tabs[tabID] = tab
        }

        // Cache the already-decoded image directly rather than leaving
        // FaviconView to re-fetch url over the network a second time.
        if let image {
            let host = tab.url.host() ?? tab.url.absoluteString
            faviconCache.cache(image, forHost: host)
        }
    }

    func webContents(_ contents: WebContents, didHoverLink url: URL?) {
        hoveredLinkURL = url
        // Not a duplicate of the line above — this feeds an AppKit view with no SwiftUI environment to read one from.
        LinkHoverStatus.shared.report(url, forContents: contents.id)
    }

    func webContents(_ contents: WebContents, didChangeStatusText text: String?) {}

    // A colour that is barely opaque must be treated as no colour — an
    // un-gated near-transparent rgba would pick near-black glyphs for a
    // near-white declared colour while the actual paint shows dark chrome behind it.
    func webContents(_ contents: WebContents, didChangeThemeColor color: NSColor?) {
        guard let tabID = tabID(for: contents) else { return }
        if let color, PageThemeColorScript.isEffectivelyOpaque(color) {
            themeColors[tabID] = ThemeColor(color)
        } else {
            themeColors.removeValue(forKey: tabID)
        }
    }

    func webContents(_ contents: WebContents, didChangeDocumentColor color: NSColor?) {
        guard let tabID = tabID(for: contents) else { return }
        if let color, PageThemeColorScript.isEffectivelyOpaque(color) {
            documentColors[tabID] = ThemeColor(color)
        } else {
            documentColors.removeValue(forKey: tabID)
        }
    }

    // MARK: Content requests

    // A new tab for a page on the opener's own site keeps the opener's site profile; a link to any other site never does.
    private func siteProfileToInherit(openerTabID: TabID, destination: URL) -> SiteProfileID? {
        guard let profile = store.boundSiteProfile(forTab: openerTabID),
              SiteIdentity.registrableDomain(of: destination) == profile.siteKey
        else { return nil }
        return profile.id
    }

    func webContents(_ contents: WebContents, requestsNewContent request: NewContentRequest) -> Bool {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return false }
        switch request.disposition {
        case .currentTab:
            return false
        case .newForegroundTab:
            openTab(url: request.url, in: tab.spaceID, section: .today, activate: true, siteProfileID: siteProfileToInherit(openerTabID: tabID, destination: request.url))
            return true
        case .newBackgroundTab:
            let opened = openTab(url: request.url, in: tab.spaceID, section: .today, activate: false, siteProfileID: siteProfileToInherit(openerTabID: tabID, destination: request.url))
            announceBackgroundTab(opened)
            return true
        case .newWindow:
            if shouldPeek(sourceTabID: tabID, modifiers: [.shift], destination: request.url) {
                openPeek(sourceTabID: tabID, url: request.url)
                return true
            }
            LittleOrbitWindowController.open(url: request.url)
            return true
        case .popup:
            LittleOrbitWindowController.open(url: request.url)
            return true
        case .download:
            return false
        }
    }

    // The engine already built and started the new WebContents, so every accepted branch must
    // adopt it — opening a fresh tab instead would drop window.opener and the navigation in flight.
    func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return false }
        let request = pending.request
        switch request.disposition {
        case .download:
            return false
        case .newWindow:
            if shouldPeek(sourceTabID: tabID, modifiers: [.shift], destination: request.url) {
                openPeek(sourceTabID: tabID, url: request.url)
                return false
            }
            guard let adopted = pending.adopt() else { return false }
            LittleOrbitWindowController.open(adopting: adopted, url: request.url)
            return true
        case .popup:
            guard let adopted = pending.adopt() else { return false }
            LittleOrbitWindowController.open(adopting: adopted, url: request.url)
            return true
        case .currentTab, .newForegroundTab, .newBackgroundTab:
            guard let adopted = pending.adopt() else { return false }
            let opened = adoptPageCreatedTab(
                adopted,
                url: request.url,
                in: tab.spaceID,
                activate: request.disposition != .newBackgroundTab
            )
            if request.disposition == .newBackgroundTab { announceBackgroundTab(opened) }
            return true
        }
    }

    func webContentsDidRequestClose(_ contents: WebContents) {
        guard let tabID = tabID(for: contents) else { return }
        if LittleOrbitWindowController.closeWindow(forTab: tabID) { return }
        closeTab(tabID)
    }

    // MARK: User interaction

    func webContents(_ contents: WebContents, showContextMenu context: ContextMenuContext) -> Bool {
        presentContextMenu(for: contents, context: context)
        return true
    }

    func webContents(
        _ contents: WebContents,
        runJavaScriptDialog request: JavaScriptDialogRequest
    ) async -> JavaScriptDialogResponse {
        guard !DebugFlags.isRunningUnderTests else {
            return JavaScriptDialogResponse(accepted: false, promptText: nil)
        }
        let alert = NSAlert()
        alert.messageText = request.origin?.host() ?? "JavaScript"
        alert.informativeText = request.message
        switch request.kind {
        case .alert:
            alert.addButton(withTitle: "OK")
        case .confirm, .beforeUnload:
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        case .prompt:
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        }
        var promptField: NSTextField?
        if request.kind == .prompt {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field.stringValue = request.defaultPromptText
            alert.accessoryView = field
            promptField = field
        }
        let response = alert.runModal()
        let accepted = response == .alertFirstButtonReturn
        return JavaScriptDialogResponse(accepted: accepted, promptText: promptField?.stringValue)
    }

    func webContents(
        _ contents: WebContents,
        requestsHTTPCredentials request: HTTPCredentialRequest
    ) async -> HTTPCredentialResponse? {
        guard !DebugFlags.isRunningUnderTests else { return nil }
        let alert = NSAlert()
        let subject = request.isProxy ? "the proxy \(request.host)" : request.host
        alert.messageText = "Sign in to \(subject)"
        var details = request.isProxy
            ? "The proxy \(request.host) requires a username and password."
            : "\(request.host) requires a username and password."
        if let realm = request.realm, !realm.isEmpty { details += " Realm: \(realm)." }
        if request.previousAttemptFailed { details += " The last username or password was not accepted." }
        alert.informativeText = details
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let username = NSTextField(frame: NSRect(x: 0, y: 56, width: 260, height: 22))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        password.placeholderString = "Password"
        let remember = NSButton(checkboxWithTitle: "Remember this password", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        remember.isEnabled = request.canRemember
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 78))
        form.addSubview(username)
        form.addSubview(password)
        form.addSubview(remember)
        username.nextKeyView = password
        alert.accessoryView = form
        alert.window.initialFirstResponder = username

        guard alert.runModal() == .alertFirstButtonReturn, !username.stringValue.isEmpty else { return nil }
        return HTTPCredentialResponse(
            username: username.stringValue,
            password: password.stringValue,
            remember: request.canRemember && remember.state == .on
        )
    }

    func webContents(
        _ contents: WebContents,
        requestsPermission request: PermissionRequest
    ) async -> PermissionDecision {
        if let refusal = Self.refusalWithoutPrompting(for: request) { return refusal }
        guard !DebugFlags.isRunningUnderTests else { return .denyAlways }
        let kinds = request.kinds
        let alert = NSAlert()
        alert.messageText = "\(request.origin.host() ?? "This site") wants to \(kinds.map(\.promptDescription).joined(separator: ", "))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .allowAlways : .denyAlways
    }

    // A request naming nothing has nothing to ask the user about.
    static func refusalWithoutPrompting(for request: PermissionRequest) -> PermissionDecision? {
        request.kinds.isEmpty ? .denyAlways : nil
    }

    // Refusing is the only safe answer with nobody to click; an unattended non-live test run
    // never opens the interstitial. The live-engine harness is the exception — it plays the user.
    func webContents(_ contents: WebContents, allowCertificateProblem problem: CertificateProblem) async -> Bool {
        // Resolved only by a SwiftUI click, so no modal window exists for ModalHangGuard to abort.
        guard !DebugFlags.isRunningUnderTests || DebugFlags.isRunningUnderLiveEngine else { return false }
        guard let tabID = tabID(for: contents) else { return false }
        // A second error on a tab already showing one would strand the first
        // continuation with no way left to resume it. Refuse the newcomer.
        guard pendingCertificateDecisions[tabID] == nil else { return false }
        // WebKit repeats the challenge after a refusal. That retry is still the same navigation.
        if refusedCertificateTabIDs.contains(tabID) { return false }
        certificateProblems[tabID] = problem
        return await withCheckedContinuation { continuation in
            pendingCertificateDecisions[tabID] = continuation
        }
    }

    /// Called by the interstitial's own two buttons. `proceed` must only ever
    /// come from an explicit click — the engine records a host exception off
    /// the back of it.
    func resolveCertificateDecision(for tabID: TabID, proceed: Bool) {
        let problem = certificateProblems.removeValue(forKey: tabID)
        // An error the engine reported as strictly enforced cannot be
        // proceeded past; the engine refuses it too, this just stops the tab
        // pretending otherwise.
        let allow = proceed && (problem?.isOverridable ?? false)
        pendingCertificateDecisions.removeValue(forKey: tabID)?.resume(returning: allow)
        guard !allow else { return }
        // Nothing committed, so there is no half-loaded page to unwind — the refused navigation's
        // own failure follows next, not a new problem to show a generic "Try Again" page for.
        refusedCertificateTabIDs.insert(tabID)
    }

    /// Driven from `didFailLoading`, not `resolveCertificateDecision`: at answer time nothing has
    /// committed yet, so going back immediately would overshoot. Waiting unwinds exactly one entry.
    private func unwindRefusedCertificateNavigation(for tabID: TabID) {
        guard let contents = webContents[tabID] else { return }
        if contents.navigationState.canGoBack {
            contents.goBack()
        } else {
            // Nowhere to go back to. Closing destroys the WebContents, which
            // is itself the engine's fail-closed path for anything still
            // pending on it.
            closeTab(tabID)
        }
    }

    func webContents(
        _ contents: WebContents,
        runOpenPanelAllowingMultiple allowsMultiple: Bool,
        allowsDirectories: Bool,
        acceptedTypes: [String]
    ) async -> [URL] {
        guard !DebugFlags.isRunningUnderTests else { return [] }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        if let types = Self.openPanelContentTypes(from: acceptedTypes) { panel.allowedContentTypes = types }
        let response = panel.runModal()
        return response == .OK ? panel.urls : []
    }

    /// The file input's accept list as content types, or nil when any entry cannot be resolved,
    /// since a partial filter would hide files the page asked for.
    static func openPanelContentTypes(from accepted: [String]) -> [UTType]? {
        var types: [UTType] = []
        for entry in accepted.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !entry.isEmpty {
            let resolved: UTType?
            switch entry {
            case "image/*": resolved = .image
            case "video/*": resolved = .movie
            case "audio/*": resolved = .audio
            case "text/*": resolved = .text
            default:
                // An unknown MIME type resolves to a dynamic type no file carries, which would hide every file.
                resolved = entry.hasPrefix(".")
                    ? UTType(filenameExtension: String(entry.dropFirst()))
                    : UTType(mimeType: entry).flatMap { $0.isDynamic ? nil : $0 }
            }
            guard let resolved else { return nil }
            types.append(resolved)
        }
        return types.isEmpty ? nil : types
    }

    // MARK: Extensions

    func webContents(
        _ contents: WebContents,
        requestsExtensionInstallConsent pending: ExtensionInstaller.PendingInstall
    ) async -> Bool {
        // Resolved only by a SwiftUI click, so no modal window exists for ModalHangGuard to abort.
        guard !DebugFlags.isRunningUnderTests else { return false }
        // ORBIT_WEBSTORE_PROBE_CLICK's own non-interactive path only; false in every normal run.
        if WebStoreInstallVerifyProbe.autoApproveExtensionInstallConsent { return true }
        guard let tabID = tabID(for: contents) else { return false }
        // The only moment the icon can be read: it lives in the installer's
        // staging directory, which stageInstall renames into the extension
        // store as soon as consent is granted.
        extensionInstallSubjects[tabID] = ExtensionInstallSubject(pending: pending)
        pendingExtensionInstallConsent[tabID] = pending
        return await withCheckedContinuation { continuation in
            pendingExtensionInstallConsentDecisions[tabID] = continuation
        }
    }

    /// Called by `SingleTabContentView`'s consent sheet when the
    /// extension-install request (backed by `pendingExtensionInstallConsent`)
    /// is answered or dismissed without an answer.
    func resolveExtensionInstallConsent(for tabID: TabID, granted: Bool) {
        pendingExtensionInstallConsent.removeValue(forKey: tabID)
        pendingExtensionInstallConsentDecisions.removeValue(forKey: tabID)?.resume(returning: granted)
    }

    func webContents(_ contents: WebContents, didUpdateExtensionInstallProgress stage: ExtensionInstallStage?) {
        guard let tabID = tabID(for: contents) else { return }
        applyExtensionInstallProgress(stage, for: tabID)
    }

    func applyExtensionInstallProgress(_ stage: ExtensionInstallStage?, for tabID: TabID) {
        guard stage != nil else {
            extensionInstallProgress.removeValue(forKey: tabID)
            extensionInstallCancelledTabIDs.remove(tabID)
            // The subject only outlives the run while an outcome is still on
            // screen naming the extension it belonged to.
            if extensionInstallOutcomes[tabID] == nil {
                extensionInstallSubjects.removeValue(forKey: tabID)
            }
            return
        }
        // Cancellation lands at the installer's next stage boundary, which can
        // be a whole unpack away; a stage reported in between must not reopen
        // the sheet the user just closed.
        guard !extensionInstallCancelledTabIDs.contains(tabID) else { return }
        extensionInstallProgress[tabID] = stage
    }

    func webContents(_ contents: WebContents, canCancelExtensionInstallWith cancel: (@Sendable () -> Void)?) {
        guard let tabID = tabID(for: contents) else { return }
        extensionInstallCancellers[tabID] = cancel
    }

    func webContents(_ contents: WebContents, didFinishExtensionInstallWith outcome: ExtensionInstallOutcome?) {
        guard let tabID = tabID(for: contents) else { return }
        extensionInstallOutcomes[tabID] = outcome
    }

    func webContents(_ contents: WebContents, confirmUninstallExtensionNamed name: String) async -> Bool {
        guard !DebugFlags.isRunningUnderTests else { return false }
        let alert = NSAlert()
        alert.messageText = "Remove \"\(name)\"?"
        alert.informativeText = "It will stop running straight away and its files will be deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Find

    func webContents(_ contents: WebContents, didUpdateFindResult result: FindResult) {
        guard let tabID = tabID(for: contents) else { return }
        findResultsByTab[tabID] = result
        if tabID == activeTabID {
            currentFindResult = result
        }
    }

    // MARK: Media & fullscreen

    func webContents(_ contents: WebContents, didChangeMediaState state: MediaState) {
        guard let tabID = tabID(for: contents) else { return }
        let previous = mediaStates[tabID]
        // Decided against the previous state, so it has to run before mediaStates is overwritten.
        if MiniPlayerVisibility.pausedByOrbit(
            previous: previous,
            current: state,
            wasPausedByOrbit: orbitPausedMediaTabIDs.contains(tabID)
        ) {
            orbitPausedMediaTabIDs.insert(tabID)
        } else {
            orbitPausedMediaTabIDs.remove(tabID)
        }
        mediaStates[tabID] = state
        store.setMediaState(state, forTab: tabID)
        if let tab = contents as? WebKitWebContents {
            var changed: WKWebExtension.TabChangedProperties = []
            if previous?.isMuted != state.isMuted { changed.insert(.muted) }
            if previous?.isAudible != state.isAudible { changed.insert(.playingAudio) }
            if !changed.isEmpty { (engine as? WebKitEngine)?.noteTabPropertiesChanged(tab, changed) }
        }
        // isMediaActive, not isPlaying || isAudible: both of those go false
        // on a pause, which used to make pausing indistinguishable from the
        // media ending and tore the tab out of picture-in-picture.
        if !state.isMediaActive {
            extensionPoints.dismissPictureInPicture?(tabID)
            // Lifted here on the state change, not lazily inside the card's
            // own body — mutating AppEnvironment during a view evaluation would write during render.
            dismissedMiniPlayerTabIDs.remove(tabID)
        }
    }

    func webContents(_ contents: WebContents, didChangeFullscreen isFullscreen: Bool) {}

    // The picture-in-picture window's "back to tab" control, not its X.
    // activateTab already switches Spaces if the tab lives outside the currently active one.
    func webContentsDidRequestActivation(_ contents: WebContents) {
        guard let tabID = tabID(for: contents) else { return }
        activateTab(tabID)
    }

    // MARK: Zoom

    // Nothing is persisted for an Incognito Space — a per-host zoom level
    // left on disk would be a record of a site having been visited.
    func webContents(_ contents: WebContents, didChangeZoomFactor factor: Double) {
        guard let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return }
        if let page = contents as? WebKitWebContents {
            (engine as? WebKitEngine)?.noteTabPropertiesChanged(page, .zoomFactor)
        }
        let isPrivate = space(tab.spaceID).map(isIncognito) ?? false
        store.setZoomFactor(isPrivate ? nil : factor, for: tabID)
        guard !isPrivate else { return }
        guard let host = SiteZoomStore.hostKey(for: contents.navigationState.url ?? tab.url) else { return }
        SiteZoomStore.setZoomFactor(factor, forHost: host)
    }

    // Must run on both materialisation and every committed navigation —
    // zoom is a property of the browser, not the page, so without this a tab
    // left at 150% on one site carries 150% to the next.
    func applyStoredZoomFactor(to contents: any WebContents, tabID: TabID, url: URL) {
        let stored: Double?
        if let host = SiteZoomStore.hostKey(for: url) {
            stored = SiteZoomStore.zoomFactor(forHost: host)
        } else {
            stored = state.tabs[tabID]?.zoomFactor
        }
        // A host with no entry is a host at 100%, not a host to leave alone.
        let factor = stored ?? SiteZoomStore.defaultZoomFactor
        // Guards against bouncing: setZoomFactor makes both backends report back through didChangeZoomFactor.
        guard abs(factor - contents.zoomFactor) > 0.0001 else { return }
        contents.setZoomFactor(factor)
    }

    // Mute is a property of the tab, not the page: it is driven by JavaScript
    // against a document-start observer that is reinstalled fresh on every
    // navigation, so the desired state has to be resent on every commit too.
    func applyStoredMuteState(to contents: any WebContents, tabID: TabID) {
        // Not reapplied when false: the fresh document's observer already
        // defaults to no override, so there is nothing to resend.
        guard state.tabs[tabID]?.isMuted == true else { return }
        contents.setMuted(true)
    }

    // MARK: Downloads

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL,
        downloadID: UUID
    ) async -> URL? {
        let downloadsDirectory = (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        // DownloadStore.uniqueDestination directly, not a private twin — it
        // carries path-traversal sanitisation on suggestedName; security-relevant, do not reimplement.
        let destination = DownloadStore.uniqueDestination(in: downloadsDirectory, suggestedName: suggestedName)
        // Pin DownloadItem.id to downloadID, not a freshly minted one — later
        // progress callbacks resolve this same UUID to find the record again.
        let item = addDownload(id: downloadID, sourceURL: sourceURL, destinationURL: destination, suggestedFileName: suggestedName, mimeType: mimeType, totalBytes: totalBytes)
        if let tabID = tabID(for: contents) {
            downloadIDByTab[tabID] = item.id
        }
        return destination
    }

    func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress) {
        updateDownload(id: id, progress: progress)

        guard progress.state == .completed else { return }
        let pageTitle = tabID(for: contents).flatMap { state.tabs[$0]?.title }
        TidyDownloadsCoordinator.shared.downloadDidComplete(id: id, pageTitle: pageTitle, env: self)
    }

    // MARK: Process health

    func webContentsDidCrash(_ contents: WebContents) {
        guard let tabID = tabID(for: contents) else { return }
        crashedTabs.insert(tabID)
    }

    func webContents(_ contents: WebContents, didChangeResponsiveness isResponsive: Bool) {
        guard let tabID = tabID(for: contents) else { return }
        if isResponsive {
            unresponsiveTabs.remove(tabID)
        } else {
            unresponsiveTabs.insert(tabID)
        }
    }

    // MARK: - External activation

    // Little Orbit remains the backstop for a stored default that cannot be
    // honoured — applyRoutingRule returns false for a destination it can't reach.
    func handleExternalOpen(url: URL) {
        if let rule = matchingRoutingRule(for: url), applyRoutingRule(rule, url: url, sourceTabID: UUID()) {
            return revealBrowserWindow(unlessOpenedIn: rule.destination)
        }
        let fallback = RoutingRule(pattern: "", destination: RoutingDefaults.destination)
        if applyRoutingRule(fallback, url: url, sourceTabID: UUID()) {
            return revealBrowserWindow(unlessOpenedIn: fallback.destination)
        }
        LittleOrbitWindowController.open(url: url)
    }

    // A link from another app lands as a tab in a normal browser window, which has to be on screen for the tab to be seen. Little Orbit and other applications show their own window.
    private func revealBrowserWindow(unlessOpenedIn destination: RoutingRule.Destination) {
        switch destination {
        case .littleOrbit, .application: return
        case .space, .profile, .mostRecentSpace: break
        }
        guard !DebugFlags.isRunningUnderTests else { return }
        OrbitWindowController.activateBrowserWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Air Traffic Control

    // A leading = means whole-URL equality, anything else is "Contains" against the host; the isEmpty guards below are explicit, not incidental, since a blank route (New Route's own starting state) must never match anything.
    func matchingRoutingRule(for url: URL) -> RoutingRule? {
        guard let host = url.host() else { return nil }
        return state.routingRules.first { rule in
            guard rule.isEnabled else { return false }
            if rule.pattern.hasPrefix("=") {
                let target = String(rule.pattern.dropFirst())
                guard !target.isEmpty else { return false }
                return url.absoluteString == target
            }
            guard !rule.pattern.isEmpty else { return false }
            return Self.hostMatchesRoutingPattern(host: host, pattern: rule.pattern)
        }
    }

    // "Contains" means this domain or a subdomain of it, not a raw substring — a bare
    // host.contains(pattern) let a short pattern match mid-label (e.g. "store" inside
    // "chromewebstore.google.com"). Anchored to a label boundary instead.
    static func hostMatchesRoutingPattern(host: String, pattern: String) -> Bool {
        let host = host.lowercased()
        let pattern = pattern.lowercased()
        guard !pattern.isEmpty else { return false }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    @discardableResult
    private func applyRoutingRule(_ rule: RoutingRule, url: URL, sourceTabID: TabID) -> Bool {
        switch rule.destination {
        case .space(let spaceID):
            // A Space named by a rule can have been deleted since — report
            // "not applied" so the caller falls back rather than parking the tab against a dead id.
            guard space(spaceID) != nil else { return false }
            openTab(url: url, in: spaceID, section: .today, activate: true)
            return true
        case .profile:
            return false // No dedicated window-per-profile model yet; fall through.
        case .application(let bundleID):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .littleOrbit:
            LittleOrbitWindowController.open(url: url)
            return true
        case .mostRecentSpace:
            guard let spaceID = state.activeSpaceID ?? spaces.first?.id else { return false }
            openTab(url: url, in: spaceID, section: .today, activate: true)
            return true
        }
    }
}

// MARK: - The Air Traffic Control default destination

// Key and vocabulary deliberately unchanged from the old @AppStorage control
// that wrote it, so nobody's stored setting resets.
enum RoutingDefaults {
    static let key = "OrbitDefaultRoutingDestination"

    // Not @AppStorage: that can only be read from a View, and handleExternalOpen(url:) is not one.
    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    static var destination: RoutingRule.Destination {
        get { decode(defaults.string(forKey: key)) }
        set { defaults.set(encode(newValue), forKey: key) }
    }

    static func decode(_ raw: String?) -> RoutingRule.Destination {
        switch raw {
        case "littleOrbit": return .littleOrbit
        case "mostRecentSpace", nil: return .mostRecentSpace
        default:
            guard let raw, let spaceID = UUID(uuidString: raw) else { return .mostRecentSpace }
            return .space(spaceID)
        }
    }

    static func encode(_ destination: RoutingRule.Destination) -> String {
        switch destination {
        case .littleOrbit: return "littleOrbit"
        case .mostRecentSpace: return "mostRecentSpace"
        case .space(let id): return id.uuidString
        case .profile, .application: return "mostRecentSpace"
        }
    }
}
