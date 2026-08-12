import AppKit
import XCTest
@testable import Orbit

@MainActor
enum OrbitScreenshotFixtures {

    enum IDs {
        // MARK: Lifted from `OrbitState.demo`

        static let personalSpaceID: SpaceID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        static let workSpaceID: SpaceID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        static let readingFolderID: FolderID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

        static let splitTabAID: TabID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        static let splitTabBID: TabID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

        static let loadingTabID: TabID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        static let audibleTabID: TabID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!

        // MARK: This fixture's own additions

        static let nestedFolderID: FolderID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
        static let nestedTab1ID: TabID = UUID(uuidString: "90000000-0000-0000-0000-000000000011")!
        static let nestedTab2ID: TabID = UUID(uuidString: "90000000-0000-0000-0000-000000000012")!
        static let downloadCompletedID = UUID(uuidString: "90000000-0000-0000-0000-000000000021")!
        static let downloadInProgressID = UUID(uuidString: "90000000-0000-0000-0000-000000000022")!
    }

    // Does not create the split group, since activateTab's selectTab side effect must not fire for every screenshot but the dedicated split one; call seedSplitGroup(_:) separately for that.
    static func configure(_ env: AppEnvironment) {
        env.state = makeState()
        env.isSidebarVisible = true
        env.sidebarWidth = OrbitMetrics.sidebarDefaultWidth + 40
        env.isSidebarHoverRevealed = false
        env.isCommandBarPresented = false
        env.focusedSplitPaneIndex = 0
        env.navigationStates = [:]
        env.mediaStates = [:]

        seedNavigationAndMediaState(env)
        seedDownloads(env)
        preloadFavicons(env)
    }

    // MARK: - State: the nested folder

    private static func makeState() -> OrbitState {
        var state = OrbitState.demo
        guard let spaceIndex = state.spaces.firstIndex(where: { $0.id == IDs.personalSpaceID }) else {
            XCTFail("OrbitScreenshotFixtures: OrbitState.demo no longer has the Personal space this fixture expects (id \(IDs.personalSpaceID)) — update IDs to match.")
            return state
        }

        state.tabs[IDs.nestedTab1ID] = Tab(
            id: IDs.nestedTab1ID,
            spaceID: IDs.personalSpaceID,
            section: .pinned,
            url: URL(string: "https://example.com/articles/css-grid-deep-dive")!,
            title: "CSS Grid, a deep dive",
            lastAccessedAt: Date().addingTimeInterval(-3600 * 30),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 45)
        )
        state.tabs[IDs.nestedTab2ID] = Tab(
            id: IDs.nestedTab2ID,
            spaceID: IDs.personalSpaceID,
            section: .pinned,
            url: URL(string: "https://example.com/articles/subpixel-rendering")!,
            title: "Subpixel rendering, explained",
            lastAccessedAt: Date().addingTimeInterval(-3600 * 33),
            createdAt: Date().addingTimeInterval(-3600 * 24 * 48)
        )

        let nestedFolder = SidebarNode.folder(Folder(
            id: IDs.nestedFolderID,
            name: "Archive",
            isExpanded: true,
            children: [.tab(IDs.nestedTab1ID), .tab(IDs.nestedTab2ID)],
            icon: "archivebox",
            iconIsEmoji: false
        ))

        // Reading folder -> [3 tabs, Archive folder -> [2 tabs]]: a folder inside a folder.
        state.spaces[spaceIndex].pinned = state.spaces[spaceIndex].pinned.map { node in
            guard case .folder(var folder) = node, folder.id == IDs.readingFolderID else { return node }
            folder.children.append(nestedFolder)
            return .folder(folder)
        }

        // Scoped to Personal alone, not Work: Work is demo's activeSpaceID and changing it there would touch five unrelated reference images.
        state.spaces[spaceIndex].setIcon(emoji: "📚")

        applyRealDefaultTheme(to: &state)

