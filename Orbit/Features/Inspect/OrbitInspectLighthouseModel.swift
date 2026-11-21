import AppKit
import Foundation
import WebKit

enum LHRunState {
    case idle
    case running(step: String, progress: Double)
    case timespanActive(startDate: Date)
    case done
    case failed(String)
}

@MainActor
@Observable
final class OrbitLighthouseModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> { ["lh.loaded", "lh.bundle", "lh.probe"] }

    /// How long a Navigation run keeps observing, from the start of the load, while it waits for a 5 s quiet window.
    /// Past this, TTI is reported as not measured and the report says the limit was hit.
    var ttiObservationCapMs: Double = 20_000

    var runMode: LHRunMode = .navigation
    /// Desktop by default; a choice the user made is remembered and wins over the default.
    var device: LHDevice = LHDevice.restored(from: OrbitDefaults.standard.string(forKey: LHDevice.preferenceKey)) {
        didSet { OrbitDefaults.standard.set(device.rawValue, forKey: LHDevice.preferenceKey) }
    }
    var runCount: Int = 1                                   // 1, 3, or 5
    var enabledCategories: Set<LHCategory> = Set(LHCategory.allCases)

    var runState: LHRunState = .idle
    var currentReport: LHReport?
    var history: [LHReport] = []                           // newest first, up to 10 per page and device
    var selectedHistoryID: UUID?                           // nil = view currentReport
    var expandedAuditIDs: Set<String> = []
    /// The run the viewed report is compared with; nil shows no comparison.
    var comparisonBaseID: UUID?

    var viewingReport: LHReport? {
        if let id = selectedHistoryID {
            return history.first(where: { $0.id == id }) ?? currentReport
        }
        return currentReport
    }

    var comparison: LHComparison? {
        guard let target = viewingReport, let baseID = comparisonBaseID, baseID != target.id,
              let base = history.first(where: { $0.id == baseID }) else { return nil }
        return OrbitLighthouseLogic.compare(base: base, target: target)
    }

    /// Runs the viewed report can be compared with, newest first.
    var comparisonCandidates: [LHReport] {
        guard let target = viewingReport else { return [] }
        return history.filter { $0.id != target.id }
    }

    func compareWithPrevious() {
        guard let target = viewingReport else { return }
        comparisonBaseID = OrbitLighthouseLogic.comparisonBaseline(for: target, in: history)?.id
    }

    func compare(withID id: UUID?) {
        comparisonBaseID = id
    }

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    var isTimespanActive: Bool {
        if case .timespanActive = runState { return true }
        return false
    }

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var loadedContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var bundleContinuation: CheckedContinuation<[String: Any]?, Never>?
    @ObservationIgnored private var probeContinuation: CheckedContinuation<[String: Any]?, Never>?
    @ObservationIgnored private var probeWaitToken = 0
    /// What the TTI wait concluded for the current run, carried into its bundle.
    @ObservationIgnored private var pendingTTI: LHTTI?
    @ObservationIgnored private var robotsTxtCache: [String: String] = [:]
    @ObservationIgnored private var pendingSIFrames: [(ms: Double, completeness: Double)] = []
    /// Set while a navigation run waits for the reload it started; the next page reset is that reload.
    @ObservationIgnored private var awaitingOwnReload = false
    @ObservationIgnored private var waitToken = 0
    @ObservationIgnored private var loadedWaitToken = 0
    @ObservationIgnored private var bundleWaitToken = 0

    /// What the tab looked like before a run emulated the device, so it can be put back exactly however the run ends.
    private struct EmulationLease {
        var device: LHDevice
        var pageZoom: CGFloat
        var scroll: (x: Double, y: Double)?
        var legacyPreset: InspectorDeviceMode.Preset?
        var agentChanged: Bool
        /// Set once a run reloads the page, because the document then came from the server under the emulated user agent.
        var documentLoadedUnderAgent = false
    }
    @ObservationIgnored private var lease: EmulationLease?

    func pageDidReset(preservingLog: Bool) {
        // The reload's commit (WebKit's, not the agent's hello) lands here mid-run; it is the run's own reload, so the run carries on.
        if awaitingOwnReload {
            awaitingOwnReload = false
            return
        }
        // The user went somewhere else, so the emulation ends but nothing reloads or scrolls the new page.
        cancelRun(restoringPage: false)
        runState = .idle
        currentReport = nil
        selectedHistoryID = nil
        comparisonBaseID = nil
    }

    func panelDidAppear(force: Bool) {
        loadHistory()
    }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard frame.isMain else { return }
        switch type {
        case "lh.loaded":
            // Until the run's own reload has committed, an lh.loaded can only come from the old document.
            guard !awaitingOwnReload else { return }
            let c = loadedContinuation
            loadedContinuation = nil
            c?.resume(returning: true)
        case "lh.bundle":
            let c = bundleContinuation
            bundleContinuation = nil
            c?.resume(returning: object)
        case "lh.probe":
            let c = probeContinuation
            probeContinuation = nil
            c?.resume(returning: object)
        default:
            break
        }
    }

    func startRun() {
        // The new run emulates and reloads on its own, so the old one's page is not restored first.
        cancelRun(restoringPage: false)
        // Running from the moment Analyze is pressed, so the panel never shows the idle state in between.
        if runMode != .timespan { setStep("Starting", progress: 0) }
        runTask = Task { [weak self] in
            await self?.performRun()
        }
    }

    func cancelRun() {
        cancelRun(restoringPage: true)
    }

    func cancelRun(restoringPage: Bool) {
        runTask?.cancel()
        runTask = nil
        awaitingOwnReload = false
        let lc = loadedContinuation; loadedContinuation = nil
        lc?.resume(returning: false)
        let bc = bundleContinuation; bundleContinuation = nil
        bc?.resume(returning: nil)
        let pc = probeContinuation; probeContinuation = nil
        pc?.resume(returning: nil)
        if isRunning || isTimespanActive { runState = .idle }
        // Restored now, not in the cancelled task: a cancel must leave the tab as it was even if that task never runs again.
        if let ended = endEmulationNow(), restoringPage {
            // A reload the restore already started must not read as the user leaving the page.
            if ended.reloadStarted { _ = expectOwnReload() }
            Task { [weak self] in await self?.restorePage(after: ended) }
        }
    }

    func startTimespan() {
        cancelRun(restoringPage: false)
        runState = .timespanActive(startDate: Date())
        runTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.beginEmulation()
            // Recording starts at the emulated size, so what the user does is measured on the chosen device.
            guard !Task.isCancelled, self.isTimespanActive else { return }
            self.session?.command(["op": "lh.timespanStart"])
        }
    }

    func stopTimespan() {
        guard isTimespanActive else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.performTimespanCollect()
        }
    }

    func toggleExpanded(auditID: String) {
        if expandedAuditIDs.contains(auditID) {
            expandedAuditIDs.remove(auditID)
        } else {
            expandedAuditIDs.insert(auditID)
        }
    }


    private func performRun() async {
        let count = max(1, runCount)
        var runs: [LHReport] = []

        setStep("Emulating \(device.title.lowercased()) viewport", progress: 0.02)
        _ = await beginEmulation()

        for i in 0 ..< count {
            guard !Task.isCancelled else { break }
            let pfx = count > 1 ? "Run \(i + 1)/\(count): " : ""
            let report: LHReport?
            switch runMode {
            case .navigation: report = await runNavigation(prefix: pfx)
            case .snapshot:   report = await runSnapshot(prefix: pfx)
            case .timespan:   report = nil   // timespan uses startTimespan/stopTimespan
            }
            if let r = report { runs.append(r) }
        }

        // Put back before the report shows, and on failure too, so the tab is never left emulating.
        if !Task.isCancelled {
            setStep("Restoring the page", progress: 0.98)
            await endEmulation()
        }

        guard !Task.isCancelled, !runs.isEmpty else {
            if !Task.isCancelled { runState = .failed("No data collected.") }
            return
        }

        let final = runs.count == 1 ? runs[0] : OrbitLighthouseLogic.medianReport(runs: runs)
        currentReport = final
        selectedHistoryID = nil
        saveToHistory(final)
        compareWithPrevious()
        runState = .done
        runTask = nil
    }

    private func runNavigation(prefix: String) async -> LHReport? {
        session?.command(["op": "lh.reset"])
        // Arms the main-thread sampler for the next document, so it runs from the reload's first script.
        session?.command(["op": "lh.arm"])
        pendingTTI = nil
        setStep(prefix + "Reloading page", progress: 0.05)
        _ = expectOwnReload()
        lease?.documentLoadedUnderAgent = true
        session?.reloadPage(ignoringCache: true)

        let siTask = Task { @MainActor [weak self] () -> VisualCapture in
            guard let self else { return VisualCapture() }
            return await self.collectVisualProgress()
        }

        setStep(prefix + "Waiting for network idle", progress: 0.2)
        let _ = await awaitLoaded(timeout: 30)
        // Loaded (or timed out) without a commit, for example a reload the page blocked: nothing is pending now.
        awaitingOwnReload = false

        try? await Task.sleep(for: .milliseconds(400))

        siTask.cancel()
        let capture = await siTask.value

        setStep(prefix + "Waiting for the page to become interactive", progress: 0.4)
        pendingTTI = await observeUntilInteractive()

        if Task.isCancelled { return nil }
        return await collectAndScore(prefix: prefix, mode: .navigation, siFrames: capture.frames, filmstrip: capture.filmstrip)
    }

    // MARK: Device emulation

    /// Lighthouse's device as Device toolbar settings. No profile is named, so nothing the user picked or saved is touched.
    static func deviceSettings(for device: LHDevice) -> OrbitDeviceSettings {
        var settings = OrbitDeviceSettings(
            profileID: nil, width: device.viewportWidth, height: device.viewportHeight,
            dpr: device.deviceScaleFactor, type: device.usesMobileAgent ? .mobile : .desktop,
            // WebKit renders here, so the phone it claims to be is a WebKit one; a Chrome-on-Android agent could be sent markup this engine was never meant to get.
            userAgent: device.usesMobileAgent ? OrbitDeviceUserAgents.iPhone : nil
        )
        // Lighthouse emulates the whole screen, so screen and outer sizes match the viewport.
        settings.emulatesScreen = true
        return settings
    }

    private struct EndedEmulation {
        var scroll: (x: Double, y: Double)?
        var emulatedWidth: Int
        /// The document came from the server under the emulated agent, so only a reload gives back the page the user had.
        var needsReload: Bool
        /// Putting back the older Screen Size menu's agent already started a reload.
        var reloadStarted: Bool
    }

    @ObservationIgnored private var ownReloadGeneration = 0

    private func expectOwnReload() -> Int {
        awaitingOwnReload = true
        ownReloadGeneration &+= 1
        return ownReloadGeneration
    }

    /// Lays the page out at the device's viewport through the Device toolbar's own emulation, after noting everything
    /// that has to come back. Returns whether the page reports the emulated size.
    @discardableResult
    private func beginEmulation() async -> Bool {
        if let current = lease { return await awaitViewport(for: current.device) }
        guard let session, let contents = session.contents, !contents.isClosed else { return false }
        let scroll = await readScroll()
        guard !Task.isCancelled, lease == nil else { return false }

        let web = contents.webView
        let agentBefore = Self.effectiveAgent(web.customUserAgent, base: contents.webKitSession.userAgent)
        // The older Screen Size menu shrinks the page inside its pane, which would undo the viewport; the Device toolbar turns it off the same way.
        let legacyMode = InspectorDeviceMode.shared
        let legacy = legacyMode.preset(for: contents)
        if legacy != .desktop { legacyMode.setPreset(.desktop, for: contents) }

        lease = EmulationLease(device: device, pageZoom: web.pageZoom, scroll: scroll,
                               legacyPreset: legacy == .desktop ? nil : legacy, agentChanged: false)
        // Page zoom scales CSS pixels, so the viewport is only 412 CSS px wide at 100%.
        web.pageZoom = 1
        session.device.borrow(Self.deviceSettings(for: device))
        lease?.agentChanged = Self.effectiveAgent(web.customUserAgent, base: contents.webKitSession.userAgent) != agentBefore

        if legacy != .desktop, web.isLoading {
            _ = expectOwnReload()
            await waitUntilLoaded(contents, timeout: 15)
        }
        return await awaitViewport(for: device)
    }

    /// Puts the toolbar, zoom and Screen Size menu back at once. The reload and scroll that may also be owed come from `restorePage`.
    private func endEmulationNow() -> EndedEmulation? {
        guard let ended = lease else { return nil }
        lease = nil
        session?.device.endBorrow()
        var reloadStarted = false
        if let contents = session?.contents {
            contents.webView.pageZoom = ended.pageZoom
            if let preset = ended.legacyPreset {
                InspectorDeviceMode.shared.setPreset(preset, for: contents)
                reloadStarted = contents.webView.isLoading
            }
        }
        return EndedEmulation(
            scroll: ended.scroll, emulatedWidth: ended.device.viewportWidth,
            needsReload: ended.documentLoadedUnderAgent && ended.agentChanged && !reloadStarted,
            reloadStarted: reloadStarted
        )
    }

    private func endEmulation() async {
        guard let ended = endEmulationNow() else { return }
        await restorePage(after: ended)
    }

    private func restorePage(after ended: EndedEmulation) async {
        guard let session, let contents = session.contents, !contents.isClosed else { return }
        if ended.needsReload || ended.reloadStarted {
            let generation = expectOwnReload()
            if ended.needsReload { session.reloadPage() }
            await waitUntilLoaded(contents, timeout: 15)
            // Only if the commit never came and no later run has started waiting for a reload of its own.
            if ownReloadGeneration == generation { awaitingOwnReload = false }
        }
        guard let scroll = ended.scroll else { return }
        // The tab returns to its own size on the next layout pass; scrolling before that would be clamped to the emulated page.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if let width = try? await session.evaluate("window.innerWidth") as? Double, abs(width - Double(ended.emulatedWidth)) > 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        _ = try? await session.evaluate("window.scrollTo(\(scroll.x), \(scroll.y)); 1")
    }

    /// The device stage lays the page out on its next pass; the run waits until the page itself reports the size,
    /// so it measures the emulated layout rather than the one it had.
    private func awaitViewport(for device: LHDevice) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if let size = try? await session?.evaluate("[window.innerWidth, window.innerHeight]") as? [Double], size.count == 2,
               abs(size[0] - Double(device.viewportWidth)) <= 1, abs(size[1] - Double(device.viewportHeight)) <= 1 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func readScroll() async -> (x: Double, y: Double)? {
        guard let values = try? await session?.evaluate("[window.scrollX, window.scrollY]") as? [Double], values.count == 2 else { return nil }
        return (values[0], values[1])
    }

    private func waitUntilLoaded(_ contents: WebKitWebContents, timeout: TimeInterval) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while contents.webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func effectiveAgent(_ custom: String?, base: String?) -> String? {
        if let custom, !custom.isEmpty { return custom }
        if let base, !base.isEmpty { return base }
        return nil
    }

    private func runSnapshot(prefix: String) async -> LHReport? {
        // The page has just been resized to the device; its own resize handlers get a moment to lay it out again.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return nil }
        return await collectAndScore(prefix: prefix, mode: .snapshot, siFrames: [], filmstrip: [])
    }

    private func performTimespanCollect() async {
        let report = await collectAndScore(prefix: "", mode: .timespan, siFrames: [], filmstrip: [])
        guard !Task.isCancelled else { return }
        await endEmulation()
        guard !Task.isCancelled else { return }
        if let report {
            currentReport = report
            selectedHistoryID = nil
            saveToHistory(report)
            compareWithPrevious()
            runState = .done
        } else {
            runState = .failed("Failed to collect timespan data.")
        }
        runTask = nil
    }

    private func collectAndScore(
        prefix: String, mode: LHRunMode, siFrames: [(ms: Double, completeness: Double)], filmstrip: [LHFilmstripFrame]
    ) async -> LHReport? {
        setStep(prefix + "Collecting DOM evidence", progress: 0.5)
        // Security evidence: cookies and the page's forms and frames are read fresh so the Security category is current.
        session?.application.loadCookiesNative()
        session?.command(["op": "sec.collect"])
        session?.command(["op": "lh.collect", "timespan": mode == .timespan])

        let bundleObj = await awaitBundle(timeout: 15)
        guard !Task.isCancelled else { return nil }
        guard let bundleObj else {
            runState = .failed("Page did not respond to collection request.")
            return nil
        }

        // Taken straight after the page measured its elements, so the outlines drawn on it match what was on screen.
        setStep(prefix + "Capturing screenshot", progress: 0.62)
        let inner = OrbitInspectDecode.object(bundleObj, "bundle") ?? bundleObj
        let shot = await captureScreenshot(viewport: OrbitInspectDecode.object(inner, "vp"), scale: device.deviceScaleFactor)
        guard !Task.isCancelled else { return nil }

        setStep(prefix + "Fetching robots.txt", progress: 0.7)
        let robotsTxt = await fetchRobotsTxt()

        setStep(prefix + "Scoring", progress: 0.85)
        var bundle = buildBundle(from: bundleObj, robotsTxt: robotsTxt, mode: mode, siFrames: siFrames)
        bundle.filmstrip = filmstrip
        bundle.screenshot = shot.screenshot
        bundle.screenshotNote = shot.note

        setStep(prefix + "Generating report", progress: 0.95)
        var report = OrbitLighthouseLogic.score(bundle: bundle)
        report.runCount = 1
        return report
    }


    /// What the load looked like: the pixel-similarity series behind Speed Index, and a few readable frames for the filmstrip.
    private struct VisualCapture {
        var frames: [(ms: Double, completeness: Double)] = []
        var filmstrip: [LHFilmstripFrame] = []
    }

    private static let filmstripFrameLimit = 8
    private static let filmstripFrameWidth: CGFloat = 240

    private func collectVisualProgress() async -> VisualCapture {
        var raw: [(ms: Double, CGImage)] = []
        var thumbs: [(ms: Double, jpeg: Data)] = []
        let start = Date()
        for tick in 0 ..< 60 {                     // up to 60 × 100 ms = 6 s
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
            let ms = Date().timeIntervalSince(start) * 1000
            if let img = await session?.contents?.capturePreview(rect: nil, size: CGSize(width: 20, height: 20)),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                raw.append((ms: ms, cgImage: cg))
            }
            // A readable frame every half second is enough for a filmstrip and keeps the snapshot cost low.
            if tick % 5 == 0, let thumb = await captureThumbnail() { thumbs.append((ms: ms, jpeg: thumb)) }
        }
        let end = Date().timeIntervalSince(start) * 1000
        if let thumb = await captureThumbnail() { thumbs.append((ms: end, jpeg: thumb)) }

        let frames = OrbitLighthouseSupport.computeCompleteness(rawFrames: raw)
        let completeness: [Double?] = thumbs.map { thumb in
            frames.min(by: { abs($0.ms - thumb.ms) < abs($1.ms - thumb.ms) })?.completeness
        }
        let picks = OrbitLighthouseLogic.filmstripSelection(completeness: completeness, maxFrames: Self.filmstripFrameLimit)
        let filmstrip = picks.map { LHFilmstripFrame(ms: thumbs[$0].ms, completeness: completeness[$0], jpeg: thumbs[$0].jpeg) }
        return VisualCapture(frames: frames, filmstrip: filmstrip)
    }

    private func captureThumbnail() async -> Data? {
        guard let image = await session?.contents?.capturePreview(rect: nil, size: CGSize(width: Self.filmstripFrameWidth, height: 0)) else {
            return nil
        }
        return OrbitLighthouseSupport.jpegData(from: image, quality: 0.6)?.data
    }

    /// The picture is the web view's own rendering at the emulated viewport, drawn at the device's pixel ratio
    /// (412 CSS px at 1.75 is 721 pixels across), so a Mobile run's screenshot is the phone layout.
    private func captureScreenshot(viewport: [String: Any]?, scale: Double) async -> (screenshot: LHScreenshot?, note: String?) {
        session?.clearHighlight()
        let cssWidth = OrbitInspectDecode.number(viewport ?? [:], "w") ?? 0
        let pixelWidth = cssWidth > 0 ? min(1400, max(240, (cssWidth * scale).rounded())) : 720
        // Snapshot widths are in points: one point per CSS pixel at 100% zoom gives the view's own sharpness to scale from.
        let pointWidth = cssWidth > 0 ? cssWidth : pixelWidth
        guard let image = await session?.contents?.capturePreview(rect: nil, size: CGSize(width: pointWidth, height: 0)) else {
            return (nil, "Orbit could not capture the page. A screenshot needs the tab to be visible while the audit runs.")
        }
        guard let encoded = OrbitLighthouseSupport.jpegData(from: image, quality: 0.6, pixelWidth: Int(pixelWidth)) else {
            return (nil, "The screenshot could not be encoded.")
        }
        let viewport = viewport ?? [:]
        return (LHScreenshot(
            jpeg: encoded.data, pixelWidth: encoded.width, pixelHeight: encoded.height,
            viewportWidth: OrbitInspectDecode.number(viewport, "w") ?? 0,
            viewportHeight: OrbitInspectDecode.number(viewport, "h") ?? 0,
            scrollX: OrbitInspectDecode.number(viewport, "sx") ?? 0,
            scrollY: OrbitInspectDecode.number(viewport, "sy") ?? 0
        ), nil)
    }


    private func buildBundle(
        from obj: [String: Any],
        robotsTxt: String?,
        mode: LHRunMode,
        siFrames: [(ms: Double, completeness: Double)]
    ) -> LHBundle {
        let inner = OrbitInspectDecode.object(obj, "bundle") ?? obj

        var b = LHBundle()
        b.url            = session?.pageURL ?? ""
        b.pageTitle      = session?.pageTitle ?? ""
        b.timestamp      = Date()
        b.mode           = mode
        b.device         = device
        b.enabledCategories = enabledCategories
        b.siFrames       = siFrames

        let viewport = OrbitInspectDecode.object(inner, "vp") ?? [:]
        b.viewportWidth = OrbitInspectDecode.number(viewport, "w") ?? 0
        b.documentScrollWidth = OrbitInspectDecode.number(inner, "docW")
        b.overflowNodes = OrbitInspectDecode.objects(inner, "overflow").map { node in
            LHOverflowNode(selector: OrbitInspectDecode.string(node, "sel"),
                           nodeID: OrbitInspectDecode.integer(node, "id"),
                           right: OrbitInspectDecode.number(node, "right") ?? 0,
                           snippet: OrbitInspectDecode.string(node, "snip"))
        }
        // From the page's own reports, not from what was requested, so a run that could not emulate says so.
        b.emulation = LHEmulation(
            device: device,
            measuredWidth: b.viewportWidth,
            measuredHeight: OrbitInspectDecode.number(viewport, "h") ?? 0,
            measuredDPR: OrbitInspectDecode.number(inner, "dpr") ?? 1,
            measuredTouchPoints: OrbitInspectDecode.integer(inner, "touchPts"),
            measuredMobileAgent: OrbitInspectDecode.bool(inner, "uaMobile"),
            documentLoadedUnderAgent: lease?.documentLoadedUnderAgent ?? false
        )

        b.fcpMs          = OrbitInspectDecode.number(inner, "fcp")
        b.lcpMs          = OrbitInspectDecode.number(inner, "lcp")
        b.lcpSelector    = OrbitInspectDecode.string(inner, "lcpSel")
        b.lcpURL         = OrbitInspectDecode.string(inner, "lcpURL")
        b.clsScore       = OrbitInspectDecode.number(inner, "cls") ?? 0
        b.inpMs          = OrbitInspectDecode.number(inner, "inp")
        b.ttfbMs         = OrbitInspectDecode.number(inner, "ttfb")
        b.longTasksAPIAvailable = OrbitInspectDecode.bool(inner, "tasksOk")
        b.timespanDurationMs    = OrbitInspectDecode.number(inner, "timespanDur")

        b.clsShifts = OrbitLighthouseLogic.decodeShifts(OrbitInspectDecode.objects(inner, "clsShifts"))
        b.clsShiftsTruncated = OrbitInspectDecode.bool(inner, "clsTruncated")
        b.lcpDetail = OrbitLighthouseLogic.decodeLCPDetail(OrbitInspectDecode.object(inner, "lcpInfo"), lcpMs: b.lcpMs, ttfbMs: b.ttfbMs)
        b.ttfbParts = OrbitLighthouseLogic.decodeTimingParts(OrbitInspectDecode.objects(inner, "ttfbParts"))
        b.nestedInteractiveNodes = OrbitLighthouseLogic.decodeEvidence(OrbitInspectDecode.objects(inner, "nestedNodes"))
        b.unfocusableScrollRegions = OrbitLighthouseLogic.decodeEvidence(OrbitInspectDecode.objects(inner, "scrollNodes"))
        b.videosWithoutCaptionNodes = OrbitLighthouseLogic.decodeEvidence(OrbitInspectDecode.objects(inner, "videoNodes"))
        b.positiveTabindexNodes = OrbitLighthouseLogic.decodeEvidence(OrbitInspectDecode.objects(inner, "posTabNodes"))
        b.longTasks = (inner["tasks"] as? [[String: Any]] ?? []).compactMap { t in
            guard let s = OrbitInspectDecode.number(t, "s"), let d = OrbitInspectDecode.number(t, "d") else { return nil }
            return LHLongTask(startMs: s, durationMs: d)
        }

        // A snapshot never armed the sampler, so whatever an earlier timespan left behind is not this audit's.
        if mode != .snapshot, let obs = Self.decodeObservation(OrbitInspectDecode.object(inner, "obs")), obs.ok {
            b.samplerAvailable = true
            b.samplerPeriodMs = obs.periodMs
            b.samplerFromMs = obs.fromMs
            b.samplerToMs = obs.toMs
            b.samplerIntervals = obs.blocks
            b.workSpans = obs.spans
            b.workTotals = obs.totals
            b.forcedLayouts = obs.layouts
            b.scriptSpans = obs.scripts
            b.requestSpans = requestSpans(obs)
            if !b.longTasksAPIAvailable {
                b.longTasks = obs.blocks.map { LHLongTask(startMs: $0.startMs, durationMs: $0.durationMs) }
                b.longTasksAPIAvailable = true
                b.longTaskSource = .lagSampler
            }
        } else if !b.longTasksAPIAvailable {
            b.longTaskSource = .none
        }
        if mode == .navigation { b.tti = pendingTTI }
        b.libraries = libraries(from: OrbitInspectDecode.object(inner, "fw"))

        b.htmlLang         = (inner["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        b.documentTitle    = OrbitInspectDecode.string(inner, "title")
        b.hasDoctype       = OrbitInspectDecode.bool(inner, "doctype")
        b.charset          = (inner["charset"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        b.hasViewport      = OrbitInspectDecode.bool(inner, "viewport")
        b.viewportContent  = OrbitInspectDecode.string(inner, "viewportContent")
        b.metaDescription  = OrbitInspectDecode.string(inner, "metaDesc")
        b.canonicalURL     = OrbitInspectDecode.optionalString(inner, "canonical")
        b.robotsMetaContent = OrbitInspectDecode.string(inner, "robotsMeta")
        b.httpStatus       = OrbitInspectDecode.integer(inner, "httpStatus")
        if b.httpStatus == 0 { b.httpStatus = 200 }

        b.hreflangLinks = (inner["hreflang"] as? [[String: Any]] ?? []).map { e in
            LHHreflangEntry(lang: OrbitInspectDecode.string(e, "lang"), href: OrbitInspectDecode.string(e, "href"))
        }

        b.headings = (inner["headings"] as? [[String: Any]] ?? []).compactMap { h in
            let level = OrbitInspectDecode.integer(h, "level")
            guard level >= 1 && level <= 6 else { return nil }
            return LHHeading(level: level, text: OrbitInspectDecode.string(h, "text"),
                             nodeID: OrbitInspectDecode.integer(h, "id"),
                             selector: OrbitInspectDecode.string(h, "sel"))
        }

        b.images = (inner["images"] as? [[String: Any]] ?? []).map { i in
            LHImage(
                src: OrbitInspectDecode.string(i, "src"),
                alt: i["alt"] as? String,          // nil = attr absent; "" = explicit empty
                naturalWidth:  OrbitInspectDecode.integer(i, "nw"),
                naturalHeight: OrbitInspectDecode.integer(i, "nh"),
                displayWidth:  OrbitInspectDecode.integer(i, "dw"),
                displayHeight: OrbitInspectDecode.integer(i, "dh"),
                hasWidthAttr:  OrbitInspectDecode.bool(i, "hw"),
                hasHeightAttr: OrbitInspectDecode.bool(i, "hh"),
                loading: OrbitInspectDecode.string(i, "loading"),
                nodeID:  OrbitInspectDecode.integer(i, "id"),
                selector: OrbitInspectDecode.string(i, "sel"),
                snippet: OrbitInspectDecode.string(i, "snip"),
                isAboveFold: OrbitInspectDecode.bool(i, "above"),
                transferSize: 0, mimeType: ""
            )
        }

        let netRecords = buildNetRecords()
        for i in 0 ..< b.images.count {
            let src = b.images[i].src
            if let rec = netRecords.first(where: { $0.url == src || $0.url.hasSuffix(src) }) {
                b.images[i].transferSize = rec.transferSize ?? 0
                b.images[i].mimeType     = rec.mimeType
            }
        }

        b.links = (inner["links"] as? [[String: Any]] ?? []).map { l in
            LHLink(
                href: OrbitInspectDecode.string(l, "href"),
                text: OrbitInspectDecode.string(l, "text"),
                selector: OrbitInspectDecode.string(l, "sel"),
                nodeID: OrbitInspectDecode.integer(l, "id"),
                isGenericText: OrbitInspectDecode.bool(l, "generic"),
                isCrawlable: OrbitInspectDecode.bool(l, "crawlable"),
                hasBlankTarget: OrbitInspectDecode.bool(l, "blank"),
                hasNoopener: OrbitInspectDecode.bool(l, "noopener"),
                isCrossOrigin: OrbitInspectDecode.bool(l, "cross")
            )
        }

        b.buttons = (inner["buttons"] as? [[String: Any]] ?? []).map { bt in
            LHElement(accessibleName: OrbitInspectDecode.string(bt, "name"),
                      selector: OrbitInspectDecode.string(bt, "sel"),
                      nodeID: OrbitInspectDecode.integer(bt, "id"),
                      snippet: OrbitInspectDecode.string(bt, "snip"))
        }

        b.inputs = (inner["inputs"] as? [[String: Any]] ?? []).map { inp in
            LHInput(inputType: OrbitInspectDecode.string(inp, "type"),
                    hasLabel: OrbitInspectDecode.bool(inp, "label"),
                    autocomplete: OrbitInspectDecode.string(inp, "ac"),
                    selector: OrbitInspectDecode.string(inp, "sel"),
                    nodeID: OrbitInspectDecode.integer(inp, "id"),
                    snippet: OrbitInspectDecode.string(inp, "snip"))
        }

        b.frames = (inner["frames"] as? [[String: Any]] ?? []).map { fr in
            LHFrameEntry(src: OrbitInspectDecode.string(fr, "src"),
                         title: OrbitInspectDecode.string(fr, "title"),
                         selector: OrbitInspectDecode.string(fr, "sel"),
                         nodeID: OrbitInspectDecode.integer(fr, "id"))
        }

        b.ariaIssues = (inner["ariaIssues"] as? [[String: Any]] ?? []).map { ar in
            LHAriaIssue(ruleID: OrbitInspectDecode.string(ar, "rule"),
                        selector: OrbitInspectDecode.string(ar, "sel"),
                        nodeID: OrbitInspectDecode.integer(ar, "id"),
                        snippet: OrbitInspectDecode.string(ar, "snip"),
                        detail: OrbitInspectDecode.string(ar, "detail"))
        }

        b.contrastIssues = (inner["contrastIssues"] as? [[String: Any]] ?? []).map { ci in
            let fg = (ci["fg"] as? [Any])?.compactMap { $0 as? Double } ?? []
            let bg = (ci["bg"] as? [Any])?.compactMap { $0 as? Double } ?? []
            return LHContrastIssue(
                selector: OrbitInspectDecode.string(ci, "sel"),
                nodeID: OrbitInspectDecode.integer(ci, "id"),
                foreground: fg, background: bg,
                ratio: OrbitInspectDecode.number(ci, "ratio") ?? 1,
                requiredRatio: OrbitInspectDecode.number(ci, "req") ?? 4.5,
                isLargeText: OrbitInspectDecode.bool(ci, "large"),
                needsReview: OrbitInspectDecode.bool(ci, "review")
            )
        }

        b.smallTargets = (inner["smallTargets"] as? [[String: Any]] ?? []).map { st in
            LHTargetEntry(selector: OrbitInspectDecode.string(st, "sel"),
                          nodeID: OrbitInspectDecode.integer(st, "id"),
                          width: OrbitInspectDecode.number(st, "w") ?? 0,
                          height: OrbitInspectDecode.number(st, "h") ?? 0,
                          snippet: OrbitInspectDecode.string(st, "snip"))
        }
        b.totalInteractiveTargets = OrbitInspectDecode.integer(inner, "totalTargets")

        b.domNodeCount    = OrbitInspectDecode.integer(inner, "domNodes")
        b.domMaxDepth     = OrbitInspectDecode.integer(inner, "domDepth")
        b.domMaxChildCount = OrbitInspectDecode.integer(inner, "domMaxKids")

        b.renderBlockers = (inner["blockers"] as? [[String: Any]] ?? []).map { bl in
            LHRenderBlocker(url: OrbitInspectDecode.string(bl, "url"),
                            type: OrbitInspectDecode.string(bl, "type"),
                            wastedMs: OrbitInspectDecode.number(bl, "wastedMs") ?? 0,
                            transferSize: OrbitInspectDecode.integer(bl, "size"))
        }

        b.devicePixelRatio = max(1, OrbitInspectDecode.number(inner, "dpr") ?? 1)
        b.cssSkipped = OrbitInspectDecode.integer(inner, "cssSkipped")
        b.unusedCSS = (inner["unusedCSS"] as? [[String: Any]] ?? []).map { sheet in
            LHUnusedCSS(
                url: OrbitInspectDecode.string(sheet, "url"),
                totalBytes: OrbitInspectDecode.integer(sheet, "total"),
                unusedBytes: OrbitInspectDecode.integer(sheet, "unused"),
                unusedRules: OrbitInspectDecode.integer(sheet, "rules"),
                nodeID: OrbitInspectDecode.integer(sheet, "id"),
                selector: OrbitInspectDecode.string(sheet, "sel")
            )
        }

        b.lcpHasFetchPriority = OrbitInspectDecode.bool(inner, "lcpFetchPri")
        b.preconnectOrigins   = OrbitInspectDecode.strings(inner, "preconnects")

        b.hasDocumentWrite    = OrbitInspectDecode.bool(inner, "docWrite")
        b.hasSyncXHR          = OrbitInspectDecode.bool(inner, "syncXHR")
        b.geoPromptDuringLoad = OrbitInspectDecode.bool(inner, "geo")
        b.notifPromptDuringLoad = OrbitInspectDecode.bool(inner, "notif")
        b.hasUnloadListeners  = OrbitInspectDecode.bool(inner, "unload")

        b.deprecatedElements = (inner["deprecated"] as? [[String: Any]] ?? []).map { de in
            LHDeprecatedElement(tag: OrbitInspectDecode.string(de, "tag"),
                                selector: OrbitInspectDecode.string(de, "sel"),
                                nodeID: OrbitInspectDecode.integer(de, "id"))
        }

        b.smallFontNodes = (inner["smallFonts"] as? [[String: Any]] ?? []).map { sf in
            LHSmallFontNode(selector: OrbitInspectDecode.string(sf, "sel"),
                            nodeID: OrbitInspectDecode.integer(sf, "id"),
                            fontSize: OrbitInspectDecode.number(sf, "size") ?? 0,
                            snippet: OrbitInspectDecode.string(sf, "snip"))
        }
        b.totalTextNodes = OrbitInspectDecode.integer(inner, "textNodes")

        b.jsonLDScripts  = OrbitInspectDecode.strings(inner, "jsonLD")
        b.animations = (inner["anims"] as? [[String: Any]] ?? []).map { an in
            LHAnimation(selector: OrbitInspectDecode.string(an, "sel"),
                        nodeID: OrbitInspectDecode.integer(an, "id"),
                        type: OrbitInspectDecode.string(an, "type"),
                        properties: OrbitInspectDecode.strings(an, "props"),
                        triggersPaint: OrbitInspectDecode.bool(an, "paint"),
                        triggersLayout: OrbitInspectDecode.bool(an, "layout"),
                        isInfinite: OrbitInspectDecode.bool(an, "infinite"),
                        respectsReducedMotion: OrbitInspectDecode.bool(an, "rm"))
        }

        b.hasMainLandmark        = OrbitInspectDecode.bool(inner, "hasMain")
        b.hasSkipLink            = OrbitInspectDecode.bool(inner, "hasSkip")
        b.videosWithoutCaptions  = OrbitInspectDecode.integer(inner, "videoCaps")
        b.scrollableNotFocusable = OrbitInspectDecode.integer(inner, "scrollFocus")
        b.nestedInteractiveCount = OrbitInspectDecode.integer(inner, "nestedInter")
        b.duplicateActiveIDs     = OrbitInspectDecode.strings(inner, "dupIDs")
        b.positiveTabindexCount  = OrbitInspectDecode.integer(inner, "posTabindex")

        b.blankTargetNoopenerIssues = (inner["blankNoopener"] as? [[String: Any]] ?? []).map { l in
            LHLink(href: OrbitInspectDecode.string(l, "href"),
                   text: OrbitInspectDecode.string(l, "text"),
                   selector: OrbitInspectDecode.string(l, "sel"),
                   nodeID: OrbitInspectDecode.integer(l, "id"),
                   isGenericText: false, isCrawlable: true,
                   hasBlankTarget: true, hasNoopener: false, isCrossOrigin: true)
        }

        b.networkRecords     = netRecords
        b.consoleErrorCount  = session?.console.errorCount ?? 0
        b.consoleErrorMessages = Array((session?.console.errorMessages ?? []).prefix(20))
        b.robotsTxtContent   = robotsTxt
        b.security           = session?.security.currentInput()

        return b
    }

    private func buildNetRecords() -> [LHNetRecord] {
        (session?.network.records ?? []).map { r in
            var respH: [String: String] = [:]
            for h in r.responseHeaders { respH[h.name.lowercased()] = h.value }
            var reqH: [String: String] = [:]
            for h in r.requestHeaders  { reqH[h.name.lowercased()] = h.value }
            return LHNetRecord(
                id: r.id, url: r.url, resourceType: r.resourceType, mimeType: r.mimeType,
                status: r.status, transferSize: r.transferSize, bodySize: r.bodySize,
                startMs: r.startTime, durationMs: r.duration,
                fromCache: r.fromCache, failed: r.failed, protocolName: r.protocolName,
                requestHeaders: reqH, responseHeaders: respH, initiatorURL: r.initiatorURL
            )
        }
    }

    // MARK: Main-thread observation

    private struct MainThreadProbe {
        var ok = false
        var periodMs = 10.0
        var fromMs = 0.0
        var toMs = 0.0
        var fcpMs: Double?
        var blocks: [LHBlockingInterval] = []
        var spans: [LHWorkSpan] = []
        var totals: [LHMainThreadRow] = []
        var layouts: [LHMainThreadRow] = []
        var scripts: [LHScriptSpan] = []
        var resources: [(span: LHRequestSpan, url: String)] = []
    }

    private static func decodeObservation(_ object: [String: Any]?) -> MainThreadProbe? {
        guard let object else { return nil }
        var o = MainThreadProbe()
        o.ok = OrbitInspectDecode.bool(object, "ok")
        guard o.ok else { return o }
        o.periodMs = OrbitInspectDecode.number(object, "period") ?? 10
        o.fromMs = OrbitInspectDecode.number(object, "from") ?? 0
        o.toMs = OrbitInspectDecode.number(object, "to") ?? 0
        o.fcpMs = OrbitInspectDecode.number(object, "fcp")
        o.blocks = OrbitInspectDecode.objects(object, "blocks").compactMap { b in
            guard let s = OrbitInspectDecode.number(b, "s"), let e = OrbitInspectDecode.number(b, "e"), e > s else { return nil }
            return LHBlockingInterval(startMs: s, endMs: e, attribution: [])
        }
        o.spans = OrbitInspectDecode.objects(object, "spans").compactMap { x in
            guard let s = OrbitInspectDecode.number(x, "s"), let e = OrbitInspectDecode.number(x, "e") else { return nil }
            return LHWorkSpan(category: OrbitInspectDecode.string(x, "c"), url: OrbitInspectDecode.optionalString(x, "u"), startMs: s, endMs: e)
        }
        o.totals = OrbitInspectDecode.objects(object, "totals").map { x in
            LHMainThreadRow(category: OrbitInspectDecode.string(x, "c"), url: OrbitInspectDecode.optionalString(x, "u"),
                            ms: OrbitInspectDecode.number(x, "t") ?? 0, count: OrbitInspectDecode.integer(x, "n"), approximate: false)
        }
        o.layouts = OrbitInspectDecode.objects(object, "layouts").map { x in
            LHMainThreadRow(category: "Forced layout", url: OrbitInspectDecode.optionalString(x, "u"),
                            ms: OrbitInspectDecode.number(x, "t") ?? 0, count: OrbitInspectDecode.integer(x, "n"), approximate: false)
        }
        o.scripts = OrbitInspectDecode.objects(object, "scripts").compactMap { x in
            guard let re = OrbitInspectDecode.number(x, "re"), let ld = OrbitInspectDecode.number(x, "ld") else { return nil }
            return LHScriptSpan(url: OrbitInspectDecode.string(x, "u"), responseEndMs: re, loadMs: ld)
        }
        o.resources = OrbitInspectDecode.objects(object, "res").compactMap { x in
            guard let s = OrbitInspectDecode.number(x, "s") else { return nil }
            return (LHRequestSpan(startMs: s, endMs: OrbitInspectDecode.number(x, "e")), OrbitInspectDecode.string(x, "u"))
        }
        return o
    }

    /// Finished requests from the page's Resource Timing, plus requests the Network log still shows in flight, which
    /// Resource Timing only lists once they finish.
    private func requestSpans(_ obs: MainThreadProbe) -> [LHRequestSpan] {
        let seen = Set(obs.resources.map(\.url))
        let pending = (session?.network.records ?? []).compactMap { record -> LHRequestSpan? in
            guard record.duration == nil, !record.failed, let start = record.startTime, !seen.contains(record.url) else { return nil }
            return LHRequestSpan(startMs: start, endMs: nil)
        }
        return obs.resources.map(\.span) + pending
    }

    /// Probes the page every half second until a 5 s quiet window has been seen in full, or the cap is reached.
    private func observeUntilInteractive() async -> LHTTI {
        let cap = ttiObservationCapMs
        while !Task.isCancelled {
            guard let reply = await awaitProbe(timeout: 5),
                  let obs = Self.decodeObservation(OrbitInspectDecode.object(reply, "obs")) else {
                return LHTTI(valueMs: nil, quietWindowStartMs: nil, observedUntilMs: 0, capReached: false,
                             note: "The page did not answer Orbit's main-thread probe.")
            }
            guard obs.ok else {
                return LHTTI(valueMs: nil, quietWindowStartMs: nil, observedUntilMs: 0, capReached: false,
                             note: "Orbit's main-thread sampler did not start for this load (the page may block sessionStorage).")
            }
            if let fcp = obs.fcpMs,
               let found = OrbitLighthouseLogic.timeToInteractive(
                   fcpMs: fcp, tasks: obs.blocks.map { ($0.startMs, $0.endMs) }, requests: requestSpans(obs), observedUntilMs: obs.toMs) {
                return LHTTI(valueMs: found.ttiMs, quietWindowStartMs: found.quietStartMs, observedUntilMs: obs.toMs, capReached: false, note: nil)
            }
            if obs.toMs >= cap {
                let limit = OrbitLighthouseLogic.formatMs(cap)
                let note = obs.fcpMs == nil
                    ? "The page reported no First Contentful Paint within the \(limit) Orbit observes."
                    : "No 5 s window without a long task and with at most two requests in flight was seen within the \(limit) Orbit observes."
                return LHTTI(valueMs: nil, quietWindowStartMs: nil, observedUntilMs: obs.toMs, capReached: true, note: note)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return LHTTI(valueMs: nil, quietWindowStartMs: nil, observedUntilMs: 0, capReached: false, note: "The run was cancelled.")
    }

    private func awaitProbe(timeout: TimeInterval) async -> [String: Any]? {
        waitToken &+= 1
        let token = waitToken
        return await withCheckedContinuation { continuation in
            self.probeContinuation = continuation
            self.probeWaitToken = token
            self.session?.command(["op": "lh.probe"])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.probeWaitToken == token, let pending = self.probeContinuation else { return }
                self.probeContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    /// The Frameworks tool's detector run on the evidence the page agent captured, keeping the libraries the advisory table covers.
    private func libraries(from fw: [String: Any]?) -> [LHLibrary] {
        guard let fw else { return [] }
        var e = FWEvidenceBundle()
        e.globals = Set(OrbitInspectDecode.strings(fw, "globals"))
        if let versions = OrbitInspectDecode.object(fw, "globalVersions") {
            for (k, v) in versions { if let s = v as? String { e.globalVersions[k] = s } }
        }
        e.domMarkers = Set(OrbitInspectDecode.strings(fw, "domMarkers"))
        e.scriptURLs = OrbitInspectDecode.strings(fw, "scriptURLs")
        e.linkURLs = OrbitInspectDecode.strings(fw, "linkURLs")
        e.metaGenerators = OrbitInspectDecode.strings(fw, "metaGenerators")
        e.classTokens = Set(OrbitInspectDecode.strings(fw, "classTokens"))
        e.cssVariablePrefixes = Set(OrbitInspectDecode.strings(fw, "cssVariablePrefixes"))
        e.hostname = OrbitInspectDecode.string(fw, "hostname")
        e.pageURL = session?.pageURL ?? ""
        e.responseHeaders = OrbitFrameworksLogic.responseHeaders(from: session?.network.records ?? [])
        let covered = OrbitLighthouseLogic.advisoryLibraries
        var seen = Set<String>()
        return OrbitFrameworksLogic.detect(evidence: e).compactMap { found in
            guard covered.contains(found.name), seen.insert(found.name).inserted else { return nil }
            return LHLibrary(name: found.name, version: found.version, evidence: found.evidence)
        }
    }

    // Each wait has a token so an old timer cannot resume the continuation of a new run after a cancel.
    private func awaitLoaded(timeout: TimeInterval) async -> Bool {
        waitToken &+= 1
        let token = waitToken
        return await withCheckedContinuation { continuation in
            self.loadedContinuation = continuation
            self.loadedWaitToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.loadedWaitToken == token, let pending = self.loadedContinuation else { return }
                self.loadedContinuation = nil
                pending.resume(returning: false)
            }
        }
    }

    private func awaitBundle(timeout: TimeInterval) async -> [String: Any]? {
        waitToken &+= 1
        let token = waitToken
        return await withCheckedContinuation { continuation in
            self.bundleContinuation = continuation
            self.bundleWaitToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.bundleWaitToken == token, let pending = self.bundleContinuation else { return }
                self.bundleContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    private func setStep(_ text: String, progress: Double) {
        runState = .running(step: text, progress: progress)
    }


    private func fetchRobotsTxt() async -> String? {
        guard let urlStr = session?.pageURL,
              let url = URL(string: urlStr),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let origin = "\(scheme)://\(host)\(port)"
        if let cached = robotsTxtCache[origin] { return cached }
        guard let robotsURL = URL(string: "\(origin)/robots.txt") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: robotsURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            robotsTxtCache[origin] = text
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }


    private var historyKey: String {
        let host = URL(string: session?.pageURL ?? "")?.host ?? "unknown"
        return "orbit.lighthouse.history.\(host)"
    }

    func loadHistory() {
        guard let data = OrbitDefaults.standard.data(forKey: historyKey),
              let reports = try? JSONDecoder().decode([LHReport].self, from: data) else { return }
        // Saved history has no pictures, so reports still in memory from this session keep theirs.
        let pictures = Dictionary(history.compactMap { report in report.visuals.map { (report.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        history = reports.map { report in
            var copy = report
            copy.visuals = pictures[report.id]
            return copy
        }
    }

    func saveToHistory(_ report: LHReport) {
        var list = history
        list.removeAll { $0.id == report.id }
        list.insert(report, at: 0)
        history = OrbitLighthouseLogic.trimmedHistory(list)
        persistHistory()
    }

    func deleteHistoryItem(id: UUID) {
        history.removeAll { $0.id == id }
        if selectedHistoryID == id { selectedHistoryID = nil }
        if comparisonBaseID == id { comparisonBaseID = nil }
        persistHistory()
    }

    /// Screenshots are large and defaults hold small values, so the saved copy keeps the numbers and evidence but not the pictures.
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history.map { $0.strippingVisuals() }) {
            OrbitDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func selectHistoryItem(id: UUID?) {
        selectedHistoryID = id
        // A different report brings its own natural baseline: its previous run of the same page and device.
        compareWithPrevious()
    }


    func exportJSON() {
        guard let report = viewingReport else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(report) else { return }
        OrbitLighthouseSupport.saveFile(data: data, suggestedName: "lighthouse-report.json", ext: "json")
    }

    func exportHTML() {
        guard let report = viewingReport else { return }
        let html = OrbitLighthouseLogic.generateHTMLReport(report)
        guard let data = html.data(using: .utf8) else { return }
        OrbitLighthouseSupport.saveFile(data: data, suggestedName: "lighthouse-report.html", ext: "html")
    }

    func copySummary() {
        guard let report = viewingReport else { return }
        session?.copy(OrbitLighthouseLogic.summaryText(report))
    }
}
