import AppKit
import Foundation

// MARK: - Engine

@MainActor
public protocol BrowserEngine: AnyObject {

    static var kind: EngineKind { get }

    var capabilities: EngineCapabilities { get }

    var manageableContentSettings: Set<PermissionKind> { get }

    var extensionActivation: ExtensionActivation { get }

    var versionDescription: String { get }

    /// Must be called once, before any `WebContents` is created.
    func start() throws

    /// `false` if teardown was deferred — some engines cannot shut down
    /// synchronously while their own message-pump work is still on this
    /// thread's stack; see the implementation for what it defers on.
    @discardableResult
    func shutdown() -> Bool

    /// Pumps the engine's message loop. A no-op for an engine that drives
    /// its own run loop integration instead of being polled from outside.
    func tick()

    // MARK: Sessions

    func session(identifier: String, persistent: Bool) throws -> EngineSession

    var defaultSession: EngineSession { get }

    // MARK: Tabs

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents

    // MARK: Global services

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async

    func addUserScript(_ script: UserScript, session: EngineSession)

    func removeUserScript(id: UUID, session: EngineSession)

    // MARK: Content blocking

    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async

    /// Installs process-wide, not per-session. When it takes effect is given
    /// by `extensionActivation`, not by this call returning.
    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension

    /// Only the bootstrap pass has any business passing `.browserStartup`;
    /// everything else is a user action and gets the two-argument form.
    func loadExtension(
        at directory: URL, session: EngineSession, reason: ExtensionLoadReason
    ) async throws -> LoadedExtension

    /// Drops the extension from the running engine but keeps everything it
    /// has stored, so loading it again resumes with the optional permissions
    /// the user already granted: a disable, an update or a reload.
    func unloadExtension(id: String, session: EngineSession)

    /// `unloadExtension` for an extension the user is getting rid of: what it
    /// stored goes too, so a later install of the same id starts from nothing.
    func uninstallExtension(id: String, session: EngineSession)

    func loadedExtensions(session: EngineSession) -> [LoadedExtension]

    /// Live chrome.action state (badge text/colour, dynamically set icon,
    /// per-tab enable/disable) as the engine last relayed it.
    var extensionActionStates: ExtensionActionStateStore { get }
}

public extension BrowserEngine {
    /// Default: an engine with nothing of its own to forget has nothing to do
    /// beyond the unload.
    func uninstallExtension(id: String, session: EngineSession) {
        unloadExtension(id: id, session: session)
    }

    /// Default: an engine with no lifecycle of its own to distinguish loads
    /// the same way for every reason.
    func loadExtension(
        at directory: URL, session: EngineSession, reason: ExtensionLoadReason
    ) async throws -> LoadedExtension {
        try await loadExtension(at: directory, session: session)
    }

    /// Default: engines that do not need external pumping leave this empty.
    func tick() {}

    /// Default: an engine with no chrome.action relay reports nothing, which
    /// reads as every action plainly enabled with no badge.
    var extensionActionStates: ExtensionActionStateStore { ExtensionActionStateStore.inert }
}

// MARK: - Session

@MainActor
public protocol EngineSession: AnyObject {
    var identifier: String { get }

    var isPersistent: Bool { get }

    var storageURL: URL? { get }

    func setUserAgent(_ userAgent: String)

    func cookies(for url: URL) async -> [HTTPCookie]

    func deleteCookies(for url: URL) async

    /// Returns the number actually accepted, which can be less than the
    /// input count.
    func setCookies(_ cookies: [EngineCookie]) async -> Int

    // MARK: Content settings

    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting

    /// `.ask` removes the stored rule (revoke) rather than storing the
    /// value "ask".
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL)
}

// MARK: - Extensions

