import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum DemoCaptureDriver {

    // MARK: - Entry point

    static func runIfEnabled() {
        guard environment["ORBIT_CAPTURE"] == "1" else { return }
        guard let directory = outputDirectory else {
            log("ORBIT_CAPTURE=1 but ORBIT_CAPTURE_DIR is unset or unusable — nothing to write to.")
            NSApp.terminate(nil)
            return
        }
        Task { await run(writingTo: directory) }
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static var outputDirectory: URL? {
        guard let path = environment["ORBIT_CAPTURE_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            log("could not create \(url.path): \(error.localizedDescription)")
            return nil
        }
        return url
    }

    private static var settleSeconds: Double {
        environment["ORBIT_CAPTURE_SETTLE"].flatMap(Double.init) ?? 6.0
    }

    // MARK: - The run

    private static func run(writingTo directory: URL) async {
        log("starting — writing to \(directory.path)")

        await settle(1.5)

        guard let window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) else {
            log("no browser window — nothing to capture.")
            NSApp.terminate(nil)
            return
        }
        let env = AppEnvironment.demoApp

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        moveToBestScreen(window)
        await settle(0.5)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle(0.5)

        await loadRealPages(in: env)

        for shot in shots {
            log("preparing \(shot.name)")
            await shot.prepare(env, window)
            await settle(shot.settle)

            guard let target = shot.window(env, window) else {
                log("FAILED \(shot.name): its window was never created")
                continue
            }
            moveToBestScreen(target)
            await settle(0.4)
            guard let image = await captureAtBackingScale(of: target) else {
                log("FAILED \(shot.name): capture returned nothing")
                continue
            }
            write(image, named: shot.name, into: directory)

            await shot.cleanUp(env, window)
            await settle(shot.settle)
        }

        log("done")
        NSApp.terminate(nil)
    }

    // MARK: - Shot list

    private struct Shot {
        var name: String
        var prepare: (AppEnvironment, NSWindow) async -> Void = { _, _ in }
        var window: (AppEnvironment, NSWindow) -> NSWindow? = { _, browser in browser }
        var cleanUp: (AppEnvironment, NSWindow) async -> Void = { _, _ in }
        var settle: Double = 2.0
    }

    private static var shots: [Shot] {
        [
            Shot(name: "window", settle: 1.0),

            Shot(
                name: "window-focus",
                prepare: { env, _ in
                    env.isSidebarVisible = false
                },
                cleanUp: { env, _ in
                    env.isSidebarVisible = true
                },
                settle: 2.0
            ),

            Shot(
                name: "sidebar",
                prepare: { env, _ in
                    if let personal = env.store.state.spaces.first(where: { $0.name == "Personal" }) {
                        env.selectSpace(personal.id)
                    }
                    env.isSidebarVisible = true
                    expandEveryFolder(in: env)
                    await loadRealPages(in: env)
                },
                settle: 2.5
            ),

            Shot(
                name: "command-bar",
                prepare: { env, window in
                    env.perform(.newTabCommandBar)
                    await settle(1.0)
                    type("design", into: window)
                },
                cleanUp: { env, _ in env.dismissCommandBar() },
                settle: 2.0
            ),

            Shot(
                name: "peek",
                prepare: { env, _ in
                    guard let sourceTabID = env.activeTabID else {
                        log("peek: no active tab to preview from")
                        return
                    }
                    PeekState.shared.present(
                        sourceTabID: sourceTabID,
                        url: URL(string: "https://developer.mozilla.org/en-US/docs/Web/CSS/grid")!
                    )
                },
                cleanUp: { _, _ in PeekState.shared.dismiss() },
                settle: 7.0
            ),

            Shot(
                name: "easel-notes",
                prepare: { env, _ in await seedEaselAndNotes(in: env) },
                settle: 4.0
            ),

            Shot(
                name: "split-view",
                prepare: { env, _ in await seedSplit(in: env) },
                settle: 8.0
            ),

            settingsShot(name: "settings-profiles", pane: .profiles),

            settingsShot(name: "settings-keybinds", pane: .shortcuts),

            settingsShot(name: "settings-general", pane: .general),

            Shot(
                name: "boosts",
                prepare: { env, _ in
                    seedBoost(in: env)
                    boostsWindow = BoostsEditorWindowController.show(host: "github.com").window
                    await settle(1.5)
                    boostsWindow?.makeKeyAndOrderFront(nil)
                },
                window: { _, _ in boostsWindow },
                settle: 2.5
            ),
        ]
    }

    private static var boostsWindow: NSWindow?

    private static func settingsShot(name: String, pane: SettingsPane) -> Shot {
        Shot(
            name: name,
            prepare: { _, _ in
                SettingsWindowController.show(pane: pane)
                await settle(1.5)
                settingsWindow?.makeKeyAndOrderFront(nil)
            },
            window: { _, _ in settingsWindow },
            settle: 2.0
        )
    }

    // "The visible window that is not a browser window": SettingsWindowController reuses one window.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is OrbitBorderlessWindow) }
    }

    // MARK: - Real pages

    private static let capturePages: [URL] = [
        URL(string: "https://github.com/Seggys116/Orbit")!,
        URL(string: "https://linear.app/")!,
        URL(string: "https://www.notion.com/")!,
        URL(string: "https://en.wikipedia.org/wiki/Orbit")!,
    ]

    private static let splitPages: [URL] = [
        URL(string: "https://en.wikipedia.org/wiki/Orbit")!,
        URL(string: "https://news.ycombinator.com/")!,
        URL(string: "https://developer.mozilla.org/en-US/docs/Web/CSS/grid")!,
    ]

    private static func loadRealPages(in env: AppEnvironment) async {
        guard let space = env.activeSpace else { return }
        // Web tabs only: an orbit:// surface has no engine contents and never appears in navigationStates.
        let tabs = Array(
            space.today
                .compactMap { env.tab($0) }
                .filter { $0.url.scheme == "http" || $0.url.scheme == "https" }
                .prefix(capturePages.count)
                .map(\.id)
        )
        guard !tabs.isEmpty else {
            log("active Space has no Today web tabs to load pages into")
            return
        }

        // Activate before loading: a freshly mounted engine view paints nothing until it draws.
        if let first = tabs.first {
            env.activateTab(first)
            await settle(0.8)
        }

        for (tab, url) in zip(tabs, capturePages) {
            env.materializeWebContents(for: tab, url: url)
            env.webContents[tab]?.load(url)
        }

        await settle(1.5)

        for tab in tabs {
            await waitForLoad(of: tab, in: env)
        }

        await settle(settleSeconds)

        // Reload after re-activating: activateTab re-hosts the engine view into an unpainted pane.
        if let first = tabs.first, let url = capturePages.first {
            env.activateTab(first)
            await settle(0.8)
            env.webContents[first]?.load(url)
            await settle(1.5)
            await waitForLoad(of: first, in: env)
            await settle(settleSeconds)
        }
        await settle(2.0)
    }

    private static func waitForLoad(of tabID: TabID, in env: AppEnvironment, timeout: Double = 25) async {
        var waited = 0.0
        let interval = 0.25
        while waited < timeout {
            if env.navigationStates[tabID]?.isLoading == false { return }
            await settle(interval)
            waited += interval
        }
        if env.navigationStates[tabID] == nil {
            log("tab \(tabID) has no navigation state after \(Int(timeout))s — it has no engine contents, so it is not a web page. Check what was put in the load list.")
        } else {
            log("tab \(tabID) still loading after \(Int(timeout))s — capturing it anyway")
        }
    }

    // MARK: - Driving the app

    private static func expandEveryFolder(in env: AppEnvironment) {
        guard let space = env.activeSpace else { return }
        for id in folderIDs(in: space.pinned) {
            env.expandedFolderOverride[id] = true
        }
    }

    private static func folderIDs(in nodes: [SidebarNode]) -> [FolderID] {
        nodes.flatMap { node -> [FolderID] in
            guard case .folder(let folder) = node else { return [] }
            return [folder.id] + folderIDs(in: folder.children)
        }
    }

    private static func seedEasel(in env: AppEnvironment) async {
        guard let space = env.activeSpace else { return }
        let store = env.easelStore

        let easelTab = (space.today + space.pinned.flatMap(\.allTabIDs))
            .compactMap { env.tab($0) }
            .first { $0.url.scheme == "orbit" && $0.url.host == "easel" }

        guard let easelTab else {
            log("easel: the demo state has no orbit://easel tab")
            return
        }

        let title = "Q4 Product Roadmap"
        let easel = store.createEasel(title: title)
        let violet = ThemeColor(red: 0.55, green: 0.36, blue: 0.96)
        let cyan = ThemeColor(red: 0.22, green: 0.74, blue: 0.97)

        store.updateEasel(easel.id) { easel in
            easel.items = [
                EaselItem(
                    frame: CGRect(x: 36, y: 32, width: 300, height: 44),
                    content: .text("Q4 reading"),
                    zIndex: 1
                ),
                EaselItem(
                    frame: CGRect(x: 36, y: 100, width: 320, height: 58),
                    content: .link(
                        url: URL(string: "https://github.com/Seggys116/Orbit")!,
                        title: "Seggys116/Orbit"
                    ),
                    zIndex: 2
                ),
                EaselItem(
                    frame: CGRect(x: 36, y: 170, width: 320, height: 58),
                    content: .link(
                        url: URL(string: "https://en.wikipedia.org/wiki/Orbital_mechanics")!,
                        title: "Orbital mechanics"
                    ),
                    zIndex: 3
                ),
                EaselItem(
                    frame: CGRect(x: 36, y: 240, width: 320, height: 58),
                    content: .link(
                        url: URL(string: "https://developer.mozilla.org/en-US/docs/Web/CSS/grid")!,
                        title: "CSS grid — MDN"
                    ),
                    zIndex: 4
                ),
                EaselItem(
                    frame: CGRect(x: 24, y: 160, width: 344, height: 78),
                    content: .shape(
                        kind: .ellipse, color: cyan, lineWidth: 2.5,
                        unitStart: CGPoint(x: 0, y: 0), unitEnd: CGPoint(x: 1, y: 1)
                    ),
                    zIndex: 5
                ),
                EaselItem(
                    frame: CGRect(x: 132, y: 318, width: 60, height: 54),
                    content: .shape(
                        kind: .arrow, color: violet, lineWidth: 2.5,
                        unitStart: CGPoint(x: 0.5, y: 0), unitEnd: CGPoint(x: 0.5, y: 1)
                    ),
                    zIndex: 6
                ),
                EaselItem(
                    frame: CGRect(x: 36, y: 384, width: 190, height: 40),
                    content: .text("start here"),
                    zIndex: 7
                ),
                EaselItem(
                    frame: CGRect(x: 36, y: 448, width: 250, height: 62),
                    content: .text("ask about the engine\nbridge on Friday"),
                    zIndex: 8
                ),
            ]
        }

        if var tab = env.store.state.tabs[easelTab.id] {
            tab.url = URL(string: "orbit://easel/\(easel.id.uuidString)")!
            env.store.state.tabs[easelTab.id] = tab
        }

        env.activateTab(easelTab.id)
        await settle(1.0)

        // customTitle, not title, and set after activation: the activation path clears title back to empty.
        if var tab = env.store.state.tabs[easelTab.id] {
            tab.customTitle = title
            env.store.state.tabs[easelTab.id] = tab
        }
        await settle(1.5)
    }

    // requiringSecureCoding: true is not optional: NotesEditorView.decode requires it, or the body decodes to nil.
    @discardableResult
    private static func seedNote(in env: AppEnvironment) -> Tab? {
        guard let space = env.activeSpace else { return nil }
        let store = env.noteStore

        let noteTab = (space.today + space.pinned.flatMap(\.allTabIDs))
            .compactMap { env.tab($0) }
            .first { $0.url.scheme == "orbit" && $0.url.host == "note" }

        guard let noteTab else {
            log("notes: the demo state has no orbit://note tab")
            return nil
        }

        let title = "Onboarding checklist"
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: "Week one\n",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                         .foregroundColor: NSColor.labelColor]
        ))
        body.append(NSAttributedString(
            string: "\u{2022} Read the engineering notes in docs/\n"
                  + "\u{2022} Pair on the Chromium bridge\n"
                  + "\u{2022} Ship one small fix end to end\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 15),
                         .foregroundColor: NSColor.labelColor]
        ))
        body.append(NSAttributedString(
            string: "Ask about\n",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                         .foregroundColor: NSColor.labelColor]
        ))
        body.append(NSAttributedString(
            string: "How Spaces map onto Profiles, and where the archive policy "
                  + "actually lives now.",
            attributes: [.font: NSFont.systemFont(ofSize: 15),
                         .foregroundColor: NSColor.labelColor]
        ))

        let note = store.createNote(
            title: title,
            bodyData: NotesEditorView.encode(body) ?? Data()
        )

        if var tab = env.store.state.tabs[noteTab.id] {
            tab.url = URL(string: "orbit://note/\(note.id.uuidString)")!
            env.store.state.tabs[noteTab.id] = tab
        }
        return env.tab(noteTab.id)
    }

    private static func seedEaselAndNotes(in env: AppEnvironment) async {
        await seedEasel(in: env)
        guard let easelTabID = env.activeTabID else { return }
        guard let noteTab = seedNote(in: env) else { return }

        env.createSplit(existingTabID: easelTabID, newTabID: noteTab.id, edge: .right)
        await settle(2.0)

        if var tab = env.store.state.tabs[noteTab.id] {
            tab.customTitle = "Onboarding checklist"
            env.store.state.tabs[noteTab.id] = tab
        }
        await settle(1.5)
    }

    private static func seedBoost(in env: AppEnvironment) {
        let store = env.boostStore
        let host = "github.com"
        guard store.boosts(forHost: host).isEmpty else { return }

        let boost = store.createBoost(name: "Focused GitHub", host: host)
        store.updateBoost(boost.id) { boost in
            boost.isEnabled = true
            boost.zappedSelectors = [".js-notification-shelf", "footer.footer"]
            boost.customCSS = """
            /* Widen the code column and calm the chrome. */
            .container-xl {
              max-width: 1400px;
            }

            .Header {
              background: #0d1117;
              border-bottom: 1px solid #21262d;
            }

            .markdown-body pre {
              border-radius: 10px;
              font-size: 13px;
            }
            """
            boost.customJavaScript = """
            // Collapse the "Used by" strip on load.
            document.querySelectorAll('.BorderGrid-cell').forEach((cell) => {
              if (cell.textContent.includes('Used by')) {
                cell.style.display = 'none';
              }
            });
            """
        }
    }

    private static func seedSplit(in env: AppEnvironment) async {
        guard let space = env.activeSpace else { return }
        let tabs = Array(space.today.prefix(3))
        guard tabs.count >= 2 else {
            log("split-view: active Space has \(tabs.count) Today tabs, need at least 2")
            return
        }

        env.activateTab(tabs[0])
        await settle(0.5)

        env.createSplit(existingTabID: tabs[0], newTabID: tabs[1], edge: .right)
        await settle(1.5)

        if tabs.count > 2 {
            env.createSplit(existingTabID: tabs[1], newTabID: tabs[2], edge: .right)
            await settle(1.5)
        }

        // Load after the panes exist: entering a split re-hosts each tab's engine view into an unpainted pane.
        for (tab, url) in zip(tabs, splitPages) {
            env.webContents[tab]?.load(url)
        }
        await settle(2.0)
        for tab in tabs {
            await waitForLoad(of: tab, in: env)
        }
        await settle(settleSeconds)
    }

    // Through the field editor's insertText, not a synthesized NSEvent: those don't reliably reach SwiftUI here.
    private static func type(_ text: String, into window: NSWindow) {
        guard let editor = window.firstResponder as? NSTextView else {
            log("command-bar: first responder is \(String(describing: window.firstResponder)), not a text view — leaving the field empty")
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    // MARK: - Capture

    // CGWindowListCreateImage, obsoleted in the macOS 15 SDK but still exported by CoreGraphics;
    // reached via dlsym since a process may capture its own windows with it without a TCC grant.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    // Without this, shots are silently half-resolution on whichever display the window opened on.
    private static func moveToBestScreen(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard let best = screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return }
        guard window.screen !== best else { return }
        log("moving \(window.title.isEmpty ? "window" : window.title) to \(best.localizedName) (@\(best.backingScaleFactor)x) from \(window.screen?.localizedName ?? "no screen") (@\(window.screen?.backingScaleFactor ?? 0)x)")
        let frame = window.frame
        let visible = best.visibleFrame
        window.setFrameOrigin(
            CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        )
    }

    // Not private: DemoEngineProbe diffs captures of this window and must go through the same path.
    // Retried because kCGWindowImageBestResolution is a request, not a guarantee.
    static func captureAtBackingScale(of window: NSWindow, attempts: Int = 4) async -> CGImage? {
        let wanted = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let expectedWidth = Int(window.frame.width * wanted)

        var last: CGImage?
        for attempt in 1...attempts {
            window.displayIfNeeded()
            await settle(0.6)

            guard let image = capture(window: window) else { return last }
            last = image
            if Double(image.width) >= Double(expectedWidth) * 0.9 {
                if attempt > 1 { log("capture came back at backing scale on attempt \(attempt)") }
                return image
            }
            log("capture returned \(image.width)px wide for a \(Int(window.frame.width))pt window (attempt \(attempt)/\(attempts)) — retrying")
            await settle(2.0)
        }
        log("giving up on backing scale — writing the last capture as-is")
        return last
    }

    // Not private: DemoEngineProbe reads pixels through this same mechanism to measure real compositor output.
    static func capture(window: NSWindow) -> CGImage? {
        guard let createImage else {
            log("CGWindowListCreateImage could not be resolved")
            return nil
        }
        let listOptionIncludingWindow: UInt32 = 1 << 3
        let imageBoundsIgnoreFraming: UInt32 = 1 << 0
        let imageBestResolution: UInt32 = 1 << 3
        return createImage(
            .null,
            listOptionIncludingWindow,
            UInt32(bitPattern: Int32(window.windowNumber)),
            imageBoundsIgnoreFraming | imageBestResolution
        )?.takeRetainedValue()
    }

    private static func write(_ image: CGImage, named name: String, into directory: URL) {
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            log("FAILED \(name): could not create a PNG destination at \(url.path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            log("FAILED \(name): PNG encoding failed")
            return
        }
        log("wrote \(name).png (\(image.width)x\(image.height))")
    }

    // MARK: - Plumbing

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("DemoCaptureDriver: \(message)\n".utf8))
    }
}
