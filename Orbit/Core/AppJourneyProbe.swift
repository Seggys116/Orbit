//  seeded random journeys through tabs, pins and splits with state and pixel checks after every step.
//  run through Scripts/interaction-smoothness --journey on a scratch profile.

import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import WebKit

@MainActor
enum AppJourneyProbe {

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func int(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
        mutating func element<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[int(items.count)] }
    }

    private final class FrameClock: NSObject {
        var times: [CFTimeInterval] = []
        @objc func tick(_ link: CADisplayLink) { times.append(CACurrentMediaTime()) }

        func worstGap(from start: CFTimeInterval, to end: CFTimeInterval) -> Double {
            let inside = times.filter { $0 >= start && $0 <= end }
            guard inside.count > 1 else { return 0 }
            var worst = 0.0
            for index in 1..<inside.count { worst = max(worst, (inside[index] - inside[index - 1]) * 1000) }
            return worst
        }
    }

    static func run(request: [String: Any], host: AppEnvironment, window: NSWindow) async -> [String: Any] {
        guard let base = request["base"] as? String, let space = host.activeSpace else {
            return ["ok": false, "error": "journey needs a \"base\" URL and an active Space"]
        }
        let seed = UInt64(request["seed"] as? Int ?? 1)
        let steps = max(1, request["steps"] as? Int ?? 60)
        let dumpDirectory = (request["dumpDir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        var generator = Generator(state: seed)
        var trace: [String] = []
        var violations: [[String: Any]] = []
        var paintDelays: [[String: Any]] = []
        var stalls: [[String: Any]] = []
        var pinnedExpectation: [TabID: URL] = [:]
        var dumped = 0
        var currentStep = 0
        var currentAction = "setup"
        var currentActionMs = 0

        let clock = FrameClock()
        guard let contentView = window.contentView else { return ["ok": false, "error": "window has no content view"] }
        let link = contentView.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }

        func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func page(_ site: Int, _ name: String) -> URL { URL(string: "\(base)/site/\(site)/\(name)")! }
        func violate(_ message: String) {
            violations.append(["step": currentStep, "action": currentAction, "problem": message])
        }
        func tabIDs() -> [TabID] {
            host.state.tabs.values.filter { $0.spaceID == space.id && $0.section != .archived }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        }
        func engine(_ id: TabID) -> WebKitWebContents? { host.webContents[id] as? WebKitWebContents }

        func short(_ id: TabID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "-" }

        // MARK: state invariants

        func stateProblems() -> [String] {
            var found: [String] = []
            let state = host.state
            if let active = host.activeTabID {
                if state.tabs[active] == nil { found.append("the active tab does not exist") }
                if let group = host.splitGroup(for: active) {
                    if !group.tabIDs.contains(active) { found.append("the active tab is not in its own split group") }
                    if host.focusedSplitPaneIndex >= group.tabIDs.count { found.append("the focused pane index \(host.focusedSplitPaneIndex) is past the split's \(group.tabIDs.count) panes") }
                    if host.focusedSplitPaneIndex >= 0, host.focusedSplitPaneIndex < group.tabIDs.count, group.tabIDs[host.focusedSplitPaneIndex] != active {
                        found.append("the focused pane is not the active tab")
                    }
                }
            } else {
                found.append("no tab is active")
            }
            for (groupID, group) in state.splitGroups {
                if group.tabIDs.count < 2 { found.append("a split holds \(group.tabIDs.count) tab(s)") }
                for tabID in group.tabIDs {
                    guard let tab = state.tabs[tabID] else { found.append("a split holds a tab that does not exist"); continue }
                    if tab.splitGroupID != groupID { found.append("a split's tab points at another split") }
                }
            }
            for tab in state.tabs.values {
                if let groupID = tab.splitGroupID {
                    guard let group = state.splitGroups[groupID] else { found.append("a tab points at a split that does not exist"); continue }
                    if !group.tabIDs.contains(tab.id) { found.append("a tab claims a split that does not list it") }
                }
            }
            for tab in state.tabs.values where tab.section == .pinned {
                if tab.pinnedURL == nil { found.append("a pinned tab has no pinned address") }
                if let expected = pinnedExpectation[tab.id], tab.pinnedURL != expected {
                    found.append("a pinned tab's pinned address moved from \(expected.path) to \(tab.pinnedURL?.path ?? "nothing") without being asked")
                }
            }
            return found
        }

        // MARK: what the window shows

        func visibleTabs() -> [TabID] {
            guard let active = host.activeTabID else { return [] }
            return host.splitGroup(for: active)?.tabIDs ?? [active]
        }

        func paneProblems() -> (problems: [String], loading: Bool) {
            var found: [String] = []
            var loading = false
            let full = WindowPixelCapture.image(of: window)
            for id in visibleTabs() {
                guard let contents = host.webContents[id] else { found.append("a shown tab has no page"); continue }
                if contents.navigationState.isLoading { loading = true; continue }
                let view = contents.view
                if view.window !== window { found.append("a shown page is not in the window"); continue }
                if view.isHiddenOrHasHiddenAncestor { found.append("a shown page is hidden"); continue }
                let rect = view.convert(view.bounds, to: nil)
                if rect.width < 60 || rect.height < 60 { found.append("a shown page is \(Int(rect.width))x\(Int(rect.height))"); continue }
                if contents.navigationState.url?.scheme == "orbit" { continue }
                guard let full, let pane = WindowPixelCapture.crop(full, toWindowRect: rect.insetBy(dx: 14, dy: 14), of: window) else { continue }
                let grey = WindowPixelCapture.fractionMatching(pane, red: 31, green: 31, blue: 31, tolerance: 7)
                if grey > 0.2 { found.append(String(format: "a shown page's pane is %.0f%% grey", grey * 100)) }
            }
            return (found, loading)
        }

        func dumpFrame(_ label: String) {
            guard let directory = dumpDirectory, dumped < 8, let full = WindowPixelCapture.image(of: window) else { return }
            dumped += 1
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: full).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("journey-\(seed)-step\(currentStep)-\(label).png"))
        }

        func settleAndCheck(started: CFTimeInterval) async {
            await sleep(0.25)
            var firstWrong: CFTimeInterval?
            var firstProblems: [String] = []
            var problems: [String] = []
            var waitedForLoad: CFTimeInterval?
            for _ in 0..<60 {
                let result = paneProblems()
                problems = result.problems
                if result.loading {
                    waitedForLoad = waitedForLoad ?? CACurrentMediaTime()
                    if CACurrentMediaTime() - (waitedForLoad ?? 0) > 8 { problems.append("a page was still loading after 8 s") ; break }
                } else if problems.isEmpty {
                    break
                } else if firstWrong == nil {
                    firstWrong = CACurrentMediaTime()
                    firstProblems = problems
                    dumpFrame("wrong")
                }
                if !result.loading, firstWrong != nil, CACurrentMediaTime() - (firstWrong ?? 0) > 3 { break }
                await sleep(0.1)
            }
            if let firstWrong, problems.isEmpty {
                let delay = (CACurrentMediaTime() - firstWrong) * 1000
                paintDelays.append(["step": currentStep, "action": currentAction, "ms": Int(delay), "what": firstProblems.joined(separator: "; ")])
                if delay > 400 { violate("the pane showed a wrong picture for \(Int(delay)) ms before the page (\(firstProblems.joined(separator: "; ")))") }
            }
            for problem in problems { violate(problem); dumpFrame("pane") }
            for problem in stateProblems() { violate(problem) }
            let ended = CACurrentMediaTime()
            let worst = clock.worstGap(from: started, to: ended)
            if worst > 250 { stalls.append(["step": currentStep, "action": currentAction, "ms": Int(worst), "actionMs": currentActionMs]) }
        }

        // MARK: actions

        func others(than id: TabID?) -> [TabID] { tabIDs().filter { $0 != id } }

        func perform(_ index: Int) async -> String {
            let active = host.activeTabID
            let all = tabIDs()
            switch index {
            case 0:
                guard let target = generator.element(others(than: active)) else { return "activate (none)" }
                let cold = host.webContents[target] == nil
                host.activateTab(target)
                return "activate \(short(target))\(cold ? " (no page yet)" : "")"
            case 1:
                var names: [String] = []
                for _ in 0..<3 {
                    guard let target = generator.element(others(than: host.activeTabID)) else { break }
                    let cold = host.webContents[target] == nil
                    host.activateTab(target)
                    names.append(short(target) + (cold ? "*" : ""))
                    await sleep(0.03)
                }
                return "activate quickly \(names.joined(separator: ","))"
            case 2:
                guard all.count < 11 else { return "open (full)" }
                let site = generator.int(6)
                let id = host.openTab(url: page(site, "a"), in: space.id)
                return "open site\(site) \(short(id))"
            case 3:
                guard all.count > 3, let target = (generator.int(2) == 0 ? active : generator.element(all)) else { return "close (kept)" }
                if host.splitGroup(for: target) != nil, generator.int(2) == 0 {
                    host.closeSplitPaneTab(target)
                    return "close pane \(short(target))"
                }
                pinnedExpectation.removeValue(forKey: target)
                host.closeTab(target)
                return "close \(short(target))"
            case 4:
                guard let target = generator.element(all), host.splitGroup(for: target) == nil else { return "pin (skipped)" }
                let wasPinned = host.state.tabs[target]?.section == .pinned
                host.togglePin(target)
                if wasPinned {
                    pinnedExpectation.removeValue(forKey: target)
                } else if let pinned = host.state.tabs[target]?.pinnedURL {
                    pinnedExpectation[target] = pinned
                }
                return "\(wasPinned ? "unpin" : "pin") \(short(target))"
            case 5:
                guard let target = active else { return "navigate (none)" }
                let url = page(generator.int(6), ["b", "c", "slow"][generator.int(3)])
                host.loadInTab(target, url: url)
                return "navigate \(short(target)) to \(url.path)"
            case 6:
                guard let contents = active.flatMap({ host.webContents[$0] }) else { return "back (none)" }
                guard contents.navigationState.canGoBack else { return "back (nothing)" }
                contents.goBack()
                return "back \(short(active!))"
            case 7:
                guard let contents = active.flatMap({ host.webContents[$0] }) else { return "forward (none)" }
                guard contents.navigationState.canGoForward else { return "forward (nothing)" }
                contents.goForward()
                return "forward \(short(active!))"
            case 8:
                let candidates = host.state.tabs.values.filter { $0.section == .pinned && $0.hasNavigatedAwayFromPinnedURL }.map(\.id)
                guard let target = generator.element(candidates), let origin = host.state.tabs[target]?.pinnedURL else { return "reset pin (none moved)" }
                host.resetPinnedTab(target)
                await sleep(1.2)
                if host.state.tabs[target]?.url != origin { violate("a reset pinned tab's address is \(host.state.tabs[target]?.url.path ?? "none"), not \(origin.path)") }
                if let shown = host.webContents[target]?.navigationState.url, shown != origin { violate("a reset pinned tab's page is \(shown.path), not \(origin.path)") }
                if host.state.tabs[target]?.pinnedURL != origin { violate("resetting a pinned tab changed its pinned address") }
                return "reset pin \(short(target))"
            case 9:
                guard let first = active, host.splitGroup(for: first) == nil, let second = generator.element(others(than: first).filter { host.splitGroup(for: $0) == nil }) else { return "split (none)" }
                let edge: SplitEdge = generator.int(3) == 0 ? .bottom : .right
                _ = host.createSplit(existingTabID: first, newTabID: second, edge: edge)
                return "split \(short(first)) with \(short(second))"
            case 10:
                guard let first = active, let group = host.splitGroup(for: first) else { return "separate (none)" }
                host.separateAllTabs(group.id)
                return "separate"
            case 11:
                guard let group = host.activeSplitGroup else { return "focus pane (none)" }
                let index = generator.int(group.tabIDs.count)
                host.focusSplitPane(index: index)
                return "focus pane \(index)"
            case 12:
                guard let target = active else { return "reload (none)" }
                host.reloadTab(target, ignoringCache: generator.int(2) == 0)
                return "reload \(short(target))"
            case 13:
                guard let contents = active.flatMap({ engine($0) }) else { return "spa (none)" }
                let name = "spa\(generator.int(100))"
                _ = try? await contents.webView.evaluateJavaScript("history.pushState({}, '', '/site/0/\(name)'); 1")
                return "same-document navigation \(name)"
            case 14:
                guard let source = active else { return "link tab (none)" }
                let id = host.openTab(url: page(generator.int(6), "c"), in: space.id)
                return "tab opened from \(short(source)): \(short(id))"
            default:
                return "idle"
            }
        }

        // MARK: setup and run

        for group in Array(host.state.splitGroups.values) { host.separateAllTabs(group.id) }
        for id in tabIDs().dropFirst() { host.closeTab(id) }
        for site in 0..<5 { _ = host.openTab(url: page(site, "a"), in: space.id, activate: site == 4) }
        await sleep(4)

        let weights: [(Int, Int)] = [(0, 14), (1, 8), (2, 6), (3, 5), (4, 6), (5, 8), (6, 6), (7, 3), (8, 6), (9, 8), (10, 6), (11, 5), (12, 3), (13, 3), (14, 4), (15, 4)]
        let total = weights.reduce(0) { $0 + $1.1 }

        for step in 1...steps {
            currentStep = step
            var roll = generator.int(total)
            var choice = 15
            for (index, weight) in weights {
                if roll < weight { choice = index; break }
                roll -= weight
            }
            let started = CACurrentMediaTime()
            currentAction = "pending"
            let description = await perform(choice)
            currentActionMs = Int((CACurrentMediaTime() - started) * 1000)
            currentAction = description
            trace.append("\(step): \(description)")
            await settleAndCheck(started: started)
        }

        return [
            "ok": true,
            "scenario": "journey",
            "seed": Int(seed),
            "steps": steps,
            "keyWindow": window.isKeyWindow,
            "violations": violations,
            "paintDelays": paintDelays,
            "stalls": stalls,
            "trace": trace,
            "tabsAtEnd": tabIDs().count,
        ]
    }
}