        return state
    }

    // Overrides only these two rendered Spaces to SpaceTheme.defaultPalette so the screenshots show a first-launch appearance without touching OrbitState.demo itself.
    private static func applyRealDefaultTheme(to state: inout OrbitState) {
        let realDefaultTheme = SpaceTheme(
            style: .mesh,
            colors: SpaceTheme.defaultPalette,
            angle: 18,
            grain: 0.35
        )
        for spaceID in [IDs.personalSpaceID, IDs.workSpaceID] {
            guard let index = state.spaces.firstIndex(where: { $0.id == spaceID }) else { continue }
            state.spaces[index].theme = realDefaultTheme
        }
    }

    // MARK: - Site Control popover (opt-in, attaches a mock engine/web contents)

    // Deliberately its own opt-in function, not folded into configure(_:): every other screenshot depends on env.activeWebContents/env.engine staying nil, so attaching a mock pair there would silently change every window-level screenshot.
    static func seedSiteControlPopover(_ env: AppEnvironment) {
        guard let tab = env.activeTab, tab.url.host() != nil else {
            XCTFail("OrbitScreenshotFixtures: expected OrbitState.demo's active tab (env.activeTab) to carry a real, hosted URL.")
            return
        }

        // Must be the same session as MockBrowserEngine's defaultSession below, since the popover reads settings off the engine but reads/writes off env.activeWebContents?.session.
        let session = MockEngineSession(identifier: "fixture-site-control", isPersistent: true)

        session.setContentSetting(.block, for: .geolocation, url: tab.url)

        let webContents = MockWebContents(session: session)
        webContents.navigationState = NavigationState(
            url: tab.url,
            title: tab.title,
            canGoBack: true,
            canGoForward: false,
            isLoading: false,
            progress: 1,
            security: .secure
        )
        webContents.certificateOverride = SiteCertificate(
            subject: tab.url.host() ?? "www.figma.com",
            issuer: "OrbitScreenshotFixtures Root CA (not a real certificate authority)",
            validFrom: Date().addingTimeInterval(-3600 * 24 * 34),
            validUntil: Date().addingTimeInterval(3600 * 24 * 56),
            serialNumber: "5B:41:2A:9F:00:C3:77:E1:6D:0A"
        )
        env._test_attachWebContents(webContents, for: tab.id)

        let engine = MockBrowserEngine(session: session)
        engine.capabilities = [.developerTools, .extensions]
        engine.manageableContentSettings = Set(PermissionKind.allCases)
        // One enabled, one not, so extensionsRow reads "1 extension enabled"
        // as a real count rather than a made-up string.
        engine.extensionsToReport = [
            LoadedExtension(
                id: "fixture.password-manager",
                name: "1Password – Password Manager",
                version: "8.10.36",
                directory: URL(fileURLWithPath: "/tmp/orbit-fixture-extensions/password-manager"),
                isEnabled: true
            ),
            LoadedExtension(
                id: "fixture.writing-assistant",
                name: "Grammarly: AI Writing Assistant",
                version: "14.1108.0",
                directory: URL(fileURLWithPath: "/tmp/orbit-fixture-extensions/writing-assistant"),
                isEnabled: false
            ),
        ]
        env._test_engineOverride = engine
    }

    // MARK: - Split group (opt-in, changes the active Space/tab)

    // Also switches the active Space/tab as a side effect of createSplit ->
    // activateTab -> selectTab. Call only for the split screenshot, after configure(_:).
    static func seedSplitGroup(_ env: AppEnvironment) {
        guard env.tab(IDs.splitTabAID) != nil, env.tab(IDs.splitTabBID) != nil else {
            XCTFail("OrbitScreenshotFixtures: expected both split tabs to already exist in OrbitState.demo.")
            return
        }
        env.createSplit(existingTabID: IDs.splitTabAID, newTabID: IDs.splitTabBID, edge: .right)
    }

    // MARK: - Loading / audible indicators

    private static func seedNavigationAndMediaState(_ env: AppEnvironment) {
        env.navigationStates[IDs.loadingTabID] = NavigationState(
            url: env.tab(IDs.loadingTabID)?.url,
            isLoading: true,
            progress: 0.55
        )
        env.mediaStates[IDs.audibleTabID] = MediaState(
            isAudible: true,
            hasVideo: false,
            isPlaying: true
        )
    }

    // MARK: - Downloads

    private static func seedDownloads(_ env: AppEnvironment) {
        guard env.downloads.isEmpty else { return }

        let completed = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://www.figma.com/file/OrbitDemo/Q4-Roadmap/export.pdf")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("Q4-Roadmap.pdf"),
            suggestedFileName: "Q4-Roadmap.pdf",
            mimeType: "application/pdf",
            totalBytes: 3_400_000
        )
        env.downloadStore.updateProgress(
            id: completed.id,
            progress: DownloadProgress(receivedBytes: 3_400_000, totalBytes: 3_400_000, bytesPerSecond: 0, state: .completed)
        )

        let inProgress = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/README.md")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("README.md"),
            suggestedFileName: "README.md",
            mimeType: "text/markdown",
            totalBytes: 48_000
        )
        env.downloadStore.updateProgress(
            id: inProgress.id,
            progress: DownloadProgress(receivedBytes: 29_760, totalBytes: 48_000, bytesPerSecond: 12_000, state: .inProgress)
        )
    }

    // MARK: - Favicons

    // Must use cacheInMemoryOnly, never cache(_:forHost:), or this persists fixture icons over the real user's own cached favicons.
    private static func preloadFavicons(_ env: AppEnvironment) {
        var hosts = Set<String>()
        for tab in env.state.tabs.values {
            if let host = tab.url.host() { hosts.insert(host) }
        }
        for space in env.state.spaces {
            for favorite in space.favorites {
                if let host = favorite.url.host() { hosts.insert(host) }
            }
        }
        for host in hosts {
            let icon = RealisticFavicon.matching(host: host)?.image(size: 64) ?? FaviconCache.fallbackIcon(forHost: host, size: 64)
            // Both: a render site that injects the environment reads the
            // first, one that hosts a bare .environment(env) reads the second.
            env.faviconCache.cacheInMemoryOnly(icon, forHost: host)
            FaviconCache.processDefault.cacheInMemoryOnly(icon, forHost: host)
        }
    }
}

