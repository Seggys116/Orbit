//  BrowserEngine conformance for Orbit's direct Chromium embed; unimplemented paths throw/no-op.

import Foundation
import OSLog

@MainActor
final class ChromiumEngine: BrowserEngine {

    static let kind: EngineKind = .chromium

    // Every capability listed here must have a non-stub implementation.
    // .pictureInPicture is conditional: an older framework leaves the button inert.
    var capabilities: EngineCapabilities {
        var capabilities: EngineCapabilities = [
            .contentBlocking, .blockedRequestCounts, .backgroundSnapshots, .extensions, .developerTools,
        ]
        if OrbitChromiumBridge.shared.supportsPictureInPicture {
            capabilities.insert(.pictureInPicture)
        }
        return capabilities
    }
    let manageableContentSettings: Set<PermissionKind> = []

    // Every loaded extension is registered with extensions::ExtensionRegistrar
    // (see orbit_extension_loader.cc) synchronously before loadExtension(at:)
    // returns -- see BrowserEngine's own doc comment on extensionActivation.
    let extensionActivation: ExtensionActivation = .immediate

    var versionDescription: String { OrbitChromiumBridge.shared.versionDescription }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ChromiumEngine")

    private let storage: EngineStorage
    private var sessions: [String: ChromiumSession] = [:]
    private var didStart = false

    // Global (this profile has no per-session isolation yet -- see
    // ChromiumSession's file comment); the full set is re-pushed to
    // OrbitUserScriptRegistry on every mutation.
    private var userScripts: [UserScript] = []

    // Fed by OrbitExtensionActionDispatcher through the bridge -- see
    // installExtensionActionRelay below.
    let extensionActionStates = ExtensionActionStateStore()

    init(storage: EngineStorage) {
        self.storage = storage
    }

    func start() throws {
        guard !didStart else { return }
        didStart = true
        // Before loadAndStart(), never after: that call schedules OrbitMain,
        // and every process needs the directory on the command line by then.
        if let directory = EngineStorageDirectory.directory(for: storage) {
            try OrbitChromiumBridge.shared.setUserDataDirectory(directory.path)
        }
        installExtensionActionRelay()
        installSearchSuggestRelay()
        try OrbitChromiumBridge.shared.loadAndStart()
        // The only push that lands before the first document exists — Orbit's
        // launch-time push runs before the framework is dlopen'd and reaches nothing.
        EngineAppearance.apply()
    }

    /// chrome.privacy.services.searchSuggestEnabled: pushes Orbit's value down as
    /// the user value; the change handler carries an extension override back up.
    private func installSearchSuggestRelay() {
        OrbitChromiumBridge.shared.browserReadyHandler = {
            AppEnvironment.processRoot.pushSearchSuggestPreferenceToEngine()
        }
        OrbitChromiumBridge.shared.searchSuggestEnabledHandler = { enabled in
            AppEnvironment.processRoot.applyEngineSearchSuggestPreference(enabled)
        }
    }

    private func installExtensionActionRelay() {
        OrbitChromiumBridge.shared.extensionActionHandler = { [weak self] json in
            guard let self, let snapshot = ExtensionActionSnapshot.decode(json: json) else { return }
            self.extensionActionStates.apply(snapshot)
        }
    }

    /// A restarted-on-the-Swift-side engine starts with an empty store while
    /// //extensions still holds real badge state; re-reading avoids drift.
    private func refreshExtensionActionStates() {
        let json = OrbitChromiumBridge.shared.extensionActionsJSON()
        extensionActionStates.replaceAll(ExtensionActionSnapshot.decodeAll(json: json))
    }

    @discardableResult
    func shutdown() -> Bool {
        OrbitChromiumBridge.shared.requestQuitBrowser()
    }

    // MARK: - Sessions

    func session(identifier: String, persistent: Bool) throws -> EngineSession {
        if let existing = sessions[identifier] { return existing }
        let session = ChromiumSession(identifier: identifier, persistent: persistent)
        sessions[identifier] = session
        return session
    }

    var defaultSession: EngineSession {
        if let existing = sessions["default"] { return existing }
        let session = ChromiumSession(identifier: "default", persistent: storage != .ephemeral)
        sessions["default"] = session
        return session
    }

