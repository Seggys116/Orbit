import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Drives the real running app to the Chrome Web Store and captures its own
/// window pixels to a PNG — a green test suite is not proof; this is.
@MainActor
enum WebStoreInstallVerifyProbe {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebStoreInstallVerifyProbe")

    // ORBIT_WEBSTORE_PROBE_CLICK's own consent decision, bypassing the SwiftUI sheet a human would
    // otherwise click. False outside that path; AppEnvironment+WebContentsDelegate reads this directly.
    static var autoApproveExtensionInstallConsent = false

    // nil means normal operation (real sheet shown). Read by OrbitChromiumPermissionsBridge
    // ahead of its isRunningUnderTests refusal, so a live suite can drive approve, not just refuse.
    static var autoAnswerExtensionPermissionsConsent: Bool?

    // MARK: - Entry point

    static func runIfEnabled(host: AppEnvironment) {
        guard isEnabled else { return }
        Task { await run(host: host) }
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static var isEnabled: Bool {
        environment["ORBIT_WEBSTORE_PROBE"] == "1"
    }

    private static var isClickModeEnabled: Bool {
        environment["ORBIT_WEBSTORE_PROBE_CLICK"] == "1"
    }

    // Skips the automatic post-install removal, so a later, separate launch can verify the
    // extension actually runs after a relaunch (extensions are only read at browser start-up).
    private static var leaveInstalledEnabled: Bool {
        environment["ORBIT_WEBSTORE_PROBE_CLICK_LEAVE_INSTALLED"] == "1"
    }

    // Standalone cleanup mode: removes an id left behind by a leave-installed run. Runs instead
    // of the store-page flow entirely.
    private static var uninstallOnlyID: String? {
        environment["ORBIT_WEBSTORE_PROBE_UNINSTALL"]
    }

    private static let docsOfflineExtensionID = "ghbmnnjooekpmoecnnnilnnbdlolhkhi"

    private static var targetURL: URL {
        if let raw = environment["ORBIT_WEBSTORE_PROBE_URL"], let url = URL(string: raw) {
            return url
        }
        if isClickModeEnabled {
            return URL(string: "https://chromewebstore.google.com/detail/\(docsOfflineExtensionID)")!
        }
        return URL(string: "https://chromewebstore.google.com/detail/gppongmhjkpfnbhagpmjfkannfbllamg")!
    }

    private static var targetExtensionID: String? {
        let path = targetURL.path
        guard let range = path.range(of: "[a-p]{32}", options: .regularExpression) else { return nil }
        return String(path[range])
    }

    private static var outputDirectory: URL? {
        guard let path = environment["ORBIT_WEBSTORE_PROBE_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var settleSeconds: Double {
        environment["ORBIT_WEBSTORE_PROBE_SETTLE"].flatMap(Double.init) ?? 10.0
    }

    private static var windowSizeOverride: NSSize? {
        guard let raw = environment["ORBIT_WEBSTORE_PROBE_SIZE"] else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return NSSize(width: width, height: height)
    }

    // Ad hoc QA interrogation only: JS evaluated in the probe tab before capture, result
    // written to stderr and eval-result.txt. Not used by the install/consent flow above.
    private static var evalJSSource: String? {
        environment["ORBIT_WEBSTORE_PROBE_EVAL_JS"]
    }

    // MARK: - The run

    private static func run(host: AppEnvironment) async {
        if let id = uninstallOnlyID {
            await settle(2.0)
            do {
                try AppEnvironment.processRoot.extensionStore.remove(id: id)
                emit("UNINSTALL-ONLY OK removed \(id)")
                finish(exitCode: 0)
            } catch {
                emit("UNINSTALL-ONLY FAIL could not remove \(id): \(error)")
                finish(exitCode: 1)
            }
            return
        }

        emit("starting — target=\(targetURL.absoluteString) clickMode=\(isClickModeEnabled)")
        // A persistent profile with restored tabs spawns several renderer
        // processes concurrently at launch; give that a head start so the
        // probe's own navigation isn't competing with a startup backlog.
        await settle(5.0)

        // A first launch shows onboarding, which is not an OrbitBorderlessWindow — skip
        // it the same way "Finish" would, instead of waiting on a window that isn't coming.
        if NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) == nil {
            if OnboardingWindowController.skipRemainingSteps(in: host) {
                emit("onboarding was showing — skipped it (host.hasCompletedOnboarding was false)")
            }
            emit("no browser window after launch — opening one")
            OrbitWindowController.openNewWindow(on: host)
            await settle(3.0)
        }
        emit("borderless windows=\(NSApp.windows.filter { $0 is OrbitBorderlessWindow }.count) frames=\(NSApp.windows.compactMap { ($0 as? OrbitBorderlessWindow).map { w in "\(Int(w.frame.width))x\(Int(w.frame.height)) visible=\(w.isVisible)" } })")

        guard let window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) else {
            emit("FAIL no browser window (no OrbitBorderlessWindow in NSApp.windows) even after skipping onboarding — cannot proceed")
            finish(exitCode: 1)
            return
        }
        guard let space = host.activeSpace else {
            emit("FAIL host.activeSpace is nil — no Space to open the Web Store tab in")
            finish(exitCode: 1)
            return
        }

        // A standard window's environment IS host.rootEnvironment (WindowSession.standard(on:)), so
        // toggling this here really does hide the sidebar this window paints — not a separate copy.
        let previousSidebarVisible = host.isSidebarVisible
        host.isSidebarVisible = false
        defer { host.isSidebarVisible = previousSidebarVisible }
        emit("sidebar hidden for the probe window (was \(previousSidebarVisible)) to give the store page's button column room")

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let size = windowSizeOverride {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true)
            emit("applied window size override \(Int(size.width))x\(Int(size.height))")
        }
        moveToBestScreen(window)
        await settle(0.5)