// MARK: - A minimal, protocol-conformant BrowserEngine stand-in

/// Gives env.engine a real (any BrowserEngine)? for seedSiteControlPopover(_:)
/// to call; every method beyond what that function configures is a trivial, unreachable stub.
@MainActor
private final class MockBrowserEngine: BrowserEngine {
    static let kind: EngineKind = .chromium

    var capabilities: EngineCapabilities = []
    var manageableContentSettings: Set<PermissionKind> = Set(PermissionKind.allCases)
    var extensionActivation: ExtensionActivation = .nextLaunch
    var versionDescription = "Chromium (OrbitScreenshotFixtures stand-in — no real engine is running)"
    var extensionsToReport: [LoadedExtension] = []

    // Must be the same MockEngineSession seedSiteControlPopover(_:) gave its MockWebContents, or this engine could claim a kind manageable that the session disagrees about.
    private let session: EngineSession

    init(session: EngineSession) {
        self.session = session
    }

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { session }
    var defaultSession: EngineSession { session }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable)
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        throw EngineError(code: .engineUnavailable)
    }
    func unloadExtension(id: String, session: EngineSession) {}
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { extensionsToReport }
}

// MARK: - Hand-drawn favicons

/// Hand-drawn, vector-style favicons for this fixture's Favourites/tabs —
/// offline and deterministic, composed inside NSImage.lockFocus() rather than fetched or bundled.
@MainActor
private enum RealisticFavicon {
    case gmail, github, figma, linear, notion, youtube
    case google, apple, wikipedia, hackerNews, reddit, nyTimes

    static func matching(host: String) -> RealisticFavicon? {
        let host = host.lowercased()
        if host.hasSuffix("mail.google.com") { return .gmail }
        if host == "github.com" || host.hasSuffix(".github.com") { return .github }
        if host.hasSuffix("figma.com") { return .figma }
        if host.hasSuffix("linear.app") { return .linear }
        if host.hasSuffix("notion.so") { return .notion }
        if host.hasSuffix("youtube.com") { return .youtube }
        if host == "google.com" || host == "www.google.com" { return .google }
        if host.hasSuffix("apple.com") { return .apple }
        if host.hasSuffix("wikipedia.org") { return .wikipedia }
        if host.hasSuffix("ycombinator.com") { return .hackerNews }
        if host.hasSuffix("reddit.com") { return .reddit }
        if host.hasSuffix("nytimes.com") { return .nyTimes }
        return nil
    }

