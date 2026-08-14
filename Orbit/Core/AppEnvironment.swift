import AppKit
import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class AppEnvironment {

    static let shared = AppEnvironment()

    // Deliberately a factory, not static let: a single shared instance would
    // let one test's leftover mutations become the next test's starting
    // state. Use demoApp below for one stable demo environment.
    static var demo: AppEnvironment { AppEnvironment.makeDemo() }

    // The single environment the Orbit Demo app runs on for its whole
    // launch — kept as a separate symbol from demo so the demo target's need
    // for a singleton cannot re-impose one on the test suite.
    static let demoApp: AppEnvironment = AppEnvironment.makeDemo()

    fileprivate static let logger = Logger(subsystem: "com.orbit.browser", category: "AppEnvironment")

    // MARK: - Backing stores (owned by the integration/persistence leads)

    // Every directory this environment's stores write to hangs off here. `.production` is
    // reachable only through OrbitDataRoot.processDefault, never by the demo app or an XCTest host.
    let dataRoot: OrbitDataRoot

    let store: BrowserStore
    let downloadStore: DownloadStore
    let boostStore: BoostStore
    let noteStore: NoteStore
    let easelStore: EaselStore
    let siteSearchStore: SiteSearchStore
    // Owned, not process-wide: pruneOrphaned below deletes every icon file this environment's
    // document does not name, so a store shared with a different document would delete its icons.
    let spaceIconImages: SpaceIconImageStore
    let faviconCache: FaviconCache
    let extensionStore: ExtensionStore
    private let historyStore: HistoryStore?
    private(set) var historyStoreStartError: Error?

    // MARK: - iCloud sync

    // Non-nil for exactly one environment in the process (production shared, never the demo or a window-scoped one): a second engine over the same document would double every push.
    let syncEngine: CloudSyncEngine?

    var state: OrbitState {
        get { store.state }
        set { store.state = newValue }
    }

    // MARK: - Engine

    // Always nil in a window-scoped environment — see engineProvider.
    private var ownEngine: (any BrowserEngine)?

    // A window-scoped environment points at AppEnvironment.shared's engine rather than starting its own; held strongly, since shared outlives every window and weak here risks silently degrading a live Incognito window to "no engine is running".
    private var engineProvider: AppEnvironment?

    // Computed, not stored, so a window-scoped environment cannot hold a
    // stale copy of an engine that has since been shut down and restarted.
    var engine: (any BrowserEngine)? {
        #if DEBUG
        if let override = _test_engineOverride { return override }
        #endif
        return engineProvider?.engine ?? ownEngine
    }

    #if DEBUG
    var _test_engineOverride: (any BrowserEngine)?
    #endif

    // self for AppEnvironment.shared, the provider for a window-scoped one.
    // Without this, an Incognito window opened from inside another Incognito
    // window would root at the first and lose its engine when that one closed.
    var rootEnvironment: AppEnvironment { engineProvider?.rootEnvironment ?? self }

    // true for makeDemo()'s output. Skips first-run onboarding and starts
    // the engine with EngineStorage.isolated rather than .persistent — the
    // real backend, real pages, just a scratch directory nothing else reads.
    let isDemo: Bool

    private(set) var engineStartError: EngineError?

    // nil when no engine is running — Boost application is skipped rather than faked.
    var boostScriptSink: BoostRuntime.ScriptSink? {
        #if DEBUG
        if let override = _test_boostScriptSinkOverride { return override }
        #endif
        guard let engine else { return nil }
        return BoostRuntime.ScriptSink(engine: engine)
    }

    #if DEBUG
    var _test_boostScriptSinkOverride: BoostRuntime.ScriptSink?
    #endif

    // Every control that exists only because a backend supports it must be
    // gated on this rather than on EngineKind, and must be absent rather
    // than present-and-inert when the capability isn't there.
    var engineCapabilities: EngineCapabilities {
        #if DEBUG
        if let override = _test_engineCapabilitiesOverride { return override }
        #endif
        return engine?.capabilities ?? []
    }

    #if DEBUG
    var _test_engineCapabilitiesOverride: EngineCapabilities?
    #endif

    // MARK: - Sidebar now-playing card

    var dismissedMiniPlayerTabIDs: Set<TabID> = []

    // MARK: - Live web contents, keyed by Tab.id

    private(set) var webContents: [TabID: any WebContents] = [:]

    // Bumped by loadInTab(_:url:) so materializeWebContents's deferred content-blocking load can tell it has been superseded.
    // Module-internal, not private: AppEnvironment+TearOff.swift reaches into another environment's copy when a tab is torn off.
    var navigationGeneration: [TabID: Int] = [:]

    // MARK: - Reactive mirrors of engine-owned, non-Observable state

    var navigationStates: [TabID: NavigationState] = [:]
    var themeColors: [TabID: ThemeColor] = [:]
    // The document's own computed background, distinct from themeColors (the
    // painted top band) — a page can have a dark nav over a white document.
    var documentColors: [TabID: ThemeColor] = [:]
    var mediaStates: [TabID: MediaState] = [:]
    var tabErrors: [TabID: EngineError] = [:]
    var crashedTabs: Set<TabID> = []
    var unresponsiveTabs: Set<TabID> = []
    var certificateProblems: [TabID: CertificateProblem] = [:]
    var findResultsByTab: [TabID: FindResult] = [:]
    var hoveredLinkURL: URL?
    var pendingCertificateDecisions: [TabID: CheckedContinuation<Bool, Never>] = [:]
    // Tabs whose next load failure is the certificate refusal the user just
    // made, so it lands as the interstitial's own outcome rather than as a
    // generic "Try Again" error page over the top of it.
    var refusedCertificateTabIDs: Set<TabID> = []
    var downloadIDByTab: [TabID: UUID] = [:]

    // chrome.webstorePrivate install consent, requested by WebStorePrivateBridge
    // and answered by SingleTabContentView's consent sheet — same shape as the
    // certificate-decision pair above.
    var pendingExtensionInstallConsent: [TabID: ExtensionInstaller.PendingInstall] = [:]
    var pendingExtensionInstallConsentDecisions: [TabID: CheckedContinuation<Bool, Never>] = [:]

    // Install progress, pushed by WebStorePrivateBridge; nil clears it. Shown
    // in the same sheet as the consent decision above, never as a separate
    // surface — see extensionInstallModalPhase(for:).
    var extensionInstallProgress: [TabID: ExtensionInstallStage] = [:]

    // Name/version/icon of the extension being installed, captured from the
    // verified manifest at consent time — the icon has to be read while the
    // installer's staging directory still exists.
    var extensionInstallSubjects: [TabID: ExtensionInstallSubject] = [:]

    // Terminal state of an install, so a failure is readable and dismissible
    // rather than vanishing with the progress it replaced.
    var extensionInstallOutcomes: [TabID: ExtensionInstallOutcome] = [:]

    // Cancels the in-flight install for a tab. Not a stage of its own: it
    // exists for exactly as long as an install task is running.
    @ObservationIgnored
    var extensionInstallCancellers: [TabID: @Sendable () -> Void] = [:]

    // Cancelling stops the pipeline at its next stage boundary (can be a whole unpack away); any
    // stage still in flight for this tab is dropped, not reopened. The installer's own nil clears it.
    @ObservationIgnored
    var extensionInstallCancelledTabIDs: Set<TabID> = []

    /// Three states of one sheet: outcome wins (terminal), consent wins over progress —
    /// `.awaitingConsent` is what the user is actually being asked for.
    func extensionInstallModalPhase(for tabID: TabID) -> ExtensionInstallModalPhase? {
        if let outcome = extensionInstallOutcomes[tabID] { return .outcome(outcome) }
        if let pending = pendingExtensionInstallConsent[tabID] { return .consent(pending) }
        if let stage = extensionInstallProgress[tabID] { return .progress(stage) }
        return nil
    }

    /// Every way out of the install sheet — Cancel, Done, Escape, clicking
    /// away — lands here, so no path can leave the sheet up or leave the
    /// installer waiting on a decision nobody is going to make.
    func dismissExtensionInstallModal(for tabID: TabID) {
        extensionInstallOutcomes.removeValue(forKey: tabID)
        if pendingExtensionInstallConsent[tabID] != nil {
            resolveExtensionInstallConsent(for: tabID, granted: false)
        }
        if extensionInstallProgress.removeValue(forKey: tabID) != nil {
            extensionInstallCancelledTabIDs.insert(tabID)
            extensionInstallCancellers[tabID]?()
            extensionInstallSubjects.removeValue(forKey: tabID)
        }
    }

    func clearExtensionInstallState(for tabID: TabID) {
        if extensionInstallProgress.removeValue(forKey: tabID) != nil {
            extensionInstallCancelledTabIDs.insert(tabID)
        }
        extensionInstallSubjects.removeValue(forKey: tabID)
        extensionInstallOutcomes.removeValue(forKey: tabID)
        extensionInstallCancellers.removeValue(forKey: tabID)?()
        pendingExtensionInstallConsent.removeValue(forKey: tabID)
        pendingExtensionInstallConsentDecisions.removeValue(forKey: tabID)?.resume(returning: false)
    }

    // chrome.permissions.request consent, answered by BrowserWindowView's sheet. Kept separate
    // from the install flow above: a running extension asking for more can be outstanding at once with an install.
    var pendingExtensionPermissionsConsent: [TabID: ExtensionPermissionsConsentRequest] = [:]

    /// Answers the engine exactly once, and only for a tab that actually has a
    /// request outstanding, so every abandonment path can call it blind.
    func resolveExtensionPermissionsConsent(for tabID: TabID, granted: Bool) {
        guard let request = pendingExtensionPermissionsConsent.removeValue(forKey: tabID) else { return }
        OrbitChromiumBridge.shared.permissionsConsentResponse(requestID: request.requestID, approved: granted)
    }

    /// The sheet's own way in: it knows the request it is showing, not the tab
    /// it was routed to, and the active tab can have moved on underneath it.
    func resolveExtensionPermissionsConsent(_ request: ExtensionPermissionsConsentRequest, granted: Bool) {
        guard let tabID = pendingExtensionPermissionsConsent
            .first(where: { $0.value.requestID == request.requestID })?.key
        else { return }
        resolveExtensionPermissionsConsent(for: tabID, granted: granted)
    }

    // MARK: - Extension points for the Features agent

    let extensionPoints = UIExtensionPoints()

    // MARK: - Sidebar UI state

    var isSidebarVisible: Bool = true {
        didSet { AppEnvironment.defaults.set(isSidebarVisible, forKey: Keys.sidebarVisible) }
    }
    var sidebarWidth: CGFloat = OrbitMetrics.sidebarDefaultWidth {
        didSet { AppEnvironment.defaults.set(Double(sidebarWidth), forKey: Keys.sidebarWidth) }
    }
    /// `true` while the hover-to-reveal overlay is showing over a hidden sidebar.
    var isSidebarHoverRevealed: Bool = false
    var hoveredSidebarTabID: TabID?
    var expandedFolderOverride: [FolderID: Bool] = [:]

    // MARK: - Command Bar

    var isCommandBarPresented: Bool = false
    var commandBarMode: CommandBarMode = .newTab
    // Counts opening gestures, not presentations — bumped so CommandBarView
    // can tell a second ⌘L over an already-open bar from the first.
    var commandBarPresentationSerial: Int = 0

    // MARK: - Find bar

    var isFindBarPresented: Bool = false
    var findQuery: String = ""
    var currentFindResult: FindResult = .none

    // MARK: - Split focus

    var focusedSplitPaneIndex: Int = 0
    var activeSplitDropZone: SplitDropZone?

    // .zero until the first layout pass, which preferredSplitOrientation(paneCount:) handles explicitly.
    var contentAreaSize: CGSize = .zero

    // MARK: - Site Control popover

    // An optional TabID, not a Bool: more than one pane can share this
    // environment (a split, or a Little Orbit window), so this names which one's popover is open.
    var siteControlPresentedTabID: TabID?

    // MARK: - Settings / About / Onboarding windows

    var settingsWindowController: NSWindowController?
    var aboutWindowController: NSWindowController?
    var hasCompletedOnboarding: Bool {
        get { AppEnvironment.defaults.bool(forKey: Keys.onboardingComplete) }
        set { AppEnvironment.defaults.set(newValue, forKey: Keys.onboardingComplete) }
    }

    // MARK: - History

    private(set) var localHistoryCache: [HistoryEntry] = []

    // localHistoryCache alone cannot answer a typed query — it holds only
    // the 500 most recent entries, so anything older needs HistoryStore's
    // own FTS index and frecency ranking consulted directly.
    private(set) var historySearchQuery: String = ""
    private(set) var historySearchResults: [HistoryEntry] = []

    // MARK: - Tab census

    // Excludes archived tabs — counting them would make "Warn before
    // quitting" fire on a session with nothing open in it.
    var openTabCount: Int {
        state.tabs.values.filter { $0.section != .archived }.count
    }

    // MARK: - Downloads

    var downloads: [DownloadItem] { downloadStore.downloads }

    // MARK: - AI provider (Assist features degrade honestly without one)

    var hasConfiguredAIProvider: Bool = false

    // MARK: - Keys and the store they live in

    enum Keys {
        static let sidebarVisible = "OrbitSidebarVisible"
        static let sidebarWidth = "OrbitSidebarWidth"
        static let onboardingComplete = "OrbitOnboardingComplete"
    }

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    // MARK: - Init

    // Each store keeps its own default rather than dataRoot.<subdirectory>: both already resolve
    // through the same OrbitDataRoot.processDefault, so paths stay the ones production has always used.
    private convenience init() {
        self.init(
            dataRoot: .processDefault,
            store: BrowserStore(),
            downloadStore: DownloadStore(),
            boostStore: BoostStore(),
            noteStore: NoteStore(),
            easelStore: EaselStore(),
            siteSearchStore: SiteSearchStore(),
            historyStore: (try? HistoryStore()),
            syncsWithICloud: true
        )
    }

    private init(
        dataRoot: OrbitDataRoot,
        store: BrowserStore,
        downloadStore: DownloadStore,
        boostStore: BoostStore,
        noteStore: NoteStore,
        easelStore: EaselStore,
        siteSearchStore: SiteSearchStore,
        historyStore: HistoryStore?,
        spaceIconImages: SpaceIconImageStore? = nil,
        faviconCache: FaviconCache? = nil,
        extensionStore: ExtensionStore? = nil,
        syncsWithICloud: Bool = false,
        isDemo: Bool = false
    ) {
        self.isDemo = isDemo
        self.dataRoot = dataRoot
        self.spaceIconImages = spaceIconImages ?? SpaceIconImageStore(diskDirectory: dataRoot.spaceIcons)
        self.faviconCache = faviconCache ?? FaviconCache(diskDirectory: dataRoot.favicons)
        self.extensionStore = extensionStore ?? ExtensionStore(root: dataRoot.extensions)
        self.store = store
        self.downloadStore = downloadStore
        self.boostStore = boostStore
        self.noteStore = noteStore
        self.easelStore = easelStore
        self.siteSearchStore = siteSearchStore
        if let historyStore {
            self.historyStore = historyStore
            self.historyStoreStartError = nil
        } else {
            self.historyStore = nil
            self.historyStoreStartError = HistoryStoreError.openFailed(reason: "HistoryStore was not provided.")
        }
        self.isSidebarVisible = AppEnvironment.defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        let storedWidth = AppEnvironment.defaults.double(forKey: Keys.sidebarWidth)
        self.sidebarWidth = storedWidth > 0 ? CGFloat(storedWidth) : OrbitMetrics.sidebarDefaultWidth

        // Only the installed browser touches the real iCloud container: a development or test run
        // must neither push scratch state into it nor pull the user's real state out of it.
        if syncsWithICloud, OrbitRuntimeScope.current.isProduction {
            let engine = CloudSyncEngine(store: store)
            self.syncEngine = engine
            engine.start()
        } else {
            self.syncEngine = nil
        }

        Task { await refreshHistoryCache() }
    }

    // MARK: - Demo factory

    // Scratch rooting here covers only the stores this type owns — it cannot
    // cover Chromium's own state (cookies, cache, local storage). startEngineIfNeeded()
    // closes that half with an EngineStorage.isolated engine for any isDemo environment.
    private static func makeDemo() -> AppEnvironment {
        let scratchRoot = OrbitDataRoot.scratch(label: "Demo")

        let stateStore = StateStore(rootDirectory: scratchRoot.state, maxBackups: 0)
        let store = BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)
        let downloadStore = DownloadStore(fileURL: scratchRoot.downloadsFile)
        let boostStore = BoostStore(fileURL: scratchRoot.boostsFile)
        let noteStore = NoteStore(directory: scratchRoot.notes)
        let easelStore = EaselStore(directory: scratchRoot.easels)
        let siteSearchStore = SiteSearchStore(fileURL: scratchRoot.siteSearchFile)
        let historyStore: HistoryStore?
        do {
            historyStore = try HistoryStore(databaseURL: scratchRoot.historyDatabase)
        } catch {
            historyStore = nil
        }

        let env = AppEnvironment(
            dataRoot: scratchRoot,
            store: store,
            downloadStore: downloadStore,
            boostStore: boostStore,
            noteStore: noteStore,
            easelStore: easelStore,
            siteSearchStore: siteSearchStore,
            historyStore: historyStore,
            isDemo: true
        )

        env.store.state = OrbitState.demo

        // TODO(demo): seed env.downloadStore with two DownloadItems (one
        // completed, one in-progress). DownloadStore has no public mutator
        // for a fully-built DownloadItem yet — add DownloadStore.seed(_:) when needed.

        // TODO(demo): seed historyStore with visits across several days.
        // HistoryStore.record(visit:) is an actor method that would race
        // refreshHistoryCache() if called synchronously here — add an async seed path when needed.

        env.isSidebarVisible = true
        env.sidebarWidth = 280
        env.hasCompletedOnboarding = true
        return env
    }

    // MARK: - Window-scoped environments

    // Shares store and the other document stores with host's root: an Incognito Space is still a real Space in the one OrbitState, kept off disk by StateStore's strippingEphemeralEntities(), so a private document per window must not be introduced.
    // windowActiveSpaceID, the live WebContents map and its mirrors, and per-window UI state are not shared and are torn down by disposeWindowSession() instead.
    static func makeWindowScoped(sharing host: AppEnvironment, activeSpaceID: SpaceID, isTornOff: Bool = false) -> AppEnvironment {
        let root = host.rootEnvironment
        let env = AppEnvironment(
            dataRoot: root.dataRoot,
            store: root.store,
            downloadStore: root.downloadStore,
            boostStore: root.boostStore,
            noteStore: root.noteStore,
            easelStore: root.easelStore,
            siteSearchStore: root.siteSearchStore,
            historyStore: root.historyStore,
            spaceIconImages: root.spaceIconImages,
            faviconCache: root.faviconCache,
            extensionStore: root.extensionStore,
            isDemo: root.isDemo
        )
        env.engineProvider = root
        env.windowActiveSpaceID = activeSpaceID
        env.isTornOffWindowSession = isTornOff
        env.hasConfiguredAIProvider = root.hasConfiguredAIProvider
        return env
    }

    // Safe to call more than once, and safe on AppEnvironment.shared — never touches the engine, stores, or document.
    func disposeWindowSession() {
        for tabID in Array(webContents.keys) {
            releaseWebContents(for: tabID, windowClosing: true)
        }
        // Resumed, never merely dropped: abandoning a suspended checked
        // continuation hangs that task forever. Declining is the safe answer for a window going away.
        for (_, continuation) in pendingCertificateDecisions {
            continuation.resume(returning: false)
        }
        pendingCertificateDecisions.removeAll()
        for (_, continuation) in pendingExtensionInstallConsentDecisions {
            continuation.resume(returning: false)
        }
        pendingExtensionInstallConsentDecisions.removeAll()
        pendingExtensionInstallConsent.removeAll()
        extensionInstallProgress.removeAll()
        extensionInstallSubjects.removeAll()
        extensionInstallOutcomes.removeAll()
        for cancel in extensionInstallCancellers.values { cancel() }
        extensionInstallCancellers.removeAll()
        extensionInstallCancelledTabIDs.removeAll()
        // Same reason as the continuations above: an unanswered permissions
        // request stays refused in the engine forever, so the window going
        // away has to refuse it explicitly.
        for tabID in Array(pendingExtensionPermissionsConsent.keys) {
            resolveExtensionPermissionsConsent(for: tabID, granted: false)
        }

        navigationStates.removeAll()
        themeColors.removeAll()
        documentColors.removeAll()
        mediaStates.removeAll()
        tabErrors.removeAll()
        crashedTabs.removeAll()
        unresponsiveTabs.removeAll()
        certificateProblems.removeAll()
        refusedCertificateTabIDs.removeAll()
        findResultsByTab.removeAll()
        downloadIDByTab.removeAll()
        dismissedMiniPlayerTabIDs.removeAll()
        hoveredLinkURL = nil
        hoveredSidebarTabID = nil
        isCommandBarPresented = false
        isFindBarPresented = false
        siteControlPresentedTabID = nil
        findQuery = ""
        currentFindResult = .none
        windowActiveSpaceID = nil
    }

    // Cmd+T in an Incognito window must open a tab in that window's own
    // Space, not whatever the main window is showing — hence falling back to
    // processRoot rather than always .shared.
    static var frontmost: AppEnvironment {
        OrbitWindowController.frontmostEnvironment ?? processRoot
    }

    // For every surface with no WindowSession to ask. nonisolated(unsafe) is safe only because this is written once, on the main actor, before any window exists.
    // Naming AppEnvironment.shared directly in the Orbit Demo process would build the real singleton (the user's real history, document and iCloud sync).
    nonisolated static var processRoot: AppEnvironment {
        get { explicitProcessRoot ?? .shared }
        set { explicitProcessRoot = newValue }
    }

    nonisolated(unsafe) private static var explicitProcessRoot: AppEnvironment?

    // MARK: - Engine lifecycle

    func startEngineIfNeeded() {
        // Deliberately no guard !isDemo — the Orbit Demo app starts the real engine too. Started first on both paths, before anything can call materializeWebContents, giving the content-blocking cache parse a head start. Idempotent.
        ContentBlockingRuntime.shared.beginInitialCacheLoad()

        // Recent Pages opens its own read-only connection, not historyStore's, so it must be pointed
        // at this environment's database before the first hover can open one.
        RecentPagesHistoryConnection.databaseURL = dataRoot.historyDatabase

        // Launch is the one point the full set of live icon IDs is knowable in a single pass. Runs
        // per environment, since spaceIconImages reads only this environment's own document.
        let liveIconImageIDs = Set(state.spaces.compactMap(\.iconImageID))
        let iconStore = spaceIconImages
        Task { iconStore.pruneOrphaned(keeping: liveIconImageIDs) }

        #if DEBUG
        runStoreDiskSelfChecksOnce()
        #endif

        if let engineProvider {
            // Borrowed: starting an engine is the provider's job alone; this
            // environment still owns materialising its own window's active tab.
            engineProvider.startEngineIfNeeded()
            materializeActiveTabIfNeeded()
            return
        }
        guard ownEngine == nil else { return }
        // .isolated, not .ephemeral: ephemeral loads no extensions and reads as incognito, so the Web
        // Store refuses installs. XCTest and the smoke probe both need this or they'd hit the real profile.
        let needsPrivateProfile = isDemo || DebugFlags.isRunningUnderTests || DebugFlags.isRunningSmokeProbe
        ownEngine = EngineFactory.makeEngine(storage: needsPrivateProfile ? .isolated : .persistent)
        // Safe only after EngineFactory.makeEngine returns: it runs loadAndStart() through dlsym, and
        // OrbitChromiumTabsBridge's init installs its delegate through that same table — see ChromiumTabsSetup.
        ChromiumTabsSetup.installHandlerOnce
        startBackgroundTabRendererPolicy()
        materializeActiveTabIfNeeded()
    }

    #if DEBUG
    // Ran off the two stores' process-wide singletons before those were
    // removed; they are per-environment now, so the probe runs once, against
    // the environment that owns the process's engine.
    private static var didRunStoreDiskSelfChecks = false

    private func runStoreDiskSelfChecksOnce() {
        guard !AppEnvironment.didRunStoreDiskSelfChecks else { return }
        AppEnvironment.didRunStoreDiskSelfChecks = true
        spaceIconImages.runSelfCheck()
        faviconCache.runSelfCheck()
    }
    #endif

    // Tabs are persisted but their renderers are not — without this, a
    // relaunched window shows an empty content area until the user clicks something.
    func materializeActiveTabIfNeeded() {
        guard let spaceID = activeSpace?.id else { return }
        guard let tab = store.activeTab(in: spaceID) else { return }
        materializeWebContents(for: tab.id, url: tab.url)
    }

    @discardableResult
    func shutdownEngine() -> Bool {
        // Borrowed engines are never shut down from here: a window-scoped
        // environment closing its window must not take the whole process's
        // renderer down with it. `disposeWindowSession()` is that path.
        guard engineProvider == nil else { return true }
        stopBackgroundTabRendererPolicy()
        let finished = ownEngine?.shutdown() ?? true
        ownEngine = nil
        // Sessions go with the engine, so every Boost script this runtime believes installed is gone too; without this a restarted engine's fresh session is skipped as "already installed" (same for the blocker's session bindings).
        BoostRuntime.shared.reset()
        ContentBlockingRuntime.shared.reset()
        return finished
    }

    // MARK: - Per-window active Space
    // A window-scoped environment carries its own active Space here and must never write state.activeSpaceID, so an Incognito window can show a different Space without the document knowing; every view reads env.activeSpace, not state.activeSpaceID.

    // nil for AppEnvironment.shared and every ordinary window, meaning "follow the document".
    private(set) var windowActiveSpaceID: SpaceID?

    // A torn-off window's Space is also Space.ephemeral, same as Incognito's
    // — this is the exact distinction isTornOffWindow/isIncognito(_:) need
    // rather than re-deriving it from Space.ephemeral plus a Profile lookup.
    private(set) var isTornOffWindowSession: Bool = false

    var isWindowScoped: Bool { windowActiveSpaceID != nil }

    // Falls back to state.activeSpaceID raw, not activeSpace?.id: store.activeSpace
    // substitutes spaces.first, but activeTabID/activeTab are strict.
    private var resolvedActiveSpaceID: SpaceID? {
        windowActiveSpaceID ?? state.activeSpaceID
    }

    // MARK: - Spaces

    var spaces: [Space] { store.spaces }

    // Falls back to the document's active Space when this environment's own
    // has gone — a window mid-teardown must render something rather than trap.
    var activeSpace: Space? {
        guard let windowActiveSpaceID else { return store.activeSpace }
        return store.space(windowActiveSpaceID) ?? store.activeSpace
    }

    func space(_ id: SpaceID) -> Space? { store.space(id) }

    // MARK: - Search engine

    var searchEngine: SearchEngine {
        searchEngine(forSpace: activeSpace?.id)
    }

    func searchEngine(forSpace spaceID: SpaceID?) -> SearchEngine {
        let profileID = spaceID.flatMap { space($0)?.profileID }
        if let profileID, let profile = state.profiles.first(where: { $0.id == profileID }) {
            return profile.searchEngine
        }
        return state.profiles.first?.searchEngine ?? .fallback
    }

    var includesSearchSuggestions: Bool {
        let profileID = activeSpace?.profileID
        if let profileID, let profile = state.profiles.first(where: { $0.id == profileID }) {
            return profile.includesSearchSuggestions
        }
        return state.profiles.first?.includesSearchSuggestions ?? true
    }

    /// The index in `state.profiles` that `includesSearchSuggestions` reads,
    /// resolved the same way, so a write lands on the profile the read answers
    /// for rather than on whichever happens to be first.
    private var searchSuggestProfileIndex: Int? {
        if let profileID = activeSpace?.profileID,
           let index = state.profiles.firstIndex(where: { $0.id == profileID }) {
            return index
        }
        return state.profiles.isEmpty ? nil : 0
    }

    /// Sends Orbit's answer as chrome.privacy.services.searchSuggestEnabled's user value. An
    /// extension override still wins; the effective result comes back through applyEngineSearchSuggestPreference.
    func pushSearchSuggestPreferenceToEngine() {
        OrbitChromiumBridge.shared.setSearchSuggestEnabled(includesSearchSuggestions)
    }

    /// The effective value after an extension's types.ChromeSetting.set, written into the Profile —
    /// where this setting genuinely lives, so readers stay pure derivations with no engine dependency.
    func applyEngineSearchSuggestPreference(_ enabled: Bool) {
        guard let index = searchSuggestProfileIndex,
              state.profiles[index].includesSearchSuggestions != enabled
        else { return }
        state.profiles[index].includesSearchSuggestions = enabled
    }

    func resolveTypedInput(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = CommandBarEngine.detectTypedURL(trimmed) {
            return url
        }
        return searchEngine.searchURL(for: trimmed)
    }

    // A non-persistent Profile always wins; otherwise a torn-off Space's own .ephemeral flag doesn't count, or every torn-off window would look private.
    func isIncognito(_ space: Space) -> Bool {
        if let profile = state.profiles.first(where: { $0.id == space.profileID }), OrbitState.isEphemeral(profile) {
            return true
        }
        guard !isTornOffWindow(for: space) else { return false }
        return space.isEphemeral
    }

    func isPrivateBrowsingContext(spaceID: SpaceID?, profileID: ProfileID) -> Bool {
        if let spaceID, let space = store.space(spaceID) { return isIncognito(space) }
        guard let profile = state.profiles.first(where: { $0.id == profileID }) else { return false }
        return OrbitState.isEphemeral(profile)
    }

    // In a window-scoped environment this moves this window only and never
    // touches state.activeSpaceID — before this existed, opening an
    // Incognito window switched every open window to the Incognito Space.
    func selectSpace(_ id: SpaceID) {
        guard isWindowScoped else {
            store.switchToSpace(id)
            // activeTabID is per Space, so the window is now showing a
            // different tab without any tab having been activated.
            syncChromiumActiveTab()
            return
        }
        guard store.space(id) != nil else { return }
        windowActiveSpaceID = id
        syncChromiumActiveTab()
    }

    func nextSpace() { stepSpace(offset: 1) }
    func previousSpace() { stepSpace(offset: -1) }

    // Must walk pagerSpaces, never the document's full spaces list — stepping through the full list could step an Incognito or torn-off window onto a Space belonging to a different, persistent window and show that window's own tab, live.
    private func stepSpace(offset: Int) {
        guard isWindowScoped else {
            if offset > 0 { store.nextSpace() } else { store.previousSpace() }
            return
        }
        let ordered = pagerSpaces
        guard !ordered.isEmpty,
              let current = activeSpace,
              let index = ordered.firstIndex(where: { $0.id == current.id }) else { return }
        let count = ordered.count
        selectSpace(ordered[((index + offset) % count + count) % count].id)
    }

    /// `Ctrl+1`...`Ctrl+9`. Reads `pagerSpaces`, not `spaces`: the full document list would let a keyboard jump point an Incognito or torn-off window at any Space in the document.
    func jumpToSpace(index: Int) {
        let ordered = pagerSpaces
        guard index >= 0, index < ordered.count else { return }
        selectSpace(ordered[index].id)
    }

    /// Redirects a mutation's `state.activeSpaceID` side effect onto this window's pointer, so an Incognito window can't drag other windows onto its Space.
    /// `deleteSpace` is deliberately not wrapped, since it does have to move the active Space.
    private func scopingActiveSpaceToThisWindow<T>(_ mutation: () -> T) -> T {
        guard isWindowScoped else { return mutation() }
        let documentActiveSpaceID = state.activeSpaceID
        let result = mutation()
        if let moved = state.activeSpaceID, moved != documentActiveSpaceID {
            windowActiveSpaceID = moved
        }
        if state.activeSpaceID != documentActiveSpaceID {
            state.activeSpaceID = documentActiveSpaceID
        }
        return result
    }

    @discardableResult
    func createSpace(name: String, icon: String, iconIsEmoji: Bool, theme: SpaceTheme, profileID: ProfileID) -> SpaceID {
        scopingActiveSpaceToThisWindow {
            store.createSpace(name: name, icon: icon, iconIsEmoji: iconIsEmoji, theme: theme, profileID: profileID)
        }
    }

    func renameSpace(_ id: SpaceID, to name: String) { store.renameSpace(id, to: name) }
    func setSpaceIcon(_ id: SpaceID, icon: String, isEmoji: Bool) { store.setIcon(icon, isEmoji: isEmoji, forSpace: id) }
    func updateSpaceTheme(_ id: SpaceID, theme: SpaceTheme) { store.setTheme(theme, forSpace: id) }
    func deleteSpace(_ id: SpaceID) { store.deleteSpace(id) }
    func reorderSpaces(_ ids: [SpaceID]) { store.reorderSpaces(ids) }

    // Sets only the switch — a name or icon the user already chose must not be reset by automatic activation.
    func autoActivateGitHubLiveFolder(in spaceID: SpaceID) {
        var updated: GitHubLiveFolderConfig?
        store.mutateSpace(spaceID) { space in
            var config = space.githubLiveFolder ?? GitHubLiveFolderConfig()
            config.enabled = true
            space.githubLiveFolder = config
            updated = config
        }
        if let updated { GitHubLiveFolderStore.shared.config = updated }
    }

    // MARK: - Tabs

    func tab(_ id: TabID) -> Tab? { store.tab(id) }

    var activeTabID: TabID? {
        get {
            guard let spaceID = resolvedActiveSpaceID else { return nil }
            return state.activeTabBySpace[spaceID]
        }
        set {
            guard let spaceID = resolvedActiveSpaceID else { return }
            state.activeTabBySpace[spaceID] = newValue
        }
    }

    var activeTab: Tab? {
        guard let spaceID = resolvedActiveSpaceID else { return nil }
        return store.activeTab(in: spaceID)
    }

    func todayTabs(in spaceID: SpaceID) -> [Tab] { store.todayTabs(in: spaceID) }

    func pinnedNodes(in spaceID: SpaceID) -> [SidebarNode] { store.pinnedNodes(in: spaceID) }

    @discardableResult
    func openTab(url: URL, in spaceID: SpaceID, section: TabSection = .today, activate: Bool = true) -> TabID {
        let tabID = scopingActiveSpaceToThisWindow {
            store.openTab(url: url, in: spaceID, section: section, activate: activate)
        }
        recordVisit(url: url, title: "", profileID: profileID(for: spaceID), spaceID: spaceID)
        materializeWebContents(for: tabID, url: url)
        syncChromiumActiveTab()
        return tabID
    }

    func activateTab(_ id: TabID) {
        guard let tab = store.tab(id) else { return }
        scopingActiveSpaceToThisWindow { store.selectTab(id) }
        materializeWebContents(for: id, url: tab.url)
        syncChromiumActiveTab()
        // Must move AppKit's real first responder, not just the visual highlight, guarded against the Command Bar/Find bar so a tab activation racing one of them never steals focus from a live text field.
        guard !isCommandBarPresented, !isFindBarPresented else { return }
        webContents[id]?.focus()
    }

    func closeTab(_ id: TabID) {
        let spaceID = store.tab(id)?.spaceID
        releaseWebContents(for: id)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.closeTab(id)
        // BrowserStore's successor has no live renderer yet, so activateTab materialises it and pushes
        // the activation through syncChromiumActiveTab — same as closeTabKeepingBookmark/removeBookmark.
        if let spaceID, let nowActive = store.activeTab(in: spaceID)?.id {
            if nowActive != id {
                activateTab(nowActive)
            } else if let survivor = store.tab(id) {
                // Closing a pinned tab unpins it, and with nothing else open it stays on screen — it needs the renderer back that was released above.
                materializeWebContents(for: id, url: survivor.url)
            }
        }
        syncChromiumActiveTab()
    }

    // Every user-facing close verb funnels through here so a bookmarked tab closes by the same rule as the minus beside its row, rather than being silently unpinned.
    func closeTabPreservingBookmark(_ id: TabID) {
        guard store.tab(id)?.section == .pinned else { return closeTab(id) }
        closeTabKeepingBookmark(id)
    }

    func reopenLastClosedTab() {
        scopingActiveSpaceToThisWindow { store.reopenLastClosedTab() }
        syncChromiumActiveTab()
    }

    // MARK: - Bookmarked (pinned) rows that are also open tabs

    // Reads webContents, not Tab.isUnloaded — that flag is untrustworthy
    // immediately after a relaunch or Restore Data restore, when no tab has a
    // renderer yet. webContents is the thing that actually knows.
    func isTabOpen(_ id: TabID) -> Bool { webContents[id] != nil }

    // Order matters: a Split View pane is separated out first (closeSplitPane),
    // or it would be left rendering a torn-down WebContents as a blank rectangle.
    func closeTabKeepingBookmark(_ id: TabID) {
        guard let tab = store.tab(id), tab.section == .pinned else { return }
        if splitGroup(for: id) != nil { closeSplitPane(id) }
        releaseWebContents(for: id)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.closeTabKeepingPin(id)
        if let nowActive = state.activeTabBySpace[tab.spaceID], nowActive != id {
            activateTab(nowActive)
        }
        syncChromiumActiveTab()
    }

    func removeBookmark(_ id: TabID) {
        guard let tab = store.tab(id), tab.section == .pinned else { return }
        if splitGroup(for: id) != nil { closeSplitPane(id) }
        releaseWebContents(for: id)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.removeBookmark(id)
        defer { syncChromiumActiveTab() }
        if let nowActive = state.activeTabBySpace[tab.spaceID], nowActive != id {
            activateTab(nowActive)
        }
    }

    // Reads the engine's live, synchronous navigationState rather than
    // Tab.url/Tab.title, which are only the asynchronous mirror — a Cmd-D
    // pressed mid-navigation can beat that mirror by an entire load.
    func livePinCapture(for id: TabID) -> (url: URL?, title: String?) {
        guard let navigationState = webContents[id]?.navigationState else { return (nil, nil) }
        return (navigationState.url, navigationState.title)
    }

    func pinTab(_ id: TabID) {
        let capture = livePinCapture(for: id)
        store.pin(id, capturedURL: capture.url, capturedTitle: capture.title)
        pushChromiumTabPinnedChanged(id)
    }
    func unpinTab(_ id: TabID) {
        store.unpin(id)
        pushChromiumTabPinnedChanged(id)
    }

    func togglePin(_ id: TabID) {
        guard let tab = store.tab(id) else { return }
        if tab.section == .pinned {
            unpinTab(id)
        } else {
            pinTab(id)
        }
    }

    func renameTab(_ id: TabID, to customTitle: String) { store.renameTab(id, to: customTitle) }

    /// Drops a custom title, so the tab shows the live page title again.
    func resetTabName(_ id: TabID) { store.resetTabName(id) }

    func muteTab(_ id: TabID, muted: Bool) {
        guard state.tabs[id] != nil else { return }
        state.tabs[id]?.isMuted = muted
        webContents[id]?.setMuted(muted)
    }

    func archiveTab(_ id: TabID) {
        let spaceID = store.tab(id)?.spaceID
        store.archiveTab(id)
        releaseWebContents(for: id)
        // Same reasoning as closeTab above: the successor BrowserStore just
        // picked has no live renderer until activateTab materialises it.
        if let spaceID, let nowActive = store.activeTab(in: spaceID)?.id, nowActive != id {
            activateTab(nowActive)
        }
        syncChromiumActiveTab()
    }

    func restoreFromArchive(_ id: TabID, section: TabSection = .today) {
        store.restoreFromArchive(id, to: section)
    }

    func archivedTabs(in spaceID: SpaceID? = nil) -> [Tab] { store.archivedTabs(in: spaceID) }

    // Tabs playing media are skipped, matching the auto-archive sweep.
    func clearTodayTabs(in spaceID: SpaceID) {
        for id in todayTabs(in: spaceID).map(\.id) where !store.tabsPlayingMedia.contains(id) {
            archiveTab(id)
        }
    }

    func runArchiveSweep(now: Date = Date()) {
        store.runArchiveSweep(now: now)
    }

    private func profileID(for spaceID: SpaceID) -> ProfileID {
        space(spaceID)?.profileID ?? state.profiles.first?.id ?? UUID()
    }

    // MARK: - Moving tabs between spaces

    func moveTab(_ id: TabID, toSpace destinationSpaceID: SpaceID, section: TabSection = .today) {
        store.moveTab(id, toSpace: destinationSpaceID, section: section)
        syncChromiumActiveTab()
    }

    // MARK: - Favorites

    func favorites(for spaceID: SpaceID) -> [Favorite] { store.favorites(for: spaceID) }

    private func siblingSpaceIDs(sharingProfileOf spaceID: SpaceID) -> [SpaceID] {
        guard let profileID = space(spaceID)?.profileID else { return [spaceID] }
        return state.spaces.filter { $0.profileID == profileID }.map(\.id)
    }

    @discardableResult
    func addFavorite(url: URL, title: String, from spaceID: SpaceID) -> FavoriteAddOutcome {
        let outcome = store.addFavorite(url: url, title: title, in: spaceID)
        for sibling in siblingSpaceIDs(sharingProfileOf: spaceID) where sibling != spaceID {
            store.addFavorite(url: url, title: title, in: sibling)
        }
        return outcome
    }

    func removeFavorite(_ favoriteID: UUID, from spaceID: SpaceID) {
        for sibling in siblingSpaceIDs(sharingProfileOf: spaceID) {
            store.removeFavorite(favoriteID, from: sibling)
        }
    }

    func reorderFavorites(_ ids: [UUID], in spaceID: SpaceID) {
        for sibling in siblingSpaceIDs(sharingProfileOf: spaceID) {
            store.reorderFavorites(ids, in: sibling)
        }
    }

    @discardableResult
    func promoteTabToFavorite(_ id: TabID) -> FavoriteAddOutcome? {
        guard let tab = store.tab(id) else { return nil }
        guard let outcome = store.promoteTabToFavorite(id) else { return nil }
        if case .atCapacity = outcome { return outcome }
        for sibling in siblingSpaceIDs(sharingProfileOf: tab.spaceID) where sibling != tab.spaceID {
            store.addFavorite(url: tab.url, title: tab.displayTitle, in: sibling)
        }
        return outcome
    }

    // Re-resolved by URL within the target Space, not by the id it arrived with — the same URL exists under a different id in every sibling Space, so an id-scoped lookup against spaceID routinely missed and silently did nothing.
    func activateFavorite(_ favorite: Favorite, in spaceID: SpaceID) {
        let localID = store.favorite(favorite.id, in: spaceID)?.id
            ?? store.favorite(matching: favorite.url, in: spaceID)?.id
        guard let localID else {
            openTab(url: favorite.url, in: spaceID)
            return
        }
        scopingActiveSpaceToThisWindow { store.activateFavorite(localID, in: spaceID) }
        if let tabID = store.favorite(localID, in: spaceID)?.liveTabID {
            materializeWebContents(for: tabID, url: favorite.url)
        }
    }

    // MARK: - Live WebContents

    // The browser process only becomes usable at PreMainMessageLoopRun, so makeWebContents can legitimately fail with .engineUnavailable right after engine.start() returns even though the engine is capable milliseconds later.
    // A short-backoff retry turns that race into an invisible delay instead of a permanently blank tab.
    private static let engineUnavailableRetryLimit = 6

    func materializeWebContents(for tabID: TabID, url: URL, retryCount: Int = 0) {
        guard webContents[tabID] == nil else { return }

        #if DEBUG
        if let factory = _test_webContentsFactory {
            let contents = factory(tabID, url)
            adoptWebContents(contents, for: tabID, url: url)
            return
        }
        #endif

        guard let engine else {
            Self.logger.error("Cannot open \(url.absoluteString, privacy: .public): no engine is running.")
            return
        }
        guard let spaceID = state.tabs[tabID]?.spaceID else {
            Self.logger.error("Cannot open \(url.absoluteString, privacy: .public): tab \(tabID, privacy: .public) is not in the store.")
            return
        }
        guard let profile = state.profiles.first(where: { $0.id == profileID(for: spaceID) }) else {
            Self.logger.error("Cannot open \(url.absoluteString, privacy: .public): space \(spaceID, privacy: .public) has no profile.")
            return
        }

        // Not try?: a session/browser that fails to come up is the
        // difference between a working browser and a blank window.
        let session: EngineSession
        let contents: WebContents
        // Non-nil when ContentBlockingRuntime reports the session must wait on an uninstalled decider or uncompiled rule set; makeWebContents is then called with initialURL: nil, deferring the fetch until this resolves.
        var contentBlockingReadiness: Task<Void, Never>?
        do {
            session = try engine.session(
                identifier: profile.sessionIdentifier,
                persistent: profile.isPersistent
            )
            // Boosts before makeWebContents: the engine needs the compiled
            // script in hand before the load starts.
            BoostRuntime.shared.prepareSession(session, env: self)
            // Bound at the same moment for the same reason — a session that
            // gets its filter rules one navigation late serves that
            // navigation's ads. No-op on a backend without .contentBlocking.
            contentBlockingReadiness = ContentBlockingRuntime.shared.prepareSession(session, engine: engine)
            // GitHub Live Folders: the one place a real EngineSession exists to read github.com cookies from; never reached for a non-persistent Profile or ephemeral Space, so Incognito can't hand it a session.
            if profile.isPersistent, let space = state.spaces.first(where: { $0.id == spaceID }), !space.isEphemeral {
                // Assigned here, not at the store's declaration: OrbitTests
                // compiles the store through a symlink and doesn't build ChromiumVersion.swift.
                GitHubLiveFolderStore.browserUserAgent = ChromiumBuild.userAgent
                GitHubLiveFolderStore.shared.activate(space: space, session: session)
                let spaceID = space.id
                GitHubLiveFolderStore.shared.onAutoActivate = { [weak self] in
                    self?.autoActivateGitHubLiveFolder(in: spaceID)
                }
            }
            // Never initialURL: navigation must not start until adoptWebContents registers the tab, or
            // WillCreateURLLoaderFactory fires first and every webRequest event reports tabId -1, which extensions drop.
            contents = try engine.makeWebContents(session: session, initialURL: nil)
        } catch {
            let engineError = error as? EngineError
            if engineError?.code == .engineUnavailable, retryCount < Self.engineUnavailableRetryLimit {
                let delayNanoseconds = UInt64(50_000_000 * (retryCount + 1))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    guard let self, self.state.tabs[tabID] != nil else { return }
                    self.materializeWebContents(for: tabID, url: url, retryCount: retryCount + 1)
                }
                return
            }
            Self.logger.error(
                "Engine failed to open \(url.absoluteString, privacy: .public) after \(retryCount, privacy: .public) retries: \(String(describing: error), privacy: .public)"
            )
            return
        }

        adoptWebContents(contents, for: tabID, url: url)

        // Deferred until content blocking is ready. `navigationGeneration` is captured before the wait and compared after: a mismatch means the user navigated meanwhile and that wins, otherwise this would snap the tab back to the original `url`.
        if let contentBlockingReadiness {
            let expectedGeneration = navigationGeneration[tabID, default: 0]
            Task { @MainActor [weak self, weak contents] in
                await contentBlockingReadiness.value
                guard let contents, !contents.isClosed else { return }
                guard let self, self.navigationGeneration[tabID, default: 0] == expectedGeneration else { return }
                contents.load(url)
            }
        } else {
            contents.load(url)
        }
    }

    // Must go through this, not webContents[tabID]?.load(url) directly: bumping navigationGeneration here lets materializeWebContents's deferred content-blocking load detect it's been superseded.
    // Also handles the no-renderer case, where a bare .load(url) would silently discard the navigation.
    func loadInTab(_ tabID: TabID, url: URL) {
        navigationGeneration[tabID, default: 0] += 1

        // Rewritten only for a blank pane or a tab with no renderer, whose
        // stored URL is stale by definition — a tab with a live renderer
        // follows the real navigation through webContentsDidChangeNavigationState instead.
        if var tab = state.tabs[tabID], tab.url != url {
            let isBlankPane: Bool
            if case .newTab = OrbitScheme.parse(tab.url) { isBlankPane = true } else { isBlankPane = false }
            if isBlankPane || webContents[tabID] == nil {
                tab.url = url
                state.tabs[tabID] = tab
            }
        }

        guard webContents[tabID] != nil else {
            materializeWebContents(for: tabID, url: url)
            return
        }
        // Deliberately still this exact optional chain after the generation
        // bump — a test asserts that ordering by reading this function's
        // source text, so rewriting the call shape would silently retire the guard.
        webContents[tabID]?.load(url)
    }

    // Factored out of materializeWebContents so the #if DEBUG test seam
    // cannot drift from production: a test that substitutes the engine call
    // still exercises the delegate wiring, mirrored state, zoom restore and unloaded-flag clear.
    private func adoptWebContents(_ contents: any WebContents, for tabID: TabID, url: URL) {
        contents.delegate = self
        webContents[tabID] = contents
        navigationStates[tabID] = contents.navigationState
        mediaStates[tabID] = contents.mediaState
        store.setMediaState(contents.mediaState, forTab: tabID)
        applyStoredZoomFactor(to: contents, tabID: tabID, url: url)
        applyStoredMuteState(to: contents, tabID: tabID)
        // Lives here, the single funnel every materialisation passes
        // through, so no future call site can bring a tab back to life while leaving it flagged unloaded.
        store.setRendererLive(tabID, true)
        contents.setPreferredColorScheme(AppearanceSettings.shared.engineColorScheme)
        // After adoption, never before, so the tab the user just asked for
        // is itself protected and can never be the one this frees.
        enforceLiveRendererBudget()
        registerChromiumTab(tabID)
    }

    // MARK: - chrome.tabs / chrome.windows push

    // What syncChromiumActiveTab last told OrbitTabRegistry, so a repeated
    // call is free and so the tab being deactivated can be named.
    private var lastPushedActiveTabID: TabID?

    // No-op for a non-Chromium WebContents or an extension popup/options page, neither of which
    // is adopted through this funnel. Module-internal: AppEnvironment+TearOff.swift reuses it too.
    func registerChromiumTab(_ tabID: TabID) {
        guard let contents = webContents[tabID] as? ChromiumWebContents else { return }
        guard let tab = state.tabs[tabID] else { return }
        let isActive = activeTabID == tabID
        OrbitChromiumTabsBridge.shared.tabCreated(
            tabUUID: tabID, handle: contents.chromiumHandle, windowOwner: self,
            index: chromiumTabIndex(for: tab), active: isActive, pinned: tab.section == .pinned
        )
        // Not short-circuited for isActive: OnTabCreated fires no chrome.tabs.onActivated, which a
        // foreground new tab owes its listeners. syncChromiumActiveTab is the one authority for that state.
        syncChromiumActiveTab()
        // The insert shifted every later sibling's position too.
        pushChromiumTabIndexes()
    }

    // Chrome guarantees pinned tabs lead the strip; Orbit flattens to each Space's pinned tree
    // then its Today list, in Space order. Tabs with no live renderer take up no index at all.
    private func chromiumWindowTabOrder() -> [TabID] {
        state.spaces.flatMap { pinnedNodes(in: $0.id).flatMap(\.allTabIDs) + $0.today }
    }

    func chromiumTabIndex(for tabID: TabID) -> Int {
        var index = 0
        for candidate in chromiumWindowTabOrder() {
            if candidate == tabID { return index }
            if webContents[candidate] is ChromiumWebContents { index += 1 }
        }
        return index
    }

    private func chromiumTabIndex(for tab: Tab) -> Int {
        chromiumTabIndex(for: tab.id)
    }

    // Pushes every registered tab's position: Chrome fires no event for a tab merely displaced
    // by a sibling's insert/close/pin/move, though its index does change — without this it goes stale.
    func pushChromiumTabIndexes() {
        var index = 0
        for tabID in chromiumWindowTabOrder() {
            guard webContents[tabID] is ChromiumWebContents else { continue }
            OrbitChromiumTabsBridge.shared.tabIndexChanged(tabUUID: tabID, index: index)
            index += 1
        }
    }

    // The one place chrome.tabs is told the active tab — every path that changes it must call
    // this, not just openTab/activateTab, or extensions reading it get a wrong answer. Idempotent.
    func syncChromiumActiveTab() {
        let current = activeTabID
        guard current != lastPushedActiveTabID else { return }
        // A tab with no live renderer is not in OrbitTabRegistry, so it cannot
        // be named as active; nil deactivates instead, and it stays unrecorded
        // so registerChromiumTab pushes it properly once it has one.
        let live = current.flatMap { webContents[$0] is ChromiumWebContents ? $0 : nil }
        let previous = lastPushedActiveTabID
        guard live != nil || previous != nil else { return }
        lastPushedActiveTabID = live
        OrbitChromiumTabsBridge.shared.activeTabChanged(
            tabUUID: live, windowOwner: self, previousTabUUID: previous
        )
    }

    // Module-internal, not private: AppEnvironment+SidebarTree.swift's own
    // pin/unpin(_:toParent:...) also need to push this.
    func pushChromiumTabPinnedChanged(_ id: TabID) {
        guard webContents[id] is ChromiumWebContents, let tab = state.tabs[id] else { return }
        OrbitChromiumTabsBridge.shared.tabPinnedChanged(tabUUID: id, pinned: tab.section == .pinned)
        // Pinning moves the tab between the two halves of the strip, so both
        // it and everything it stepped over has a new index.
        pushChromiumTabIndexes()
    }

    // Called after a reorder has already happened; recomputes the tab's own
    // new index rather than trusting a caller-supplied one, since
    // store.reorderTab is free to clamp/adjust it.
    func pushChromiumTabMoved(_ id: TabID, fromIndex: Int) {
        guard webContents[id] is ChromiumWebContents, let tab = state.tabs[id] else { return }
        let toIndex = chromiumTabIndex(for: tab)
        guard toIndex != fromIndex else { return }
        OrbitChromiumTabsBridge.shared.tabMoved(tabUUID: id, windowOwner: self, fromIndex: fromIndex, toIndex: toIndex)
        pushChromiumTabIndexes()
    }

    // MARK: - Extension-adopted tabs

    // handle's native WebContents is already built by OrbitExtensionHostDelegate::CreateTab.
    // Wraps it through the same funnel as any tab; nil means declined, and the caller must destroy handle.
    @discardableResult
    func adoptExtensionTab(handle: UnsafeMutableRawPointer, url: URL, active: Bool) -> TabID? {
        guard let spaceID = activeSpace?.id, let engine else { return nil }
        guard let contents = try? ChromiumWebContents(adopting: handle, session: engine.defaultSession) else {
            return nil
        }
        let tabID = scopingActiveSpaceToThisWindow {
            store.openTab(url: url, in: spaceID, section: .today, activate: active)
        }
        adoptWebContents(contents, for: tabID, url: url)
        if active {
            webContents[tabID]?.focus()
        }
        recordVisit(url: url, title: "", profileID: profileID(for: spaceID), spaceID: spaceID)
        return tabID
    }

    // MARK: - Page-created windows

    // A page's own window.open(), whose WebContents the engine already built and started navigating.
    // Adopting it, not reloading fresh, keeps window.opener and the navigation in flight — reloading breaks OAuth/checkout popups.
    @discardableResult
    func adoptPageCreatedTab(_ contents: any WebContents, url: URL, in spaceID: SpaceID, activate: Bool) -> TabID {
        let tabID = scopingActiveSpaceToThisWindow {
            store.openTab(url: url, in: spaceID, section: .today, activate: activate)
        }
        adoptWebContents(contents, for: tabID, url: url)
        if activate {
            webContents[tabID]?.focus()
        }
        recordVisit(url: url, title: "", profileID: profileID(for: spaceID), spaceID: spaceID)
        syncChromiumActiveTab()
        return tabID
    }

    // The same adoption for a request asking for its own window — a detached tab hosted by
    // LittleOrbitWindowController. Mirrors makeDetachedTab(url:) minus the materialisation already done.
    @discardableResult
    func adoptPageCreatedDetachedTab(_ contents: any WebContents, url: URL) -> TabID {
        let spaceID = activeSpace?.id ?? state.spaces.first?.id ?? UUID()
        let tab = Tab(spaceID: spaceID, section: .today, url: url)
        state.tabs[tab.id] = tab
        adoptWebContents(contents, for: tab.id, url: url)
        recordVisit(url: url, title: "", profileID: space(spaceID)?.profileID ?? state.profiles.first?.id ?? UUID())
        return tab.id
    }

    // MARK: - Content appearance

    func applyContentAppearanceToLiveTabs() {
        let scheme = AppearanceSettings.shared.engineColorScheme
        for contents in webContents.values where !contents.isClosed {
            contents.setPreferredColorScheme(scheme)
        }
    }

    // processRoot is included explicitly and de-duplicated by identity: it
    // is not one of the open windows' environments when every browser window
    // is closed and only a Library or Settings window is up.
    static func applyContentAppearanceEverywhere() {
        var seen: [AppEnvironment] = []
        for environment in [processRoot] + OrbitWindowController.openEnvironments
        where !seen.contains(where: { $0 === environment }) {
            seen.append(environment)
            environment.applyContentAppearanceToLiveTabs()
        }
    }

    // windowClosing threads through to tabRemoved's own OrbitTabsRemoved
    // push -- true only from disposeWindowSession()'s per-tab loop, when the
    // whole window this tab lives in is going away, not merely this one tab.
    func releaseWebContents(for tabID: TabID, windowClosing: Bool = false) {
        // Resumed, never dropped: abandoning strands the task forever. The engine refuses its own half
        // regardless (~OrbitWebContentsHost); must run before .close(), while the decision still belongs to a live tab.
        certificateProblems.removeValue(forKey: tabID)
        refusedCertificateTabIDs.remove(tabID)
        pendingCertificateDecisions.removeValue(forKey: tabID)?.resume(returning: false)
        // Same reason: an install sheet whose tab has gone must not outlive it,
        // and its installer must not be left awaiting a decision.
        clearExtensionInstallState(for: tabID)
        resolveExtensionPermissionsConsent(for: tabID, granted: false)
        // Must run before .close() destroys the native WebContents: OrbitTabRegistry's contract
        // (orbit_tab_registry.h's OrbitTabInfo) requires OrbitTabsRemoved first, or its raw_ptr dangles.
        let wasRegistered = webContents[tabID] is ChromiumWebContents
        if wasRegistered {
            OrbitChromiumTabsBridge.shared.tabRemoved(tabUUID: tabID, windowClosing: windowClosing)
        }
        webContents[tabID]?.close()
        webContents.removeValue(forKey: tabID)
        // After the removal, so the closing tab no longer takes an index off
        // everything that followed it in the strip.
        if wasRegistered {
            pushChromiumTabIndexes()
        }
        // An exemption that outlived its WebContents would keep a tab out of
        // the auto-archive sweep forever, so it's cleared at this single funnel.
        store.clearMediaState(forTab: tabID)
    }

    // The one caller that must not close what it removes: tearing a tab off
    // into its own window hands the same live renderer to a second
    // environment rather than destroying it and forcing a reload.
    func detachWebContents(for tabID: TabID) -> (any WebContents)? {
        guard let contents = webContents[tabID] else { return nil }
        webContents.removeValue(forKey: tabID)
        return contents
    }

    // Does not call materializeWebContents's other setup (zoom restore,
    // content-blocking prep, setRendererLive) — the renderer already went
    // through all of that in its original session.
    func installTransferredWebContents(_ contents: any WebContents, for tabID: TabID) {
        contents.delegate = self
        webContents[tabID] = contents
    }

    #if DEBUG
    var _test_webContentsFactory: ((TabID, URL) -> any WebContents)?
    #endif

    // MARK: - Background tab renderer policy

    // No test asserts this value — tests lower liveRendererBudget instead
    // and assert the behaviour that follows.
    static let defaultLiveRendererBudget = 12

    // var so tests can drive the overflow path — nothing in Orbit/UI writes it, no setting exposes it.
    var liveRendererBudget: Int = AppEnvironment.defaultLiveRendererBudget

    static let rendererReleaseIdleThreshold: TimeInterval = 120

    static let inactivitySuspendThreshold: TimeInterval = 30 * 60

    static let inactivitySweepInterval: TimeInterval = 60

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private var inactivitySweepTask: Task<Void, Never>?

    // Engine-side state beyond what BrowserStore.isEligibleForRendererRelease checks on the Tab: media uses isMediaActive, not isAudible || isPlaying, since both go false on pause and would let a paused-but-active tab's renderer be released.
    var rendererPolicyProtectedTabIDs: Set<TabID> {
        var protected: Set<TabID> = []
        for (tabID, media) in mediaStates
        where media.isMediaActive || media.isPictureInPictureActive || media.isFullscreen {
            protected.insert(tabID)
        }
        for (tabID, navigation) in navigationStates where navigation.isLoading {
            protected.insert(tabID)
        }
        protected.formUnion(pendingCertificateDecisions.keys)
        protected.formUnion(pendingExtensionInstallConsentDecisions.keys)
        protected.formUnion(pendingExtensionPermissionsConsent.keys)
        protected.formUnion(extensionInstallProgress.keys)
        protected.formUnion(extensionInstallOutcomes.keys)
        protected.formUnion(downloadIDByTab.keys)
        return protected
    }

    // Only the engine-owning environment installs a source — a window-scoped
    // one (Incognito) would just run the same kernel-signal pass twice.
    func startBackgroundTabRendererPolicy() {
        guard engineProvider == nil, memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                self.handleMemoryPressure(event)
            }
        }
        memoryPressureSource = source
        source.resume()

        inactivitySweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppEnvironment.inactivitySweepInterval))
                guard !Task.isCancelled else { break }
                self?.runInactivitySweep()
            }
        }
    }

    func stopBackgroundTabRendererPolicy() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        inactivitySweepTask?.cancel()
        inactivitySweepTask = nil
    }

    @discardableResult
    func runInactivitySweep(now: Date = Date()) -> [TabID] {
        releaseBackgroundRenderers(
            .inactivity(after: Self.inactivitySuspendThreshold),
            now: now
        )
    }

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            releaseBackgroundRenderers(.memoryPressureCritical)
        } else if event.contains(.warning) {
            releaseBackgroundRenderers(
                .memoryPressureWarning(idleThreshold: Self.rendererReleaseIdleThreshold)
            )
        }
    }

    @discardableResult
    func releaseBackgroundRenderers(
        _ policy: TabRendererReleasePolicy,
        now: Date = Date()
    ) -> [TabID] {
        let released = store.tabsToReleaseRenderers(
            liveTabIDs: Set(webContents.keys),
            protectedTabIDs: rendererPolicyProtectedTabIDs,
            policy: policy,
            now: now
        )
        guard !released.isEmpty else { return [] }

        for tabID in released {
            releaseWebContents(for: tabID)
            store.setRendererLive(tabID, false)
            navigationStates.removeValue(forKey: tabID)
            mediaStates.removeValue(forKey: tabID)
            findResultsByTab.removeValue(forKey: tabID)
            tabErrors.removeValue(forKey: tabID)
            crashedTabs.remove(tabID)
            unresponsiveTabs.remove(tabID)
            // themeColors is deliberately kept: it's a property of the page,
            // not the renderer — dropping it would flash the header to neutral and back on reselect.
        }
        return released
    }

    private func enforceLiveRendererBudget() {
        let overshoot = webContents.count - liveRendererBudget
        guard overshoot > 0 else { return }
        releaseBackgroundRenderers(
            .budgetOvershoot(overshoot, idleThreshold: Self.rendererReleaseIdleThreshold)
        )
    }

    // MARK: - Restore Data

    func availableStateBackups() -> [StateBackup] { store.availableBackups() }

    // Every live WebContents is released, not only the ones whose tab
    // vanished — a surviving tab id can be sitting on a different URL in the
    // restored document than the renderer currently on screen shows.
    @discardableResult
    func restoreData(from backup: StateBackup, scope: RestoreDataScope = .sidebar) throws -> RestoreOutcome {
        let outcome = try store.restore(from: backup, scope: scope)
        for tabID in Array(webContents.keys) {
            releaseWebContents(for: tabID)
        }
        navigationStates.removeAll()
        mediaStates.removeAll()
        themeColors.removeAll()
        documentColors.removeAll()
        tabErrors.removeAll()
        crashedTabs.removeAll()
        unresponsiveTabs.removeAll()
        findResultsByTab.removeAll()
        materializeActiveTabIfNeeded()
        return outcome
    }

    // contents.id (the backend's own freshly generated UUID) is NOT Tab.id
    // anywhere in this codebase — resolves the real id via a reverse lookup
    // by reference identity instead. Every WebContentsDelegate callback must use this, not contents.id.
    func tabID(for contents: WebContents) -> TabID? {
        webContents.first { $0.value === contents }?.key
    }

    #if DEBUG
    // MARK: - Test seam

    func _test_attachWebContents(_ contents: WebContents, for tabID: TabID) {
        webContents[tabID] = contents
        navigationStates[tabID] = contents.navigationState
        mediaStates[tabID] = contents.mediaState
    }

    func _test_detachWebContents(for tabID: TabID) {
        webContents.removeValue(forKey: tabID)
    }
    #endif

    // MARK: - History

    func recordVisit(url: URL, title: String, profileID: ProfileID, spaceID: SpaceID? = nil, wasTyped: Bool = false) {
        guard let historyStore else { return }
        // Incognito leaves no history — checked here, the single funnel
        // every recorded visit passes through, so a future caller cannot forget the rule.
        guard !isPrivateBrowsingContext(spaceID: spaceID, profileID: profileID) else { return }
        let visit = HistoryVisit(url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: wasTyped)
        Task {
            _ = try? await historyStore.record(visit: visit)
            await refreshHistoryCache()
        }
    }

    private func refreshHistoryCache(query: String = "") async {
        guard let historyStore else { return }
        // A failed refresh leaves the previous cache alone, not [] — stale
        // rows are strictly better than dropped ones for a Command Bar
        // reading this cache on every keystroke.
        guard let found = try? await historyStore.search(query, limit: 500) else { return }
        localHistoryCache = found
    }

    // historyStore, localHistoryCache and the search mirrors are all private to
    // this file, so the Data Reset layer clears them through here.
    func clearAllHistory() async -> Bool {
        guard let historyStore else { return false }
        do {
            try await historyStore.clear(since: nil)
        } catch {
            return false
        }
        localHistoryCache = []
        historySearchQuery = ""
        historySearchResults = []
        return true
    }

    // BrowserImportCoordinator writes to HistoryStore directly (it records
    // original timestamps, which recordVisit has no parameter for) — without
    // this, imported pages are invisible to Cmd+T until visited again.
    func reloadHistoryCacheAfterBulkImport() async {
        await refreshHistoryCache()
    }

    func prepareHistorySearch(for query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            historySearchQuery = ""
            historySearchResults = []
            return
        }
        guard trimmed != historySearchQuery else { return }
        guard let historyStore else { return }
        let found = (try? await historyStore.search(trimmed, limit: 60)) ?? []
        // The query may have moved on while the store was answering; a stale
        // result set attributed to the current query would be worse than none.
        guard !Task.isCancelled else { return }
        historySearchQuery = trimmed
        historySearchResults = found
    }

    func historyResults(matching query: String, limit: Int = 50) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(localHistoryCache.prefix(limit)) }

        return Self.blendHistory(
            indexed: historySearchQuery == trimmed ? historySearchResults : [],
            cached: localHistoryCache,
            matching: trimmed,
            limit: limit
        )
    }

    // Both sources are filtered here, not just the recency cache: a HistoryStore.search result reflects the row's state when indexed, not now, so an unmatched row must be dropped rather than ranked on stale frecency.
    nonisolated static func blendHistory(
        indexed: [HistoryEntry],
        cached: [HistoryEntry],
        matching query: String,
        limit: Int
    ) -> [HistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        var seen = Set<String>()
        var results: [HistoryEntry] = []

        func take(_ entry: HistoryEntry) {
            guard results.count < limit else { return }
            guard historyEntryMatches(entry, terms: terms) else { return }
            guard seen.insert(entry.url.absoluteString.lowercased()).inserted else { return }
            results.append(entry)
        }

        indexed.forEach(take)
        cached.forEach(take)
        return results
    }

    nonisolated static func historyEntryMatches(_ entry: HistoryEntry, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystacks = [entry.title.lowercased(), entry.url.absoluteString.lowercased()]
        return terms.allSatisfy { term in haystacks.contains { $0.contains(term) } }
    }

    func historyEntries(in range: ClosedRange<Date>, limit: Int = 2000) async -> [HistoryEntry] {
        guard let historyStore else { return [] }
        return (try? await historyStore.entries(in: range, limit: limit)) ?? []
    }

    // MARK: - Downloads

    func addDownload(id: UUID = UUID(), sourceURL: URL, destinationURL: URL, suggestedFileName: String, mimeType: String, totalBytes: Int64) -> DownloadItem {
        downloadStore.beginDownload(id: id, sourceURL: sourceURL, destinationURL: destinationURL, suggestedFileName: suggestedFileName, mimeType: mimeType, totalBytes: totalBytes)
    }

    func updateDownload(id: UUID, progress: DownloadProgress) {
        downloadStore.updateProgress(id: id, progress: progress)
    }

    // Tells the engine, not just the local record, or the transfer keeps running underneath a UI that shows it cancelled; reaches every tab's WebContents rather than downloadIDByTab, which remembers only the most recent download per tab.
    func cancelDownload(_ id: UUID) {
        downloadStore.cancel(id)
        for contents in webContents.values {
            contents.cancelDownload(id: id)
        }
    }

    var recentDownloads: [DownloadItem] { Array(downloadStore.downloads.prefix(6)) }
}
