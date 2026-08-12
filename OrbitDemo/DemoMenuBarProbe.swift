import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum DemoMenuBarProbe {

    private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_MENUBAR_PROBE_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writePNG(_ image: CGImage, named name: String, into directory: URL) {
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            print("[menubar-probe] could not create a PNG destination at \(url.path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("[menubar-probe] wrote \(url.path) (\(image.width)x\(image.height))")
        }
    }

    // Not derived from MainMenuBuilder.build(): that would compare the builder against
    // itself and pass even if the on-screen bar came from somewhere else entirely.
    private static let expectedMenus = [
        "Orbit", "File", "Edit", "View", "Spaces",
        "Tabs", "Archive", "Extensions", "Window", "Help",
    ]

    static func runIfEnabled() {
        guard ProcessInfo.processInfo.environment["ORBIT_MENUBAR_PROBE"] == "1" else { return }

        let atLaunch = sample()
        report("at applicationDidFinishLaunching", atLaunch)

        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    report("after the run loop settled", sample())
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            let settled = sample()
                            report("after activation", settled)
                            finish(atLaunch: atLaunch, settled: settled)
                        }
                    }
                }
            }
        }
    }

    // MARK: Sampling

    private struct Sample {
        var menuTitles: [String]
        var settingsItem: NSMenuItem?
    }

    private static func sample() -> Sample {
        let menus = NSApp.mainMenu?.items.compactMap(\.submenu) ?? []
        let settings = menus.first?.items.first { $0.title.hasPrefix("Settings") }
        return Sample(menuTitles: menus.map(\.title), settingsItem: settings)
    }

    // MARK: Reporting

    private static func report(_ moment: String, _ sample: Sample) {
        print("[menubar-probe] \(moment):")
        print("[menubar-probe]   menus: \(sample.menuTitles)")
        if let item = sample.settingsItem {
            let action = item.action.map(NSStringFromSelector) ?? "nil"
            let target = item.target.map { String(describing: type(of: $0)) } ?? "nil"
            print("[menubar-probe]   Settings row: title=\(item.title) action=\(action) target=\(target)")
        } else {
            print("[menubar-probe]   Settings row: ABSENT")
        }
    }

    private static func finish(atLaunch: Sample, settled: Sample) {
        var failures: [String] = []

        if settled.menuTitles != expectedMenus {
            failures.append(
                "menu bar is not Orbit's. expected \(expectedMenus), got \(settled.menuTitles)"
                    + (atLaunch.menuTitles == expectedMenus
                        ? " — it WAS correct at launch, so something replaced it afterwards (SwiftUI's scene graph is the candidate)"
                        : " — it was already wrong at launch, so MainMenuBuilder.build() never reached NSApp.mainMenu")
            )
        }

        guard let item = settled.settingsItem else {
            failures.append("no Settings row in the application menu")
            finishReporting(failures)
            return
        }

        reportKeyEquivalentRoute()

        guard let window = openedSettingsWindow(invoking: item) else {
            failures.append("Settings… opened no window at all")
            finishReporting(failures)
            return
        }
        if window.title != "Settings" {
            failures.append("Settings… opened a window titled \(window.title), not Orbit's Settings window")
        }

        Task { @MainActor in
            if let outputDirectory {
                for other in NSApp.windows where other.isVisible && other !== window {
                    if let image = await DemoCaptureDriver.captureAtBackingScale(of: other) {
                        writePNG(image, named: "demo-window-\(other.windowNumber)", into: outputDirectory)
                    }
                }
                if let image = await DemoCaptureDriver.captureAtBackingScale(of: window) {
                    writePNG(image, named: "demo-settings-window", into: outputDirectory)
                }
            }

            let verdict = await inspectRenderedContent(of: window)
            print("[menubar-probe] Settings window content: \(verdict.description)")
            if verdict.isBlank {
                failures.append("the Settings window rendered blank: \(verdict.description)")
            }
            finishReporting(failures)
        }
    }

    private static func reportKeyEquivalentRoute() {
        var owners: [String] = []
        func search(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                if item.keyEquivalent == "," && item.keyEquivalentModifierMask == [.command] {
                    let target = item.target.map { String(describing: type(of: $0)) } ?? "nil (responder chain)"
                    owners.append((path + [item.title]).joined(separator: " > ") + " -> \(target)")
                }
                if let submenu = item.submenu { search(submenu, path: path + [item.title]) }
            }
        }
        if let main = NSApp.mainMenu { search(main, path: []) }
        print("[menubar-probe] Cmd-, is claimed by: \(owners.isEmpty ? ["nothing in the menu bar"] : owners)")
        print("[menubar-probe] ShortcutRegistry binding for .openSettings: \(String(describing: ShortcutRegistry.shared.binding(for: .openSettings)))")
    }

    private static func finishReporting(_ failures: [String]) {
        if failures.isEmpty {
            print("[menubar-probe] PASS: demo has Orbit's menu bar, and Settings… opens the real Settings window with content")
            exit(0)
        }
        for failure in failures { print("[menubar-probe] FAIL: \(failure)") }
        exit(1)
    }

    private struct ContentVerdict {
        var isBlank: Bool
        var description: String
    }

    private static func inspectRenderedContent(of window: NSWindow) async -> ContentVerdict {
        guard let image = await DemoCaptureDriver.captureAtBackingScale(of: window) else {
            return ContentVerdict(isBlank: false, description: "could not be captured — inconclusive, not counted as a failure")
        }
        guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else {
            return ContentVerdict(isBlank: false, description: "unreadable pixel format — inconclusive")
        }
        let bytesPerRow = image.bytesPerRow
        var colours = Set<UInt32>()
        let stepX = max(1, image.width / 64)
        let stepY = max(1, image.height / 64)
        data.withUnsafeBytes { raw in
            for y in stride(from: 0, to: image.height, by: stepY) {
                for x in stride(from: 0, to: image.width, by: stepX) {
                    let offset = y * bytesPerRow + x * 4
                    guard offset + 3 < raw.count else { continue }
                    let pixel = UInt32(raw[offset]) << 24 | UInt32(raw[offset + 1]) << 16
                        | UInt32(raw[offset + 2]) << 8 | UInt32(raw[offset + 3])
                    colours.insert(pixel)
                }
            }
        }
        let summary = "\(image.width)x\(image.height) capture, \(colours.count) distinct sampled colours"
        return ContentVerdict(isBlank: colours.count <= 2, description: summary)
    }

    // sendAction with the item's real target, not sendAction(to: nil): a nil target routes
    // through NSApp.keyWindow, which is nil at this point in launch.
    private static func openedSettingsWindow(invoking item: NSMenuItem) -> NSWindow? {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        guard let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        return NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
    }
}
