//  Drives the real app bundle to a painted page and a clean quit. Inert
//  without ORBIT_SMOKE_PROBE=1, and must never touch the real profile.

import AppKit
import CoreGraphics
import Foundation
import OSLog
import WebKit

@MainActor
enum AppSmokeProbe {

    // ORBIT-SMOKE: STAGES — Scripts/app_launch_smoke.py reads these case names
    // and fails a run that did not reach every one of them.
    enum Stage: String, CaseIterable {
        case delegateEntered
        case delegateFinished
        case windowReady
        case engineReady
        case pageLoaded
        case painted
        case resultWritten
        case terminating
        case engineShutdown
    }

    // ORBIT-SMOKE: CHECKS — same inventory rule: every case must appear in
    // result.json, and every one of them must have passed.
    enum Check: String, CaseIterable {
        case browserWindow
        case webkitEngine
        case engineVersion
        case scratchDataRoot
        case isolatedEngineStorage
        case pageLoad
        case inPageJavaScript
        case userAgent
        case rendererSurfacePaint
        case windowPixelPaint
        case mainMenuBar
    }

    // ORBIT-BENCH: COMMANDS: Scripts/benchmark.py refuses to drive a build missing a command it sends.
    enum BenchCommand: String, CaseIterable {
        case openTabs
        case closeOpenedTabs
        case status
        case quit
    }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "AppSmokeProbe")
    private static let started = Date()

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { DebugFlags.isRunningSmokeProbe }

    private static var outputDirectory: URL? {
        guard let path = environment["ORBIT_SMOKE_PROBE_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var targetURL: URL? {
        environment["ORBIT_SMOKE_PROBE_URL"].flatMap { URL(string: $0) }
    }

    /// "RRGGBB". Set by the harness together with the page it points
    /// ORBIT_SMOKE_PROBE_URL at, so the paint checks can assert that this exact
    /// page reached the screen rather than that something did.
    private static var markerColour: (red: Int, green: Int, blue: Int)? {
        guard let raw = environment["ORBIT_SMOKE_PROBE_MARKER"], raw.count == 6,
              let value = Int(raw, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    private static var markerTolerance: Int {
        environment["ORBIT_SMOKE_PROBE_MARKER_TOLERANCE"].flatMap(Int.init) ?? 24
    }

    private static var markerMinimumFraction: Double {
        environment["ORBIT_SMOKE_PROBE_MARKER_FRACTION"].flatMap(Double.init) ?? 0.25
    }

    private static var results: [(check: Check, passed: Bool, detail: String)] = []

    private static var isBenchmarking: Bool {
        isEnabled && environment["ORBIT_SMOKE_PROBE_BENCH"] == "1"
    }

    private static var benchOpenedTabs: [TabID] = []
    private static var benchNextSequence = 1
    private static var benchWatcher: DispatchSourceFileSystemObject?
    private static var benchFallbackTimer: DispatchSourceTimer?

    // MARK: - Entry points

    static func noteStage(_ stage: Stage) {
        guard isEnabled else { return }
        // A returning user has finished onboarding, so a benchmarked launch must not pay for showing it.
        if stage == .delegateEntered, isBenchmarking {
            AppEnvironment.defaults.set(true, forKey: AppEnvironment.Keys.onboardingComplete)
        }
        emit("stage \(stage.rawValue)")
        guard let directory = outputDirectory else { return }
        let line = String(format: "%.3f\t%@\n", Date().timeIntervalSince(started), stage.rawValue)
        let url = directory.appendingPathComponent("stages.tsv", isDirectory: false)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Never records `.engineShutdown`: a run that only got as far as trying must fail on the
    /// missing stage, not pass on a hopeful one.
    static func noteTeardownIncomplete() {
        guard isEnabled else { return }
        emit("applicationWillTerminate finished but the engine teardown did not complete — not recording the \(Stage.engineShutdown.rawValue) stage")
    }

    static func runIfEnabled(host: AppEnvironment) {
        guard isEnabled else { return }
        if isBenchmarking {
            Task { await runBenchmark(host: host) }
            return
        }
        Task { await run(host: host) }
    }

    // MARK: - The run

    private static func run(host: AppEnvironment) async {
        emit("starting — bundle=\(Bundle.main.bundlePath) pid=\(getpid())")

        guard let window = await resolveWindow(host: host) else {
            record(.browserWindow, false, "no OrbitBorderlessWindow after launch, even after skipping onboarding and opening one")
            await finish(host: host, tabID: nil)
            return
        }
        record(.browserWindow, true, "\(Int(window.frame.width))x\(Int(window.frame.height)) visible=\(window.isVisible)")
        noteStage(.windowReady)

        checkEngine(host: host)
        checkDataRoot(host: host)
        noteStage(.engineReady)

        WindowPixelCapture.moveToBestScreen(window)
        WindowPixelCapture.bringToFront(window)
        await settle(0.8)
        let paneBaseline = await WindowPixelCapture.atBackingScale(of: window, log: emit)

        let tabID = await checkPage(host: host)
        noteStage(.pageLoaded)

        checkEngineStorage(host: host, tabID: tabID)
        await checkPaint(host: host, tabID: tabID, window: window, baseline: paneBaseline)
        noteStage(.painted)

        await checkMainMenuBar()

        await finish(host: host, tabID: tabID)
    }

    private static func resolveWindow(host: AppEnvironment) async -> NSWindow? {
        await settle(2.0)
        if NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) == nil {
            if OnboardingWindowController.skipRemainingSteps(in: host) {
                emit("onboarding was showing — skipped it")
            }
            OrbitWindowController.openNewWindow(on: host)
            await settle(3.0)
        }
        return NSApp.windows.first(where: { $0 is OrbitBorderlessWindow })
    }

    // MARK: - Engine identity

    private static func checkEngine(host: AppEnvironment) {
        guard let engine = host.engine else {
            record(.webkitEngine, false, "host.engine is nil — no engine started at all")
            record(.engineVersion, false, "no engine to ask for a version")
            return
        }
        let typeName = String(describing: type(of: engine))
        guard engine is WebKitEngine, type(of: engine).kind == .webkit else {
            record(.webkitEngine, false, "engine is \(typeName), not WebKitEngine")
            record(.engineVersion, false, "engine is \(typeName), not WebKitEngine")
            return
        }

        let required: [(EngineCapabilities, String)] = [
            (.extensions, "extensions"),
            (.contentBlocking, "contentBlocking"),
            (.backgroundSnapshots, "backgroundSnapshots"),
            (.developerTools, "developerTools"),
        ]
        let missing = required.filter { !engine.capabilities.contains($0.0) }.map(\.1)
        if missing.isEmpty {
            record(.webkitEngine, true, "\(typeName), kind=\(type(of: engine).kind.rawValue), full capability set")
        } else {
            record(.webkitEngine, false, "\(typeName) does not advertise \(missing.joined(separator: ", "))")
        }

        let version = engine.versionDescription
        if version.contains("WebKit") {
            record(.engineVersion, true, version)
        } else {
            record(.engineVersion, false, "the running engine reports \(version)")
        }
    }

    // MARK: - Where this run is allowed to write

    private static func checkDataRoot(host: AppEnvironment) {
        let production = OrbitDataRoot.production.url.resolvingSymlinksInPath().path
        let resolved = host.dataRoot.url.resolvingSymlinksInPath().path
        if host.dataRoot.isProduction || resolved == production || resolved.hasPrefix(production + "/") {
            record(.scratchDataRoot, false, "the app resolved its data root to \(host.dataRoot.url.path), which is the real user's profile")
        } else {
            record(.scratchDataRoot, true, host.dataRoot.url.path)
        }
    }

    private static func checkEngineStorage(host: AppEnvironment, tabID: TabID?) {
        guard let engine = host.engine else {
            record(.isolatedEngineStorage, false, "no engine, so no storage to place")
            return
        }
        let session = tabID.flatMap { host.webContents[$0]?.session } ?? engine.defaultSession
        guard let storageURL = session.storageURL else {
            record(.isolatedEngineStorage, false, "session \"\(session.identifier)\" reports no storageURL, so nothing knows where the engine's own files are")
            return
        }
        let resolved = storageURL.resolvingSymlinksInPath().path
        let productionProfile = EngineStorageDirectory.productionProfile.resolvingSymlinksInPath().path
        let privateRoot = EngineStorageDirectory.privateRoot.resolvingSymlinksInPath().path

        if resolved == productionProfile || resolved.hasPrefix(productionProfile + "/") {
            record(.isolatedEngineStorage, false, "the engine directory is \(storageURL.path), inside the real profile at \(productionProfile)")
            return
        }
        guard resolved.hasPrefix(privateRoot + "/") else {
            record(.isolatedEngineStorage, false, "the engine directory is \(storageURL.path), neither the production profile nor under \(privateRoot), so nothing knows to sweep it")
            return
        }
        guard session.isPersistent else {
            record(.isolatedEngineStorage, false, "session \"\(session.identifier)\" is ephemeral; a smoke run must exercise the persistent, extension-loading configuration the app really ships")
            return
        }
        // WebKit writes website data under ~/Library/WebKit/<bundle id>/WebsiteDataStore/<store uuid>, not under the engine directory above.
        guard let webKitSession = session as? WebKitSession,
              let storeIdentifier = webKitSession.dataStore.identifier,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            record(.isolatedEngineStorage, false, "session \"\(session.identifier)\" is persistent but has no identified WKWebsiteDataStore, so WebKit's website data location cannot be determined")
            return
        }
        let websiteData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(bundleIdentifier)/WebsiteDataStore/\(storeIdentifier.uuidString)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: websiteData.path))
        if let entries, !entries.isEmpty {
            record(.isolatedEngineStorage, true, "persistent; engine files private at \(storageURL.path), WebKit website data at \(websiteData.path) (\(entries.count) entries)")
        } else {
            record(.isolatedEngineStorage, false, "\(websiteData.path) is missing or empty after a page loaded, so WebKit wrote this session's website data somewhere else")
        }
    }

    // MARK: - A real page

    private static func checkPage(host: AppEnvironment) async -> TabID? {
        guard let url = targetURL else {
            failRemainingPageChecks("ORBIT_SMOKE_PROBE_URL is unset or not a URL, so there is nothing to load")
            return nil
        }
        guard let space = host.activeSpace else {
            failRemainingPageChecks("host.activeSpace is nil — no Space to open a tab in")
            return nil
        }

        let tabID = host.openTab(url: url, in: space.id, activate: true)
        await settle(1.0)
        guard host.webContents[tabID] != nil else {
            failRemainingPageChecks("opening a tab on \(url.absoluteString) produced no WebContents at all")
            return tabID
        }
        host.loadInTab(tabID, url: url)

        var waited = 0.0
        while waited < 60.0 {
            let state = host.navigationStates[tabID]
            if state?.isLoading == false, isTarget(state?.url, url) { break }
            await settle(0.25)
            waited += 0.25
        }
        guard let committed = host.navigationStates[tabID]?.url, isTarget(committed, url),
              host.navigationStates[tabID]?.isLoading == false else {
            let engineError = host.tabErrors[tabID].map { "\($0.code) \($0.underlyingDescription)" } ?? "none"
            failRemainingPageChecks(
                "after 60s the tab reports url=\(String(describing: host.navigationStates[tabID]?.url)) "
                + "isLoading=\(String(describing: host.navigationStates[tabID]?.isLoading)) engineError=\(engineError)"
            )
            return tabID
        }

        guard let contents = host.webContents[tabID] else {
            failRemainingPageChecks("the WebContents for tab \(tabID) disappeared after the load")
            return tabID
        }

        var report: [String: Any]?
        var documentWaited = 0.0
        while documentWaited < 30.0 {
            let raw = try? await contents.evaluateJavaScript("""
            JSON.stringify({
              ready: document.readyState,
              href: location.href,
              ua: navigator.userAgent,
              title: document.title,
              text: document.getElementById('fixture') ? document.getElementById('fixture').textContent : '',
              chrome: typeof window.chrome,
              math: String(6*7),
              bodyLength: document.body ? document.body.innerHTML.length : -1
            })
            """)
            if let json = raw as? String,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (object["ready"] as? String) == "complete",
               isTarget(URL(string: object["href"] as? String ?? ""), url) {
                report = object
                break
            }
            await settle(0.5)
            documentWaited += 0.5
        }
        guard let report else {
            let engineError = host.tabErrors[tabID].map { "\($0.code) \($0.underlyingDescription)" } ?? "none"
            failRemainingPageChecks(
                "the browser reported \(committed.absoluteString) loaded, but 30s later the main frame never "
                + "reached readyState complete on that URL (engineError=\(engineError))"
            )
            return tabID
        }

        let documentText = report["text"] as? String ?? ""
        let expectedText = environment["ORBIT_SMOKE_PROBE_TEXT"] ?? ""
        let pageDetail = "\(committed.absoluteString) complete after \(String(format: "%.1f", waited + documentWaited))s, title=\(report["title"] ?? ""), text=\(documentText), bodyLength=\(report["bodyLength"] ?? "")"
        if !expectedText.isEmpty && documentText != expectedText {
            record(.pageLoad, false, "\(pageDetail); expected text \(expectedText)")
        } else {
            record(.pageLoad, true, pageDetail)
        }

        // 6*7 proves the page ran script. window.chrome stays absent; the default identity is WebKit.
        let arithmetic = "\(report["math"] as? String ?? "")-\(report["chrome"] as? String ?? "")"
        if arithmetic == "42-undefined" {
            record(.inPageJavaScript, true, arithmetic)
        } else {
            record(.inPageJavaScript, false, "in-page JavaScript returned \(arithmetic), expected \"42-undefined\"")
        }

        let agent = report["ua"] as? String ?? ""
        if agent.contains("AppleWebKit") {
            record(.userAgent, true, agent)
        } else {
            record(.userAgent, false, "navigator.userAgent does not name AppleWebKit: \(agent)")
        }
        return tabID
    }

    private static func failRemainingPageChecks(_ reason: String) {
        for check in [Check.pageLoad, .inPageJavaScript, .userAgent] where !results.contains(where: { $0.check == check }) {
            record(check, false, reason)
        }
    }

    private static func isTarget(_ candidate: URL?, _ target: URL) -> Bool {
        guard let candidate else { return false }
        if let host = target.host, !host.isEmpty { return candidate.host == host }
        if target.isFileURL, candidate.isFileURL {
            return candidate.resolvingSymlinksInPath().standardizedFileURL
                == target.resolvingSymlinksInPath().standardizedFileURL
        }
        return candidate.absoluteString == target.absoluteString
    }

    // MARK: - Real pixels

    private static func checkPaint(
        host: AppEnvironment,
        tabID: TabID?,
        window: NSWindow,
        baseline: CGImage?
    ) async {
        guard let tabID, let contents = host.webContents[tabID] else {
            record(.rendererSurfacePaint, false, "no WebContents to capture")
            record(.windowPixelPaint, false, "no WebContents to locate in the window")
            return
        }

        WindowPixelCapture.bringToFront(window)
        await settle(1.5)

        if let preview = await contents.capturePreview(rect: nil, size: CGSize(width: 1000, height: 700)),
           let surface = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            dump(surface, named: "renderer-surface")
            judgePaint(.rendererSurfacePaint, image: surface, what: "renderer surface")
        } else {
            record(.rendererSurfacePaint, false, "capturePreview returned nothing — CopyFromSurface produced no frame, so there is no live renderer surface behind this tab")
        }

        let view = contents.view
        guard view.window === window else {
            record(.windowPixelPaint, false, "the tab's engine view is not in this window (\(view.window.map { NSStringFromClass(type(of: $0)) } ?? "no window")), so nothing on screen belongs to it")
            return
        }
        let paneInWindow = view.convert(view.bounds, to: nil)
        guard paneInWindow.width > 40, paneInWindow.height > 40 else {
            record(.windowPixelPaint, false, "the engine view is \(NSStringFromRect(paneInWindow)) in the window — too small to read pixels from")
            return
        }
        guard let full = await WindowPixelCapture.atBackingScale(of: window, log: emit),
              let pane = WindowPixelCapture.crop(full, toWindowRect: paneInWindow, of: window) else {
            record(.windowPixelPaint, false, "the window capture returned nothing; occlusionVisible=\(window.occlusionState.contains(.visible)) miniaturized=\(window.isMiniaturized) screen=\(window.screen?.localizedName ?? "none") appActive=\(NSApp.isActive)")
            return
        }
        dump(pane, named: "window-pane")
        var changedDetail = ""
        if let baseline, let before = WindowPixelCapture.crop(baseline, toWindowRect: paneInWindow, of: window) {
            let changed = WindowPixelCapture.differingPixels(before, pane)
            changedDetail = ", \(changed) of \(pane.width * pane.height) pane pixels changed across the load"
        }
        judgePaint(.windowPixelPaint, image: pane, what: "window pixels", extra: changedDetail)
    }

    private static func judgePaint(_ check: Check, image: CGImage, what: String, extra: String = "") {
        let colours = WindowPixelCapture.distinctSampledColours(of: image)
        guard colours > 2 else {
            record(check, false, "\(what) \(image.width)x\(image.height) has only \(colours) distinct sampled colours — a blank frame\(extra)")
            return
        }
        guard let marker = markerColour else {
            record(check, true, "\(what) \(image.width)x\(image.height), \(colours) distinct sampled colours (no ORBIT_SMOKE_PROBE_MARKER set, so only blankness was ruled out)\(extra)")
            return
        }
        let fraction = WindowPixelCapture.fractionMatching(
            image, red: marker.red, green: marker.green, blue: marker.blue, tolerance: markerTolerance
        )
        let percentage = String(format: "%.1f%%", fraction * 100)
        let needed = String(format: "%.1f%%", markerMinimumFraction * 100)
        if fraction >= markerMinimumFraction {
            record(check, true, "\(what) \(image.width)x\(image.height), \(percentage) of sampled pixels are the page's marker colour (needed \(needed)), \(colours) distinct colours\(extra)")
        } else {
            record(check, false, "\(what) \(image.width)x\(image.height) is only \(percentage) marker colour, needed \(needed) — the page reported loaded but its pixels are not the ones on screen\(extra)")
        }
    }

    private static func dump(_ image: CGImage, named name: String) {
        guard let directory = outputDirectory else { return }
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        if WindowPixelCapture.write(image, to: url) {
            emit("wrote \(url.path) (\(image.width)x\(image.height))")
        }
    }

    // MARK: - Verdict

    /// SwiftUI's App scene installs a stock menu with no Edit menu; without Orbit's own bar Cmd-V, Cmd-C and Cmd-A beep in every text field.
    /// Judged only after the window has painted and settled, long after SwiftUI's own installation has had its chance to run.
    private static func checkMainMenuBar() async {
        NSApp.activate(ignoringOtherApps: true)
        await settle(1.5)
        let top = NSApp.mainMenu?.items.map { $0.submenu?.title ?? $0.title } ?? []
        let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let paste = edit?.items.first { $0.title == "Paste" }
        let isKept = NSApp.mainMenu === MainMenuKeeper.shared.menu
        let passed = paste?.keyEquivalent == "v" && isKept
        record(.mainMenuBar, passed, "menus=\(top) pasteRow=\(paste != nil) keptByKeeper=\(isKept)")
    }

    private static func record(_ check: Check, _ passed: Bool, _ detail: String) {
        results.append((check, passed, detail))
        emit("\(passed ? "OK  " : "FAIL") \(check.rawValue): \(detail)")
    }

    private static func finish(host: AppEnvironment, tabID: TabID?) async {
        for check in Check.allCases where !results.contains(where: { $0.check == check }) {
            record(check, false, "never ran")
        }
        let failures = results.filter { !$0.passed }

        let payload: [String: Any] = [
            "schema": 1,
            "label": environment["ORBIT_SMOKE_PROBE_LABEL"] ?? "",
            "attempt": environment["ORBIT_SMOKE_PROBE_ATTEMPT"] ?? "",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "bundlePath": Bundle.main.bundlePath,
            "pid": Int(getpid()),
            "url": targetURL?.absoluteString ?? "",
            "elapsed": Date().timeIntervalSince(started),
            "verdict": failures.isEmpty ? "PASS" : "FAIL",
            "checks": results.map { ["name": $0.check.rawValue, "passed": $0.passed, "detail": $0.detail] },
        ]

        if let directory = outputDirectory,
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            let url = directory.appendingPathComponent("result.json", isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
                noteStage(.resultWritten)
            } catch {
                emit("could not write \(url.path): \(error)")
            }
        } else {
            emit("ORBIT_SMOKE_PROBE_OUT is unset — no result.json written, so this run cannot be judged")
        }

        emit(failures.isEmpty
             ? "VERDICT PASS — \(results.count) checks"
             : "VERDICT FAIL — \(failures.count) of \(results.count) checks failed")

        if let tabID { host.closeTab(tabID) }
        await settle(0.5)

        // The ordinary quit path, deliberately: applicationWillTerminate is
        // where the engine is shut down, and a shutdown that hangs or crashes
        // is exactly the kind of launch-adjacent defect this harness is for.
        noteStage(.terminating)
        NSApp.terminate(nil)
    }

    // MARK: - Benchmark mode

    private static func runBenchmark(host: AppEnvironment) async {
        emit("benchmark mode — bundle=\(Bundle.main.bundlePath) pid=\(getpid())")
        guard let directory = outputDirectory else {
            emit("ORBIT_SMOKE_PROBE_OUT is unset — benchmark mode has no channel to the harness")
            return
        }

        var window: NSWindow?
        var polls = 0
        while polls < 3000 {
            window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow })
            if window != nil, host.activeSpace != nil { break }
            await settle(0.01)
            polls += 1
        }
        guard let window, let space = host.activeSpace else {
            emit("no browser window and Space within 30s — benchmark mode cannot start")
            return
        }

        WindowPixelCapture.moveToBestScreen(window)
        WindowPixelCapture.bringToFront(window)

        var ready: [String: Any] = [
            "schema": 1,
            "pid": Int(getpid()),
            "bundlePath": Bundle.main.bundlePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "dataRoot": host.dataRoot.url.path,
            "engine": host.engine?.versionDescription ?? "",
            "commands": BenchCommand.allCases.map(\.rawValue),
        ]
        if let url = targetURL {
            let started = Date().timeIntervalSince1970
            let tabID = host.openTab(url: url, in: space.id, activate: true)
            benchOpenedTabs.append(tabID)
            ready["initialTab"] = ["url": url.absoluteString, "startEpoch": started]
        }
        ready["epoch"] = Date().timeIntervalSince1970
        writeBenchJSON(ready, named: "bench-ready.json", in: directory)
        startBenchWatcher(host: host, directory: directory)
    }

    private static func startBenchWatcher(host: AppEnvironment, directory: URL) {
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: .write, queue: .main
            )
            source.setEventHandler {
                MainActor.assumeIsolated { drainBenchCommands(host: host, directory: directory) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            benchWatcher = source
        } else {
            emit("could not watch \(directory.path); commands are only picked up by the 5s fallback check")
        }

        // The file watcher is the only wake-up that costs nothing while idle; this covers a missed event.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            MainActor.assumeIsolated { drainBenchCommands(host: host, directory: directory) }
        }
        timer.resume()
        benchFallbackTimer = timer

        drainBenchCommands(host: host, directory: directory)
    }

    private static func drainBenchCommands(host: AppEnvironment, directory: URL) {
        while true {
            let sequence = benchNextSequence
            let commandURL = directory.appendingPathComponent("bench-command-\(sequence).json", isDirectory: false)
            guard let data = try? Data(contentsOf: commandURL) else { return }
            benchNextSequence += 1
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            var response = executeBench(request, host: host)
            response["seq"] = sequence
            writeBenchJSON(response, named: "bench-response-\(sequence).json", in: directory)
            if response["quit"] as? Bool == true {
                NSApp.terminate(nil)
                return
            }
        }
    }

    private static func executeBench(_ request: [String: Any], host: AppEnvironment) -> [String: Any] {
        guard let name = request["command"] as? String, let command = BenchCommand(rawValue: name) else {
            return ["ok": false, "error": "unknown command \(String(describing: request["command"]))"]
        }
        switch command {
        case .openTabs: return benchOpenTabs(request, host: host)
        case .closeOpenedTabs: return benchCloseOpenedTabs(host: host)
        case .status: return benchStatus(host: host)
        case .quit: return ["ok": true, "quit": true]
        }
    }

    private static func benchOpenTabs(_ request: [String: Any], host: AppEnvironment) -> [String: Any] {
        guard let urls = request["urls"] as? [String], !urls.isEmpty else {
            return ["ok": false, "error": "openTabs needs a non-empty \"urls\" array"]
        }
        guard let space = host.activeSpace else {
            return ["ok": false, "error": "host.activeSpace is nil — no Space to open a tab in"]
        }
        var opened: [[String: Any]] = []
        for text in urls {
            guard let url = URL(string: text) else {
                return ["ok": false, "error": "not a URL: \(text)", "opened": opened]
            }
            let started = Date().timeIntervalSince1970
            let tabID = host.openTab(url: url, in: space.id, activate: true)
            benchOpenedTabs.append(tabID)
            opened.append(["url": text, "startEpoch": started])
        }
        return ["ok": true, "opened": opened]
    }

    // Newest first, so each close activates a tab whose renderer is still live.
    private static func benchCloseOpenedTabs(host: AppEnvironment) -> [String: Any] {
        let identifiers = benchOpenedTabs.reversed()
        benchOpenedTabs.removeAll()
        for tabID in identifiers { host.closeTab(tabID) }
        return ["ok": true, "closed": identifiers.count, "liveRenderers": host.webContents.count]
    }

    private static func benchStatus(host: AppEnvironment) -> [String: Any] {
        var response: [String: Any] = [
            "ok": true,
            "pid": Int(getpid()),
            "liveRenderers": host.webContents.count,
            "openedTabs": benchOpenedTabs.count,
            "dataRoot": host.dataRoot.url.path,
        ]
        if let engine = host.engine as? WebKitEngine {
            let attribution = WebKitProcessAttribution.gather(
                from: engine.openTabs.map(\.webView),
                extensionViews: engine.extensionWebViews
            )
            response["processes"] = OrbitProcessMonitor.sample(attribution: attribution).processes.map {
                (info: OrbitProcessInfo) -> [String: Any] in
                [
                    "pid": Int(info.processID),
                    "role": info.role.rawValue,
                    "name": info.executableName,
                    "footprintBytes": info.memoryFootprintBytes,
                ]
            }
        } else {
            response["processes"] = [[String: Any]]()
            response["warning"] = "the engine is not WebKitEngine, so no helper processes are attributed"
        }
        response["tabs"] = benchOpenedTabs.map { (tabID: TabID) -> [String: Any] in
            let state = host.navigationStates[tabID]
            return [
                "url": state?.url?.absoluteString ?? "",
                "isLoading": state?.isLoading ?? false,
                "error": host.tabErrors[tabID].map { "\($0.code) \($0.underlyingDescription)" } ?? "",
            ]
        }
        return response
    }

    private static func writeBenchJSON(_ object: [String: Any], named name: String, in directory: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            emit("could not encode \(name)")
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent(name, isDirectory: false), options: .atomic)
        } catch {
            emit("could not write \(name): \(error)")
        }
    }

    // MARK: - Plumbing

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("AppSmokeProbe: \(message)\n".utf8))
        logger.info("\(message, privacy: .public)")
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