    func image(size: CGFloat) -> NSImage {
        switch self {
        case .gmail: return Self.drawGmail(size: size)
        case .github: return Self.drawGitHub(size: size)
        case .figma: return Self.drawFigma(size: size)
        case .linear: return Self.drawLinear(size: size)
        case .notion: return Self.drawNotion(size: size)
        case .youtube: return Self.drawYouTube(size: size)
        case .google: return Self.drawGoogle(size: size)
        case .apple: return Self.drawApple(size: size)
        case .wikipedia: return Self.drawWikipedia(size: size)
        case .hackerNews: return Self.drawHackerNews(size: size)
        case .reddit: return Self.drawReddit(size: size)
        case .nyTimes: return Self.drawNYTimes(size: size)
        }
    }

    // MARK: Canvas helpers

    private static func makeIcon(
        size: CGFloat,
        background: NSColor?,
        cornerRadiusFraction: CGFloat = 0.22,
        draw: (NSRect) -> Void
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: bounds, xRadius: size * cornerRadiusFraction, yRadius: size * cornerRadiusFraction).setClip()
        if let background {
            background.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        draw(bounds)
        return image
    }

    private static func drawLetter(_ letter: String, in bounds: NSRect, color: NSColor, font: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let textSize = letter.size(withAttributes: attributes)
        let rect = NSRect(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2 - bounds.height * 0.03,
            width: textSize.width,
            height: textSize.height
        )
        letter.draw(in: rect, withAttributes: attributes)
    }

    private static func serifBold(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        if let descriptor = base.fontDescriptor.withDesign(.serif), let serif = NSFont(descriptor: descriptor, size: size) {
            return serif
        }
        return base
    }

    // MARK: The six required Favourites marks