public struct LoadedExtension: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var directory: URL
    public var iconURL: URL?
    public var hasToolbarAction: Bool
    public var manifestVersion: Int
    public var isEnabled: Bool
    // False only for an extension the running engine has not actually loaded yet (installed/enabled after start()) — see `extensionActivation`; on a `.nextLaunch` engine its chrome-extension:// origin answers nothing until the next launch.
    public var isActivated: Bool
    // True when `id` is the id the running engine itself assigned (orbit_extension_loader.cc reports extension.id() verbatim), not one Orbit derived on its own.
    // The engine's id is the only one its chrome-extension:// origin answers to; see ExtensionActionPopupSupport.isExtensionIDAddressable.
    public var idIsEngineAssigned: Bool

    public init(
        id: String,
        name: String,
        version: String,
        directory: URL,
        iconURL: URL? = nil,
        hasToolbarAction: Bool = false,
        manifestVersion: Int = 3,
        isEnabled: Bool = true,
        isActivated: Bool = true,
        idIsEngineAssigned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.directory = directory
        self.iconURL = iconURL
        self.hasToolbarAction = hasToolbarAction
        self.manifestVersion = manifestVersion
        self.isEnabled = isEnabled
        self.isActivated = isActivated
        self.idIsEngineAssigned = idIsEngineAssigned
    }
}

// MARK: - Web contents

/// Call `close()` exactly once; every method after that is a no-op.
@MainActor
public protocol WebContents: AnyObject {

    /// Not `Tab.id` — use `AppEnvironment.tabID(for:)` to resolve the tab.
    var id: UUID { get }

    var view: NSView { get }

    var session: EngineSession { get }

    var delegate: WebContentsDelegate? { get set }

    // MARK: State

    var navigationState: NavigationState { get }

    var mediaState: MediaState { get }

    var zoomFactor: Double { get }

    var isClosed: Bool { get }

    // MARK: Navigation

    func load(_ url: URL)
    func loadHTML(_ html: String, baseURL: URL?)
    func reload(ignoringCache: Bool)
    func stopLoading()
    func goBack()
    func goForward()

    func go(offset: Int)

    func sessionHistory() -> [SessionHistoryEntry]

    func currentCertificate() -> SiteCertificate?

    // MARK: Scripting

    @discardableResult
    func evaluateJavaScript(_ script: String) async throws -> Any?

    func injectUserScript(_ script: UserScript)

    // MARK: Find in page

    func find(_ text: String, options: FindOptions)
    func stopFinding(clearSelection: Bool)

    // MARK: Editing
    // Native content::WebContents commands; Paste cannot go through a page script.

    func cut()
    func copy()
    func paste()
    func selectAll()

    // MARK: Zoom

    func setZoomFactor(_ factor: Double)

    // MARK: Content sizing

    /// Reports each result via `didChangePreferredSize`; pins zoom to neutral
    /// so a page-zoom-scaled size doesn't size its host wrong.
    func enableContentSizing(minimum: CGSize, maximum: CGSize)

    // MARK: Colour scheme

    func setPreferredColorScheme(_ scheme: ContentColorScheme?)

    // MARK: Media

    func setMuted(_ muted: Bool)
    func togglePictureInPicture()

    // MARK: Presentation

    /// The host owns this fact; inferring it from window-server events gets it
    /// wrong for a view adopted into a container not yet in a window.
    func setVisible(_ visible: Bool)

    /// Renders via the compositor, never the screen, so it cannot trigger a
    /// screen-recording prompt.
    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage?

    func print()

    func savePage()

    // MARK: Downloads

    func cancelDownload(id: UUID)

    // MARK: Developer tools

    func showDeveloperTools(inspectAt point: CGPoint?)
    func closeDeveloperTools()

    // MARK: Focus

    func focus()

    // MARK: Lifetime

    func close()
}

public extension WebContents {
    func enableContentSizing(minimum: CGSize, maximum: CGSize) {}

    // An engine whose view is not a compositor surface has nothing to declare:
    // its `view` paints whenever AppKit draws it.
    func setVisible(_ visible: Bool) {}
}

public struct SessionHistoryEntry: Identifiable, Sendable, Hashable {
    public var id: Int
    public var url: URL
    public var title: String
    public var offset: Int

    public init(id: Int, url: URL, title: String, offset: Int) {
        self.id = id
        self.url = url
        self.title = title
        self.offset = offset
    }
}

// MARK: - Delegate

@MainActor
public protocol WebContentsDelegate: AnyObject {

