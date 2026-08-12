//  Drives the real app bundle to a painted page and a clean quit. Inert
//  without ORBIT_SMOKE_PROBE=1, and must never touch the real profile.

import AppKit
import CoreGraphics
import Foundation
import MachO
import OSLog

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
        case chromiumEngine
        case engineVersion
        case engineBundleLayout
        case loadedEngineFramework
        case scratchDataRoot
        case isolatedEngineStorage
        case pageLoad
        case inPageJavaScript
        case userAgent
        case rendererSurfacePaint
        case windowPixelPaint
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

    // MARK: - Entry points

    static func noteStage(_ stage: Stage) {
        guard isEnabled else { return }
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
        checkEngineBundle()
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
            record(.chromiumEngine, false, "host.engine is nil — no engine started at all")
            record(.engineVersion, false, "no engine to ask for a version")
            return
        }
        let typeName = String(describing: type(of: engine))
        guard let chromium = engine as? ChromiumEngine else {
            record(.chromiumEngine, false, "engine is \(typeName), not ChromiumEngine")
            record(.engineVersion, false, "engine is \(typeName), not ChromiumEngine")
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
            record(.chromiumEngine, true, "\(typeName), kind=\(type(of: engine).kind.rawValue), full capability set")
        } else {
            record(.chromiumEngine, false, "\(typeName) does not advertise \(missing.joined(separator: ", "))")
        }

        let version = chromium.versionDescription
        if version.contains(ChromiumBuild.version) {
            record(.engineVersion, true, "\(version) matches the pinned \(ChromiumBuild.version)")
        } else {
            record(.engineVersion, false, "the running engine reports \(version), but this build is pinned to \(ChromiumBuild.version)")
        }
    }

    private static func checkEngineBundle() {
        let framework = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Orbit Framework.framework", isDirectory: true)
        let versioned = framework.appendingPathComponent("Versions/A", isDirectory: true)

        var missing: [String] = []
        let binary = versioned.appendingPathComponent("Orbit Framework", isDirectory: false)
        if !FileManager.default.isExecutableFile(atPath: binary.path) {
            missing.append(binary.path)
        }
        for suffix in ["", " (GPU)", " (Renderer)"] {
            let name = "Orbit Helper\(suffix)"
            let executable = versioned.appendingPathComponent("Helpers/\(name).app/Contents/MacOS/\(name)")
            if !FileManager.default.isExecutableFile(atPath: executable.path) {
                missing.append(executable.path)
            }
        }
        for resource in ["orbit_resources.pak", "icudtl.dat", "v8_context_snapshot.arm64.bin"] {
            let url = versioned.appendingPathComponent("Resources/\(resource)", isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(url.path)
            }
        }
        if missing.isEmpty {
            record(.engineBundleLayout, true, "framework binary, three helper apps and three engine resources all present")
        } else {
            record(.engineBundleLayout, false, "missing or non-executable: \(missing.joined(separator: ", "))")
        }

        if let loaded = loadedFrameworkPath() {
            if loaded.hasPrefix(framework.path) {
                record(.loadedEngineFramework, true, loaded)
            } else {
                record(.loadedEngineFramework, false, "the loaded Orbit Framework is \(loaded), outside this bundle (\(framework.path))")
            }
        } else {
            record(.loadedEngineFramework, false, "no image named \"Orbit Framework\" is loaded in this process")
        }
    }

    private static func loadedFrameworkPath() -> String? {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            if path.hasSuffix("/Orbit Framework.framework/Versions/A/Orbit Framework")
                || path.hasSuffix("/Orbit Framework.framework/Orbit Framework") {
                return path
            }
        }
        return nil
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
            record(.isolatedEngineStorage, false, "session \"\(session.identifier)\" reports no storageURL — nothing knows where Chromium is writing")
            return
        }
        let resolved = storageURL.resolvingSymlinksInPath().path
        let productionProfile = EngineStorageDirectory.productionProfile.resolvingSymlinksInPath().path
        let privateRoot = EngineStorageDirectory.privateRoot.resolvingSymlinksInPath().path

        if resolved == productionProfile || resolved.hasPrefix(productionProfile + "/") {
            record(.isolatedEngineStorage, false, "the engine's browser context is \(storageURL.path), inside the real profile at \(productionProfile)")
            return
        }
        guard resolved.hasPrefix(privateRoot + "/") else {
            record(.isolatedEngineStorage, false, "the engine's browser context is \(storageURL.path), neither the production profile nor under \(privateRoot) — nothing knows to sweep it")
            return
        }
        guard session.isPersistent else {
            record(.isolatedEngineStorage, false, "session \"\(session.identifier)\" is ephemeral; a smoke run must exercise the persistent, extension-loading configuration the app really ships")
            return
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: storageURL.path)) ?? []
        if entries.isEmpty {
            record(.isolatedEngineStorage, false, "\(storageURL.path) is empty — Chromium wrote its browser state somewhere else")
        } else {
            record(.isolatedEngineStorage, true, "persistent, private at \(storageURL.path) (\(entries.count) entries)")
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

        record(.pageLoad, true, "\(committed.absoluteString) complete after \(String(format: "%.1f", waited + documentWaited))s, title=\(report["title"] ?? ""), bodyLength=\(report["bodyLength"] ?? "")")

        let arithmetic = "\(report["math"] as? String ?? "")-\(report["chrome"] as? String ?? "")"
        if arithmetic == "42-object" {
            record(.inPageJavaScript, true, arithmetic)
        } else {
            record(.inPageJavaScript, false, "in-page JavaScript returned \(arithmetic), expected \"42-object\"")
        }

        let agent = report["ua"] as? String ?? ""
        if agent.contains("Chrome/\(ChromiumBuild.majorVersion).") {
            record(.userAgent, true, agent)
        } else {
            record(.userAgent, false, "navigator.userAgent does not name Chrome \(ChromiumBuild.majorVersion): \(agent)")
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

    // MARK: - Plumbing

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("AppSmokeProbe: \(message)\n".utf8))
        logger.info("\(message, privacy: .public)")
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
