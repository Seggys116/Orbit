//  Measures how the running app feels while it is used: a display link counts the frames the real window produces
//  during an interaction, and the pane's real composited pixels say whether the page was ever replaced by something
//  that is not the page. Driven by Scripts/interaction-smoothness through the benchmark probe's command channel,
//  so it only ever runs against a scratch profile.

import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import UniformTypeIdentifiers
import WebKit

@MainActor
enum AppInteractionProbe {

    /// A page of a known solid colour, so a pane showing anything else is visible in the pixels.
    struct Page {
        var tabID: TabID
        var red: Int
        var green: Int
        var blue: Int
    }

    enum Scenario: String, CaseIterable {
        /// Nothing happens. Its gaps are the noise floor of the machine, not of the app.
        case idle
        case warmSwitch
        case rapidSwitch
        case openTab
        case openTabBackground
        case openBlankTab
        case activateFreshTab
        case activateRightAway
        case activateAfterBriefWait
        case focusPane
        case enterSplitKeyboard
        case enterSplitBlank
        case enterSplitLoaded
        case leaveSplitClose
        case leaveSplitSeparate
        case closeTab
    }

    private final class Recorder: NSObject {
        var times: [CFTimeInterval] = []
        /// Main-thread CPU seconds at each frame. A busy machine stretches the wall-clock gap between frames but not the CPU the main thread spent in it.
        var cpu: [Double] = []
        var inspect: (() -> [String])?
        var defects: [[String]] = []

        @objc func tick(_ link: CADisplayLink) {
            times.append(CACurrentMediaTime())
            cpu.append(Self.mainThreadCPUSeconds())
            defects.append(inspect?() ?? [])
        }

        static func mainThreadCPUSeconds() -> Double {
            let port = mach_thread_self()
            defer { mach_port_deallocate(mach_task_self_, port) }
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
            return user + system
        }
    }

