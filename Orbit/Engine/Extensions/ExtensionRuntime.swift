import Foundation
import Observation
import OSLog

/// The one place `ExtensionStore` (what is installed on disk) is joined to the
/// running engine (what is actually loaded). Without this, an install only ever
/// wrote files and a JSON record and nothing ever reached Chromium.
@MainActor
@Observable
public final class ExtensionRuntime {

    public static let shared = ExtensionRuntime()

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ExtensionRuntime")

    @ObservationIgnored
    private let store: ExtensionStore

    @ObservationIgnored
    private weak var engine: (any BrowserEngine)?
    @ObservationIgnored
    private var observerToken: UUID?
    @ObservationIgnored
    private var bootstrapTask: Task<Void, Never>?

    /// ids this runtime has successfully loaded into the engine it is bound to.
    private(set) var activatedIDs: Set<String> = []

    /// Last failure from a load/unload attempt, for the Extensions pane to show.
    private(set) var lastError: String?

    /// Bumped every time a load or unload finishes, so a view can refresh off
    /// the engine settling rather than polling for it.
    private(set) var settleSerial = 0

    public init(store: ExtensionStore? = nil) {
        self.store = store ?? AppEnvironment.processRoot.extensionStore
    }

    // MARK: - Binding

    func bind(to engine: any BrowserEngine) {
        guard engine.capabilities.contains(.extensions), engine.extensionActivation != .unsupported else { return }
        guard self.engine !== engine else { return }

        unbind()
        self.engine = engine
        observerToken = store.addChangeObserver { [weak self] event in
            self?.apply(event)
        }
        // Snapshotted here, not inside the task: an install landing before the
        // task's first turn would otherwise double-load and tear down the service worker.
        let bootstrapInstallations = store.enabledInstallations()
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.loadEnabledExtensions(bootstrapInstallations)
        }
    }

    func unbind() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        if let observerToken {
            store.removeChangeObserver(observerToken)
        }
        observerToken = nil
        engine = nil
        activatedIDs = []
    }

    // MARK: - Bootstrap

    /// `OrbitLoadExtension` answers "not ready yet" until the BrowserContext
    /// exists, so a load issued right after `start()` legitimately retries.
    private func loadEnabledExtensions(_ installations: [(id: String, directory: URL)]) async {
        guard !installations.isEmpty else {
            store.markActivated(ids: [])
            return
        }
        for installation in installations {
            guard !Task.isCancelled else { return }
            // .browserStartup fires chrome.runtime.onStartup and skips
            // re-installing an unchanged version, preserving its service worker.
            await load(
                directory: installation.directory, id: installation.id,
                reason: .browserStartup, retries: 40
            )
        }
        store.markActivated(ids: Array(activatedIDs))
    }

    // MARK: - Store changes

    private func apply(_ event: ExtensionStore.ChangeEvent) {
        guard engine != nil else { return }
        switch event {
        case .installed(let ext), .enabled(let ext):
            Task { [weak self] in
                guard let self else { return }
                // An update or a reinstall reuses the id, so drop the running
                // copy first: UnpackedInstaller would otherwise be adding an
                // extension the registrar already holds under that id.
                self.unload(id: ext.id)
                await self.load(directory: ext.directory, id: ext.id, retries: 4)
                self.store.markActivated(ids: Array(self.activatedIDs))
            }
        case .uninstalled(let id):
            uninstall(id: id)
            store.markActivated(ids: Array(activatedIDs))
        case .disabled(let ext):
            unload(id: ext.id)
            store.markActivated(ids: Array(activatedIDs))
        case .willReplace(let id):
            // Synchronous, not a Task: the caller awaits this dispatch and must
            // see the id fully unloaded before it touches its files on disk.
            unload(id: id)
            store.markActivated(ids: Array(activatedIDs))
        }
    }

    // MARK: - Engine calls

    private func load(
        directory: URL, id: String, reason: ExtensionLoadReason = .userAction, retries: Int
    ) async {
        guard let engine else { return }
        var attempt = 0
        while true {
            do {
                let loaded = try await engine.loadExtension(
                    at: directory, session: engine.defaultSession, reason: reason
                )
                activatedIDs.insert(loaded.id)
                lastError = nil
                settleSerial += 1
                Self.logger.info("loaded extension \(loaded.id, privacy: .public) v\(loaded.version, privacy: .public)")
                return
            } catch {
                attempt += 1
                let description = (error as? EngineError)?.underlyingDescription ?? error.localizedDescription
                guard attempt <= retries, description.contains("not ready") else {
                    activatedIDs.remove(id)
                    lastError = "\(id): \(description)"
                    settleSerial += 1
                    Self.logger.error("failed to load extension \(id, privacy: .public): \(description, privacy: .public)")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// A disable, an update and a reload all come through here, and all three
    /// have to keep the optional permissions the user granted this extension.
    private func unload(id: String) {
        guard let engine else { return }
        guard engine.loadedExtensions(session: engine.defaultSession).contains(where: { $0.id == id }) else {
            activatedIDs.remove(id)
            return
        }
        engine.unloadExtension(id: id, session: engine.defaultSession)
        activatedIDs.remove(id)
        settleSerial += 1
    }

    /// Runs even for an id the engine is not holding: a disabled extension is
    /// unloaded already, and its stored state still has to go.
    private func uninstall(id: String) {
        guard let engine else { return }
        let wasLoaded = engine.loadedExtensions(session: engine.defaultSession).contains { $0.id == id }
        engine.uninstallExtension(id: id, session: engine.defaultSession)
        activatedIDs.remove(id)
        if wasLoaded {
            settleSerial += 1
        }
    }
}
