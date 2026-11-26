import AppKit
import OSLog

@MainActor
class OrbitAppDelegate: NSObject, NSApplicationDelegate {

    static let quitLog = Logger(subsystem: "com.orbit.browser", category: "Quit")

    // Every member below must read this, not AppEnvironment.shared directly —
    // OrbitDemoAppDelegate overrides it, and .shared would build the real environment in the demo process.
    var host: AppEnvironment { .shared }

    private var dockDownloadProgress: DockDownloadProgress?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if !SingleInstanceGuard.claim() {
            Self.quitLog.log("another copy of this Orbit bundle is running; handing over to it")
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Inert without ORBIT_SMOKE_PROBE=1. First and last statements of this
        // method on purpose: Scripts/app-launch-smoke tells a crash before the
        // delegate ran from one inside it by which stages reached disk.
        AppSmokeProbe.noteStage(.delegateEntered)

        // Before the guard below: the live-engine test host opens real
        // inspectors and needs the same appearance tracking the real app has.
        EngineAppearance.startObserving()

        // XCTestConfigurationFilePath is set exactly when this process is
        // hosting a test bundle — bail out before opening any window or engine.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Before the first engine: its profiles resolve their data stores against what WebKit already holds.
        InstalledDataStores.preload()

        // Before anything else can name AppEnvironment.shared by accident.
        AppEnvironment.processRoot = host

        dockDownloadProgress = DockDownloadProgress(store: host.downloadStore)

        // Before the first window opens, so no surface ever paints a stock 17pt scroller first.
        OrbitScrollerInstaller.start()

        // orderFront can paint immediately. Notes, easel, and the other surfaces
        // read these closures during that first layout.
        FeatureRegistration.installAll(into: host)

        if OnboardingWindowController.showIfNeeded(on: host) == nil {
            OrbitWindowController.openNewWindow(on: host)
        }

        // The first window is already ordered front. None of this paints it,
        // so it runs after that call; each one still runs this launch.
        // ORBIT_SPARKLE, not canImport(Sparkle) — the latter is also true in
        // the host-less OrbitTests target, which cannot resolve UpdaterController.
        #if ORBIT_SPARKLE
        UpdaterController.shared.start()
        #endif

        // Kept, not just set: the SwiftUI App scene can replace it with its stock View/Window/Help menu after launch.
        MainMenuKeeper.shared.install(MainMenuBuilder.build())
        GlobalKeyEventMonitor.shared.start()

        // origin, not openTornOffWindow's processRoot default: needed to find the tab's already-live WebContents.
        SidebarTearOff.handler = { payload, point, origin in
            OrbitWindowController.openTornOffWindow(adopting: payload.nodeID, at: point, on: origin)
        }

        SidebarTearOff.frontmostEnvironmentResolver = { OrbitWindowController.frontmostEnvironment }

        // Inert without ORBIT_WEBSTORE_PROBE=1. Runs on both schemes:
        // OrbitDemoAppDelegate calls through to this via super before its
        // own probes. See Orbit/Core/WebStoreInstallVerifyProbe.swift.
        WebStoreInstallVerifyProbe.runIfEnabled(host: host)

        // Inert without ORBIT_SMOKE_PROBE=1. Runs on both schemes, through the
        // same super call. See Orbit/Core/AppSmokeProbe.swift.
        AppSmokeProbe.noteStage(.delegateFinished)
        AppSmokeProbe.runIfEnabled(host: host)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` counts every ordered-front window, including the off-screen
        // window WebKit keeps so a background page can still paint. After the
        // last browser window closes, that helper is the only one left, so a
        // dock click would do nothing.
        switch Self.dockReopenAction(windows: sender.windows) {
        case .revealExisting:
            return true
        case .deminiaturize(let window):
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return false
        case .openNewWindow:
            OrbitWindowController.openNewWindow(on: host)
            return false
        }
    }

    enum DockReopenAction {
        case revealExisting
        case deminiaturize(NSWindow)
        case openNewWindow
    }

    /// A window the user can see. An ordered-front window parked off every
    /// screen, or one drawn with no opacity, is not one.
    static func isOnScreenWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.alphaValue > 0.01 && window.screen != nil
    }

    static func dockReopenAction(windows: [NSWindow]) -> DockReopenAction {
        if windows.contains(where: isOnScreenWindow) {
            return .revealExisting
        }
        if let miniaturized = windows.first(where: { $0.isMiniaturized && $0.alphaValue > 0.01 }) {
            return .deminiaturize(miniaturized)
        }
        return .openNewWindow
    }

    // Can fire with the app backgrounded or zero windows open, so every row
    // activates the app itself rather than assuming a key window will dispatch it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        OrbitAppDelegate.buildDockMenu()
    }

    /// `windows` is injectable so the rows can be checked without opening real windows.
    static func buildDockMenu(windows injected: [DockWindowEntry]? = nil) -> NSMenu {
        let windows = injected ?? OrbitWindowController.dockWindowEntries + LittleOrbitWindowController.dockWindowEntries
        let menu = NSMenu(title: "Dock")
        menu.addItem(DockCommandMenuItem(title: "New Window", command: .newWindow))
        menu.addItem(DockCommandMenuItem(title: "New Incognito Window", command: .newIncognitoWindow))
        // .newTabCommandBar only presents the command bar over an already-open window;
        // ensure one exists first, or the Dock item would silently do nothing.
        menu.addItem(DockCommandMenuItem(title: "New Tab", command: .newTabCommandBar) {
            OrbitWindowController.activateBrowserWindow()
        })
        if !windows.isEmpty {
            menu.addItem(.separator())
            for entry in windows {
                menu.addItem(DockWindowMenuItem(entry: entry))
            }
        }
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            host.handleExternalOpen(url: url)
        }
    }

    // Must return .terminateLater: the browser process's own nested NSApplication pump is on this thread's stack, and tearing it down from inside that pump is unsafe.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // RelaunchController.relaunch() is itself the user's confirmation — asking again here would just be redundant, and tabs are not lost on this path.
        let shouldWarn = !RelaunchController.isRelaunching && QuitConfirmation.shouldConfirm(openTabCount: host.openTabCount)
        var userConfirmedQuit = true
        if shouldWarn {
            let alert = NSAlert()
            alert.messageText = QuitConfirmation.message(openTabCount: host.openTabCount)
            alert.informativeText = QuitConfirmation.informativeText
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            userConfirmedQuit = alert.runModal() == .alertFirstButtonReturn
        }

        let decision = Self.terminationDecision(
            shouldWarn: shouldWarn,
            userConfirmedQuit: userConfirmedQuit,
            isEngineRunning: host.engine != nil
        )

        Self.quitLog.info("applicationShouldTerminate -> \(String(describing: decision), privacy: .public)")

        if decision == .terminateLater {
            Self.performOnMainRunLoop {
                Self.quitLog.info("replying to applicationShouldTerminate")
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return decision
    }

    /// The run loop, not the main queue: the serial main queue cannot start
    /// anything while `NSApp.terminate` is on the stack of one of its own blocks.
    static func performOnMainRunLoop(_ work: @escaping () -> Void) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// userConfirmedQuit is ignored when shouldWarn is false.
    static func terminationDecision(
        shouldWarn: Bool,
        userConfirmedQuit: Bool,
        isEngineRunning: Bool
    ) -> NSApplication.TerminateReply {
        guard !shouldWarn || userConfirmedQuit else {
            return .terminateCancel
        }
        return isEngineRunning ? .terminateLater : .terminateNow
    }

    // The one guaranteed place a graceful quit runs code: applicationShouldTerminateAfterLastWindowClosed
    // is false, so nothing else reaches here except via applicationShouldTerminate above.
    func applicationWillTerminate(_ notification: Notification) {
        let began = Date()
        Self.quitLog.info("applicationWillTerminate began")

        // Must come first: otherwise OnboardingWindowController.windowWillClose
        // treats the window AppKit is about to close as "skip the rest of setup".
        OnboardingWindowController.isApplicationTerminating = true

        // Must run before shutdownEngine() below, while editors are still
        // mounted — the last point flushAll() can reach a pending edit.
        // try?, not try: a write failure here must not block termination.
        DocumentEditorFlushRegistry.shared.flushAll()
        try? host.store.saveNow()
        try? host.noteStore.saveNow()
        try? host.easelStore.saveNow()
        try? host.downloadStore.saveNow()
        try? host.boostStore.saveNow()
        try? host.siteSearchStore.saveNow()
        host.syncEngine?.flushPendingCacheWrites()

        // Safe only from this exact call site: applicationShouldTerminate
        // above replies from the main run loop, so no main-queue block is on the stack.
        let engineFinished = host.shutdownEngine()

        Self.quitLog.info(
            "applicationWillTerminate finished in \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s (engine teardown completed: \(engineFinished, privacy: .public))"
        )

        // The last stage Scripts/app-launch-smoke expects: a quit that never
        // gets here is a shutdown that hung or died, and the harness fails on
        // the missing stage rather than on a process that merely went away.
        if engineFinished {
            AppSmokeProbe.noteStage(.engineShutdown)
        } else {
            AppSmokeProbe.noteTeardownIncomplete()
        }
    }
}

// Dispatches the identical ShortcutCommandID verb CommandMenuItem uses in the
// menu bar, so the Dock menu can never drift from it. frontmost, not shared:
// falls back to processRoot when no window exists yet.
@MainActor
final class DockCommandMenuItem: NSMenuItem {

    let command: ShortcutCommandID
    private let precondition: (() -> Void)?

    init(title: String, command: ShortcutCommandID, precondition: (() -> Void)? = nil) {
        self.command = command
        self.precondition = precondition
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        NSApp.activate(ignoringOtherApps: true)
        precondition?()
        AppEnvironment.frontmost.perform(command)
    }
}

/// A window shown in the Dock menu. `title` is already the text to display.
struct DockWindowEntry {
    var window: NSWindow
    var title: String
}

// One row per open window. Orbit windows carry no title, so the system lists none of them under the Dock
// icon; without these rows a window behind others, or minimized, could not be reached from there.
@MainActor
final class DockWindowMenuItem: NSMenuItem {

    static let maximumTitleLength = 48

    private weak var window: NSWindow?

    init(entry: DockWindowEntry) {
        self.window = entry.window
        super.init(title: Self.displayTitle(entry.title), action: #selector(reveal), keyEquivalent: "")
        self.target = self
        // The checkmark marks the window in front; a diamond-style dash marks one that is minimized.
        if entry.window.isMiniaturized {
            state = .mixed
        } else if entry.window.isKeyWindow {
            state = .on
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let single = trimmed.replacingOccurrences(of: "\n", with: " ")
        guard single.count > maximumTitleLength else { return single.isEmpty ? "Untitled" : single }
        return String(single.prefix(maximumTitleLength - 1)) + "\u{2026}"
    }

    @objc private func reveal() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}


/// Draws downloads on the Dock icon: a progress bar across the bottom of the app icon, a count badge when more than one is running, and a single bounce when one finishes while Orbit is in the background.
@MainActor
final class DockDownloadProgress {
    private let store: DownloadStore
    private let tile: NSDockTile
    private let iconView = DockProgressIconView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var observers: [NSObjectProtocol] = []
    private var sweepTimer: Timer?

    init(store: DownloadStore, tile: NSDockTile = NSApp.dockTile) {
        self.store = store
        self.tile = tile
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .orbitDownloadActivityChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .orbitDownloadFinished, object: store, queue: .main) { [weak self] note in
            let destination = (note.userInfo?["item"] as? DownloadItem)?.destinationURL
            MainActor.assumeIsolated { self?.downloadFinished(destination: destination) }
        })
        refresh()
    }

    private func refresh() {
        let activity = store.activity
        guard activity.isActive else {
            sweepTimer?.invalidate()
            sweepTimer = nil
            tile.badgeLabel = nil
            tile.contentView = nil
            tile.display()
            return
        }
        iconView.fraction = activity.fraction
        tile.badgeLabel = activity.activeCount > 1 ? "\(activity.activeCount)" : nil
        if tile.contentView !== iconView { tile.contentView = iconView }
        updateSweep(indeterminate: activity.fraction == nil)
        tile.display()
    }

    // An unknown size has no fraction to show, so the bar runs a short segment back and forth instead.
    private func updateSweep(indeterminate: Bool) {
        guard indeterminate, !OrbitMotion.prefersReducedMotion else {
            sweepTimer?.invalidate()
            sweepTimer = nil
            iconView.sweepPhase = 0
            return
        }
        guard sweepTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.iconView.sweepPhase = (self.iconView.sweepPhase + 0.035).truncatingRemainder(dividingBy: 2)
                self.tile.display()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    private func downloadFinished(destination: URL?) {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        // The same signal Safari sends, so the Downloads stack in the Dock bounces and shows the new file.
        if let destination, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           destination.standardizedFileURL.path.hasPrefix(downloads.standardizedFileURL.path + "/") {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.apple.DownloadFileFinished"),
                object: destination.path,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}

/// The Dock tile's content while a download runs: the app icon with the progress bar over it.
final class DockProgressIconView: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    /// 0 ..< 2, used only when `fraction` is nil: the segment travels right across 0 ..< 1 and back across 1 ..< 2.
    var sweepPhase: Double = 0 { didSet { needsDisplay = true } }
    var icon: NSImage? = NSApp.applicationIconImage

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
        let side = bounds.width
        let barHeight = side * 0.105
        let inset = side * 0.14
        let bar = NSRect(x: inset, y: side * 0.1, width: side - inset * 2, height: barHeight)
        let radius = barHeight / 2

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = side * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
        shadow.set()
        NSColor(white: 0.12, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        let track = bar.insetBy(dx: side * 0.012, dy: side * 0.012)
        let trackRadius = track.height / 2
        NSBezierPath(roundedRect: track, xRadius: trackRadius, yRadius: trackRadius).addClip()

        NSColor(white: 1, alpha: 0.16).setFill()
        track.fill()

        let fill: NSRect
        if let fraction {
            fill = NSRect(x: track.minX, y: track.minY, width: track.width * max(0.04, min(1, fraction)), height: track.height)
        } else {
            let segment = track.width * 0.32
            let travel = sweepPhase <= 1 ? sweepPhase : 2 - sweepPhase
            fill = NSRect(x: track.minX + (track.width - segment) * travel, y: track.minY, width: segment, height: track.height)
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: trackRadius, yRadius: trackRadius).fill()
        let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)])
        sheen?.draw(in: NSRect(x: fill.minX, y: fill.midY, width: fill.width, height: fill.height / 2), angle: 90)
    }
}
