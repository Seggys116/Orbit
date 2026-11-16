import AppKit
import Foundation

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

    var messageTypes: Set<String> { ["lh.loaded", "lh.bundle"] }

    var runMode: LHRunMode = .navigation
    var device: LHDevice = .mobile
    var runCount: Int = 1                                   // 1, 3, or 5
    var enabledCategories: Set<LHCategory> = Set(LHCategory.allCases)

    var runState: LHRunState = .idle
    var currentReport: LHReport?
    var history: [LHReport] = []                           // newest first, up to 10 per origin
    var selectedHistoryID: UUID?                           // nil = view currentReport
    var expandedAuditIDs: Set<String> = []

    var viewingReport: LHReport? {
        if let id = selectedHistoryID {
            return history.first(where: { $0.id == id }) ?? currentReport
        }
        return currentReport
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
    @ObservationIgnored private var robotsTxtCache: [String: String] = [:]
    @ObservationIgnored private var pendingSIFrames: [(ms: Double, completeness: Double)] = []
    /// Set while a navigation run waits for the reload it started; the next page reset is that reload.
    @ObservationIgnored private var awaitingOwnReload = false
    @ObservationIgnored private var waitToken = 0
    @ObservationIgnored private var loadedWaitToken = 0
    @ObservationIgnored private var bundleWaitToken = 0

    func pageDidReset(preservingLog: Bool) {
        // The reload's commit (WebKit's, not the agent's hello) lands here mid-run; it is the run's own reload, so the run carries on.
        if awaitingOwnReload {
            awaitingOwnReload = false
            return
        }
        cancelRun()
        runState = .idle
        currentReport = nil
        selectedHistoryID = nil
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
        default:
            break
        }
    }

    func startRun() {
        cancelRun()
        // Running from the moment Analyze is pressed, so the panel never shows the idle state in between.
        if runMode != .timespan { setStep("Starting", progress: 0) }
        runTask = Task { [weak self] in
            await self?.performRun()
        }
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        awaitingOwnReload = false
        let lc = loadedContinuation; loadedContinuation = nil
        lc?.resume(returning: false)
        let bc = bundleContinuation; bundleContinuation = nil
        bc?.resume(returning: nil)
        if isRunning || isTimespanActive { runState = .idle }
    }

    func startTimespan() {
        cancelRun()
        runState = .timespanActive(startDate: Date())
        session?.command(["op": "lh.timespanStart"])
    }

    func stopTimespan() {
        guard isTimespanActive else { return }
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

        guard !Task.isCancelled, !runs.isEmpty else {
            if !Task.isCancelled { runState = .failed("No data collected.") }
            return
        }

        let final = runs.count == 1 ? runs[0] : OrbitLighthouseLogic.medianReport(runs: runs)
        currentReport = final
        selectedHistoryID = nil
        saveToHistory(final)
        runState = .done
        runTask = nil
    }

    private func runNavigation(prefix: String) async -> LHReport? {
        session?.command(["op": "lh.reset"])
        setStep(prefix + "Reloading page", progress: 0.05)
        awaitingOwnReload = true
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

        if Task.isCancelled { return nil }
        return await collectAndScore(prefix: prefix, mode: .navigation, siFrames: capture.frames, filmstrip: capture.filmstrip)
    }

    private func runSnapshot(prefix: String) async -> LHReport? {
        return await collectAndScore(prefix: prefix, mode: .snapshot, siFrames: [], filmstrip: [])
    }

    private func performTimespanCollect() async {
        if let report = await collectAndScore(prefix: "", mode: .timespan, siFrames: [], filmstrip: []) {
            currentReport = report
            selectedHistoryID = nil
            saveToHistory(report)
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
        session?.command(["op": "lh.collect"])

        let bundleObj = await awaitBundle(timeout: 15)
        guard !Task.isCancelled else { return nil }
        guard let bundleObj else {
            runState = .failed("Page did not respond to collection request.")
            return nil
        }

        // Taken straight after the page measured its elements, so the outlines drawn on it match what was on screen.
        setStep(prefix + "Capturing screenshot", progress: 0.62)
        let inner = OrbitInspectDecode.object(bundleObj, "bundle") ?? bundleObj
        let shot = await captureScreenshot(viewport: OrbitInspectDecode.object(inner, "vp"))
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

    private func captureScreenshot(viewport: [String: Any]?) async -> (screenshot: LHScreenshot?, note: String?) {
        session?.clearHighlight()
        guard let image = await session?.contents?.capturePreview(rect: nil, size: CGSize(width: 720, height: 0)) else {
            return (nil, "Orbit could not capture the page. A screenshot needs the tab to be visible while the audit runs.")
        }
        guard let encoded = OrbitLighthouseSupport.jpegData(from: image, quality: 0.6) else {
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
        list = Array(list.prefix(10))
        history = list
        persistHistory()
    }

    func deleteHistoryItem(id: UUID) {
        history.removeAll { $0.id == id }
        if selectedHistoryID == id { selectedHistoryID = nil }
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