    private static func drawGitHub(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedWhite: 0.06, alpha: 1)) { bounds in
            let s = bounds.width
            NSColor.white.setFill()

            NSBezierPath(ovalIn: NSRect(x: s * 0.28, y: s * 0.18, width: s * 0.44, height: s * 0.40)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.30, y: s * 0.50, width: s * 0.40, height: s * 0.34)).fill()

            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: s * 0.34, y: s * 0.78))
            leftEar.line(to: NSPoint(x: s * 0.40, y: s * 0.90))
            leftEar.line(to: NSPoint(x: s * 0.44, y: s * 0.76))
            leftEar.close()
            leftEar.fill()

            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: s * 0.66, y: s * 0.78))
            rightEar.line(to: NSPoint(x: s * 0.60, y: s * 0.90))
            rightEar.line(to: NSPoint(x: s * 0.56, y: s * 0.76))
            rightEar.close()
            rightEar.fill()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: s * 0.70, y: s * 0.30))
            tail.curve(
                to: NSPoint(x: s * 0.86, y: s * 0.50),
                controlPoint1: NSPoint(x: s * 0.82, y: s * 0.24),
                controlPoint2: NSPoint(x: s * 0.90, y: s * 0.36)
            )
            tail.curve(
                to: NSPoint(x: s * 0.74, y: s * 0.58),
                controlPoint1: NSPoint(x: s * 0.82, y: s * 0.62),
                controlPoint2: NSPoint(x: s * 0.76, y: s * 0.62)
            )
            tail.lineWidth = s * 0.075
            tail.lineCapStyle = .round
            tail.stroke()

            NSBezierPath(ovalIn: NSRect(x: s * 0.20, y: s * 0.20, width: s * 0.12, height: s * 0.12)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.66, y: s * 0.20, width: s * 0.12, height: s * 0.12)).fill()
        }
    }

    private static func drawFigma(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedWhite: 0.97, alpha: 1)) { bounds in
            let s = bounds.width
            let unit = s * 0.19
            let leftX = s * 0.30
            let rightX = leftX + unit

            let orange = NSColor(calibratedRed: 0.95, green: 0.31, blue: 0.12, alpha: 1)
            let purple = NSColor(calibratedRed: 0.64, green: 0.35, blue: 1.0, alpha: 1)
            let green = NSColor(calibratedRed: 0.04, green: 0.81, blue: 0.51, alpha: 1)
            let blue = NSColor(calibratedRed: 0.10, green: 0.74, blue: 1.0, alpha: 1)
            let pink = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.38, alpha: 1)

            orange.setFill()
            NSBezierPath(roundedRect: NSRect(x: leftX, y: s * 0.62, width: unit, height: unit), xRadius: unit * 0.5, yRadius: unit * 0.5).fill()
            NSBezierPath(rect: NSRect(x: leftX, y: s * 0.62, width: unit, height: unit * 0.5)).fill()

            purple.setFill()
            NSBezierPath(rect: NSRect(x: leftX, y: s * 0.43, width: unit, height: unit)).fill()

            green.setFill()
            NSBezierPath(roundedRect: NSRect(x: leftX, y: s * 0.24, width: unit, height: unit), xRadius: unit * 0.5, yRadius: unit * 0.5).fill()
            NSBezierPath(rect: NSRect(x: leftX, y: s * 0.24 + unit * 0.5, width: unit, height: unit * 0.5)).fill()

            blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: rightX, y: s * 0.43, width: unit, height: unit)).fill()

            pink.setFill()
            NSBezierPath(ovalIn: NSRect(x: rightX, y: s * 0.24, width: unit, height: unit)).fill()
        }
    }

    private static func drawLinear(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedWhite: 0.07, alpha: 1)) { bounds in
            let s = bounds.width
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: s * 0.32, y: s * 0.24))
            chevron.line(to: NSPoint(x: s * 0.70, y: s * 0.50))
            chevron.line(to: NSPoint(x: s * 0.32, y: s * 0.76))
            chevron.lineWidth = s * 0.14
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
            chevron.stroke()
        }
    }

    private static func drawNotion(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: .white) { bounds in
            let s = bounds.width
            NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: s * 0.045, dy: s * 0.045), xRadius: s * 0.16, yRadius: s * 0.16)
            border.lineWidth = s * 0.035
            border.stroke()
            drawLetter("N", in: bounds, color: .black, font: .systemFont(ofSize: s * 0.52, weight: .black))
        }
    }

    private static func drawYouTube(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1), cornerRadiusFraction: 0.28) { bounds in
            let s = bounds.width
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: s * 0.40, y: s * 0.30))
            triangle.line(to: NSPoint(x: s * 0.40, y: s * 0.70))
            triangle.line(to: NSPoint(x: s * 0.72, y: s * 0.50))
            triangle.close()
            NSColor.white.setFill()
            triangle.fill()
        }
    }

    private static func drawGmail(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: .white) { bounds in
            let s = bounds.width
            let envelope = bounds.insetBy(dx: s * 0.16, dy: s * 0.20)
            let red = NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.15, alpha: 1)

            NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
            let outline = NSBezierPath(roundedRect: envelope, xRadius: s * 0.05, yRadius: s * 0.05)
            outline.lineWidth = s * 0.03
            outline.stroke()

            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: envelope.minX, y: envelope.maxY))
            flap.line(to: NSPoint(x: envelope.midX, y: envelope.midY))
            flap.line(to: NSPoint(x: envelope.maxX, y: envelope.maxY))
            flap.line(to: NSPoint(x: envelope.maxX, y: envelope.maxY - envelope.height * 0.18))
            flap.line(to: NSPoint(x: envelope.midX, y: envelope.midY - envelope.height * 0.22))
            flap.line(to: NSPoint(x: envelope.minX, y: envelope.maxY - envelope.height * 0.18))
            flap.close()
            red.setFill()
            flap.fill()
        }
    }

    // MARK: Everyday sites (Personal Space's own Favourites)

    private static func drawGoogle(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: .white) { bounds in
            let s = bounds.width
            let ringRect = bounds.insetBy(dx: s * 0.14, dy: s * 0.14)
            let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
            let radius = ringRect.width / 2
            let lineWidth = s * 0.16

            func wedge(from startDeg: CGFloat, to endDeg: CGFloat, color: NSColor) {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: startDeg, endAngle: endDeg)
                path.lineWidth = lineWidth
                path.lineCapStyle = .butt
                color.setStroke()
                path.stroke()
            }

            wedge(from: 0, to: 80, color: NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.96, alpha: 1))
            wedge(from: 90, to: 170, color: NSColor(calibratedRed: 0.20, green: 0.66, blue: 0.33, alpha: 1))
            wedge(from: 180, to: 260, color: NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.02, alpha: 1))
            wedge(from: 270, to: 350, color: NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1))
        }
    }

    private static func drawApple(size: CGFloat) -> NSImage {
        let background = NSColor(calibratedWhite: 0.05, alpha: 1)
        return makeIcon(size: size, background: background) { bounds in
            let s = bounds.width
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.26, y: s * 0.18, width: s * 0.48, height: s * 0.52)).fill()

            background.setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.60, y: s * 0.36, width: s * 0.22, height: s * 0.22)).fill()

            NSColor.white.setFill()
            let leaf = NSBezierPath(ovalIn: NSRect(x: s * 0.48, y: s * 0.68, width: s * 0.16, height: s * 0.10))
            var rotateAroundLeafCenter = AffineTransform.identity
            rotateAroundLeafCenter.translate(x: s * 0.56, y: s * 0.73)
            rotateAroundLeafCenter.rotate(byDegrees: 35)
            rotateAroundLeafCenter.translate(x: -s * 0.56, y: -s * 0.73)
            leaf.transform(using: rotateAroundLeafCenter)
            leaf.fill()
        }
    }

    private static func drawWikipedia(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedWhite: 0.98, alpha: 1)) { bounds in
            let s = bounds.width
            NSColor(calibratedWhite: 0.2, alpha: 1).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: s * 0.08, dy: s * 0.08))
            ring.lineWidth = s * 0.025
            ring.stroke()
            drawLetter("W", in: bounds, color: NSColor(calibratedWhite: 0.1, alpha: 1), font: serifBold(size: s * 0.46))
        }
    }

    private static func drawHackerNews(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: NSColor(calibratedRed: 1.0, green: 0.40, blue: 0.0, alpha: 1), cornerRadiusFraction: 0.14) { bounds in
            drawLetter("Y", in: bounds, color: .black, font: .systemFont(ofSize: bounds.width * 0.56, weight: .black))
        }
    }

    private static func drawReddit(size: CGFloat) -> NSImage {
        let background = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.0, alpha: 1)
        return makeIcon(size: size, background: background) { bounds in
            let s = bounds.width
            NSColor.white.setFill()
            NSColor.white.setStroke()

            NSBezierPath(ovalIn: NSRect(x: s * 0.24, y: s * 0.18, width: s * 0.52, height: s * 0.46)).fill()

            let leftStalk = NSBezierPath()
            leftStalk.move(to: NSPoint(x: s * 0.38, y: s * 0.58))
            leftStalk.line(to: NSPoint(x: s * 0.30, y: s * 0.80))
            leftStalk.lineWidth = s * 0.035
            leftStalk.stroke()
            NSBezierPath(ovalIn: NSRect(x: s * 0.24, y: s * 0.78, width: s * 0.12, height: s * 0.12)).fill()

            let rightStalk = NSBezierPath()
            rightStalk.move(to: NSPoint(x: s * 0.62, y: s * 0.58))
            rightStalk.line(to: NSPoint(x: s * 0.70, y: s * 0.80))
            rightStalk.lineWidth = s * 0.035
            rightStalk.stroke()
            NSBezierPath(ovalIn: NSRect(x: s * 0.64, y: s * 0.78, width: s * 0.12, height: s * 0.12)).fill()

            background.setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.36, y: s * 0.36, width: s * 0.09, height: s * 0.09)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.55, y: s * 0.36, width: s * 0.09, height: s * 0.09)).fill()
        }
    }

    private static func drawNYTimes(size: CGFloat) -> NSImage {
        makeIcon(size: size, background: .white) { bounds in
            drawLetter("T", in: bounds, color: .black, font: serifBold(size: bounds.width * 0.6))
        }
    }
}
