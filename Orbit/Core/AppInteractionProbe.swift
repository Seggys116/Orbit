//  Measures how the running app feels while it is used: a display link counts the frames the real window produces
//  during an interaction, and the pane's real composited pixels say whether the page was ever replaced by something
//  that is not the page. Driven by Scripts/interaction-smoothness through the benchmark probe's command channel,
//  so it only ever runs against a scratch profile.

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

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
        guard let name = request["scenario"] as? String, let scenario = Scenario(rawValue: name) else {
            return ["ok": false, "error": "unknown scenario \(String(describing: request["scenario"])); known: \(Scenario.allCases.map(\.rawValue))"]
        }
        let iterations = max(1, request["iterations"] as? Int ?? 12)
        let capturePixels = request["pixels"] as? Bool ?? false
        let colours = request["colours"] as? [[Int]] ?? []
        guard tabs.count >= 3, colours.count == tabs.count, colours.allSatisfy({ $0.count == 3 }) else {
            return ["ok": false, "error": "needs at least 3 open pages and one colour per page (have \(tabs.count) pages, \(colours.count) colours)"]
        }
        guard let space = host.activeSpace else { return ["ok": false, "error": "no active Space"] }
        let pages = zip(tabs, colours).map { Page(tabID: $0, red: $1[0], green: $1[1], blue: $1[2]) }
        let context = Context(host: host, window: window, pages: pages, spaceID: space.id, capturePixels: capturePixels)

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

    // MARK: - One run

    @MainActor
    private final class Context {
        let host: AppEnvironment
        let window: NSWindow
        let pages: [Page]
        let spaceID: SpaceID
        let capturePixels: Bool

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
            for page in expected {
                guard let contents = host.webContents[page.tabID] else { found.append("page missing"); continue }
                let view = contents.view
                guard view.window === window else { found.append("page not in the window"); continue }
                if view.isHiddenOrHasHiddenAncestor { found.append("page hidden"); continue }
                let rect = view.convert(view.bounds, to: nil)
                guard rect.width > 60, rect.height > 60 else { found.append("page \(Int(rect.width))x\(Int(rect.height))"); continue }
                guard let full, let pane = WindowPixelCapture.crop(full, toWindowRect: rect.insetBy(dx: 14, dy: 14), of: window) else { continue }
                let fraction = WindowPixelCapture.fractionMatching(pane, red: page.red, green: page.green, blue: page.blue, tolerance: 28)
                if fraction < 0.75 { found.append(String(format: "pane only %.0f%% the page colour", fraction * 100)) }
            }
            return found
        }
    }

    /// The window the probe measures: the app's own browser window.
    static func browserWindow() -> NSWindow? {
        NSApp.windows.first { $0 is OrbitBorderlessWindow }
    }
}