    // MARK: Navigation lifecycle

    func webContentsDidChangeNavigationState(_ contents: WebContents)

    func webContents(
        _ contents: WebContents,
        shouldAllowNavigationTo url: URL,
        kind: NavigationKind,
        isMainFrame: Bool
    ) -> Bool

    func webContents(_ contents: WebContents, didCommitNavigationTo url: URL, kind: NavigationKind)

    func webContents(_ contents: WebContents, didFinishLoading url: URL, statusCode: Int)

    func webContents(_ contents: WebContents, didFailLoading error: EngineError)

    // MARK: Chrome

    func webContents(_ contents: WebContents, didChangeTitle title: String)
    func webContents(_ contents: WebContents, didChangeFavicon image: NSImage?, url: URL?)
    func webContents(_ contents: WebContents, didHoverLink url: URL?)
    func webContents(_ contents: WebContents, didChangeStatusText text: String?)
    func webContents(_ contents: WebContents, didChangeThemeColor color: NSColor?)

    /// Distinct from `didChangeThemeColor`: the document's own background,
    /// not the header colour.
    func webContents(_ contents: WebContents, didChangeDocumentColor color: NSColor?)

    // MARK: Content requests

    func webContents(_ contents: WebContents, requestsNewContent request: NewContentRequest) -> Bool

    /// `pending` carries a live, mid-navigation WebContents; returning false
    /// destroys it. Distinct from `requestsNewContent`, for a Cmd-click with nothing built yet.
    func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool

    func webContentsDidRequestClose(_ contents: WebContents)

    // MARK: User interaction

    func webContents(_ contents: WebContents, showContextMenu context: ContextMenuContext) -> Bool

    func webContents(
        _ contents: WebContents,
        runJavaScriptDialog request: JavaScriptDialogRequest
    ) async -> JavaScriptDialogResponse

    func webContents(
        _ contents: WebContents,
        requestsPermission request: PermissionRequest
    ) async -> PermissionDecision

    func webContents(_ contents: WebContents, allowCertificateProblem problem: CertificateProblem) async -> Bool

    func webContents(
        _ contents: WebContents,
        runOpenPanelAllowingMultiple allowsMultiple: Bool,
        acceptedTypes: [String]
    ) async -> [URL]

    // MARK: Extensions

    func webContents(
        _ contents: WebContents,
        requestsExtensionInstallConsent pending: ExtensionInstaller.PendingInstall
    ) async -> Bool

    /// Progress for a Web Store install driven by `WebStorePrivateBridge`, shown
    /// in the same sheet as the consent decision; `nil` clears it.
    func webContents(_ contents: WebContents, didUpdateExtensionInstallProgress stage: ExtensionInstallStage?)

    /// Hands the UI a way to stop the install it is showing progress for;
    /// `nil` clears it once there is nothing left to cancel.
    func webContents(_ contents: WebContents, canCancelExtensionInstallWith cancel: (@Sendable () -> Void)?)

    /// The install's terminal state, so a failure stays readable and
    /// dismissible instead of disappearing with the progress it replaced.
    func webContents(_ contents: WebContents, didFinishExtensionInstallWith outcome: ExtensionInstallOutcome?)

    /// Confirms an extension removal requested via `chrome.management.uninstall`
    /// with `showConfirmDialog: true`.
    func webContents(_ contents: WebContents, confirmUninstallExtensionNamed name: String) async -> Bool

    // MARK: Find

    func webContents(_ contents: WebContents, didUpdateFindResult result: FindResult)

    // MARK: Media & fullscreen

    func webContents(_ contents: WebContents, didChangeMediaState state: MediaState)
    func webContents(_ contents: WebContents, didChangeFullscreen isFullscreen: Bool)

    // MARK: Zoom

    func webContents(_ contents: WebContents, didChangeZoomFactor factor: Double)

    // MARK: Content sizing

    /// Only ever called for a contents `enableContentSizing(minimum:maximum:)`
    /// was called on, and always with a size already inside those bounds.
    func webContents(_ contents: WebContents, didChangePreferredSize size: CGSize)