        let tabID = host.openTab(url: targetURL, in: space.id, activate: true)
        emit("opened tab \(tabID) -> \(targetURL.absoluteString)")
        await settle(1.0)

        // A cookie-less session in a consent-wall region bounces to consent.google.com before
        // reaching the store, which never self-dismisses; pre-seed CONSENT=YES so it lands on the store.
        if let contents = host.webContents[tabID] {
            let session = contents.session
            let now = Date()
            let stored = await session.setCookies([
                EngineCookie(
                    name: "CONSENT",
                    value: "YES+cb.20240101-00-p0.en+FX+000",
                    domain: ".google.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: false,
                    sameSite: .lax,
                    expiresAt: now.addingTimeInterval(60 * 60 * 24 * 365),
                    createdAt: now,
                    lastAccessedAt: now
                ),
                // CONSENT alone still bounces to consent.google.com in some regions (GB
                // observed); SOCS is the second cookie the live-engine suites also seed.
                EngineCookie(
                    name: "SOCS",
                    value: "CAI",
                    domain: ".google.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: false,
                    sameSite: .lax,
                    expiresAt: now.addingTimeInterval(60 * 60 * 24 * 365),
                    createdAt: now,
                    lastAccessedAt: now
                ),
            ])
            emit("pre-seeded CONSENT+SOCS cookies on .google.com (stored=\(stored)) — reloading")
            host.webContents[tabID]?.load(targetURL)
            await settle(1.0)
        } else {
            emit("no session for tab \(tabID) yet — skipping CONSENT cookie pre-seed")
        }

        // isLoading==false fires for the consent interstitial too, so wait for the committed
        // host to actually become the store's, not just for loading to stop once.
        await waitForWebStoreOrigin(of: tabID, in: host, timeout: 45)
        // The store's own bootstrap re-renders the button client-side after
        // the network load finishes; isLoading==false does not mean the
        // button has settled into its final state yet.
        await settle(settleSeconds)

        window.displayIfNeeded()
        await settle(0.3)

        if let evalJSSource, let contents = host.webContents[tabID] {
            await runEvalJS(evalJSSource, in: contents)
        }

        let image = await captureAtBackingScale(of: window)
        if image == nil {
            emit("FAIL capture returned nothing")
        }

