import AppKit
import Foundation

@MainActor
public protocol BrowserEngine: AnyObject {

    static var kind: EngineKind { get }

    var capabilities: EngineCapabilities { get }

    var manageableContentSettings: Set<PermissionKind> { get }

    var extensionActivation: ExtensionActivation { get }

    var versionDescription: String { get }

    func start() throws

    /// `false` if teardown was deferred: some engines cannot shut down while their own message-pump work is on the stack.
    @discardableResult
    func shutdown() -> Bool

    func tick()

    func session(identifier: String, persistent: Bool) throws -> EngineSession

    var defaultSession: EngineSession { get }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async

    func addUserScript(_ script: UserScript, session: EngineSession)

    func removeUserScript(id: UUID, session: EngineSession)

    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async

    /// Installs process-wide, not per-session; `extensionActivation` says when it takes effect.
    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension

    func loadExtension(
        at directory: URL, session: EngineSession, reason: ExtensionLoadReason
    ) async throws -> LoadedExtension

    /// Keeps the extension's stored data, so loading it again resumes with the permissions already granted.
    func unloadExtension(id: String, session: EngineSession)

    /// Like `unloadExtension` but the stored data goes too, so a later install of the same id starts clean.
    func uninstallExtension(id: String, session: EngineSession)

    func loadedExtensions(session: EngineSession) -> [LoadedExtension]

    var extensionActionStates: ExtensionActionStateStore { get }
}

public extension BrowserEngine {
    func uninstallExtension(id: String, session: EngineSession) {
        unloadExtension(id: id, session: session)
    }

    func loadExtension(
        at directory: URL, session: EngineSession, reason: ExtensionLoadReason
    ) async throws -> LoadedExtension {
        try await loadExtension(at: directory, session: session)
    }

    func tick() {}

    var extensionActionStates: ExtensionActionStateStore { ExtensionActionStateStore.inert }
}

@MainActor
public protocol EngineSession: AnyObject {
    var identifier: String { get }

    var isPersistent: Bool { get }

    var storageURL: URL? { get }

    func setUserAgent(_ userAgent: String)

    func cookies(for url: URL) async -> [HTTPCookie]

    func deleteCookies(for url: URL) async

    func setCookies(_ cookies: [EngineCookie]) async -> Int

    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting

    /// `.ask` removes the stored rule (revoke) rather than storing the value "ask".
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL)
}

public struct LoadedExtension: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var directory: URL
    public var iconURL: URL?
    public var hasToolbarAction: Bool
    public var manifestVersion: Int
    public var isEnabled: Bool
    // False for an extension installed or enabled after start(); on a `.nextLaunch` engine its chrome-extension:// origin answers nothing until relaunch.
    public var isActivated: Bool
    // True when `id` is the id the engine itself assigned, the only one its chrome-extension:// origin answers to.
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

/// Call `close()` exactly once; every method after that is a no-op.
@MainActor
public protocol WebContents: AnyObject {

    /// Not `Tab.id`; use `AppEnvironment.tabID(for:)` to resolve the tab.
    var id: UUID { get }

    var view: NSView { get }

    var session: EngineSession { get }

    var delegate: WebContentsDelegate? { get set }

    var navigationState: NavigationState { get }

    var mediaState: MediaState { get }

    var zoomFactor: Double { get }

    var isClosed: Bool { get }

    func load(_ url: URL)
    func loadHTML(_ html: String, baseURL: URL?)
    func reload(ignoringCache: Bool)
    func stopLoading()
    func goBack()
    func goForward()

    func go(offset: Int)

    func sessionHistory() -> [SessionHistoryEntry]

    func currentCertificate() -> SiteCertificate?

    @discardableResult
    func evaluateJavaScript(_ script: String) async throws -> Any?

    func injectUserScript(_ script: UserScript)

    func find(_ text: String, options: FindOptions)
    func stopFinding(clearSelection: Bool)

    // Native content::WebContents commands; Paste cannot go through a page script.
    func cut()
    func copy()
    func paste()
    func selectAll()

    func setZoomFactor(_ factor: Double)

    func enableContentSizing(minimum: CGSize, maximum: CGSize)

    func setPreferredColorScheme(_ scheme: ContentColorScheme?)

    func setMuted(_ muted: Bool)
    func togglePictureInPicture()

    /// The host owns this fact; inferring it from window-server events gets it wrong for a view not yet in a window.
    func setVisible(_ visible: Bool)

    /// Renders via the compositor, never the screen, so it cannot trigger a screen-recording prompt.
    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage?

    func print()

    func savePage()

    func cancelDownload(id: UUID)

    func extensionContextMenuGroups() -> [ExtensionContextMenuGroup]

    func performExtensionContextMenuItem(_ id: ExtensionContextMenuItemID)

    func showDeveloperTools(inspectAt point: CGPoint?)
    func closeDeveloperTools()

    /// Orbit's inspector. A point selects the element under it; nil starts the element picker.
    func showInspectElement(at point: CGPoint?)
    func showJavaScriptConsole()
    func showOrbitDeveloperTools()

    func focus()

    /// Puts a saved login into the page field `token` named in a `PasswordFieldFocus`. The engine checks the field's own frame against `credentials.origin`
    /// (same site; an https login never goes into an http frame) and against the frame's live origin, and refuses a mismatch.
    func fillPassword(into token: String, credentials: PasswordFillCredentials) async -> PasswordFillOutcome

