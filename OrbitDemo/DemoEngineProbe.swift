import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MachO
import UniformTypeIdentifiers

@MainActor
enum DemoEngineProbe {

    // MARK: - Entry points

    // Called before super in applicationDidFinishLaunching, the last moment no engine exists:
    // super opens the first window, and OrbitWindowController.openNewWindow is what calls
    // startEngineIfNeeded().
    static func captureBaseline() {
        guard isEnabled else { return }
        observeCompetitors()
        baseline = snapshotOfRealProfile()
        emit("baseline: \(baseline.count) entr\(baseline.count == 1 ? "y" : "ies") under \(realProfileDirectory.path)")
    }

    static func runIfEnabled() {
        guard isEnabled else { return }
        Task { await run() }
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORBIT_DEMO_ENGINE_PROBE"] == "1"
    }

    private static var probeURL: URL {
        let raw = ProcessInfo.processInfo.environment["ORBIT_DEMO_ENGINE_PROBE_URL"]
        return raw.flatMap(URL.init(string:)) ?? URL(string: "https://example.com/")!
    }

    private static var baseline: [String: String] = [:]
    private static var failures: [String] = []

    // MARK: - The run

    private static func run() async {
        await settle(2.0)

        let env = AppEnvironment.demoApp

        // Before any pixel is read: a window left on whatever screen it opened on is routinely
        // occluded and at the wrong backing scale, and every capture below would then be measuring
        // the absence of a screen rather than the absence of a page.
        if let window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) {
            bringToFront(window)
            moveToBestScreen(window)
            bringToFront(window)
            await settle(1.5)
            if !window.occlusionState.contains(.visible) {
                emit("     the demo window is still occluded after being ordered front — every pixel check below is measuring a window macOS is not compositing.")
            }
        }

        checkEngineType(env)
        checkEmbeddedChromium()
        await checkPageLoads(env)
        await checkRendererSurface()
        await checkHoveredLinkReadout(env)
        checkStorageIsNotEphemeral(env)
        checkRealProfileUntouched()

