import AppKit
import Foundation
import OSLog
import Observation
import SwiftUI
import WebKit

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

    // Tabs whose current pause came from Orbit's own controls (the mini player, or the picture-in-picture
    // window). Only those keep a mini player row while paused; a pause made on the page itself drops it.
    // See MiniPlayerVisibility for the rule and AppEnvironment+Media for where it is set.
    var orbitPausedMediaTabIDs: Set<TabID> = []

    // MARK: - Background tab notice

    /// Set when a link opens in a background tab; see AppEnvironment+BackgroundTabNotice.swift.
    var backgroundTabNotice: BackgroundTabNotice?
    // Not observed: it only lets a notice's own dismissal timer tell it has been replaced.
    @ObservationIgnored var backgroundTabNoticeGeneration = 0

    // MARK: - Live web contents, keyed by Tab.id

    private(set) var webContents: [TabID: any WebContents] = [:]
    @ObservationIgnored private var tabIDsByContents: [ObjectIdentifier: TabID] = [:]

    // Bumped by loadInTab(_:url:) so materializeWebContents's deferred content-blocking load can tell it has been superseded.
    // Module-internal, not private: AppEnvironment+TearOff.swift reaches into another environment's copy when a tab is torn off.
    var navigationGeneration: [TabID: Int] = [:]

    // MARK: - Reactive mirrors of engine-owned, non-Observable state

    // Keys change only when a renderer is adopted, released or reset; per-tab updates go through the box,
    // so one tab's progress tick invalidates only views reading that tab. Values: navigationStates.
    var navigationBoxes: [TabID: NavigationBox] = [:]
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
        WebKitExtensionPermissionConsent.shared.answer(requestID: request.requestID, approved: granted)
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

    // MARK: - New Tab page bookkeeping

    @ObservationIgnored var lastObservedActiveTabID: TabID?

    // MARK: - Find bar

    var isFindBarPresented: Bool = false
    var findBarFocusRequest = UUID()
    var findQuery: String = ""
    var currentFindResult: FindResult = .none

    // MARK: - Split focus

    /// The focused pane is the one holding the active tab, so the sidebar's highlight and the pane's border cannot disagree. Setting it selects that pane's tab.
    var focusedSplitPaneIndex: Int {
        get {
            guard let active = activeTabID, let group = splitGroup(for: active) else { return 0 }
            return group.tabIDs.firstIndex(of: active) ?? 0
        }
        set {
            guard let group = activeSplitGroup, group.tabIDs.indices.contains(newValue) else { return }
            let target = group.tabIDs[newValue]
            guard activeTabID != target else { return }
            activeTabID = target
            syncExtensionActiveTab()
        }
    }
    var activeSplitDropZone: SplitDropZone?
    /// The motion of a pane arriving in a split: which pane, from which edge, and how far along it is (0 as it starts, 1 when it has landed). Nil when nothing is arriving.
    var splitMotion: SplitMotion?

    // .zero until the first layout pass, which preferredSplitOrientation(paneCount:) handles explicitly.
    var contentAreaSize: CGSize = .zero

    // MARK: - Site Control popover

    // An optional TabID, not a Bool: more than one pane can share this
    // environment (a split, or a Little Orbit window), so this names which one's popover is open.
    var siteControlPresentedTabID: TabID?

    // Set by _execute_action, which must open the extension's own popup rather
    // than merely the Site Control popover that hosts it; cleared once opened.
    var pendingExtensionActionID: String?

    // MARK: - Settings / About / Onboarding windows

    var settingsWindowController: NSWindowController?
    var aboutWindowController: NSWindowController?
    var hasCompletedOnboarding: Bool {
        get { AppEnvironment.defaults.bool(forKey: Keys.onboardingComplete) }
        set { AppEnvironment.defaults.set(newValue, forKey: Keys.onboardingComplete) }
    }

    // MARK: - History

    // The cache is held as prepared entries (search text lowercased once, here, when an entry
    // enters it) so a keystroke never re-lowercases hundreds of titles and URLs.
    // localHistoryCache is the plain view of it.
    private var historyIndex: [PreparedHistoryEntry] = []

    // Bumped on every change to historyIndex, so views can memoise work derived from the cache.
    private(set) var historyCacheVersion = 0

    private(set) var localHistoryCache: [HistoryEntry] {
        get { historyIndex.map(\.entry) }
        set { setHistoryIndex(newValue.map(PreparedHistoryEntry.init)) }
    }

    // localHistoryCache alone cannot answer a typed query — it holds only
    // the 500 most recent entries, so anything older needs HistoryStore's
    // own FTS index and frecency ranking consulted directly.
    private(set) var historySearchQuery: String = ""
    private var historySearchIndex: [PreparedHistoryEntry] = []

    // Bumped when prepareHistorySearch changes what historyResults would return for the
    // current query, so the Command Bar re-scores only when the search brought something new.
    private(set) var historySearchEpoch = 0

    private(set) var historySearchResults: [HistoryEntry] {
        get { historySearchIndex.map(\.entry) }
        set { historySearchIndex = newValue.map(PreparedHistoryEntry.init) }
    }

    // Visits folded into the cache one at a time since its last full reload; the incremental
    // order only approximates the store's frecency order, so a full reload runs periodically.
    @ObservationIgnored private var historyUpsertsSinceReload = 0
    private static let historyCacheCapacity = 500
    private static let historyUpsertsBetweenReloads = 40

    // MARK: - Tab census

    // Excludes archived tabs — counting them would make "Warn before
    // quitting" fire on a session with nothing open in it.
    var openTabCount: Int {
        state.tabs.values.filter { $0.section != .archived }.count
    }

    // MARK: - Downloads

    var downloads: [DownloadItem] { downloadStore.downloads }

    var libraryDownloads: [DownloadItem] { downloadStore.allDownloads }

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
            downloadStore: DownloadStore(indexedFolder: WebKitDownloads.downloadsDirectory),
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
            // start() activates CloudKit and reconciles the whole store; neither is needed to show the first page.
            // start() ends in a full reconcile, so edits made before it runs are still pushed.
            Task { @MainActor in
                await LaunchGate.shared.waitForFirstCommit(timeout: .seconds(3))
                engine.start()
            }
        } else {
            self.syncEngine = nil
        }

        store.onTabsAutoArchived = { [weak self] tabIDs in
            guard let self else { return }
            for tabID in tabIDs { self.releaseWebContents(for: tabID) }
        }

        Task { await refreshHistoryCache() }
    }

    // MARK: - Demo factory

    // Scratch rooting here covers only the stores this type owns. Cookies, cache,
    // and local storage live in the WebKit data store. startEngineIfNeeded()
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
    static func makeWindowScoped(
        sharing host: AppEnvironment,
        activeSpaceID: SpaceID,
        isTornOff: Bool = false,
        isIndependentStandardWindow: Bool = false
    ) -> AppEnvironment {
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
        env.isIndependentStandardWindow = isIndependentStandardWindow
        if isIndependentStandardWindow {
            // Chrome that belongs to the user's layout, not to this window's own state.
            env.isSidebarVisible = root.isSidebarVisible
            env.sidebarWidth = root.sidebarWidth
        }
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

        removeAllNavigationStates()
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
        orbitPausedMediaTabIDs.removeAll()
        hoveredLinkURL = nil
        hoveredSidebarTabID = nil
        isCommandBarPresented = false
        isFindBarPresented = false
        siteControlPresentedTabID = nil
        pendingExtensionActionID = nil
        findQuery = ""
        currentFindResult = .none
        windowActiveSpaceID = nil
        windowActiveTabBySpace.removeAll()
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
        // Deliberately no guard !isDemo — the Orbit Demo app starts the real engine too. Queued first on both paths, before anything can call materializeWebContents, so the cache parse is already running when that function returns and waits on it. Idempotent. The head start disappears if materializeWebContents does unrelated synchronous work before returning.
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
            materializeWhenChromiumSiteDataIsReady()
            return
        }
        guard ownEngine == nil else { return }
        // .isolated, not .ephemeral: ephemeral loads no extensions and reads as incognito, so the Web
        // Store refuses installs. XCTest and the smoke probe both need this or they'd hit the real profile.
        let needsPrivateProfile = isDemo || DebugFlags.isRunningUnderTests || DebugFlags.isRunningSmokeProbe
        ownEngine = EngineFactory.makeEngine(storage: needsPrivateProfile ? .isolated : .persistent)
        startBackgroundTabRendererPolicy()
        materializeWhenChromiumSiteDataIsReady()
    }

    /// The Chromium jar is copied before the first navigation, so the page that opens is already signed in.
    private func materializeWhenChromiumSiteDataIsReady() {
        guard let engine = engine as? WebKitEngine, engine.isMigratingChromiumSiteData else {
            materializeActiveTabIfNeeded()
            return
        }
        Task { @MainActor in
            await engine.preparePersistentSiteData()
            self.materializeActiveTabIfNeeded()
        }
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
        guard let tab = activeTab(in: spaceID) else { return }
        materializeWebContents(for: tab.id, url: tab.url, isWake: true)
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

    // MARK: - Per-window active tab
    // The first window follows the document's own active tab. Every further ordinary window is independent: it reads the same
    // tabs and Spaces but keeps its own selection here, so two windows can show two different pages and choosing a tab in one
    // never moves the other.

    private(set) var isIndependentStandardWindow: Bool = false

    private(set) var windowActiveTabBySpace: [SpaceID: TabID] = [:]

    /// The tab this independent window shows in a Space, or nil when it has none or the one it had is closed or moved.
    private func independentActiveTabID(in spaceID: SpaceID) -> TabID? {
        guard let id = windowActiveTabBySpace[spaceID], let tab = store.tab(id),
              tab.spaceID == spaceID, tab.section != .archived else { return nil }
        return tab.id
    }

    /// The tab this window shows in the Space: its own selection when independent, the document's otherwise.
    func activeTab(in spaceID: SpaceID) -> Tab? {
        guard isIndependentStandardWindow else { return store.activeTab(in: spaceID) }
        return independentActiveTabID(in: spaceID).flatMap { store.tab($0) }
    }

    /// Whether this window is showing the tab, as the active tab or a pane of the active split.
    func isDisplaying(_ tabID: TabID) -> Bool {
        guard let tab = store.tab(tabID), activeSpace?.id == tab.spaceID, let active = activeTabID else { return false }
        if active == tabID { return true }
        return splitGroup(for: active)?.tabIDs.contains(tabID) == true
    }

    /// Another open window that is showing the tab right now. A tab can be on screen in one window only.
    func otherEnvironmentDisplaying(_ tabID: TabID) -> AppEnvironment? {
        OrbitWindowController.openEnvironments.first { $0 !== self && $0.isDisplaying(tabID) }
    }

    /// An environment, other than this one, that holds the tab's live page: another window's, or the process root's when its window is gone.
    private func otherEnvironmentHolding(_ tabID: TabID) -> AppEnvironment? {
        let candidates = OrbitWindowController.openEnvironments + [rootEnvironment]
        return candidates.first { $0 !== self && $0.webContents[tabID] != nil && !$0.isDisplaying(tabID) }
    }

    /// Every other environment holding the tab's live page, whether or not it shows it, so a close from any window ends it.
    private func otherEnvironmentsHoldingPage(_ tabID: TabID) -> [AppEnvironment] {
        var holders: [AppEnvironment] = []
        for candidate in OrbitWindowController.openEnvironments + [rootEnvironment]
        where candidate !== self && candidate.webContents[tabID] != nil && !holders.contains(where: { $0 === candidate }) {
            holders.append(candidate)
        }
        return holders
    }

    /// For an independent window about to lose its active tab, the tab beside it to move to, never one another window is showing.
    func successorBeforeClosing(_ id: TabID, in spaceID: SpaceID?) -> TabID? {
        guard isIndependentStandardWindow, let spaceID, activeTabID == id else { return nil }
        let order = todayTabs(in: spaceID).map(\.id)
        guard let index = order.firstIndex(of: id) else { return nil }
        let nearest = order.indices.filter { $0 != index }.sorted { abs($0 - index) < abs($1 - index) }
        return nearest.map { order[$0] }.first { otherEnvironmentDisplaying($0) == nil }
    }

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
    func pushSearchSuggestPreferenceToEngine() {}

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
    func selectSpace(_ id: SpaceID, animated: Bool = true) {
        animatingSpaceSwitch(animated) {
            guard isWindowScoped else {
                store.switchToSpace(id)
                return
            }
            guard store.space(id) != nil else { return }
            windowActiveSpaceID = id
        }
        materializeActiveTabIfNeeded()
        syncExtensionActiveTab()
    }

    // The one place a Space switch gets its theme crossfade; the swipe settle passes animated: false.
    private func animatingSpaceSwitch(_ animated: Bool, _ change: () -> Void) {
        guard animated else {
            change()
            return
        }
        withAnimation(OrbitThemeMotion.animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            change()
        }
    }

    func nextSpace() { stepSpace(offset: 1) }
    func previousSpace() { stepSpace(offset: -1) }

    // Must walk pagerSpaces, never the document's full spaces list — stepping through the full list could step an Incognito or torn-off window onto a Space belonging to a different, persistent window and show that window's own tab, live.
    private func stepSpace(offset: Int) {
        guard isWindowScoped else {
            animatingSpaceSwitch(true) {
                if offset > 0 { store.nextSpace() } else { store.previousSpace() }
            }
            materializeActiveTabIfNeeded()
            syncExtensionActiveTab()
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
        let documentActiveTabs = state.activeTabBySpace
        let result = mutation()
        if let moved = state.activeSpaceID, moved != documentActiveSpaceID {
            windowActiveSpaceID = moved
        }
        if state.activeSpaceID != documentActiveSpaceID {
            state.activeSpaceID = documentActiveSpaceID
        }
        if isIndependentStandardWindow {
            // The store moves the document's active tab for the Space. That pointer is the first window's, so this
            // window keeps the new selection for itself and the document's is put back.
            for (spaceID, tabID) in state.activeTabBySpace where documentActiveTabs[spaceID] != tabID {
                windowActiveTabBySpace[spaceID] = tabID
                if let previous = documentActiveTabs[spaceID] {
                    state.activeTabBySpace[spaceID] = previous
                } else {
                    state.activeTabBySpace.removeValue(forKey: spaceID)
                }
            }
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
    func deleteSpace(_ id: SpaceID) {
        guard spaces.count > 1, space(id) != nil else { return }
        for tabID in state.tabs.values.filter({ $0.spaceID == id }).map(\.id) {
            releaseWebContents(for: tabID)
        }
        store.deleteSpace(id)
    }
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
            if isIndependentStandardWindow { return independentActiveTabID(in: spaceID) }
            return state.activeTabBySpace[spaceID]
        }
        set {
            guard let spaceID = resolvedActiveSpaceID else { return }
            if isIndependentStandardWindow {
                windowActiveTabBySpace[spaceID] = newValue
            } else {
                state.activeTabBySpace[spaceID] = newValue
            }
        }
    }

    var activeTab: Tab? {
        guard let spaceID = resolvedActiveSpaceID else { return nil }
        return activeTab(in: spaceID)
    }

    func todayTabs(in spaceID: SpaceID) -> [Tab] { store.todayTabs(in: spaceID) }

    func pinnedNodes(in spaceID: SpaceID) -> [SidebarNode] { store.pinnedNodes(in: spaceID) }

    @discardableResult
    func openTab(url: URL, in spaceID: SpaceID, section: TabSection = .today, activate: Bool = true, siteProfileID: SiteProfileID? = nil) -> TabID {
        let tabID = scopingActiveSpaceToThisWindow {
            store.openTab(url: url, in: spaceID, section: section, activate: activate)
        }
        if let siteProfileID { _ = store.setSiteProfile(siteProfileID, forTab: tabID) }
        // No visit is recorded here: the page's own commit records it, with its final address and its own title. A visit
        // recorded before the load kept the address as it was asked for (before any redirect) and an empty title.
        materializeWebContents(for: tabID, url: url)
        syncExtensionActiveTab()
        return tabID
    }

    /// The store moves the document's pointers only when the tab chosen differs from the one they already name, and the window scoping above copies a selection only from such a change. Choosing the tab the document already holds therefore never reached a window of its own, which kept showing the split it was on.
    private func claimSelectionForThisWindow(_ id: TabID) {
        guard isWindowScoped, let tab = store.tab(id) else { return }
        if windowActiveSpaceID != tab.spaceID { windowActiveSpaceID = tab.spaceID }
        if isIndependentStandardWindow, windowActiveTabBySpace[tab.spaceID] != id {
            windowActiveTabBySpace[tab.spaceID] = id
        }
    }

    func activateTab(_ id: TabID) {
        guard let tab = store.tab(id) else { return }
        // A page is on screen in one window only; asking for it here brings that window forward instead of
        // taking the page from it or showing it twice.
        if let owner = otherEnvironmentDisplaying(id) {
            Self.logger.info("a tab was chosen but another window shows it, so that window was brought forward instead")
            OrbitWindowController.window(for: owner)?.makeKeyAndOrderFront(nil)
            return
        }
        store.selectTab(id, updatingActiveTab: !isIndependentStandardWindow, updatingActiveSpace: !isWindowScoped)
        claimSelectionForThisWindow(id)
        if activeTabID != id {
            Self.logger.error("a tab was chosen but is not the active tab afterwards: sectionIsArchived=\(tab.section == .archived) spaceMatches=\(tab.spaceID == self.activeSpace?.id)")
        }
        materializeWebContents(for: id, url: tab.url, isWake: true)
        // Selecting the tab is the user asking to see it: a pane left frozen or hidden takes the page back.
        if let contents = webContents[id] { WebContentsPresentation.shared.requestPresentation(of: contents) }
        syncExtensionActiveTab()
        // Must move AppKit's real first responder, not just the visual highlight, guarded against the Command Bar/Find bar so a tab activation racing one of them never steals focus from a live text field.
        guard !isCommandBarPresented, !isFindBarPresented else { return }
        webContents[id]?.focus()
    }

    /// Builds a released tab's renderer ahead of the click that will open it. Does nothing the click would not do: a tab with a live page, one already shown in another window, or an archived one (which selecting restores first) is left alone.
    func prefetchRenderer(for id: TabID) {
        guard webContents[id] == nil,
              let tab = store.tab(id), tab.section != .archived,
              otherEnvironmentDisplaying(id) == nil else { return }
        materializeWebContents(for: id, url: tab.url, isWake: true)
    }

    func closeTab(_ id: TabID, destroyRenderer: Bool = true) {
        let spaceID = store.tab(id)?.spaceID
        let successor = successorBeforeClosing(id, in: spaceID)
        releaseWebContents(for: id, destroyRenderer: destroyRenderer)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.closeTab(id)
        // BrowserStore's successor has no live renderer yet, so activateTab materialises it and pushes
        // the activation through syncExtensionActiveTab — same as closeTabKeepingBookmark/removeBookmark.
        if let spaceID, let nowActive = activeTab(in: spaceID)?.id {
            if nowActive != id {
                activateTab(nowActive)
            } else if let survivor = store.tab(id) {
                // Closing a pinned tab unpins it, and with nothing else open it stays on screen — it needs the renderer back that was released above.
                materializeWebContents(for: id, url: survivor.url, isWake: true)
            }
        } else if let successor {
            activateTab(successor)
        }
        syncExtensionActiveTab()
    }

    // Every user-facing close verb funnels through here so a bookmarked tab closes by the same rule as the minus beside its row, rather than being silently unpinned.
    func closeTabPreservingBookmark(_ id: TabID, destroyRenderer: Bool = true) {
        guard store.tab(id)?.section == .pinned else { return closeTab(id, destroyRenderer: destroyRenderer) }
        closeTabKeepingBookmark(id, destroyRenderer: destroyRenderer)
    }

    func reopenLastClosedTab() {
        let reopening = store.recentlyClosedRecords.last?.tabID
        scopingActiveSpaceToThisWindow { store.reopenLastClosedTab() }
        if let reopening, activeTabID == reopening {
            activateTab(reopening)
        }
        syncExtensionActiveTab()
    }

    /// A tab can reach the screen through a path that never called activateTab (a store fallback, sync, a Space switch); the pane calls this so it still gets a page.
    func materializeDisplayedTab(_ tabID: TabID, shownInOwnWindow: Bool = false) {
        guard webContents[tabID] == nil, shownInOwnWindow || isDisplaying(tabID), otherEnvironmentDisplaying(tabID) == nil,
              let tab = store.tab(tabID) else { return }
        materializeWebContents(for: tabID, url: tab.url, isWake: true)
        syncExtensionActiveTab()
    }

    /// With no renderer there is nothing to reload, so the tab's own URL is loaded instead.
    func reloadTab(_ tabID: TabID, ignoringCache: Bool) {
        // Try Again on a failure card loads the page that failed. Reloading the web view would reload whatever it last committed, which after a failed first navigation out of a new tab is the empty new-tab document.
        if let failedURL = tabErrors[tabID]?.url, let contents = webContents[tabID] {
            tabErrors.removeValue(forKey: tabID)
            crashedTabs.remove(tabID)
            WebContentsPresentation.shared.requestPresentation(of: contents)
            loadInTab(tabID, url: failedURL)
            return
        }
        if let contents = webContents[tabID] {
            // A reload the pane cannot show is no reload at all to the user.
            WebContentsPresentation.shared.requestPresentation(of: contents)
            contents.reload(ignoringCache: ignoringCache)
            return
        }
        guard let tab = store.tab(tabID) else { return }
        loadInTab(tabID, url: tab.url)
    }

    // MARK: - Bookmarked (pinned) rows that are also open tabs

    // Reads webContents, not Tab.isUnloaded — that flag is untrustworthy
    // immediately after a relaunch or Restore Data restore, when no tab has a
    // renderer yet. webContents is the thing that actually knows.
    func isTabOpen(_ id: TabID) -> Bool { webContents[id] != nil }

    /// The active tab id the closing verbs below compare against: this window's own selection when independent, the document's otherwise.
    private func activeTabIDForSuccession(in spaceID: SpaceID) -> TabID? {
        isIndependentStandardWindow ? independentActiveTabID(in: spaceID) : state.activeTabBySpace[spaceID]
    }

    // Order matters: a Split View pane is separated out first (closeSplitPane),
    // or it would be left rendering a torn-down WebContents as a blank rectangle.
    func closeTabKeepingBookmark(_ id: TabID, destroyRenderer: Bool = true) {
        guard let tab = store.tab(id), tab.section == .pinned else { return }
        if splitGroup(for: id) != nil { closeSplitPane(id) }
        // "-" puts the pin back as it was saved, so the page it was left on is not kept to be restored when the tab next opens.
        releaseWebContents(for: id, destroyRenderer: destroyRenderer, keepingSessionState: false)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.closeTabKeepingPin(id)
        // Like the document's own pointer, this window's goes empty rather than moving on to a neighbour.
        if windowActiveTabBySpace[tab.spaceID] == id { windowActiveTabBySpace.removeValue(forKey: tab.spaceID) }
        if let nowActive = activeTabIDForSuccession(in: tab.spaceID), nowActive != id {
            activateTab(nowActive)
        }
        syncExtensionActiveTab()
    }

    func removeBookmark(_ id: TabID) {
        guard let tab = store.tab(id), tab.section == .pinned else { return }
        let successor = successorBeforeClosing(id, in: tab.spaceID)
        if splitGroup(for: id) != nil { closeSplitPane(id) }
        releaseWebContents(for: id)
        PaneHeaderColorResolver.shared.forget(tab: id)
        store.removeBookmark(id)
        defer { syncExtensionActiveTab() }
        if let nowActive = activeTabIDForSuccession(in: tab.spaceID), nowActive != id {
            activateTab(nowActive)
        } else if let successor {
            activateTab(successor)
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
        pushExtensionTabPinnedChanged(id)
    }
    func unpinTab(_ id: TabID) {
        store.unpin(id)
        pushExtensionTabPinnedChanged(id)
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
        let successor = successorBeforeClosing(id, in: spaceID)
        store.archiveTab(id)
        releaseWebContents(for: id)
        // Same reasoning as closeTab above: the successor BrowserStore just
        // picked has no live renderer until activateTab materialises it.
        if let spaceID, let nowActive = activeTab(in: spaceID)?.id, nowActive != id {
            activateTab(nowActive)
        } else if let successor {
            activateTab(successor)
        }
        syncExtensionActiveTab()
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

    func profileID(for spaceID: SpaceID) -> ProfileID {
        space(spaceID)?.profileID ?? state.profiles.first?.id ?? UUID()
    }

    // MARK: - Moving tabs between spaces

    func moveTab(_ id: TabID, toSpace destinationSpaceID: SpaceID, section: TabSection = .today) {
        store.moveTab(id, toSpace: destinationSpaceID, section: section)
        syncExtensionActiveTab()
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

    /// `isWake` is a page coming back for a tab that already existed (after its renderer was let go, at launch, or when a pane shows it): it is not a new visit, and its saved session, if any, is restored in place of loading the last address.
    func materializeWebContents(for tabID: TabID, url: URL, retryCount: Int = 0, isWake: Bool = false) {
        guard webContents[tabID] == nil else { return }

        // The tab's page may already be live in another window (it was last used there). Moving that page here keeps its
        // state; building a second one would run the same tab twice.
        if let holder = otherEnvironmentHolding(tabID) {
            adoptWebContents(for: tabID, from: holder)
            return
        }

        #if DEBUG
        if let factory = _test_webContentsFactory {
            _test_materializations.append((tabID, store.siteProfileForSession(of: tabID)?.id))
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

        let siteProfile = store.siteProfileForSession(of: tabID)

        // Not try?: a session/browser that fails to come up is the
        // difference between a working browser and a blank window.
        let session: EngineSession
        let contents: WebContents
        // Non-nil only while the launch-time cached rules are still loading; see loadOnceCachedRulesLand.
        var firstLoadHold: Task<Void, Never>?
        do {
            session = try engine.session(
                identifier: siteProfile?.sessionIdentifier ?? profile.sessionIdentifier,
                persistent: profile.isPersistent
            )
            // Bound before the web view exists so the rule load is already running. The first launch navigation
            // waits for it only briefly (see loadOnceCachedRulesLand): an unbounded wait would leave the tab blank
            // behind a cold compile, so the hold is capped and the page loads without rules if the cap passes.
            let hold = ContentBlockingRuntime.shared.prepareSession(session, engine: engine)
            if let hold, ContentBlockingRuntime.shared.shouldHoldFirstNavigation { firstLoadHold = hold }
            // Never initialURL: navigation must not start until adoptWebContents registers the tab, or
            // WillCreateURLLoaderFactory fires first and every webRequest event reports tabId -1, which extensions drop.
            // The engine registers the tab inside makeWebContents, before this window is its delegate.
            (engine as? WebKitEngine)?.registeringEnvironment = self
            defer { (engine as? WebKitEngine)?.registeringEnvironment = nil }
            contents = try engine.makeWebContents(session: session, initialURL: nil)
        } catch {
            let engineError = error as? EngineError
            if engineError?.code == .engineUnavailable, retryCount < Self.engineUnavailableRetryLimit {
                let delayNanoseconds = UInt64(50_000_000 * (retryCount + 1))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    guard let self, self.state.tabs[tabID] != nil else { return }
                    self.materializeWebContents(for: tabID, url: url, retryCount: retryCount + 1, isWake: isWake)
                }
                return
            }
            Self.logger.error(
                "Engine failed to open \(url.absoluteString, privacy: .public) after \(retryCount, privacy: .public) retries: \(String(describing: error), privacy: .public)"
            )
            return
        }

        adoptWebContents(contents, for: tabID, url: url)

        // Boosts reinstall onto a web view that already exists, so they do not have to
        // finish before makeWebContents. They do have to finish before load(): the first
        // document would otherwise start without them. Content blocking does not: its
        // compile keeps running and applies to requests the page makes after the rules land.
        BoostRuntime.shared.prepareSession(session, env: self)
        if isWake { quietLoadTabIDs.insert(tabID) }
        if isWake, let saved = releasedSessionStates.removeValue(forKey: tabID), contents.restoreSessionState(saved) {
            // The page and its whole back/forward list are back as they were; loading the last address instead would start a one-entry list.
            releasedSessionOrder.removeAll { $0 == tabID }
        } else if let hold = firstLoadHold {
            loadOnceCachedRulesLand(contents, tabID: tabID, url: url, hold: hold)
        } else {
            contents.load(url)
        }

        // GitHub Live Folders only read this session's cookies and poll. They never
        // touch the tab's request, so this must not sit in front of load(). Never
        // reached for a non-persistent Profile or ephemeral Space, so Incognito
        // can't hand it a session. Nor a Site Profile session: the folders belong to the Space's own account.
        // browserUserAgent is assigned here, not at the store's declaration: OrbitTests
        // compiles the store through a symlink and does not see EngineFactory.
        if siteProfile == nil, profile.isPersistent, let space = state.spaces.first(where: { $0.id == spaceID }), !space.isEphemeral {
            let capturedSpace = space
            Task { @MainActor in
                GitHubLiveFolderStore.browserUserAgent = WebKitProduct.userAgent
                GitHubLiveFolderStore.shared.activate(space: capturedSpace, session: session)
                let capturedSpaceID = capturedSpace.id
                GitHubLiveFolderStore.shared.onAutoActivate = { [weak self] in
                    self?.autoActivateGitHubLiveFolder(in: capturedSpaceID)
                }
            }
        }
    }

    // Holds the launch's first navigation until the cached rules are installed, so the page's first requests are
    // already filtered, but never longer than the cap. A navigation issued meanwhile through loadInTab bumps
    // navigationGeneration and wins; a released or replaced tab drops the load.
    private func loadOnceCachedRulesLand(_ contents: any WebContents, tabID: TabID, url: URL, hold: Task<Void, Never>) {
        let generation = navigationGeneration[tabID, default: 0]
        Task { @MainActor [weak self] in
            await ContentBlockingRuntime.shared.awaitReadiness(hold, timeout: .milliseconds(300))
            guard let self,
                  self.webContents[tabID] === contents,
                  self.navigationGeneration[tabID, default: 0] == generation
            else { return }
            contents.load(url)
        }
    }

    // Must go through this, not webContents[tabID]?.load(url) directly: bumping navigationGeneration here lets a load that was queued before this one detect it has been superseded.
    // Also handles the no-renderer case, where a bare .load(url) would silently discard the navigation.
    func loadInTab(_ tabID: TabID, url: URL) {
        navigationGeneration[tabID, default: 0] += 1
        // A new navigation supersedes the failure card. Left up until the new page commits, a load that ends without committing (a download, a 204, a cancel) would keep showing the old error over a working tab.
        tabErrors.removeValue(forKey: tabID)
        crashedTabs.remove(tabID)

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
        registerWebContents(contents, for: tabID)
        inheritSiteProfile(from: contents, for: tabID, url: url)
        installForeignSiteCookieMirror(on: contents, tabID: tabID)
        setNavigationState(contents.navigationState, for: tabID)
        mediaStates[tabID] = contents.mediaState
        store.setMediaState(contents.mediaState, forTab: tabID)
        applyStoredZoomFactor(to: contents, tabID: tabID, url: url)
        applyStoredMuteState(to: contents, tabID: tabID)
        // Lives here, the single funnel every materialisation passes
        // through, so no future call site can bring a tab back to life while leaving it flagged unloaded.
        store.setRendererLive(tabID, true)
        contents.setPreferredColorScheme(AppearanceSettings.shared.engineColorScheme)
        if isCommandBarPresented {
            (contents as? WebKitWebContents)?.setFocusSuppressed(true)
        }
        // After adoption, never before, so the tab the user just asked for
        // is itself protected and can never be the one this frees.
        enforceLiveRendererBudget()
        registerExtensionTab(tabID)
    }

    // MARK: - chrome.tabs / chrome.windows push

    // What syncExtensionActiveTab last told OrbitTabRegistry, so a repeated
    // call is free and so the tab being deactivated can be named.
    private var lastPushedActiveTabID: TabID?

    // The back/forward list of every tab whose renderer was let go, kept for the next time it is shown. Newest last; the oldest are dropped past the limit.
    @ObservationIgnored private var releasedSessionStates: [TabID: Data] = [:]
    @ObservationIgnored private var releasedSessionOrder: [TabID] = []
    private static let releasedSessionLimit = 40
    // Tabs whose next commit is a page coming back, not a visit.
    @ObservationIgnored var quietLoadTabIDs: Set<TabID> = []

    /// A tab that slept is also forgotten here, not only one with a live page: the saved copy is what a later wake would put back.
    func forgetSessionState(for tabID: TabID) {
        releasedSessionStates.removeValue(forKey: tabID)
        releasedSessionOrder.removeAll { $0 == tabID }
    }

    func forgetAllSessionStates() {
        releasedSessionStates.removeAll()
        releasedSessionOrder.removeAll()
    }

    private func rememberSessionState(_ data: Data, for tabID: TabID) {
        releasedSessionStates[tabID] = data
        releasedSessionOrder.removeAll { $0 == tabID }
        releasedSessionOrder.append(tabID)
        while releasedSessionOrder.count > Self.releasedSessionLimit {
            releasedSessionStates.removeValue(forKey: releasedSessionOrder.removeFirst())
        }
    }

    // No-op unless this tab has a live WebKit web view. Module-internal: AppEnvironment+TearOff.swift reuses it too.
    func registerExtensionTab(_ tabID: TabID) {
        guard let contents = webContents[tabID] as? WebKitWebContents else { return }
        let webKitEngine = self.engine as? WebKitEngine
        webKitEngine?.bind(storeTabID: tabID, to: contents)
        webKitEngine?.noteTabOpened(contents)
        if activeTabID == tabID { webKitEngine?.noteActive(contents) }
        syncExtensionActiveTab()
        pushExtensionTabIndexes()
    }

    // Chrome guarantees pinned tabs lead the strip; Orbit flattens to each Space's pinned tree
    // then its Today list, in Space order. Tabs with no live renderer take up no index at all.
    private func extensionWindowTabOrder() -> [TabID] {
        state.spaces.flatMap { pinnedNodes(in: $0.id).flatMap(\.allTabIDs) + $0.today }
    }

    func extensionTabIndex(for tabID: TabID) -> Int {
        var index = 0
        for candidate in extensionWindowTabOrder() {
            if candidate == tabID { return index }
            if webContents[candidate] is WebKitWebContents { index += 1 }
        }
        return index
    }

    private func extensionTabIndex(for tab: Tab) -> Int {
        extensionTabIndex(for: tab.id)
    }

    // Invalidates extension tab positions after an insert, close, pin or move.
    func pushExtensionTabIndexes() {
        (engine as? WebKitEngine)?.noteTabLayoutChanged()
    }

    // The one place chrome.tabs is told the active tab — every path that changes it must call
    // this, not just openTab/activateTab, or extensions reading it get a wrong answer. Idempotent.
    func syncExtensionActiveTab() {
        discardNewTabPageIfLeft()
        let current = activeTabID
        guard current != lastPushedActiveTabID else { return }
        // A tab with no live renderer is not in OrbitTabRegistry, so it cannot
        // be named as active; nil deactivates instead, and it stays unrecorded
        // so registerExtensionTab pushes it properly once it has one.
        let liveContents = current.flatMap { webContents[$0] as? WebKitWebContents }
        let previous = lastPushedActiveTabID
        guard liveContents != nil || previous != nil else { return }
        lastPushedActiveTabID = liveContents == nil ? nil : current
        if let liveContents { (engine as? WebKitEngine)?.noteActive(liveContents) }
    }

    // Module-internal, not private: AppEnvironment+SidebarTree.swift's own
    // pin/unpin(_:toParent:...) also need to push this.
    func pushExtensionTabPinnedChanged(_ id: TabID) {
        guard let contents = webContents[id] as? WebKitWebContents else { return }
        (engine as? WebKitEngine)?.noteTabPropertiesChanged(contents, .pinned)
        // Pinning moves the tab between the two halves of the strip, so both
        // it and everything it stepped over has a new index.
        pushExtensionTabIndexes()
    }

    // Called after a reorder has already happened; recomputes the tab's own
    // new index rather than trusting a caller-supplied one, since
    // store.reorderTab is free to clamp/adjust it.
    func pushExtensionTabMoved(_ id: TabID, fromIndex: Int) {
        guard let contents = webContents[id] as? WebKitWebContents else { return }
        (engine as? WebKitEngine)?.noteTabMoved(contents, from: fromIndex)
        pushExtensionTabIndexes()
    }

    // MARK: - Extension-adopted tabs

    // handle's native WebContents is already built by OrbitExtensionHostDelegate::CreateTab.
    // Wraps it through the same funnel as any tab; nil means declined, and the caller must destroy handle.
    @discardableResult
    func adoptExtensionTab(handle: UnsafeMutableRawPointer, url: URL, active: Bool) -> TabID? {
        guard let spaceID = activeSpace?.id else { return nil }
        let contents = Unmanaged<WebKitWebContents>.fromOpaque(handle).takeUnretainedValue()
        return adoptPageCreatedTab(contents, url: url, in: spaceID, activate: active)
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
        syncExtensionActiveTab()
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
    // `keepingSessionState` is false where the page is being thrown away on purpose (the pin reset, clearing data, a changed site profile): the tab must come back as its address says, not as the page it was left on.
    func releaseWebContents(for tabID: TabID, windowClosing: Bool = false, destroyRenderer: Bool = true, keepingSessionState: Bool = true) {
        if !keepingSessionState { forgetSessionState(for: tabID) }
        if webContents[tabID] == nil {
            for holder in otherEnvironmentsHoldingPage(tabID) {
                holder.releaseWebContents(for: tabID, destroyRenderer: destroyRenderer, keepingSessionState: keepingSessionState)
            }
        }
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
        let wasRegistered = webContents[tabID] is WebKitWebContents
        // Also on the path that leaves the view alive for a moment: a floating window must not wait for it.
        (webContents[tabID] as? WebKitWebContents)?.endPictureInPictureForClose()
        if windowClosing, let contents = webContents[tabID] as? WebKitWebContents {
            (engine as? WebKitEngine)?.noteTabWillCloseWithWindow(contents)
        }
        if !windowClosing, keepingSessionState, let state = webContents[tabID]?.captureSessionState() {
            rememberSessionState(state, for: tabID)
        }
        if destroyRenderer {
            webContents[tabID]?.close()
        } else if let contents = webContents[tabID] as? WebKitWebContents {
            // chrome.tabs.remove is still on WebKit's stack. Destroying the WKWebView here
            // deallocates it (idle -> failed(deinit)) and takes the web process with it.
            // Drop it from the extension's tab list now; the view itself goes later.
            (engine as? WebKitEngine)?.noteTabClosed(contents)
        } else {
            webContents[tabID]?.close()
        }
        detachWebContents(for: tabID)
        // After the removal, so the closing tab no longer takes an index off
        // everything that followed it in the strip.
        if wasRegistered {
            pushExtensionTabIndexes()
        }
        // An exemption that outlived its WebContents would keep a tab out of
        // the auto-archive sweep forever, so it's cleared at this single funnel.
        store.clearMediaState(forTab: tabID)
        // Closing archives the tab rather than deleting it, so a stale "playing" state here would keep a card for it in the mini player, and clicking that card would reopen the closed page.
        mediaStates.removeValue(forKey: tabID)
        dismissedMiniPlayerTabIDs.remove(tabID)
        orbitPausedMediaTabIDs.remove(tabID)
    }

    // The one caller that must not close what it removes: tearing a tab off
    // into its own window hands the same live renderer to a second
    // environment rather than destroying it and forcing a reload.
    @discardableResult
    func detachWebContents(for tabID: TabID) -> (any WebContents)? {
        guard let contents = webContents.removeValue(forKey: tabID) else { return nil }
        tabIDsByContents.removeValue(forKey: ObjectIdentifier(contents))
        return contents
    }

    private func registerWebContents(_ contents: any WebContents, for tabID: TabID) {
        if let previous = webContents[tabID] {
            tabIDsByContents.removeValue(forKey: ObjectIdentifier(previous))
        }
        tabIDsByContents[ObjectIdentifier(contents)] = tabID
        webContents[tabID] = contents
    }

    // Does not call materializeWebContents's other setup (zoom restore,
    // content-blocking prep, setRendererLive) — the renderer already went
    // through all of that in its original session.
    func installTransferredWebContents(_ contents: any WebContents, for tabID: TabID) {
        contents.delegate = self
        registerWebContents(contents, for: tabID)
    }

    #if DEBUG
    var _test_webContentsFactory: ((TabID, URL) -> any WebContents)?
    // Every factory-path materialization with the Site Profile its session was chosen for, nil meaning the Space's own Profile session.
    var _test_materializations: [(tabID: TabID, siteProfileID: SiteProfileID?)] = []
    #endif

    // MARK: - Background tab renderer policy

    // No test asserts this value — tests lower liveRendererBudget instead
    // and assert the behaviour that follows.
    static let defaultLiveRendererBudget = 12

    // While the Mac runs hot (thermal state serious or critical) or in Low Power Mode.
    static let constrainedLiveRendererBudget = 6

    // Read through the root only: one budget for every window, not one per window.
    @ObservationIgnored private var sharedLiveRendererBudget = AppEnvironment.defaultLiveRendererBudget

    // Process-wide (the root's). Settable so tests can drive the overflow path; nothing in Orbit/UI writes it, no setting exposes it.
    var liveRendererBudget: Int {
        get { rootEnvironment.sharedLiveRendererBudget }
        set { rootEnvironment.sharedLiveRendererBudget = newValue }
    }

    var effectiveLiveRendererBudget: Int {
        let root = rootEnvironment
        guard root.isRendererResourceConstrained else { return root.sharedLiveRendererBudget }
        return min(root.sharedLiveRendererBudget, Self.constrainedLiveRendererBudget)
    }

    static let rendererReleaseIdleThreshold: TimeInterval = 120

    // The budget never takes a tab used more recently than this, so flipping between a few tabs never reloads one.
    static let rendererRecentUseFloor: TimeInterval = 30

    static let inactivitySuspendThreshold: TimeInterval = 15 * 60

    static let inactivitySweepInterval: TimeInterval = 60

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private var inactivitySweepTask: Task<Void, Never>?

    @ObservationIgnored private var rendererResourceObservers: [NSObjectProtocol] = []

    // The root's copy is the one that counts; see setRendererResourceConstrained(_:).
    @ObservationIgnored private(set) var isRendererResourceConstrained = false

    // Root's copy only. Renderers the budget has already counted; one it has not is the page adoptWebContents just
    // installed, which must never be what its own adoption frees, whatever its tab's last-access time says.
    @ObservationIgnored private var budgetSeenRendererIDs: Set<UUID> = []

    // Root's copy only. Renderers a pane has put on screen: only those have a picture worth keeping on release.
    @ObservationIgnored private var shownRendererIDs: Set<UUID> = []

    // Each environment allocates one, but only the root's is used, so a tab moving between windows keeps its picture.
    private let ownRendererSnapshotCache = RendererSnapshotCache()

    var rendererSnapshotCache: RendererSnapshotCache { rootEnvironment.ownRendererSnapshotCache }

    // Engine-side state beyond what BrowserStore.isEligibleForRendererRelease checks on the Tab: media uses isMediaActive, not isAudible || isPlaying, since both go false on pause and would let a paused-but-active tab's renderer be released.
    // Per environment; the policy unions it across every window (see releaseBackgroundRenderers).
    var rendererPolicyProtectedTabIDs: Set<TabID> {
        var protected: Set<TabID> = []
        for (tabID, media) in mediaStates
        where media.isMediaActive || media.isPictureInPictureActive || media.isFullscreen {
            protected.insert(tabID)
        }
        for (tabID, box) in navigationBoxes where box.isLoading {
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

        // Both are posted on arbitrary threads; queue .main brings them to the main actor.
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRendererResourceConstraint()
                }
            }
            rendererResourceObservers.append(token)
        }
        refreshRendererResourceConstraint()
    }

    func stopBackgroundTabRendererPolicy() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        inactivitySweepTask?.cancel()
        inactivitySweepTask = nil
        for token in rendererResourceObservers {
            NotificationCenter.default.removeObserver(token)
        }
        rendererResourceObservers.removeAll()
    }

    private func refreshRendererResourceConstraint() {
        let info = ProcessInfo.processInfo
        let isHot = info.thermalState == .serious || info.thermalState == .critical
        setRendererResourceConstrained(isHot || info.isLowPowerModeEnabled)
    }

    /// Lowers the effective budget to constrainedLiveRendererBudget while true. Entering the constrained state
    /// enforces at once; leaving it needs nothing more, since released tabs reload when shown and the full
    /// budget applies from the next adoption.
    func setRendererResourceConstrained(_ constrained: Bool) {
        let root = rootEnvironment
        guard root.isRendererResourceConstrained != constrained else { return }
        root.isRendererResourceConstrained = constrained
        if constrained { enforceLiveRendererBudget() }
    }

    @discardableResult
    func runInactivitySweep(now: Date = Date()) -> [TabID] {
        releaseBackgroundRenderers(
            .inactivity(after: Self.inactivitySuspendThreshold),
            now: now
        )
    }

    // Snapshots go first at either level: they are the cheapest memory to give back.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            rendererSnapshotCache.removeAll()
            releaseBackgroundRenderers(.memoryPressureCritical)
        } else if event.contains(.warning) {
            rendererSnapshotCache.removeAll()
            releaseBackgroundRenderers(
                .memoryPressureWarning(idleThreshold: Self.rendererReleaseIdleThreshold)
            )
        }
    }

    /// Every environment on this one's engine: the root, each open window's, and this one (a test's may be neither).
    var rendererPolicyEnvironments: [AppEnvironment] {
        let root = rootEnvironment
        var group: [AppEnvironment] = [root]
        for candidate in OrbitWindowController.openEnvironments + [self]
        where candidate.rootEnvironment === root && !group.contains(where: { $0 === candidate }) {
            group.append(candidate)
        }
        return group
    }

    /// Tabs on screen somewhere: each window's active tab in its visible Space, every pane of a split it shows,
    /// and the tab of each Little Orbit window. Other Spaces' active tabs and off-screen splits are not included.
    var rendererOnScreenTabIDs: Set<TabID> {
        var onScreen = Set((NSApp?.windows ?? []).compactMap { LittleOrbitWindowController.tabID(forWindow: $0) })
        for environment in rendererPolicyEnvironments {
            guard let active = environment.activeTabID else { continue }
            onScreen.insert(active)
            if let group = environment.splitGroup(for: active) {
                onScreen.formUnion(group.tabIDs)
            }
        }
        return onScreen
    }

    // Global: candidates, protections and the on-screen set span every window on the engine, and each release
    // runs in the environment that holds the page.
    @discardableResult
    func releaseBackgroundRenderers(
        _ policy: TabRendererReleasePolicy,
        now: Date = Date()
    ) -> [TabID] {
        releaseBackgroundRenderers(policy, sparing: [], now: now)
    }

    private func releaseBackgroundRenderers(
        _ policy: TabRendererReleasePolicy,
        sparing: Set<TabID>,
        now: Date
    ) -> [TabID] {
        let environments = rendererPolicyEnvironments
        var liveTabIDs: Set<TabID> = []
        var protected = rendererOnScreenTabIDs.union(sparing)
        for environment in environments {
            liveTabIDs.formUnion(environment.webContents.keys)
            protected.formUnion(environment.rendererPolicyProtectedTabIDs)
        }
        let released = store.tabsToReleaseRenderers(
            liveTabIDs: liveTabIDs,
            protectedTabIDs: protected,
            policy: policy,
            now: now
        )
        guard !released.isEmpty else { return [] }

        for tabID in released {
            for environment in environments where environment.webContents[tabID] != nil {
                environment.releaseRendererForPolicy(tabID, capturingSnapshot: policy.capturesSnapshot)
            }
            store.setRendererLive(tabID, false)
        }
        return released
    }

    private func releaseRendererForPolicy(_ tabID: TabID, capturingSnapshot: Bool) {
        let snapshotRequest = capturingSnapshot
            ? webContents[tabID].flatMap { rendererSnapshotRequest(for: $0, tabID: tabID) }
            : nil
        // With a picture to take, the page leaves the tab now but is closed only once photographed.
        releaseWebContents(for: tabID, destroyRenderer: snapshotRequest == nil)
        removeNavigationState(for: tabID)
        mediaStates.removeValue(forKey: tabID)
        findResultsByTab.removeValue(forKey: tabID)
        tabErrors.removeValue(forKey: tabID)
        crashedTabs.remove(tabID)
        unresponsiveTabs.remove(tabID)
        // themeColors is deliberately kept: it's a property of the page,
        // not the renderer — dropping it would flash the header to neutral and back on reselect.
        if let snapshotRequest {
            captureRendererSnapshotThenClose(snapshotRequest)
        }
    }

    private func enforceLiveRendererBudget() {
        let root = rootEnvironment
        var liveCount = 0
        var liveRendererIDs: Set<UUID> = []
        var justAdopted: Set<TabID> = []
        for environment in rendererPolicyEnvironments {
            for (tabID, contents) in environment.webContents {
                liveCount += 1
                liveRendererIDs.insert(contents.id)
                if !root.budgetSeenRendererIDs.contains(contents.id) { justAdopted.insert(tabID) }
            }
        }
        root.budgetSeenRendererIDs = liveRendererIDs
        root.shownRendererIDs.formIntersection(liveRendererIDs)
        pruneRendererSnapshots()

        let overshoot = liveCount - effectiveLiveRendererBudget
        guard overshoot > 0 else { return }
        releaseBackgroundRenderers(
            .budgetOvershoot(overshoot, idleThreshold: Self.rendererRecentUseFloor),
            sparing: justAdopted,
            now: Date()
        )
    }

    // MARK: - Released-tab snapshots

    private struct RendererSnapshotRequest {
        let contents: any WebContents
        let tabID: TabID
        let url: URL
        let profileID: ProfileID
        let size: CGSize
    }

    /// Called by the pane each time it puts a renderer on screen; a page never shown has no picture worth keeping.
    func noteRendererShown(_ contentsID: UUID) {
        rootEnvironment.shownRendererIDs.insert(contentsID)
    }

    /// The picture of a released tab's page, only while it still shows what the tab would reload: the same URL
    /// in the same Profile, and the tab not closed.
    func rendererSnapshot(for tabID: TabID) -> NSImage? {
        guard let entry = rendererSnapshotCache.entry(for: tabID), isRendererSnapshotCurrent(entry, for: tabID) else {
            return nil
        }
        return entry.image
    }

    func discardRendererSnapshot(for tabID: TabID) {
        rendererSnapshotCache.remove(tabID)
    }

    func discardAllRendererSnapshots() {
        rendererSnapshotCache.removeAll()
    }

    private func isRendererSnapshotCurrent(_ entry: RendererSnapshotCache.Entry, for tabID: TabID) -> Bool {
        guard let tab = store.tab(tabID), tab.section != .archived, tab.url == entry.url else { return false }
        return profileID(for: tab.spaceID) == entry.profileID
    }

    private func pruneRendererSnapshots() {
        rendererSnapshotCache.removeAll { tabID, entry in !isRendererSnapshotCurrent(entry, for: tabID) }
    }

    private func rendererSnapshotRequest(for contents: any WebContents, tabID: TabID) -> RendererSnapshotRequest? {
        guard rootEnvironment.shownRendererIDs.contains(contents.id), !contents.isClosed,
              let tab = store.tab(tabID) else { return nil }
        // A warm page keeps its pane's size while hidden; a page with none falls back to this window's content area.
        var size = contents.view.bounds.size
        if size.width < 1 || size.height < 1 { size = contentAreaSize }
        guard size.width >= 1, size.height >= 1 else { return nil }
        return RendererSnapshotRequest(
            contents: contents,
            tabID: tabID,
            url: tab.url,
            profileID: profileID(for: tab.spaceID),
            size: size
        )
    }

    private func captureRendererSnapshotThenClose(_ request: RendererSnapshotRequest) {
        let contents = request.contents
        // A snapshot WebKit never answers must not keep the page's process alive.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppEnvironment.snapshotCaptureTimeout))
            AppEnvironment.closeReleasedRenderer(contents)
        }
        Task { @MainActor [weak self] in
            var captured: NSImage?
            if !contents.isClosed {
                captured = await contents.capturePreview(rect: nil, size: request.size)
            }
            AppEnvironment.closeReleasedRenderer(contents)
            guard let captured, let cgImage = captured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let width = Int(request.size.width.rounded())
            let height = Int(request.size.height.rounded())
            // Off the main actor: the redraw to 1x is the only real cost here and must not land on a tab switch.
            let scaled = await Task.detached(priority: .userInitiated) {
                RendererSnapshotCache.downscale(cgImage, width: width, height: height)
            }.value
            guard let self, let scaled else { return }
            self.storeRendererSnapshot(NSImage(cgImage: scaled, size: request.size), for: request)
        }
    }

    // releaseWebContents already told the extension system the tab closed, so this close must not tell it again.
    // Idempotent: the capture and its timeout both call it.
    private static func closeReleasedRenderer(_ contents: any WebContents) {
        guard !contents.isClosed else { return }
        if let webKitContents = contents as? WebKitWebContents {
            webKitContents.teardown(notifyExtensionController: false)
        } else {
            contents.close()
        }
    }

    private static let snapshotCaptureTimeout: TimeInterval = 2

    private func storeRendererSnapshot(_ image: NSImage, for request: RendererSnapshotRequest) {
        // The tab came back while its picture was taken: the new page is what it shows, and a stale picture
        // left in the cache would flash over it the next time it is selected.
        guard !rendererPolicyEnvironments.contains(where: { $0.webContents[request.tabID] != nil }) else { return }
        let entry = RendererSnapshotCache.Entry(image: image, url: request.url, profileID: request.profileID)
        guard isRendererSnapshotCurrent(entry, for: request.tabID) else { return }
        rendererSnapshotCache.insert(entry, for: request.tabID)
    }

    /// Pictures of released tabs, keyed by tab id so nothing crosses tabs or Profiles. Bounded by count and by
    /// pixel bytes, oldest capture evicted first.
    @MainActor
    @Observable
    final class RendererSnapshotCache {
        struct Entry {
            let image: NSImage
            let url: URL
            let profileID: ProfileID
            let byteCost: Int

            init(image: NSImage, url: URL, profileID: ProfileID) {
                self.image = image
                self.url = url
                self.profileID = profileID
                let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
                    ?? Int(image.size.width * image.size.height)
                byteCost = max(0, pixels) * 4
            }
        }

        static let entryLimit = 24
        static let byteLimit = 100 * 1024 * 1024

        private var entries: [TabID: Entry] = [:]
        @ObservationIgnored private var captureOrder: [TabID: UInt64] = [:]
        @ObservationIgnored private var clock: UInt64 = 0

        var count: Int { entries.count }

        var totalByteCost: Int { entries.values.reduce(0) { $0 + $1.byteCost } }

        func entry(for tabID: TabID) -> Entry? { entries[tabID] }

        func insert(_ entry: Entry, for tabID: TabID) {
            guard entry.byteCost <= Self.byteLimit else { return }
            clock &+= 1
            entries[tabID] = entry
            captureOrder[tabID] = clock
            while entries.count > Self.entryLimit || totalByteCost > Self.byteLimit,
                  let oldest = captureOrder.min(by: { $0.value < $1.value })?.key {
                remove(oldest)
            }
        }

        // Guarded so a no-op never invalidates the panes that read the cache.
        func remove(_ tabID: TabID) {
            captureOrder.removeValue(forKey: tabID)
            guard entries[tabID] != nil else { return }
            entries.removeValue(forKey: tabID)
        }

        func removeAll() {
            captureOrder.removeAll()
            guard !entries.isEmpty else { return }
            entries.removeAll()
        }

        func removeAll(where shouldRemove: (TabID, Entry) -> Bool) {
            for (tabID, entry) in entries where shouldRemove(tabID, entry) {
                remove(tabID)
            }
        }

        /// Redrawn at one pixel per point, a quarter of a Retina capture's memory.
        nonisolated static func downscale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
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
        removeAllNavigationStates()
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
        // Track registration changes when a SwiftUI view resolves its tab.
        access(keyPath: \.webContents)
        return tabIDsByContents[ObjectIdentifier(contents)]
    }

    #if DEBUG
    // MARK: - Test seam

    func _test_attachWebContents(_ contents: WebContents, for tabID: TabID) {
        registerWebContents(contents, for: tabID)
        setNavigationState(contents.navigationState, for: tabID)
        mediaStates[tabID] = contents.mediaState
    }

    func _test_detachWebContents(for tabID: TabID) {
        detachWebContents(for: tabID)
    }
    #endif

    // MARK: - History

    var browserHistory: HistoryStore? { historyStore }

    func recordVisit(url: URL, title: String, profileID: ProfileID, spaceID: SpaceID? = nil, wasTyped: Bool = false) {
        Task {
            await recordVisitReportingItem(
                url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: wasTyped
            )
        }
    }

    // The same funnel, awaitable, so chrome.history.addUrl answers only once the visit is committed.
    @discardableResult
    func recordVisitReportingItem(
        url: URL, title: String, profileID: ProfileID, spaceID: SpaceID? = nil, wasTyped: Bool = false
    ) async -> HistoryStore.HistoryURLRow? {
        guard let historyStore else { return nil }
        // Incognito leaves no history — checked here, the single funnel
        // every recorded visit passes through, so a future caller cannot forget the rule.
        guard !isPrivateBrowsingContext(spaceID: spaceID, profileID: profileID) else { return nil }
        let visit = HistoryVisit(url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: wasTyped)
        guard let recorded = try? await historyStore.recordReportingRow(visit: visit) else { return nil }
        upsertHistoryCache(recorded.entry, typedCount: recorded.row.typedCount)
        ChromeExtensionAPI.postVisited(recorded.row)
        return recorded.row
    }

    /// Gives the history row for `url` the title the page has now. A visit is recorded when the page commits, before the page has a title of its own.
    func noteHistoryTitle(_ title: String, for url: URL, spaceID: SpaceID?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let historyStore else { return }
        let profileID = spaceID.flatMap { space($0)?.profileID } ?? state.profiles.first?.id ?? UUID()
        guard !isPrivateBrowsingContext(spaceID: spaceID, profileID: profileID) else { return }
        Task { [weak self] in
            guard (try? await historyStore.updateTitle(trimmed, forURL: url)) == true, let self else { return }
            var index = self.historyIndex
            guard let position = index.firstIndex(where: { $0.entry.url == url }), index[position].entry.title != trimmed else { return }
            var entry = index[position].entry
            entry.title = trimmed
            index[position] = PreparedHistoryEntry(entry)
            self.setHistoryIndex(index)
        }
    }

    private func refreshHistoryCache(query: String = "") async {
        guard let historyStore else { return }
        // A failed refresh leaves the previous cache alone, not [] — stale
        // rows are strictly better than dropped ones for a Command Bar
        // reading this cache on every keystroke.
        guard let found = try? await historyStore.search(query, limit: Self.historyCacheCapacity) else { return }
        localHistoryCache = found
    }

    private func setHistoryIndex(_ index: [PreparedHistoryEntry]) {
        historyIndex = index
        historyCacheVersion &+= 1
    }

    // Folds one recorded visit into the cache instead of re-reading and re-sorting
    // 2000 rows after every page commit. The store orders this cache by frecency, so the
    // visit is re-placed by the same score; existing entries only carry wasTyped, so their
    // typed count is approximated, and a periodic full reload corrects any drift.
    private func upsertHistoryCache(_ entry: HistoryEntry, typedCount: Int) {
        historyUpsertsSinceReload += 1
        if historyUpsertsSinceReload >= Self.historyUpsertsBetweenReloads {
            historyUpsertsSinceReload = 0
            Task { await refreshHistoryCache() }
        }

        let now = Date()
        let newScore = HistoryStore.frecencyScore(visitCount: entry.visitCount, typedCount: typedCount, lastVisit: entry.visitedAt, now: now)
        var index = historyIndex
        let countBefore = index.count
        index.removeAll { $0.entry.url == entry.url }
        let removedExisting = index.count != countBefore
        let position = index.firstIndex { existing in
            HistoryStore.frecencyScore(
                visitCount: existing.entry.visitCount,
                typedCount: existing.entry.wasTyped ? 1 : 0,
                lastVisit: existing.entry.visitedAt,
                now: now
            ) < newScore
        } ?? index.count

        // Ranked below a full cache's last entry: it would not have made the cut on a reload either.
        guard position < Self.historyCacheCapacity else {
            if removedExisting { setHistoryIndex(index) }
            return
        }
        index.insert(PreparedHistoryEntry(entry), at: position)
        if index.count > Self.historyCacheCapacity { index.removeLast() }
        setHistoryIndex(index)
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
        ChromeExtensionAPI.postVisitsRemoved(allHistory: true, urls: [])
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
        // The query just changed, so every earlier historyResults for it used no search hits at all:
        // any hit is new. No hits means a re-score would reproduce what is already on screen.
        if !found.isEmpty { historySearchEpoch &+= 1 }
    }

    func historyResults(matching query: String, limit: Int = 50) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return historyIndex.prefix(limit).map(\.entry) }

        let sources = historySources(matching: trimmed)
        return CommandBarEngine.blendHistory(
            indexed: sources.indexed,
            cached: sources.cached,
            query: FuzzyMatcher.PreparedQuery(trimmed),
            limit: limit
        ).map(\.entry)
    }

    // The two blend inputs for a typed query, copy-on-write handles that are O(1) to take on the main actor:
    // the store's FTS hits (only while they belong to this exact query), then the recency cache.
    func historySources(matching trimmed: String) -> (indexed: [PreparedHistoryEntry], cached: [PreparedHistoryEntry]) {
        (historySearchQuery == trimmed ? historySearchIndex : [], historyIndex)
    }

    // Both sources are filtered here, not just the recency cache: a HistoryStore.search result reflects the row's state when indexed, not now, so an unmatched row must be dropped rather than ranked on stale frecency.
    nonisolated static func blendHistory(
        indexed: [HistoryEntry],
        cached: [HistoryEntry],
        matching query: String,
        limit: Int
    ) -> [HistoryEntry] {
        CommandBarEngine.blendHistory(
            indexed: indexed.map(PreparedHistoryEntry.init),
            cached: cached.map(PreparedHistoryEntry.init),
            query: FuzzyMatcher.PreparedQuery(query),
            limit: limit
        ).map(\.entry)
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

    var recentDownloads: [DownloadItem] { Array(downloadStore.allDownloads.prefix(6)) }
}