    static func run(request: [String: Any], host: AppEnvironment, tabs: [TabID], window: NSWindow) async -> [String: Any] {
        if request["scenario"] as? String == "journey" {
            return await AppJourneyProbe.run(request: request, host: host, window: window)
        }
        if request["scenario"] as? String == "dropTargetEvent" {
            guard let activeID = host.activeTabID, let spaceID = host.activeSpace?.id,
                  let other = tabs.first(where: { $0 != activeID }),
                  let view = host.webContents[activeID]?.view, let root = window.contentView?.superview else { return ["ok": false, "error": "needs an active tab and another"] }
            let payload = SidebarDragPayload(nodeID: other, kind: .todayTab, spaceID: spaceID)
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            if let data = try? JSONEncoder().encode(payload) { item.setData(data, forType: NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)) }
            pasteboard.writeObjects([item])
            let bounds = view.convert(view.bounds, to: nil)
            let point = CGPoint(x: bounds.maxX - 40, y: bounds.midY)
            var seen: [String: Any]?
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                if seen == nil {
                    let hit = root.hitTest(point)
                    seen = ["hit": hit.map { "\(type(of: $0))" } ?? "nil", "currentEvent": NSApp.currentEvent.map { Int($0.type.rawValue) } ?? -1, "inFlight": SidebarDragSession.hasInFlightDrag, "current": SidebarDragSession.current != nil]
                }
                return event
            }
            SidebarDragSession.begin(payload)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(moved, atStart: true)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let monitor { NSEvent.removeMonitor(monitor) }
            SidebarDragSession.end()
            return ["ok": true, "seen": seen ?? [:]]
        }
        if request["scenario"] as? String == "elementFullscreen" {
            return await runElementFullscreen(request: request, host: host, tabs: tabs, window: window)
        }
        guard let name = request["scenario"] as? String, let scenario = Scenario(rawValue: name) else {
            return ["ok": false, "error": "unknown scenario \(String(describing: request["scenario"])); known: \(Scenario.allCases.map(\.rawValue))"]
        }
        let iterations = max(1, request["iterations"] as? Int ?? 12)
        let capturePixels = request["pixels"] as? Bool ?? false
        let dumpDirectory = (request["dumpDir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let colours = request["colours"] as? [[Int]] ?? []
        guard tabs.count >= 3, colours.count == tabs.count, colours.allSatisfy({ $0.count == 3 }) else {
            return ["ok": false, "error": "needs at least 3 open pages and one colour per page (have \(tabs.count) pages, \(colours.count) colours)"]
        }
        guard let space = host.activeSpace else { return ["ok": false, "error": "no active Space"] }
        let pages = zip(tabs, colours).map { Page(tabID: $0, red: $1[0], green: $1[1], blue: $1[2]) }
        let context = Context(host: host, window: window, pages: pages, spaceID: space.id, capturePixels: capturePixels)
        context.dumpDirectory = dumpDirectory
        context.dumpName = name

        var results: [[String: Any]] = []
        for iteration in 0..<iterations {
            await context.resetToSingle()
            let plan = await context.plan(for: scenario, iteration: iteration)
            let outcome = await context.measure(duration: plan.duration, expecting: plan.expecting, action: plan.action)
            await plan.cleanup()
            results.append(outcome)
        }
        await context.resetToSingle()
        return [
            "ok": true,
            "scenario": name,
            "pixels": capturePixels,
            "refreshHz": window.screen?.maximumFramesPerSecond ?? 0,
            "keyWindow": window.isKeyWindow,
            "appActive": NSApp.isActive,
            "iterations": results,
        ]
    }

    // MARK: - Element fullscreen

    // enters real element fullscreen and records where the page is, how big, and what its window shows
    private static func runElementFullscreen(request: [String: Any], host: AppEnvironment, tabs: [TabID], window: NSWindow) async -> [String: Any] {
        guard let tabID = tabs.first, let contents = host.webContents[tabID] as? WebKitWebContents else {
            return ["ok": false, "error": "needs an open WebKit page"]
        }
        let iterations = max(1, request["iterations"] as? Int ?? 3)
        let dumpDirectory = (request["dumpDir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let colour = (r: 255, g: 136, b: 0)
        let pageURL = (request["fullscreenURL"] as? String).flatMap(URL.init(string:))
        let customScript = request["fullscreenScript"] as? String
        var runs: [[String: Any]] = []
        func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        for iteration in 0..<iterations {
            host.activateTab(tabID)
            await sleep(0.6)
            switch request["variant"] as? String {
            case "split":
                if tabs.count > 1 { host.createSplit(existingTabID: tabID, newTabID: tabs[1], edge: .right) }
                await sleep(1.0)
                host.focusSplitPane(index: 0)
            case "splitSecond":
                if tabs.count > 1 { host.createSplit(existingTabID: tabs[1], newTabID: tabID, edge: .right) }
                await sleep(1.0)
                host.focusSplitPane(index: 1)
            case "pinned":
                host.pinTab(tabID)
            case "inspector":
                _ = host.perform(.inspectElement)
                await sleep(1.5)
            default: break
            }
            await sleep(0.4)
            if let pageURL {
                host.loadInTab(tabID, url: pageURL)
                await sleep(2)
                for _ in 0..<60 where contents.navigationState.isLoading { await sleep(0.5) }
                await sleep(8)
            }
            let setup = customScript ?? """
            (function () {
              var old = document.getElementById('orbit-fs'); if (old) old.remove();
              var d = document.createElement('div'); d.id = 'orbit-fs';
              d.style.cssText = 'position:fixed;left:0;top:0;width:300px;height:200px;background:#ff8800;z-index:99999';
              document.body.appendChild(d);
              d.requestFullscreen().catch(function () {});
              return 1;
            })()
            """
            _ = try? await contents.webView.evaluateJavaScript(setup, withUserGesture: true)
            var samples: [[String: Any]] = []
            var entered = false
            for step in 0..<30 {
                await sleep(0.1)
                let view = contents.view
                let fullscreenWindow = view.window
                var sample: [String: Any] = [
                    "t": Double(step + 1) * 0.1,
                    "isFullscreen": contents.mediaState.isFullscreen,
                    "windowIsBrowser": fullscreenWindow === window,
                    "viewFrame": NSStringFromRect(view.frame),
                    "windowFrame": fullscreenWindow.map { NSStringFromRect($0.frame) } ?? "none",
                    "windowClass": fullscreenWindow.map { String(describing: type(of: $0)) } ?? "none",
                    "hidden": view.isHiddenOrHasHiddenAncestor,
                    "declaredVisible": contents.declaredVisibility.map { $0 as Any } ?? NSNull(),
                ]
                sample["strayWindows"] = NSApp.windows.filter { $0 !== window && $0 !== fullscreenWindow }.map { other in
                    "\(type(of: other)) frame=\(NSStringFromRect(other.frame)) alpha=\(other.alphaValue) opaque=\(other.isOpaque) onScreen=\(other.screen?.localizedName ?? "none") visible=\(other.occlusionState.contains(.visible)) space=\(other.isOnActiveSpace)"
                }
                if contents.mediaState.isFullscreen { entered = true }
                if let fullscreenWindow, fullscreenWindow !== window, let image = WindowPixelCapture.image(of: fullscreenWindow) {
                    let fraction = WindowPixelCapture.fractionMatching(image, red: colour.r, green: colour.g, blue: colour.b, tolerance: 40)
                    sample["fullscreenWindowOrange"] = fraction
                    if [4, 14, 28].contains(step), let directory = dumpDirectory {
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("fullscreen-\(iteration)-\(step).png"))
                    }
                }
                samples.append(sample)
            }
            _ = try? await contents.webView.evaluateJavaScript("document.exitFullscreen && document.exitFullscreen(); 1")
            var returned = false
            for _ in 0..<40 {
                await sleep(0.1)
                let view = contents.view
                if !contents.mediaState.isFullscreen, view.window === window, !view.isHiddenOrHasHiddenAncestor {
                    returned = true
                    break
                }
            }
            await sleep(0.8)
            var after: [String: Any] = [
                "returnedToPane": returned,
                "isFullscreen": contents.mediaState.isFullscreen,
                "viewFrame": NSStringFromRect(contents.view.frame),
                "paneFrame": NSStringFromRect(contents.view.superview?.bounds ?? .zero),
            ]
            if let full = WindowPixelCapture.image(of: window) {
                let rect = contents.view.convert(contents.view.bounds, to: nil).insetBy(dx: 14, dy: 14)
                if let pane = WindowPixelCapture.crop(full, toWindowRect: rect, of: window) {
                    after["paneAfterNonGrey"] = 1 - WindowPixelCapture.fractionMatching(pane, red: 31, green: 31, blue: 31, tolerance: 8)
                }
            }
            if let group = host.splitGroup(for: tabID) { host.separateAllTabs(group.id) }
            runs.append(["entered": entered, "samples": samples, "after": after])
            await sleep(0.5)
        }
        return ["ok": true, "scenario": "elementFullscreen", "keyWindow": window.isKeyWindow, "appActive": NSApp.isActive, "runs": runs]
    }

    // MARK: - One run

    @MainActor
    private final class Context {
        let host: AppEnvironment
        let window: NSWindow
        let pages: [Page]
        let spaceID: SpaceID
        let capturePixels: Bool
        // first few wrong frames are written here as images
        var dumpDirectory: URL?
        var dumpName = ""
        private var dumped = 0

        init(host: AppEnvironment, window: NSWindow, pages: [Page], spaceID: SpaceID, capturePixels: Bool) {
            self.host = host
            self.window = window
            self.pages = pages
            self.spaceID = spaceID
            self.capturePixels = capturePixels
        }

        struct Plan {
            var duration: TimeInterval
            var expecting: [Page]
            var action: () -> Void
            var cleanup: () async -> Void = {}
        }

        var first: Page { pages[0] }
        var knownTabs: Set<TabID> { Set(pages.map(\.tabID)) }

        func settle(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        /// The pages stay open between runs. Anything else a run created (the blank panes a split opens) is closed.
        func resetToSingle() async {
            if let active = host.activeTabID, let group = host.splitGroup(for: active) {
                host.separateAllTabs(group.id)
            }
            let known = knownTabs
            for id in Array(host.state.tabs.keys) where !known.contains(id) {
                host.closeTab(id)
            }
            host.activateTab(first.tabID)
            await settle(0.5)
        }

        func plan(for scenario: Scenario, iteration: Int) async -> Plan {
            let first = self.first
            let pages = self.pages
            let host = self.host
            let spaceID = self.spaceID
            switch scenario {
            case .idle:
                return Plan(duration: 0.7, expecting: [first]) {}
            case .warmSwitch:
                let target = pages[(iteration % (pages.count - 1)) + 1]
                return Plan(duration: 0.6, expecting: [target]) { host.activateTab(target.tabID) }
            case .openTab:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                return Plan(duration: 1.2, expecting: []) { _ = host.openTab(url: address, in: spaceID) }
            case .openTabBackground:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                return Plan(duration: 1.2, expecting: []) { _ = host.openTab(url: address, in: spaceID, section: .today, activate: false) }
            case .openBlankTab:
                return Plan(duration: 1.2, expecting: []) { _ = host.openTab(url: URL(string: "orbit://new-tab")!, in: spaceID) }
            case .activateFreshTab:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                let fresh = host.openTab(url: address, in: spaceID, section: .today, activate: false)
                await settle(1.2)
                return Plan(duration: 1.0, expecting: []) { host.activateTab(fresh) }
            case .activateRightAway:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                return Plan(duration: 1.2, expecting: []) {
                    let fresh = host.openTab(url: address, in: spaceID, section: .today, activate: false)
                    host.activateTab(fresh)
                }
            case .activateAfterBriefWait:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                let fresh = host.openTab(url: address, in: spaceID, section: .today, activate: false)
                await settle(0.12)
                return Plan(duration: 1.0, expecting: []) { host.activateTab(fresh) }
            case .rapidSwitch:
                return Plan(duration: 1.6, expecting: []) {
                    Task { @MainActor in
                        for index in 0..<8 {
                            host.activateTab(pages[(index % (pages.count - 1)) + 1].tabID)
                            try? await Task.sleep(nanoseconds: 25_000_000)
                        }
                    }
                }
            case .focusPane:
                host.createSplit(existingTabID: first.tabID, newTabID: pages[1].tabID, edge: .right)
                await settle(0.8)
                host.focusSplitPane(index: iteration % 2)
                await settle(0.3)
                return Plan(duration: 0.6, expecting: [first]) { host.focusSplitPane(index: (iteration + 1) % 2) }
            case .enterSplitKeyboard:
                return Plan(duration: 1.0, expecting: [first], action: { _ = host.perform(.addSplit) }, cleanup: { [self] in await settle(0.3) })
            case .enterSplitBlank:
                return Plan(duration: 1.0, expecting: [first], action: {
                    let blank = host.openTab(url: URL(string: "orbit://new-tab")!, in: spaceID, section: .today, activate: false)
                    host.createSplit(existingTabID: first.tabID, newTabID: blank, edge: .right)
                }, cleanup: { [self] in await settle(0.3) })
            case .enterSplitLoaded:
                return Plan(duration: 1.0, expecting: [first], action: {
                    host.createSplit(existingTabID: first.tabID, newTabID: pages[1].tabID, edge: .right)
                }, cleanup: { [self] in await settle(0.3) })
            case .leaveSplitClose:
                _ = host.perform(.addSplit)
                await settle(0.9)
                return Plan(duration: 1.0, expecting: [first]) {
                    if let active = host.activeTabID { host.closeSplitPaneTab(active) }
                }
            case .leaveSplitSeparate:
                host.createSplit(existingTabID: first.tabID, newTabID: pages[1].tabID, edge: .right)
                await settle(0.9)
                return Plan(duration: 1.0, expecting: [first]) {
                    if let group = host.activeSplitGroup { host.separateAllTabs(group.id) }
                }
            case .closeTab:
                let address = host.webContents[first.tabID]?.navigationState.url ?? URL(string: "about:blank")!
                let extra = host.openTab(url: address, in: spaceID)
                await settle(1.2)
                return Plan(duration: 0.7, expecting: [], action: { host.closeTab(extra) })
            }
        }

        func measure(duration: TimeInterval, expecting: [Page], action: () -> Void) async -> [String: Any] {
            guard let view = window.contentView else { return ["error": "window has no content view"] }
            let recorder = Recorder()
            recorder.inspect = { [self] in defects(for: expecting) }
            let cpuAtStart = Recorder.mainThreadCPUSeconds()
            let link = view.displayLink(target: recorder, selector: #selector(Recorder.tick(_:)))
            link.add(to: .main, forMode: .common)
            let before = CACurrentMediaTime()
            action()
            let actionMilliseconds = (CACurrentMediaTime() - before) * 1000
            await settle(duration)
            link.invalidate()

            var gaps: [Double] = []
            for index in recorder.times.indices.dropFirst() {
                gaps.append((recorder.times[index] - recorder.times[index - 1]) * 1000)
            }
            var longestCPUBurst = 0.0
            var previousCPU = cpuAtStart
            for value in recorder.cpu {
                longestCPUBurst = max(longestCPUBurst, (value - previousCPU) * 1000)
                previousCPU = value
            }
            let nominal = 1000.0 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 30))
            let defectFrames = recorder.defects.filter { !$0.isEmpty }
            // When each wrong frame was shown, counted from the action. One frame right after it is the previous picture still on screen, not a fault.
            var defectTimes: [Double] = []
            for index in recorder.defects.indices where !recorder.defects[index].isEmpty {
                defectTimes.append((recorder.times[index] - before) * 1000)
            }
            return [
                "actionMs": actionMilliseconds,
                "frames": recorder.times.count,
                "longestGapMs": gaps.max() ?? 0,
                "longestCpuBurstMs": longestCPUBurst,
                "hitches": gaps.filter { $0 > nominal * 1.5 }.count,
                "nominalMs": nominal,
                "defectFrames": defectFrames.count,
                "defectTimesMs": defectTimes,
                "firstDefect": defectFrames.first?.joined(separator: "; ") ?? "",
            ]
        }

        /// What is wrong with a pane showing `expected`: the page is missing, hidden, or not the page's colour.
        func defects(for expected: [Page]) -> [String] {
            let full: CGImage? = capturePixels ? WindowPixelCapture.image(of: window) : nil
            var found: [String] = []
            defer {
                if !found.isEmpty, let full, let directory = dumpDirectory, dumped < 6 {
                    dumped += 1
                    let bitmap = NSBitmapImageRep(cgImage: full)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(dumpName)-defect-\(dumped).png"))
                }
            }
            for page in expected {
                guard let contents = host.webContents[page.tabID] else { found.append("page missing"); continue }
                let view = contents.view
                guard view.window === window else { found.append("page not in the window"); continue }
                if view.isHiddenOrHasHiddenAncestor { found.append("page hidden"); continue }
                let rect = view.convert(view.bounds, to: nil)
                guard rect.width > 60, rect.height > 60 else { found.append("page \(Int(rect.width))x\(Int(rect.height))"); continue }
                guard let full, let pane = WindowPixelCapture.crop(full, toWindowRect: rect.insetBy(dx: 14, dy: 14), of: window) else { continue }
                let fraction = WindowPixelCapture.fractionMatching(pane, red: page.red, green: page.green, blue: page.blue, tolerance: 28)
                if fraction < 0.75 {
                    var chain: [String] = []
                    var current: NSView? = view
                    for _ in 0..<7 {
                        guard let node = current else { break }
                        let bg = node.layer?.backgroundColor.map { String(describing: NSColor(cgColor: $0)) } ?? "no-bg"
                        let under = (node as? WKWebView).map { " underPage=\(String(describing: $0.underPageBackgroundColor))" } ?? ""
                        chain.append("\(type(of: node)) \(NSStringFromRect(node.frame)) \(bg)\(under)")
                        current = node.superview
                    }
                    found.append(String(format: "pane only %.0f%% the page colour; ", fraction * 100) + chain.joined(separator: " <- "))
                }
            }
            return found
        }
    }

    /// The window the probe measures: the app's own browser window.
    static func browserWindow() -> NSWindow? {
        NSApp.windows.first { $0 is OrbitBorderlessWindow }
    }
}
