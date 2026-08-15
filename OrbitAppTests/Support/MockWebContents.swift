//  `id` is its own freshly generated UUID, exactly like ChromiumWebContents
//  — never the tab's TabID. Tests must not assume id == tabID.

import AppKit
import Foundation
@testable import Orbit

final class MockEngineSession: EngineSession {
    let identifier: String
    let isPersistent: Bool
    var storageURL: URL?

    var manageableContentSettings: Set<PermissionKind> = Set(PermissionKind.allCases)

    private var settings: [String: [PermissionKind: ContentSetting]] = [:]

    init(identifier: String = "mock", isPersistent: Bool = false) {
        self.identifier = identifier
        self.isPersistent = isPersistent
    }

    func setUserAgent(_ userAgent: String) {}
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
    func setCookies(_ cookies: [EngineCookie]) async -> Int { 0 }
    func deleteCookies(for url: URL) async {}

    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting {
        guard manageableContentSettings.contains(kind) else { return .unsupported }
        guard let origin = ContentSettingOrigin.normalize(url) else { return .unsupported }
        return settings[origin.absoluteString]?[kind] ?? .ask
    }

    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {
        guard manageableContentSettings.contains(kind) else { return }
        guard let origin = ContentSettingOrigin.normalize(url) else { return }
        var perOrigin = settings[origin.absoluteString] ?? [:]
        switch setting {
        case .ask, .unsupported: perOrigin.removeValue(forKey: kind)
        case .allow, .block: perOrigin[kind] = setting
        }
        settings[origin.absoluteString] = perOrigin
    }
}

@MainActor
final class MockWebContents: NSObject, WebContents {

    let id = UUID()
    let session: EngineSession
    weak var delegate: WebContentsDelegate?

    var navigationState: NavigationState = .empty
    var mediaState: MediaState = .idle
    var zoomFactor: Double = 1.0
    var isClosed: Bool = false

    private(set) var lastEvaluatedScript: String?
    private(set) var reloadCallCount = 0
    private(set) var stopLoadingCallCount = 0
    private(set) var goBackCallCount = 0
    private(set) var goForwardCallCount = 0

    private(set) var showDeveloperToolsCallCount = 0
    private(set) var lastInspectPoint: CGPoint?
    private(set) var closeDeveloperToolsCallCount = 0

    var previewImageOverride: NSImage?
    private(set) var capturePreviewCallCount = 0

    var evaluateJavaScriptHandler: ((String) -> Any?)?
    private(set) var evaluateJavaScriptCallCount = 0

    // Resolved in the body, not as a default parameter value: SE-0338 default-argument expressions are nonisolated, and MockEngineSession()'s init is @MainActor-isolated.
    override convenience init() {
        self.init(session: MockEngineSession())
    }

    init(session: EngineSession) {
        self.session = session
    }

    // MARK: Navigation

    func load(_ url: URL) { navigationState.url = url }
    func loadHTML(_ html: String, baseURL: URL?) {}
    func reload(ignoringCache: Bool) { reloadCallCount += 1 }
    func stopLoading() { stopLoadingCallCount += 1 }
    func goBack() { goBackCallCount += 1 }
    func goForward() { goForwardCallCount += 1 }
    func go(offset: Int) {}
    func sessionHistory() -> [SessionHistoryEntry] { [] }

    var extensionContextMenuGroupsOverride: [ExtensionContextMenuGroup] = []
    private(set) var performedExtensionContextMenuItemIDs: [ExtensionContextMenuItemID] = []

    func extensionContextMenuGroups() -> [ExtensionContextMenuGroup] { extensionContextMenuGroupsOverride }

    func performExtensionContextMenuItem(_ id: ExtensionContextMenuItemID) {
        performedExtensionContextMenuItemIDs.append(id)
    }

    var certificateOverride: SiteCertificate?
    private(set) var currentCertificateCallCount = 0

    func currentCertificate() -> SiteCertificate? {
        currentCertificateCallCount += 1
        return certificateOverride
    }

    // MARK: Scripting

    @discardableResult
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        lastEvaluatedScript = script
        evaluateJavaScriptCallCount += 1
        return evaluateJavaScriptHandler?(script)
    }

    private(set) var injectedUserScripts: [UserScript] = []

    func injectUserScript(_ script: UserScript) {
        injectedUserScripts.append(script)
    }

    // MARK: Find

    func find(_ text: String, options: FindOptions) {}
    func stopFinding(clearSelection: Bool) {}

    // MARK: Editing

    private(set) var cutCallCount = 0
    private(set) var copyCallCount = 0
    private(set) var pasteCallCount = 0
    private(set) var selectAllCallCount = 0

    func cut() { cutCallCount += 1 }
    func copy() { copyCallCount += 1 }
    func paste() { pasteCallCount += 1 }
    func selectAll() { selectAllCallCount += 1 }

    // MARK: Zoom

    func setZoomFactor(_ factor: Double) { zoomFactor = factor }

    // MARK: Content sizing

    private(set) var contentSizingBounds: (minimum: CGSize, maximum: CGSize)?

    func enableContentSizing(minimum: CGSize, maximum: CGSize) {
        contentSizingBounds = (minimum, maximum)
    }

    /// Stands in for the renderer reporting a preferred size back through
    /// `OrbitWebContentsCallbacks.preferred_size_changed`.
    func reportPreferredSize(_ size: CGSize) {
        delegate?.webContents(self, didChangePreferredSize: size)
    }

    // MARK: Colour scheme

    private(set) var preferredColorSchemes: [ContentColorScheme?] = []

    func setPreferredColorScheme(_ scheme: ContentColorScheme?) {
        preferredColorSchemes.append(scheme)
    }

    // MARK: Media

    private(set) var muteCalls: [Bool] = []

    func setMuted(_ muted: Bool) {
        muteCalls.append(muted)
        mediaState.isMuted = muted
    }

    private(set) var togglePictureInPictureCallCount = 0

    func togglePictureInPicture() { togglePictureInPictureCallCount += 1 }

    // MARK: Presentation

    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? {
        capturePreviewCallCount += 1
        return previewImageOverride
    }
    func print() {}
    func savePage() {}

    // MARK: Downloads

    private(set) var cancelledDownloadIDs: [UUID] = []

    func cancelDownload(id: UUID) {
        cancelledDownloadIDs.append(id)
    }

    // MARK: Developer tools

    func showDeveloperTools(inspectAt point: CGPoint?) {
        showDeveloperToolsCallCount += 1
        lastInspectPoint = point
    }

    func closeDeveloperTools() { closeDeveloperToolsCallCount += 1 }

    // MARK: Focus

    private(set) var focusCallCount = 0

    func focus() { focusCallCount += 1 }

    // MARK: Lifetime

    func close() { isClosed = true }

    // MARK: View

    lazy var view: NSView = NSView(frame: .zero)
}