    // MARK: Downloads

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL
    ) async -> URL?

    /// Carries the id later `didUpdate` progress calls use; the unused
    /// default forwards to the id-less overload.
    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL,
        downloadID: UUID
    ) async -> URL?

    func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress)

    // MARK: Process health

    func webContentsDidCrash(_ contents: WebContents)

    func webContents(_ contents: WebContents, didChangeResponsiveness isResponsive: Bool)
}

// MARK: - Delegate defaults

public extension WebContentsDelegate {
    func webContentsDidChangeNavigationState(_ contents: WebContents) {}

    func webContents(
        _ contents: WebContents,
        shouldAllowNavigationTo url: URL,
        kind: NavigationKind,
        isMainFrame: Bool
    ) -> Bool { true }

    func webContents(_ contents: WebContents, didCommitNavigationTo url: URL, kind: NavigationKind) {}
    func webContents(_ contents: WebContents, didFinishLoading url: URL, statusCode: Int) {}
    func webContents(_ contents: WebContents, didFailLoading error: EngineError) {}
    func webContents(_ contents: WebContents, didChangeTitle title: String) {}
    func webContents(_ contents: WebContents, didChangeFavicon image: NSImage?, url: URL?) {}
    func webContents(_ contents: WebContents, didHoverLink url: URL?) {}
    func webContents(_ contents: WebContents, didChangeStatusText text: String?) {}
    func webContents(_ contents: WebContents, didChangeThemeColor color: NSColor?) {}
    func webContents(_ contents: WebContents, didChangeDocumentColor color: NSColor?) {}
    func webContents(_ contents: WebContents, requestsNewContent request: NewContentRequest) -> Bool { false }
    func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool { false }
    func webContentsDidRequestClose(_ contents: WebContents) {}
    func webContents(_ contents: WebContents, showContextMenu context: ContextMenuContext) -> Bool { false }

    func webContents(
        _ contents: WebContents,
        runJavaScriptDialog request: JavaScriptDialogRequest
    ) async -> JavaScriptDialogResponse {
        JavaScriptDialogResponse(accepted: request.kind == .beforeUnload)
    }

    func webContents(
        _ contents: WebContents,
        requestsPermission request: PermissionRequest
    ) async -> PermissionDecision { .deny }

    func webContents(
        _ contents: WebContents,
        allowCertificateProblem problem: CertificateProblem
    ) async -> Bool { false }

    func webContents(
        _ contents: WebContents,
        runOpenPanelAllowingMultiple allowsMultiple: Bool,
        acceptedTypes: [String]
    ) async -> [URL] { [] }

    func webContents(
        _ contents: WebContents,
        requestsExtensionInstallConsent pending: ExtensionInstaller.PendingInstall
    ) async -> Bool { false }

    func webContents(_ contents: WebContents, didUpdateExtensionInstallProgress stage: ExtensionInstallStage?) {}
    func webContents(_ contents: WebContents, canCancelExtensionInstallWith cancel: (@Sendable () -> Void)?) {}
    func webContents(_ contents: WebContents, didFinishExtensionInstallWith outcome: ExtensionInstallOutcome?) {}

    func webContents(_ contents: WebContents, confirmUninstallExtensionNamed name: String) async -> Bool { false }

    func webContents(_ contents: WebContents, didUpdateFindResult result: FindResult) {}
    func webContents(_ contents: WebContents, didChangeMediaState state: MediaState) {}
    func webContents(_ contents: WebContents, didChangeFullscreen isFullscreen: Bool) {}
    func webContents(_ contents: WebContents, didChangeZoomFactor factor: Double) {}
    func webContents(_ contents: WebContents, didChangePreferredSize size: CGSize) {}

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL
    ) async -> URL? { nil }

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL,
        downloadID: UUID
    ) async -> URL? {
        await webContents(contents, willBeginDownload: suggestedName, mimeType: mimeType, totalBytes: totalBytes, sourceURL: sourceURL)
    }

    func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress) {}
    func webContentsDidCrash(_ contents: WebContents) {}
    func webContents(_ contents: WebContents, didChangeResponsiveness isResponsive: Bool) {}
}