    /// Fills a generated password into the new-password field `token` and the confirmation field beside it.
    func fillGeneratedPassword(_ password: String, into token: String) async -> PasswordFillOutcome

    func close()
}

public extension WebContents {
    func fillPassword(into token: String, credentials: PasswordFillCredentials) async -> PasswordFillOutcome { .unsupported }
    func fillGeneratedPassword(_ password: String, into token: String) async -> PasswordFillOutcome { .unsupported }

    func enableContentSizing(minimum: CGSize, maximum: CGSize) {}

    func extensionContextMenuGroups() -> [ExtensionContextMenuGroup] { [] }
    func performExtensionContextMenuItem(_ id: ExtensionContextMenuItemID) {}

    func setVisible(_ visible: Bool) {}

    func showInspectElement(at point: CGPoint?) { showDeveloperTools(inspectAt: point) }
    func showJavaScriptConsole() { showDeveloperTools(inspectAt: nil) }
    func showOrbitDeveloperTools() { showDeveloperTools(inspectAt: nil) }
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

@MainActor
public protocol WebContentsDelegate: AnyObject {

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

    func webContents(_ contents: WebContents, didChangeTitle title: String)
    func webContents(_ contents: WebContents, didChangeFavicon image: NSImage?, url: URL?)
    func webContents(_ contents: WebContents, didHoverLink url: URL?)
    func webContents(_ contents: WebContents, didChangeStatusText text: String?)
    func webContents(_ contents: WebContents, didChangeThemeColor color: NSColor?)

    /// Distinct from `didChangeThemeColor`: the document's own background, not the header colour.
    func webContents(_ contents: WebContents, didChangeDocumentColor color: NSColor?)

    func webContents(_ contents: WebContents, requestsNewContent request: NewContentRequest) -> Bool

    /// `pending` carries a live, mid-navigation WebContents; returning false destroys it.
    func webContents(_ contents: WebContents, requestsAdoptionOf pending: PendingWebContents) -> Bool

    func webContentsDidRequestClose(_ contents: WebContents)

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

    func webContents(
        _ contents: WebContents,
        runOpenPanelAllowingMultiple allowsMultiple: Bool,
        allowsDirectories: Bool,
        acceptedTypes: [String]
    ) async -> [URL]

    func webContents(
        _ contents: WebContents,
        requestsExtensionInstallConsent pending: ExtensionInstaller.PendingInstall
    ) async -> Bool

    func webContents(_ contents: WebContents, didUpdateExtensionInstallProgress stage: ExtensionInstallStage?)

    func webContents(_ contents: WebContents, canCancelExtensionInstallWith cancel: (@Sendable () -> Void)?)

    func webContents(_ contents: WebContents, didFinishExtensionInstallWith outcome: ExtensionInstallOutcome?)

    func webContents(_ contents: WebContents, confirmUninstallExtensionNamed name: String) async -> Bool

    func webContents(_ contents: WebContents, didUpdateFindResult result: FindResult)

    func webContents(_ contents: WebContents, didChangeMediaState state: MediaState)
    func webContents(_ contents: WebContents, didChangeFullscreen isFullscreen: Bool)

    /// Fired by the picture-in-picture window's "back to tab" control, not its X, which closes without activating.
    func webContentsDidRequestActivation(_ contents: WebContents)

    func webContents(_ contents: WebContents, didChangeZoomFactor factor: Double)

    func webContents(_ contents: WebContents, didChangePreferredSize size: CGSize)

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL
    ) async -> URL?

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL,
        downloadID: UUID
    ) async -> URL?

    func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress)

    func webContentsDidCrash(_ contents: WebContents)

    func webContents(_ contents: WebContents, didChangeResponsiveness isResponsive: Bool)

    /// Asked before any password message from the page is acted on. Answer false for a page that must never be offered or saved logins, such as an Incognito one; the default is false.
    func webContentsAllowsPasswordAutofill(_ contents: WebContents) -> Bool

    /// The user focused or clicked a sign-in field in a frame of the page.
    func webContents(_ contents: WebContents, didFocusPasswordField field: PasswordFieldFocus)

    /// The focused field moved (scroll, resize, layout); `rect` is in screen coordinates.
    func webContents(_ contents: WebContents, didMovePasswordField token: String, toScreenRect rect: CGRect)

    /// The field lost focus, scrolled out of view, or the page navigated.
    func webContentsDidDismissPasswordField(_ contents: WebContents)

    /// A sign-in the user made has completed: the next document committed, or the page removed its password field.
    func webContents(_ contents: WebContents, didCapturePasswordSubmission submission: PasswordSubmission)
}

public extension WebContentsDelegate {
    func webContentsAllowsPasswordAutofill(_ contents: WebContents) -> Bool { false }
    func webContents(_ contents: WebContents, didFocusPasswordField field: PasswordFieldFocus) {}
    func webContents(_ contents: WebContents, didMovePasswordField token: String, toScreenRect rect: CGRect) {}
    func webContentsDidDismissPasswordField(_ contents: WebContents) {}
    func webContents(_ contents: WebContents, didCapturePasswordSubmission submission: PasswordSubmission) {}

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
        runOpenPanelAllowingMultiple allowsMultiple: Bool,
        allowsDirectories: Bool,
        acceptedTypes: [String]
    ) async -> [URL] {
        await webContents(contents, runOpenPanelAllowingMultiple: allowsMultiple, acceptedTypes: acceptedTypes)
    }

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
    func webContentsDidRequestActivation(_ contents: WebContents) {}
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