        if failures.isEmpty {
            emit("VERDICT: PASS — OrbitDemo is running Orbit's embedded Chromium \(ChromiumBuild.version), on a persistent non-ephemeral session, and left the real profile alone.")
            NSApp.terminate(nil)
            exit(0)
        } else {
            for failure in failures { emit("FAIL: \(failure)") }
            emit("VERDICT: FAIL — \(failures.count) check(s) failed.")
            exit(1)
        }
    }

    // MARK: - 1. The engine object

    private static func checkEngineType(_ env: AppEnvironment) {
        guard let engine = env.engine else {
            fail("AppEnvironment.demoApp.engine is nil — no engine started at all.")
            return
        }
        let typeName = String(describing: type(of: engine))
        guard let chromium = engine as? ChromiumEngine else {
            fail("engine is \(typeName), not ChromiumEngine.")
            return
        }
        emit("OK   engine type: \(typeName)")
        emit("OK   engine kind: \(type(of: engine).kind.rawValue)")

        // versionDescription comes back through the dlsym'd OrbitChromiumVersionNumber, so it is
        // the loaded engine binary talking, not a Swift constant describing what should be there.
        let version = chromium.versionDescription
        if version.contains(ChromiumBuild.version) {
            emit("OK   engine version: \(version) (matches the pinned \(ChromiumBuild.version))")
        } else {
            fail("the running engine reports \(version), but this build is pinned to Chromium \(ChromiumBuild.version) — the app is not running the Chromium it was built against.")
        }

        let capabilities = engine.capabilities
        for required: (EngineCapabilities, String) in [
            (.extensions, "extensions"),
            (.contentBlocking, "contentBlocking"),
            (.backgroundSnapshots, "backgroundSnapshots"),
            (.developerTools, "developerTools"),
        ] where !capabilities.contains(required.0) {
            fail("the engine does not advertise .\(required.1), which ChromiumEngine declares — this is not a full Chromium embed.")
        }
        emit("OK   engine capabilities: extensions, contentBlocking, backgroundSnapshots, developerTools")
    }

    // MARK: - 2. What is inside this bundle, and what is actually loaded

    private static func checkEmbeddedChromium() {
        let frameworks = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let framework = frameworks
            .appendingPathComponent("Orbit Framework.framework", isDirectory: true)
        let versioned = framework.appendingPathComponent("Versions/A", isDirectory: true)

        let binary = versioned.appendingPathComponent("Orbit Framework", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: binary.path) {
            emit("OK   embedded framework binary: \(binary.path)")
        } else {
            fail("no executable Orbit Framework binary at \(binary.path)")
        }

        // Named individually, not counted: three correct helpers and one missing one looks like a
        // near-right count. The names come from Chromium/Embedder/BUILD.gn's helper bundles, which
        // are nested inside the framework rather than beside it.
        for suffix in ["", " (GPU)", " (Renderer)"] {
            let name = "Orbit Helper\(suffix)"
            let executable = versioned
                .appendingPathComponent("Helpers/\(name).app/Contents/MacOS/\(name)")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                emit("OK   helper: \(name).app")
            } else {
                fail("missing or non-executable helper at \(executable.path)")
            }
        }

        for resource in ["orbit_resources.pak", "icudtl.dat", "v8_context_snapshot.arm64.bin"] {
            let url = versioned.appendingPathComponent("Resources/\(resource)", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                emit("OK   engine resource: \(resource)")
            } else {
                fail("missing engine resource \(resource) at \(url.path)")
            }
        }

        // On disk is not the same claim as loaded: this walks dyld's own image list, so it can only
        // be satisfied by the framework this process really dlopen'd.
        let loadedPath = loadedFrameworkPath()
        if let loadedPath {
            emit("OK   dyld has the engine framework loaded: \(loadedPath)")
            if loadedPath.hasPrefix(framework.path) {
                emit("OK   the loaded framework is this bundle's own copy, not one from elsewhere on disk")
            } else {
                fail("the loaded Orbit Framework is at \(loadedPath), which is outside this app bundle (\(framework.path)) — the demo is running someone else's engine.")
            }
        } else {
            fail("no image named \"Orbit Framework\" is loaded in this process — nothing dlopen'd the engine, so whatever answered above is not Chromium.")
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

    // MARK: - 3 and 4. A real tab, a real page, a real renderer

    private static var probedTab: TabID?
    private static var probedContents: (any WebContents)?

    private static func checkPageLoads(_ env: AppEnvironment) async {
        guard let space = env.activeSpace else {
            fail("the demo's seeded document has no active Space — the pre-seeded defaults are broken.")
            return
        }
        let window = NSApp.windows.first { $0 is OrbitBorderlessWindow }
        var paneBaseline: CGImage?
        if let window {
            paneBaseline = await captureAtBackingScale(of: window)
        }

        let url = probeURL
        let tab = env.openTab(url: url, in: space.id, activate: true)
        await settle(1.5)
        guard let contents = env.webContents[tab] else {
            fail("opening a tab on \(url.absoluteString) produced no WebContents at all.")
            return
        }
        probedTab = tab
        probedContents = contents

        let contentsType = String(describing: type(of: contents))
        if contents is ChromiumWebContents {
            emit("OK   tab renderer type: \(contentsType)")
        } else {
            fail("the demo's tab is backed by \(contentsType), not ChromiumWebContents.")
        }

        // loadInTab, not contents.load: a bare load bypasses the navigation-generation bump that
        // materializeWebContents' deferred content-blocking load checks, and the deferred load then
        // races this one. This is also the funnel every real navigation in the app goes through.
        env.loadInTab(tab, url: url)
        await settle(1.5)
        var waited = 0.0
        while waited < 30.0 {
            let state = env.navigationStates[tab]
            if state?.isLoading == false, isTarget(state?.url, url) { break }
            await settle(0.25)
            waited += 0.25
        }
        guard let committed = env.navigationStates[tab]?.url, isTarget(committed, url),
              env.navigationStates[tab]?.isLoading == false
        else {
            let engineError = env.tabErrors[tab].map { "\($0.code) \($0.underlyingDescription)" } ?? "none reported"
            fail("after 30s the tab reports url=\(String(describing: env.navigationStates[tab]?.url)) isLoading=\(String(describing: env.navigationStates[tab]?.isLoading)) engineError=\(engineError) — \(url.absoluteString) never finished loading.")
            return
        }
        if let engineError = env.tabErrors[tab] {
            fail("the navigation to \(url.absoluteString) reported an engine error: \(engineError.code) \(engineError.underlyingDescription)")
        }
        emit("OK   loaded \(committed.absoluteString) (polled \(String(format: "%.1f", waited))s)")

        // isLoading==false can still mean the initial empty document (also readyState "complete"),
        // so this waits for the document to be complete AND actually be the requested URL.
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
              anchors: document.querySelectorAll('a[href^="http"]').length,
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
            let last = try? await contents.evaluateJavaScript("document.readyState + ' ' + location.href")
            let engineError = env.tabErrors[tab].map { "\($0.code) \($0.underlyingDescription)" } ?? "none"
            fail("30s after the browser reported \(committed.absoluteString) loaded, the tab's main frame is still \(String(describing: last ?? "")) — the navigation never reached the renderer. Browser-side state: isLoading=\(String(describing: env.navigationStates[tab]?.isLoading)) url=\(String(describing: env.navigationStates[tab]?.url)) engineError=\(engineError).")
            return
        }
        emit("OK   document reached readyState complete after \(String(format: "%.1f", documentWaited))s: href=\(report["href"] ?? "") title=\(report["title"] ?? "") anchors=\(report["anchors"] ?? "") bodyLength=\(report["bodyLength"] ?? "")")

        let agentString = report["ua"] as? String ?? ""
        if agentString.contains("Chrome/\(ChromiumBuild.majorVersion).") {
            emit("OK   navigator.userAgent: \(agentString)")
        } else {
            fail("navigator.userAgent does not name Chrome \(ChromiumBuild.majorVersion): \(agentString)")
        }

        let arithmeticString = "\(report["math"] as? String ?? "")-\(report["chrome"] as? String ?? "")"
        if arithmeticString == "42-object" {
            emit("OK   evaluated in-page JavaScript: \(arithmeticString)")
        } else {
            fail("in-page JavaScript returned \(arithmeticString), expected \"42-object\".")
        }

        await checkPagePaintedOnScreen(window: window, baseline: paneBaseline, contents: contents)
    }

    // Host equality alone is not enough: about:blank and a file:// target both have no host, so the
    // initial empty document would satisfy a host comparison for every local page.
    private static func isTarget(_ candidate: URL?, _ target: URL) -> Bool {
        guard let candidate else { return false }
        if let host = target.host, !host.isEmpty { return candidate.host == host }
        if target.isFileURL, candidate.isFileURL {
            return candidate.resolvingSymlinksInPath().standardizedFileURL
                == target.resolvingSymlinksInPath().standardizedFileURL
        }
        return candidate.absoluteString == target.absoluteString
    }

    // The status flag says "loaded"; this says the compositor's output for that load actually
    // reached this window's real screen pixels.
    private static func checkPagePaintedOnScreen(
        window: NSWindow?,
        baseline: CGImage?,
        contents: any WebContents
    ) async {
        guard let window else {
            fail("paint check skipped: the demo has no OrbitBorderlessWindow to read pixels from.")
            return
        }
        guard let baseline else {
            fail("paint check skipped: the pre-load window capture returned nothing.")
            return
        }
        bringToFront(window)
        await settle(2.0)
        emitWindowDiagnostics(window, contents: contents)

        guard let paneInWindow = paneRectInWindow(for: contents, window: window) else {
            fail("paint check skipped: the tab's engine view is not in this window, so nothing on screen belongs to it.")
            return
        }
        guard let before = crop(baseline, toWindowRect: paneInWindow, of: window),
              let after = await captureAtBackingScale(of: window).flatMap({ crop($0, toWindowRect: paneInWindow, of: window) })
        else {
            fail("paint check: could not crop the pane out of the window captures.")
            return
        }
        dump(before, named: "page-pane-before")
        dump(after, named: "page-pane-after")

        let changed = differingPixels(before, after)
        let total = after.width * after.height
        let threshold = max(1_000, total / 50)
        if changed > threshold {
            emit("OK   page painted on screen: \(changed) of \(total) pane pixels changed across the load (needed > \(threshold))")
        } else {
            fail("paint check: only \(changed) of \(total) pane pixels changed across the load (needed > \(threshold)). Navigation reported success but the compositor put nothing new on screen — a blank pane is the engine view being missing from the container.")
        }
    }

    // A window macOS considers occluded stops receiving compositor frames, and every pixel check
    // below would then be measuring the absence of a screen, not the absence of a page.
    private static func emitWindowDiagnostics(_ window: NSWindow, contents: any WebContents) {
        let view = contents.view
        emit("""
                 window: frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible) key=\(window.isKeyWindow) \
        occlusionVisible=\(window.occlusionState.contains(.visible)) miniaturized=\(window.isMiniaturized) \
        screen=\(window.screen?.localizedName ?? "none") appActive=\(NSApp.isActive)
        """)
        emit("""
                 engine view: \(NSStringFromClass(type(of: view))) frame=\(NSStringFromRect(view.frame)) \
        hidden=\(view.isHidden) inWindow=\(view.window === window) \
        superview=\(view.superview.map { NSStringFromClass(type(of: $0)) } ?? "none")
        """)
    }

    // MARK: - 5. The renderer's own surface, independent of screen compositing

    private static func checkRendererSurface() async {
        guard let contents = probedContents else {
            fail("surface check skipped: the page check never produced a WebContents.")
            return
        }
        guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: 1000, height: 700)) else {
            fail("surface check: capturePreview returned nil — RenderWidgetHostView::CopyFromSurface produced nothing, so there is no live renderer surface behind this tab.")
            return
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail("surface check: capturePreview's NSImage has no CGImage backing.")
            return
        }
        dump(cgImage, named: "renderer-surface")
        let colours = distinctSampledColours(of: cgImage)
        if colours > 2 {
            emit("OK   renderer surface: \(cgImage.width)x\(cgImage.height), \(colours) distinct sampled colours")
        } else {
            fail("surface check: the renderer surface is \(cgImage.width)x\(cgImage.height) with only \(colours) distinct sampled colours — the compositor copied back a blank frame.")
        }
    }

    // MARK: - 6. The hovered-link readout, end to end, in this build

    private static func checkHoveredLinkReadout(_ env: AppEnvironment) async {
        guard let contents = probedContents, let tab = probedTab else {
            fail("hover check skipped: the page check never produced a WebContents.")
            return
        }
        guard let window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) else {
            fail("hover check skipped: the demo has no browser window, so nothing hosts the readout.")
            return
        }

        bringToFront(window)
        await settle(0.8)

        let href: String
        do {
            let value = try await contents.evaluateJavaScript(
                "(document.querySelector('a[href^=\"http\"]') || {}).href || ''"
            )
            href = String(describing: value ?? "")
        } catch {
            fail("hover check: reading the page's first anchor threw: \(error)")
            return
        }
        guard !href.isEmpty, let expected = URL(string: href) else {
            fail("hover check: \(probeURL.absoluteString) has no http(s) anchor to hover. Point ORBIT_DEMO_ENGINE_PROBE_URL at a page that has one.")
            return
        }
        emit("OK   page anchor to hover: \(href)")

        guard let overlay = overlayView(above: contents.view) else {
            fail("hover check: no PageOverlayHostingView in the pane hosting this tab — the readout is not mounted at all, so it cannot ever appear.")
            return
        }
        guard let container = overlay.superview, container.subviews.last === overlay else {
            let order = (overlay.superview?.subviews ?? []).map { NSStringFromClass(type(of: $0)) }
            fail("hover check: the overlay is not the topmost subview of its container, so the page draws over it. Order was \(order).")
            return
        }
        emit("OK   readout overlay is the topmost subview of the pane (\(container.subviews.count) subviews)")

        guard let cornerInWindow = readoutCornerInWindow(overlay: overlay, window: window) else {
            fail("hover check: could not locate the readout corner in window coordinates.")
            return
        }

        emit("     window frame \(NSStringFromRect(window.frame)), overlay in window \(NSStringFromRect(overlay.convert(overlay.bounds, to: nil))), sampling \(NSStringFromRect(cornerInWindow))")

        LinkHoverStatus.shared.report(nil, forContents: contents.id)
        await settle(0.6)
        guard let before = await stableBaselineCorner(of: window, cornerInWindow) else {
            return
        }

        _ = try? await contents.evaluateJavaScript("""
        document.querySelector('a[href^="http"]')
            .dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
        """)

        var waited = 0.0
        while waited < 8.0, LinkHoverStatus.shared.url(forContents: contents.id) == nil {
            await settle(0.2)
            waited += 0.2
        }
        guard let reported = LinkHoverStatus.shared.url(forContents: contents.id) else {
            fail("hover check: LinkHoverStatus never received a URL after \(String(format: "%.0f", waited))s — the LinkHoverObserverScript -> orbitLinkHover channel -> WebContentsDelegate chain is broken in this build.")
            return
        }
        guard reported == expected else {
            fail("hover check: LinkHoverStatus holds \(reported.absoluteString) but the anchor is \(href).")
            return
        }
        emit("OK   LinkHoverStatus received: \(reported.absoluteString)")

        guard let pillText = LinkHoverStatusText.text(for: reported) else {
            fail("hover check: LinkHoverStatusText refuses to render \(reported.absoluteString), so the pill would draw nothing.")
            return
        }
        emit("OK   readout text would be: \(pillText)")

        if env.hoveredLinkURL == expected {
            emit("OK   AppEnvironment.hoveredLinkURL: \(expected.absoluteString)")
        } else {
            fail("hover check: AppEnvironment.hoveredLinkURL is \(String(describing: env.hoveredLinkURL)), expected \(expected.absoluteString).")
        }

        await settle(1.2)
        guard let during = await captureCorner(of: window, cornerInWindow) else {
            fail("hover check: the hovered window capture returned nothing.")
            return
        }
        dump(before, named: "hover-corner-before")
        dump(during, named: "hover-corner-during")
        if let wholeWindow = await captureAtBackingScale(of: window) {
            dump(wholeWindow, named: "hover-window-during")
        }
        let changedOnHover = differingPixels(before, during)
        let threshold = 1_000
        if changedOnHover > threshold {
            emit("OK   readout painted: \(changedOnHover) pixels changed in the pane's bottom-left corner")
        } else {
            fail("hover check: only \(changedOnHover) pixels changed in the readout corner (needed > \(threshold)). The URL arrived but nothing was drawn.")
            return
        }

        _ = try? await contents.evaluateJavaScript("""
        document.querySelector('a[href^="http"]')
            .dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: document.body }));
        """)
        waited = 0.0
        while waited < 8.0, LinkHoverStatus.shared.url(forContents: contents.id) != nil {
            await settle(0.2)
            waited += 0.2
        }
        if LinkHoverStatus.shared.url(forContents: contents.id) != nil {
            fail("hover check: leaving the link did not clear the readout, so the last URL hovered stays on screen for the rest of the session.")
            return
        }
        await settle(1.2)
        guard let after = await captureCorner(of: window, cornerInWindow) else {
            fail("hover check: the post-mouseout window capture returned nothing.")
            return
        }
        let changedAfterLeaving = differingPixels(before, after)
        if changedAfterLeaving < changedOnHover / 4 {
            emit("OK   readout cleared: corner returned to \(changedAfterLeaving) pixels different from baseline (was \(changedOnHover))")
        } else {
            fail("hover check: after mouseout the corner is still \(changedAfterLeaving) pixels from baseline (hover was \(changedOnHover)) — the change was not the readout appearing and disappearing.")
        }

        LinkHoverStatus.shared.report(nil, forContents: contents.id)
        _ = tab
    }

    // Taken twice and accepted only when they agree: the window may still be settling.
    private static func stableBaselineCorner(of window: NSWindow, _ corner: CGRect) async -> CGImage? {
        var lastDrift = -1
        for attempt in 1...4 {
            guard let first = await captureCorner(of: window, corner) else {
                fail("hover check: the baseline window capture returned nothing.")
                return nil
            }
            await settle(0.7)
            guard let second = await captureCorner(of: window, corner) else {
                fail("hover check: the second baseline window capture returned nothing.")
                return nil
            }
            let drift = differingPixels(first, second)
            lastDrift = drift
            let allowed = max(200, (second.width * second.height) / 100)
            if drift <= allowed {
                if attempt > 1 { emit("     baseline capture settled on attempt \(attempt) (drift \(drift) <= \(allowed))") }
                return second
            }
            emit("     baseline capture unsteady: \(drift) pixels drifted between two idle captures (attempt \(attempt)/4)")
            await settle(1.5)
        }
        fail("hover check: could not get a steady baseline capture of the readout corner after 4 attempts (last drift \(lastDrift) pixels). The window was still changing while nothing was hovered, so a before/after comparison would mean nothing. This is a measurement failure, not a verdict on the readout — re-run with the demo's window unobscured.")
        return nil
    }

    // MARK: - Pixels

    // Through DemoCaptureDriver, not a private copy: its dlsym'd CGWindowListCreateImage reads this
    // process's own window without a screen-recording grant, and the capture must go through the
    // same path the screenshot driver uses or the two would be measuring different things.
    private static func captureAtBackingScale(of window: NSWindow) async -> CGImage? {
        await DemoCaptureDriver.captureAtBackingScale(of: window)
    }

    private static func dump(_ image: CGImage, named name: String) {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_DEMO_ENGINE_PROBE_OUT"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            emit("     wrote \(url.path) (\(image.width)x\(image.height))")
        }
    }

    // Found by class name: the type is private to WebContentsHostView.swift and should stay that way.
    private static func overlayView(above pageView: NSView) -> NSView? {
        guard let container = pageView.superview else { return nil }
        return container.subviews.first {
            NSStringFromClass(type(of: $0)).contains("PageOverlayHostingView")
        }
    }

    private static func readoutCornerInWindow(overlay: NSView, window: NSWindow) -> CGRect? {
        guard overlay.window === window else { return nil }
        let inWindow = overlay.convert(overlay.bounds, to: nil)
        guard inWindow.width > 40, inWindow.height > 40 else { return nil }
        let width = min(inWindow.width * 0.7, inWindow.width)
        let height = min(90.0, inWindow.height)
        return CGRect(x: inWindow.minX, y: inWindow.minY, width: width, height: height)
    }

    // orderFrontRegardless as well as activate: another app is frontmost while this runs and macOS
    // routinely refuses the activation, leaving the window occluded and therefore uncomposited.
    private static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // Without this the shot is silently half-resolution, and more often than not on a screen where
    // the window is fully occluded and stops being composited at all.
    private static func moveToBestScreen(_ window: NSWindow) {
        guard let best = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return }
        guard window.screen !== best else { return }
        let frame = window.frame
        let visible = best.visibleFrame
        window.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    private static func paneRectInWindow(for contents: any WebContents, window: NSWindow) -> CGRect? {
        let view = contents.view
        guard view.window === window else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        guard rect.width > 40, rect.height > 40 else { return nil }
        return rect
    }

    private static func captureCorner(of window: NSWindow, _ cornerInWindow: CGRect) async -> CGImage? {
        guard let full = await captureAtBackingScale(of: window) else { return nil }
        return crop(full, toWindowRect: cornerInWindow, of: window)
    }

    private static func crop(_ full: CGImage, toWindowRect rectInWindow: CGRect, of window: NSWindow) -> CGImage? {
        let scale = CGFloat(full.width) / window.frame.width
        guard scale > 0 else { return nil }
        let flippedY = window.frame.height - rectInWindow.maxY
        let rect = CGRect(
            x: (rectInWindow.minX * scale).rounded(.down),
            y: (flippedY * scale).rounded(.down),
            width: (rectInWindow.width * scale).rounded(.down),
            height: (rectInWindow.height * scale).rounded(.down)
        ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard rect.width > 8, rect.height > 8 else { return nil }
        return full.cropping(to: rect)
    }

    private static func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return .max }
        guard let left = rgbaBytes(of: a), let right = rgbaBytes(of: b) else { return .max }
        var count = 0
        var index = 0
        while index + 3 < left.count {
            let dr = abs(Int(left[index]) - Int(right[index]))
            let dg = abs(Int(left[index + 1]) - Int(right[index + 1]))
            let db = abs(Int(left[index + 2]) - Int(right[index + 2]))
            if dr + dg + db > 24 { count += 1 }
            index += 4
        }
        return count
    }

    private static func distinctSampledColours(of image: CGImage) -> Int {
        guard let bytes = rgbaBytes(of: image) else { return 0 }
        var colours = Set<UInt32>()
        let stepX = max(1, image.width / 64)
        let stepY = max(1, image.height / 64)
        for y in stride(from: 0, to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                let offset = (y * image.width + x) * 4
                guard offset + 3 < bytes.count else { continue }
                colours.insert(
                    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
                )
            }
        }
        return colours.count
    }

    // Redraws into a known 8-bit RGBA layout: two CGImages of the same window aren't
    // guaranteed to share a byte order, so comparing raw buffers directly compares encodings.
    private static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let success: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? buffer : nil
    }

    // MARK: - 7. Where it is allowed to write

    // The demo must run EngineStorage.isolated (persistent, private per-process dir), not ephemeral:
    // an ephemeral engine loads no extensions and reads as incognito, so the Web Store refuses installs.
    private static func checkStorageIsNotEphemeral(_ env: AppEnvironment) {
        guard let engine = env.engine else { return }
        guard env.isDemo else {
            fail("AppEnvironment.demoApp.isDemo is false — the demo is running the production environment.")
            return
        }
        let session = probedContents?.session ?? engine.defaultSession
        if session.isPersistent {
            emit("OK   engine session \"\(session.identifier)\" is persistent, not ephemeral")
        } else {
            fail("engine session \"\(session.identifier)\" is ephemeral. The demo must run EngineStorage.isolated, not .ephemeral — an ephemeral engine loads no extensions and every session reads as incognito.")
        }

        guard let storageURL = session.storageURL else {
            fail("the engine session reports no storageURL — OrbitBrowserContextPath answered nothing, so there is no way to tell where Chromium is writing.")
            return
        }
        emit("     engine browser-context path: \(storageURL.path)")

        // The other half of EngineStorage.isolated: a private per-process directory. Both sides come
        // from EngineStorageDirectory rather than being spelled out here, so a redirected home moves
        // them together and this compares like with like.
        let productionProfile = EngineStorageDirectory.productionProfile
        let privateRoot = EngineStorageDirectory.privateRoot
        let resolvedStorage = storageURL.resolvingSymlinksInPath().path
        let resolvedProduction = productionProfile.resolvingSymlinksInPath().path
        if resolvedStorage == resolvedProduction || resolvedStorage.hasPrefix(resolvedProduction + "/") {
            fail("the demo's Chromium browser context is \(storageURL.path), which is the production profile directory (\(productionProfile.path)). EngineStorage.isolated promises a private per-process directory, so running the demo is writing cookies, cache, Preferences and extension state straight into the real browser's profile.")
        } else if !resolvedStorage.hasPrefix(privateRoot.resolvingSymlinksInPath().path + "/") {
            fail("the demo's Chromium browser context is \(storageURL.path), which is neither the production profile nor under EngineStorageDirectory's private root (\(privateRoot.path)) — nothing knows to sweep it, so every demo run leaks a profile.")
        } else {
            emit("OK   engine browser-context path is a private per-process directory under \(privateRoot.path), isolated from the production profile at \(productionProfile.path)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: storageURL.path)) ?? []
        if contents.isEmpty {
            fail("the engine's browser-context directory is empty — Chromium wrote its browser-process state somewhere else entirely.")
        } else {
            emit("OK   Chromium wrote into its browser-context directory: \(contents.sorted().prefix(12).joined(separator: ", "))\(contents.count > 12 ? ", … (\(contents.count) entries)" : "")")
        }
    }

    // MARK: - 8. The real profile

    private static func checkRealProfileUntouched() {
        let after = snapshotOfRealProfile()
        if after == baseline {
            emit("OK   real profile unchanged (\(baseline.count) entr\(baseline.count == 1 ? "y" : "ies") at \(realProfileDirectory.path))")
            return
        }

        let added = after.keys.filter { baseline[$0] == nil }.sorted()
        let removed = baseline.keys.filter { after[$0] == nil }.sorted()
        let changed = after.keys.filter { baseline[$0] != nil && baseline[$0] != after[$0] }.sorted()
        let detail = "added \(summarise(added)), removed \(summarise(removed)), modified \(summarise(changed))"

        // Sampled continuously since the baseline, not once at the end: an OrbitAppTests live-engine
        // host can start and exit entirely within this run, and a final-only snapshot would miss it.
        for application in currentCompetitors() {
            noteCompetitor(application)
        }
        if competitorsSeen.isEmpty {
            fail("the real profile at \(realProfileDirectory.path) changed during this run — \(detail). No other Orbit ran at any point between the baseline and now, so this process wrote them.")
        } else {
            fail("could not measure whether the demo left the real profile alone: \(competitorsSeen.count) other Orbit process(es) ran against that directory during this probe — \(competitorsSeen.sorted().joined(separator: ", ")). Files that changed: \(detail). Re-run with no other Orbit, and no OrbitAppTests live-engine run, in flight.")
        }
    }

    // MARK: - Other processes on the same profile

    private static var competitorsSeen: Set<String> = []
    private static var competitorObserver: NSObjectProtocol?

    private static func observeCompetitors() {
        for application in currentCompetitors() {
            noteCompetitor(application)
        }
        competitorObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == competitorBundleID
            else { return }
            MainActor.assumeIsolated { noteCompetitor(application) }
        }
    }

    private static let competitorBundleID = "com.zak-noble-clarke.Orbit"

    private static func currentCompetitors() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == competitorBundleID }
    }

    private static func noteCompetitor(_ application: NSRunningApplication) {
        competitorsSeen.insert("\(application.localizedName ?? "Orbit") (pid \(application.processIdentifier))")
    }

    private static func summarise(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "none" }
        let shown = paths.prefix(15).joined(separator: ", ")
        return paths.count > 15 ? "\(shown), … (\(paths.count) total)" : "\(shown) (\(paths.count))"
    }

    // Resolved from the password database, not from the environment: CFFIXED_USER_HOME/HOME move
    // every Foundation and Chromium path lookup at once, so reading this the ordinary way would let
    // a redirected run pass this check without ever looking at the directory it is about.
    static var realProfileDirectory: URL {
        var home = NSHomeDirectory()
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_dir {
            home = String(cString: raw)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Orbit", isDirectory: true)
    }

    private static func snapshotOfRealProfile() -> [String: String] {
        let root = realProfileDirectory
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return [:] }

        var result: [String: String] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            result[relative] = "\(size)@\(modified)"
        }
        return result
    }

    // MARK: - Plumbing

    private static func fail(_ message: String) {
        failures.append(message)
        emit("FAIL \(message)")
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("DemoEngineProbe: \(message)\n".utf8))
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