    // MARK: - Tabs

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        try ChromiumWebContents(session: session, initialURL: initialURL)
    }

    // MARK: - Global services

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {
        Self.logger.notice("clearBrowsingData not implemented yet — BrowsingDataRemover is not wired up")
    }

    func addUserScript(_ script: UserScript, session: EngineSession) {
        if let index = userScripts.firstIndex(where: { $0.id == script.id }) {
            userScripts[index] = script
        } else {
            userScripts.append(script)
        }
        pushUserScripts()
    }

    func removeUserScript(id: UUID, session: EngineSession) {
        userScripts.removeAll { $0.id == id }
        pushUserScripts()
    }

    private func pushUserScripts() {
        guard let data = try? JSONEncoder().encode(userScripts),
              let json = String(data: data, encoding: .utf8)
        else {
            Self.logger.error("failed to encode user scripts for OrbitSetUserScripts")
            return
        }
        OrbitChromiumBridge.shared.setUserScripts(json: json)
    }

    // MARK: - Content blocking

    // Global, like addUserScript: no per-session isolation yet, so `session` is unread.
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {
        OrbitChromiumBridge.shared.contentBlockingDecisionHandler = { requestURL, documentURL, resourceTypeRaw in
            guard let blocker else { return .allow }
            let resourceType = ContentBlockingResourceType(rawValue: Int(resourceTypeRaw)) ?? .other
            switch blocker.decision(forURL: requestURL, documentURL: documentURL, resourceType: resourceType) {
            case .block:
                return .block
            case .redirect(_, _, let substitution):
                let stub = blocker.stubPayload(for: substitution, resourceType: resourceType)
                return .substitute(mimeType: stub.mimeType, body: stub.content)
            case .allow, .exempted, .allowlistedSite, .disabled:
                return .allow
            }
        }
        // Separate from the handler above: this is what actually gates
        // whether OrbitContentBlockingURLLoaderFactory is installed at all --
        // see OrbitChromiumBridge.setContentBlockingActive's own comment.
        OrbitChromiumBridge.shared.setContentBlockingActive(blocker != nil)
    }

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        try await loadExtension(at: directory, session: session, reason: .userAction)
    }

    func loadExtension(
        at directory: URL, session: EngineSession, reason: ExtensionLoadReason
    ) async throws -> LoadedExtension {
        let (success, extensionJSON, errorMessage) = await OrbitChromiumBridge.shared.loadExtension(
            directoryPath: directory.path, forStartup: reason == .browserStartup
        )
        guard success, let extensionJSON else {
            throw EngineError(
                code: .engineUnavailable,
                url: directory,
                underlyingDescription: errorMessage.isEmpty ? "failed to load extension" : errorMessage
            )
        }
        guard let loaded = Self.decodeLoadedExtension(extensionJSON) else {
            throw EngineError(
                code: .unknown, url: directory,
                underlyingDescription: "loaded extension but could not decode its metadata"
            )
        }
        refreshExtensionActionStates()
        return loaded
    }

    func unloadExtension(id: String, session: EngineSession) {
        OrbitChromiumBridge.shared.unloadExtension(id: id)
        extensionActionStates.remove(extensionID: id)
    }

    func uninstallExtension(id: String, session: EngineSession) {
        OrbitChromiumBridge.shared.uninstallExtension(id: id)
        extensionActionStates.remove(extensionID: id)
    }

    func loadedExtensions(session: EngineSession) -> [LoadedExtension] {
        let json = OrbitChromiumBridge.shared.loadedExtensionsJSON()
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ChromiumExtensionJSON].self, from: data)
        else {
            return []
        }
        return entries.map { $0.asLoadedExtension() }
    }

    private static func decodeLoadedExtension(_ json: String) -> LoadedExtension? {
        guard let data = json.data(using: .utf8),
              let entry = try? JSONDecoder().decode(ChromiumExtensionJSON.self, from: data)
        else {
            return nil
        }
        return entry.asLoadedExtension()
    }
}

// MARK: - Extension JSON

/// Mirrors orbit_extension_loader.cc's ExtensionToDict field-for-field.
private struct ChromiumExtensionJSON: Decodable {
    var id: String
    var name: String
    var version: String
    var directory: String
    var iconPath: String
    var hasToolbarAction: Bool
    var manifestVersion: Int
    var isEnabled: Bool

    func asLoadedExtension() -> LoadedExtension {
        LoadedExtension(
            id: id,
            name: name,
            version: version,
            directory: URL(fileURLWithPath: directory),
            iconURL: iconPath.isEmpty ? nil : URL(fileURLWithPath: iconPath),
            hasToolbarAction: hasToolbarAction,
            manifestVersion: manifestVersion,
            isEnabled: isEnabled,
            isActivated: true,
            idIsEngineAssigned: true
        )
    }
}