        if isClickModeEnabled {
            await performClickInstallTest(tabID: tabID, host: host)
        }

        guard let image else {
            host.closeTab(tabID)
            finish(exitCode: 1)
            return
        }

        guard let directory = outputDirectory else {
            emit("OK captured (\(image.width)x\(image.height)) but ORBIT_WEBSTORE_PROBE_OUT is unset — nothing written to disk")
            host.closeTab(tabID)
            finish(exitCode: 0)
            return
        }

        let url = directory.appendingPathComponent("webstore-add-to-chrome.png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            emit("FAIL could not create a PNG destination at \(url.path)")
            host.closeTab(tabID)
            finish(exitCode: 1)
            return
        }
        // Independent of screen compositing: CGWindowListCreateImage returns
        // blank when the display is asleep, capturePreview reads the renderer's
        // own surface.
        if let contents = host.webContents[tabID],
           let preview = await contents.capturePreview(rect: nil, size: CGSize(width: 1200, height: 800)),
           let previewCG = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let previewURL = directory.appendingPathComponent("surface-capture.png", isDirectory: false)
            if let previewDestination = CGImageDestinationCreateWithURL(previewURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(previewDestination, previewCG, nil)
                if CGImageDestinationFinalize(previewDestination) {
                    emit("OK wrote \(previewCG.width)x\(previewCG.height) surface capture to \(previewURL.path)")
                }
            }
        } else {
            emit("capturePreview returned nil — no surface capture written")
        }

        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            emit("OK wrote \(image.width)x\(image.height) PNG to \(url.path)")
            host.closeTab(tabID)
            finish(exitCode: 0)
        } else {
            emit("FAIL PNG encoding failed")
            host.closeTab(tabID)
            finish(exitCode: 1)
        }
    }

    private static func runEvalJS(_ source: String, in contents: any WebContents) async {
        do {
            let result = try await contents.evaluateJavaScript(source)
            let described: String
            if JSONSerialization.isValidJSONObject(["v": result as Any]),
               let data = try? JSONSerialization.data(withJSONObject: ["v": result as Any]),
               let json = String(data: data, encoding: .utf8) {
                described = json
            } else {
                described = String(describing: result)
            }
            emit("EVAL-JS OK result=\(described)")
            if let directory = outputDirectory {
                let url = directory.appendingPathComponent("eval-result.txt", isDirectory: false)
                try? described.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            emit("EVAL-JS FAIL \(error)")
        }
    }

    // Non-webstore URLs can never satisfy the origin check below and would burn the whole
    // 45s timeout; those fall back to isLoading==false. The consent-interstitial path is untouched.
    private static func waitForWebStoreOrigin(of tabID: TabID, in host: AppEnvironment, timeout: Double) async {
        let requireWebStoreOrigin = WebStorePrivateBridge.isWebStoreOrigin(targetURL)
        var waited = 0.0
        let interval = 0.25
        var lastURL: URL?
        while waited < timeout {
            let state = host.navigationStates[tabID]
            if let url = state?.url, url != lastURL {
                lastURL = url
                emit("tab \(tabID) committed \(url.absoluteString)")
            }
            if state?.isLoading == false, let url = state?.url {
                if !requireWebStoreOrigin { return }
                if WebStorePrivateBridge.isWebStoreOrigin(url) { return }
            }
            await settle(interval)
            waited += interval
        }
        emit("tab \(tabID) never settled on a chromewebstore.google.com/chrome.google.com origin after \(Int(timeout))s (last committed: \(lastURL?.absoluteString ?? "none")) — capturing anyway")
    }

    // MARK: - ORBIT_WEBSTORE_PROBE_CLICK: real click, real install, real cleanup

    private static let buttonReadyProbeScript = """
    (function() {
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      var candidates = document.querySelectorAll('button, [role="button"]');
      for (var i = 0; i < candidates.length; i++) {
        var name = norm(candidates[i].getAttribute('aria-label') || candidates[i].textContent || '');
        if (name.indexOf('add to chrome') !== -1) {
          return candidates[i].disabled ? 'found-disabled' : 'ready';
        }
      }
      return 'not-found';
    })()
    """

    /// Matches either label: the button's DOM identity does not change between states, only its text.
    private static let buttonClickDispatchScript = """
    (function() {
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      var candidates = document.querySelectorAll('button, [role="button"]');
      for (var i = 0; i < candidates.length; i++) {
        var name = norm(candidates[i].getAttribute('aria-label') || candidates[i].textContent || '');
        if (name.indexOf('add to chrome') !== -1 || name.indexOf('remove from chrome') !== -1) {
          candidates[i].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          return 'dispatched';
        }
      }
      return 'not-found';
    })()
    """

    private static let buttonLabelStateScript = """
    (function() {
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      var candidates = document.querySelectorAll('button, [role="button"]');
      for (var i = 0; i < candidates.length; i++) {
        var name = norm(candidates[i].getAttribute('aria-label') || candidates[i].textContent || '');
        if (name.indexOf('remove from chrome') !== -1) { return candidates[i].disabled ? 'remove-disabled' : 'remove'; }
        if (name.indexOf('add to chrome') !== -1) { return candidates[i].disabled ? 'add-disabled' : 'add'; }
      }
      return 'not-found';
    })()
    """

    private static func performClickInstallTest(tabID: TabID, host: AppEnvironment) async {
        guard let extensionID = targetExtensionID else {
            emit("CLICK-MODE FAIL could not extract an extension id from \(targetURL.absoluteString)")
            return
        }
        guard let contents = host.webContents[tabID] else {
            emit("CLICK-MODE FAIL no WebContents for tab \(tabID)")
            return
        }
        if AppEnvironment.processRoot.extensionStore.installed().contains(where: { $0.id == extensionID }) {
            emit(
                "CLICK-MODE SKIP \(extensionID) is already installed on this machine — beginInstallWithManifest3 would " +
                "short-circuit to already_installed rather than exercise a real consent+install, so leaving it alone " +
                "instead of uninstalling a real extension this owner may actually use"
            )
            return
        }

        autoApproveExtensionInstallConsent = true
        defer { autoApproveExtensionInstallConsent = false }

        let cycles = max(1, Int(environment["ORBIT_WEBSTORE_PROBE_SOAK_CYCLES"] ?? "") ?? 1)
        for cycle in 1...cycles {
            emit("CLICK-MODE cycle \(cycle)/\(cycles) starting")

            var readyState: String?
            for _ in 0..<20 {
                readyState = try? await contents.evaluateJavaScript(buttonReadyProbeScript) as? String
                if readyState == "ready" { break }
                await settle(1.0)
            }
            emit("CLICK-MODE cycle \(cycle) button ready state before install dispatch = \(readyState ?? "nil")")
            guard readyState == "ready" else {
                emit("CLICK-MODE FAIL cycle \(cycle): button never reported ready within 20s — not dispatching a click")
                return
            }

            let installDispatch = try? await contents.evaluateJavaScript(buttonClickDispatchScript) as? String
            emit("CLICK-MODE cycle \(cycle) install click dispatch result = \(installDispatch ?? "nil")")
            guard installDispatch == "dispatched" else {
                emit("CLICK-MODE FAIL cycle \(cycle): could not find the button to dispatch an install click at")
                return
            }

            var installed: LoadedExtension?
            let installDeadline = Date().addingTimeInterval(300)
            while Date() < installDeadline {
                if let match = AppEnvironment.processRoot.extensionStore.installed().first(where: { $0.id == extensionID }) {
                    installed = match
                    break
                }
                await settle(1.0)
            }
            guard let installed else {
                emit("CLICK-MODE FAIL cycle \(cycle): no matching record ever appeared in AppEnvironment.processRoot.extensionStore.installed() within 300s after the click")
                return
            }
            emit("CLICK-MODE cycle \(cycle) OK installed id=\(installed.id) name=\(installed.name) version=\(installed.version) enabled=\(installed.isEnabled)")

            if leaveInstalledEnabled {
                emit("CLICK-MODE left \(installed.id) installed (ORBIT_WEBSTORE_PROBE_CLICK_LEAVE_INSTALLED=1) — clean it up with ORBIT_WEBSTORE_PROBE_UNINSTALL=\(installed.id)")
                return
            }

            var postInstallLabel: String?
            for _ in 0..<20 {
                postInstallLabel = try? await contents.evaluateJavaScript(buttonLabelStateScript) as? String
                if postInstallLabel == "remove" { break }
                await settle(1.0)
            }
            emit("CLICK-MODE cycle \(cycle) button label after install (via chrome.management.onInstalled) = \(postInstallLabel ?? "nil")")
            if postInstallLabel != "remove" {
                emit("CLICK-MODE FAIL cycle \(cycle): button label never reverted to 'Remove from Chrome' after a real install — the onInstalled management event round trip did not reach the page")
            }

            let uninstallDispatch = try? await contents.evaluateJavaScript(buttonClickDispatchScript) as? String
            emit("CLICK-MODE cycle \(cycle) uninstall click dispatch result = \(uninstallDispatch ?? "nil")")
            guard uninstallDispatch == "dispatched" else {
                emit("CLICK-MODE FAIL cycle \(cycle): could not find the button to dispatch an uninstall click at")
                return
            }

            var stillInstalled = true
            let uninstallDeadline = Date().addingTimeInterval(60)
            while Date() < uninstallDeadline {
                stillInstalled = AppEnvironment.processRoot.extensionStore.installed().contains { $0.id == extensionID }
                if !stillInstalled { break }
                await settle(1.0)
            }
            if stillInstalled {
                emit("CLICK-MODE FAIL cycle \(cycle): \(extensionID) is STILL in AppEnvironment.processRoot.extensionStore.installed() 60s after the uninstall click")
                return
            }

            let directory = AppEnvironment.processRoot.extensionStore.root.appendingPathComponent(extensionID, isDirectory: true)
            let directoryGone = !FileManager.default.fileExists(atPath: directory.path)
            emit("CLICK-MODE cycle \(cycle) uninstall record removed=true stagedDirectoryGone=\(directoryGone) (\(directory.path))")
            if !directoryGone {
                emit("CLICK-MODE FAIL cycle \(cycle): staged directory still exists after uninstall: \(directory.path)")
            }

            var postUninstallLabel: String?
            for _ in 0..<20 {
                postUninstallLabel = try? await contents.evaluateJavaScript(buttonLabelStateScript) as? String
                if postUninstallLabel == "add" { break }
                await settle(1.0)
            }
            emit("CLICK-MODE cycle \(cycle) button label after uninstall (via chrome.management.onUninstalled) = \(postUninstallLabel ?? "nil")")
            if postUninstallLabel != "add" {
                emit("CLICK-MODE FAIL cycle \(cycle): button label never reverted to 'Add to Chrome' after a real uninstall — the onUninstalled management event round trip did not reach the page")
            }

            emit("CLICK-MODE cycle \(cycle)/\(cycles) OK complete round trip: install -> real consent -> ExtensionStore record -> button flipped -> uninstall -> record and directory gone -> button flipped back")
        }
    }

    // MARK: - Capture

    // WindowPixelCapture, shared with AppSmokeProbe: no Screen Recording grant needed. Same
    // technique is used under XCTest — see EaselTeardownRegressionTests / ChromiumTabSwitchLiveTests.
    private static func captureAtBackingScale(of window: NSWindow, attempts: Int = 4) async -> CGImage? {
        await WindowPixelCapture.atBackingScale(of: window, attempts: attempts, log: emit)
    }

    private static func moveToBestScreen(_ window: NSWindow) {
        WindowPixelCapture.moveToBestScreen(window)
    }

    // MARK: - Plumbing

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("WebStoreInstallVerifyProbe: \(message)\n".utf8))
        logger.info("\(message, privacy: .public)")
    }

    private static func finish(exitCode: Int32) {
        NSApp.terminate(nil)
        exit(exitCode)
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
