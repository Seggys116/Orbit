import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum SettingsVerificationProbe {

    // MARK: - Entry point

    static func runIfEnabled() {
        guard isEnabled else { return }
        Task { await run() }
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORBIT_SETTINGS_PROBE"] == "1"
    }

    private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_SETTINGS_PROBE_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var failures: [String] = []

    // MARK: - The run

    private static func run() async {
        await settle(1.5)
        let env = AppEnvironment.demoApp

        SettingsWindowController.show(pane: .shortcuts)
        await settle(1.2)
        guard let window = settingsWindow else {
            fail("no Settings window found after SettingsWindowController.show(pane: .shortcuts) — nothing below can run.")
            finish()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        moveToBestScreen(window)
        await settle(0.8)

        await capture(window, named: "keybinds-baseline")

        SettingsRouter.shared.selectedPane = .general
        await settle(0.6)
        await capture(window, named: "general-accent-live")
        SettingsRouter.shared.selectedPane = .shortcuts
        await settle(0.6)

        await checkConflictBadges(env: env, window: window)

        checkCategoryFilterClickDelivery(window: window)
        await settle(0.4)
        await capture(window, named: "keybinds-category-filter-state")

        finish()
    }

    // MARK: - 2. Conflict badges, driven through the real registry

    private static func checkConflictBadges(env: AppEnvironment, window: NSWindow) async {
        let registry = ShortcutRegistry.shared
        let first = ShortcutCommandID.zoomIn
        let second = ShortcutCommandID.zoomOut
        let collision = KeyBinding(key: "0", modifiers: [.control, .option, .shift])

        registry.setBinding(collision, for: first)
        registry.setBinding(collision, for: second)
        await settle(0.6)

        let conflictsOfFirst = registry.conflicts(for: first)
        let conflictsOfSecond = registry.conflicts(for: second)
        if conflictsOfFirst.contains(second) && conflictsOfSecond.contains(first) {
            emit("OK   ShortcutRegistry.conflicts(for:) reports the collision both ways: \(first.rawValue) <-> \(second.rawValue)")
        } else {
            fail("conflicts(for:) did not report the collision both ways — for \(first.rawValue): \(conflictsOfFirst), for \(second.rawValue): \(conflictsOfSecond).")
        }

        await capture(window, named: "keybinds-conflict-both-rows")

        if let defaultBinding = registry.command(for: first)?.defaultBinding {
            registry.setBinding(defaultBinding, for: first)
        } else {
            registry.setBinding(nil, for: first)
        }
        await settle(0.6)

        let conflictsOfFirstAfterReset = registry.conflicts(for: first)
        let conflictsOfSecondAfterReset = registry.conflicts(for: second)
        if conflictsOfFirstAfterReset.isEmpty && conflictsOfSecondAfterReset.isEmpty {
            emit("OK   resetting \(first.rawValue) cleared the conflict on both sides — \(second.rawValue) no longer reports \(first.rawValue) either.")
        } else {
            fail("resetting \(first.rawValue) did not clear the conflict — for \(first.rawValue): \(conflictsOfFirstAfterReset), for \(second.rawValue): \(conflictsOfSecondAfterReset).")
        }

        await capture(window, named: "keybinds-conflict-cleared")

        if let defaultBinding = registry.command(for: second)?.defaultBinding {
            registry.setBinding(defaultBinding, for: second)
        } else {
            registry.setBinding(nil, for: second)
        }
        await settle(0.3)
    }

    // MARK: - 3. Category filter: real click delivery, real menu, no modal tracking

    // Does not call the real presentMenu (NSMenu.popUp): its modal tracking session would block
    // this thread with no accessibility grant available to dismiss it, hanging the probe.
    private static func checkCategoryFilterClickDelivery(window: NSWindow) {
        guard let contentView = window.contentView else {
            fail("category filter check: Settings window has no contentView.")
            return
        }
        guard let hostView = firstView(ofClassNamed: "OrbitPopupButtonMenuHostView", in: contentView) as? OrbitMenuButtonClickCatchingView else {
            fail("category filter check: no OrbitPopupButtonMenuHostView found in the Keybinds pane's real view tree — the category filter is not mounted at all.")
            return
        }
        emit("OK   found the category filter's real OrbitPopupButtonMenuHostView in the live view tree, at \(hostView.convert(hostView.bounds, to: nil))")

        var capturedMenu: NSMenu?
        let original = hostView.presentMenu
        hostView.presentMenu = { menu, _ in capturedMenu = menu }
        defer { hostView.presentMenu = original }

        let pointInWindow = hostView.convert(NSPoint(x: hostView.bounds.midX, y: hostView.bounds.midY), to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fail("category filter check: could not construct a synthesized NSEvent.")
            return
        }

        window.sendEvent(down)

        guard let menu = capturedMenu else {
            fail("category filter check: a real mouseDown through window.sendEvent(_:) did not reach OrbitPopupButtonMenuHostView.mouseDown — the click was swallowed somewhere in the real, hosted view hierarchy.")
            return
        }
        emit("OK   a real, window-dispatched mouseDown reached the click catcher and built a real NSMenu (\(menu.items.count) items).")

        let expectedCount = ShortcutCategory.allCases.count + 1
        if menu.items.count == expectedCount {
            emit("OK   menu item count matches \"All Categories\" + every ShortcutCategory (\(expectedCount)).")
        } else {
            fail("category filter check: menu has \(menu.items.count) items, expected \(expectedCount) (\"All Categories\" + \(ShortcutCategory.allCases.count) categories).")
        }

        guard let checked = menu.items.first(where: { $0.state == .on }) else {
            fail("category filter check: no menu item is checked — the currently-selected \"All Categories\" option should carry a checkmark.")
            return
        }
        emit("OK   currently-selected option is checked in the real menu: \"\(checked.title)\"")

        guard menu.items.count > 1 else {
            fail("category filter check: menu has no category items to invoke.")
            return
        }
        let categoryItem = menu.items[1]
        guard let target = categoryItem.target, let action = categoryItem.action else {
            fail("category filter check: \"\(categoryItem.title)\" has no target/action pair to invoke.")
            return
        }
        _ = (target as AnyObject).perform(action, with: categoryItem)
        emit("OK   invoked \"\(categoryItem.title)\"'s real target/action pair (the same pair NSMenu's own tracking loop would invoke on a real click).")
    }

    // MARK: - Window / view discovery

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is OrbitBorderlessWindow) }
    }

    private static func firstView(ofClassNamed name: String, in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)).contains(name) { return root }
        for subview in root.subviews {
            if let found = firstView(ofClassNamed: name, in: subview) { return found }
        }
        return nil
    }

    // MARK: - Capture

    private static func capture(_ window: NSWindow, named name: String) async {
        window.displayIfNeeded()
        await settle(0.3)
        guard let image = await DemoCaptureDriver.captureAtBackingScale(of: window) else {
            fail("capture \(name): DemoCaptureDriver.captureAtBackingScale returned nothing.")
            return
        }
        guard let directory = outputDirectory else {
            emit("     (no ORBIT_SETTINGS_PROBE_OUT set — \(name) captured but not written to disk)")
            return
        }
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("capture \(name): could not create a PNG destination at \(url.path).")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            emit("OK   wrote \(name).png (\(image.width)x\(image.height)) to \(url.path)")
        } else {
            fail("capture \(name): PNG encoding failed.")
        }
    }

    private static func moveToBestScreen(_ window: NSWindow) {
        guard let best = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return }
        guard window.screen !== best else { return }
        let frame = window.frame
        let visible = best.visibleFrame
        window.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    // MARK: - Plumbing

    private static func fail(_ message: String) {
        failures.append(message)
        emit("FAIL \(message)")
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("SettingsVerificationProbe: \(message)\n".utf8))
    }

    private static func finish() {
        if failures.isEmpty {
            emit("VERDICT: PASS — every state-based check passed. PNGs still need a human (or another agent) to actually read them.")
            NSApp.terminate(nil)
            exit(0)
        } else {
            for failure in failures { emit("FAIL: \(failure)") }
            emit("VERDICT: FAIL — \(failures.count) check(s) failed.")
            exit(1)
        }
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
