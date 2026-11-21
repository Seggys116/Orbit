//  How the browser feels, measured on the real thing: the shipped window controller, the shipped SwiftUI
//  window, real WebKit pages from a local server, and the window's real composited pixels. Each interaction
//  is run with a display link counting frames, so a stall shows up as a gap and a grey flash shows up as a
//  pane that is not the page's colour.
//
//  Excluded on GitHub-hosted runners: hosts a real window on a real display, which needs the app open.

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class InteractionSmoothnessLiveTests: LiveEnvironmentTestCase {

    private struct Page {
        var path: String
        var red: Int
        var green: Int
        var blue: Int
        var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    private static let pages = [
        Page(path: "/a", red: 31, green: 157, blue: 85),
        Page(path: "/b", red: 43, green: 108, blue: 176),
        Page(path: "/c", red: 192, green: 86, blue: 33),
        Page(path: "/d", red: 128, green: 62, blue: 160),
        Page(path: "/e", red: 190, green: 160, blue: 30),
        Page(path: "/f", red: 20, green: 130, blue: 140),
    ]

    private var server: LiveHTTPTestServer!
    private var spaceID: SpaceID!
    private var window: NSWindow?
    private var controller: OrbitWindowController?
    private var tabs: [TabID] = []
    private let probe = FrameProbe()

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A page with real weight: a few thousand text nodes over a solid colour, so layout and compositing are not free.
        let routes = Self.pages.reduce(into: [String: LiveHTTPTestServer.Route]()) { routes, page in
            let rows = (0..<1500).map { "<p>Row \($0) of \(page.path): the quick brown fox jumps over the lazy dog.</p>" }.joined()
            routes[page.path] = .init(
                contentType: "text/html; charset=utf-8",
                body: """
                <!doctype html><html><head><title>\(page.path)</title>
                <meta name="theme-color" content="\(page.hex)">
                <style>html,body{margin:0;background:\(page.hex);color:\(page.hex)}p{margin:0;padding:2px 12px}</style>
                </head><body>\(rows)</body></html>
                """
            )
        }
        server = try LiveHTTPTestServer(routes: routes)
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "Smoothness", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDownWithError() throws {
        if let window {
            window.orderOut(nil)
            window.contentView = nil
            window.delegate = nil
            window.close()
        }
        controller?.window = nil
        controller = nil
        window = nil
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    // MARK: - Setup

    private func url(_ page: Page) -> URL { server.baseURL.appendingPathComponent(String(page.path.dropFirst())) }

    private func waitUntilLoaded(_ tabID: TabID, timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let state = env.webContents[tabID]?.navigationState, state.url != nil, !state.isLoading { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "tab never finished loading")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func openRealWindow() {
        let window = OrbitWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        let controller = OrbitWindowController(window: window)
        controller.adopt(WindowSession.standard(on: env))
        window.delegate = controller
        controller.installContentView(window: window)
        WindowPixelCapture.moveToBestScreen(window)
        // A real session has a key window. Without one, the command bar's focus claim keeps asking the window server for it, which no user ever pays for.
        let policyChanged = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        print("SMOOTHNESS environment: activation policy set to regular=\(policyChanged) (now \(NSApp.activationPolicy().rawValue))")
        window.orderFrontRegardless()
        self.window = window
        self.controller = controller
    }

    private func openAllPages() async throws {
        env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
        openRealWindow()
        await settle(0.5)
        print("SMOOTHNESS environment: key window=\(NSApp.keyWindow === window), app active=\(NSApp.isActive), refresh=\(window?.screen?.maximumFramesPerSecond ?? 0)Hz, screen=\(window?.screen?.localizedName ?? "none")")
        for page in Self.pages {
            let tabID = env.openTab(url: url(page), in: spaceID)
            tabs.append(tabID)
            try await waitUntilLoaded(tabID)
        }
        // The content blocker compiles its rule lists once, after the first page opens, and finishes on the main thread. That is a launch cost, not part of any interaction measured below.
        if let engine = env._test_engineOverride as? WebKitEngine {
            let started = ContinuousClock.now
            while engine.contentBlocking.installedListCount == 0, ContinuousClock.now - started < .seconds(90) {
                try await Task.sleep(for: .milliseconds(100))
            }
            print("SMOOTHNESS environment: content blocker lists installed=\(engine.contentBlocking.installedListCount) after \(ContinuousClock.now - started)")
            await settle(2.0)
        }
        // The page-colour observer reports after load; the placeholder colour depends on it.
        await settle(1.5)
    }

    private func expectation(for tabID: TabID) -> PanePixelCheck.Expectation {
        let index = tabs.firstIndex(of: tabID) ?? 0
        let page = Self.pages[min(index, Self.pages.count - 1)]
        return PanePixelCheck.Expectation(tabID: tabID, red: page.red, green: page.green, blue: page.blue)
    }

    // MARK: - Scenarios

    private struct Scenario {
        var name: String
        var iterations = 4
        var pixelIterations = 2
        var duration: TimeInterval = 0.7
        /// Runs before each measured iteration and is not measured.
        var prepare: @MainActor (Int) async -> Void = { _ in }
        var action: @MainActor (Int) -> Void
        var expecting: @MainActor (Int) -> [TabID]
        /// Runs after each iteration and is not measured.
        var cleanup: @MainActor (Int) async -> Void = { _ in }
    }

    private struct Result {
        var name: String
        var timing: [FrameProbe.Report]
        var pixels: [FrameProbe.Report]
        var freezes: Int

        func percentile(_ fraction: Double, of values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))]
        }

        var longestGaps: [Double] { timing.map(\.longestGapMilliseconds) }
        var medianLongestGap: Double { percentile(0.5, of: longestGaps) }
        var p90LongestGap: Double { percentile(0.9, of: longestGaps) }
        var worstLongestGap: Double { longestGaps.max() ?? 0 }
        var meanHitches: Double { Double(timing.map(\.hitchCount).reduce(0, +)) / Double(max(timing.count, 1)) }
        var medianAction: Double { percentile(0.5, of: timing.map(\.actionMilliseconds)) }
        /// Frames more than 50ms after the action. The first frame or two after an action are the previous picture still on screen.
        private func settledDefects(_ reports: [FrameProbe.Report]) -> Int {
            reports.map { $0.defectiveFrames.filter { $0.at > 0.05 }.count }.reduce(0, +)
        }
        var stateDefects: Int { settledDefects(timing) }
        var pixelDefects: Int { settledDefects(pixels) }
        var pixelFrames: Int { pixels.map { $0.frames.count }.reduce(0, +) }
        var firstDefect: String { (timing + pixels).first { !$0.defectiveFrames.isEmpty }?.summary ?? "" }

        var line: String {
            String(
                format: "%-34@ runs %2d | action %5.1fms | longest gap median %5.1f p90 %5.1f worst %5.1fms | hitches/run %.1f | dim freezes %d | state defects %d | pixel defects %d of %d frames",
                name as NSString, timing.count, medianAction, medianLongestGap, p90LongestGap, worstLongestGap,
                meanHitches, freezes, stateDefects, pixelDefects, pixelFrames
            )
        }
    }

    private func run(_ scenario: Scenario) async -> Result {
        var timing: [FrameProbe.Report] = []
        var pixels: [FrameProbe.Report] = []
        var freezes = 0
        for (passIsPixels, count) in [(false, scenario.iterations), (true, scenario.pixelIterations)] {
            for iteration in 0..<count {
                await scenario.prepare(iteration)
                let frozenBefore = FrozenFrameProbe.appearances
                let report = await measure(
                    scenario.name,
                    expecting: { scenario.expecting(iteration) },
                    capturePixels: passIsPixels,
                    duration: scenario.duration
                ) { scenario.action(iteration) }
                if !passIsPixels { freezes += FrozenFrameProbe.appearances - frozenBefore }
                if passIsPixels { pixels.append(report) } else { timing.append(report) }
                await scenario.cleanup(iteration)
            }
        }
        return Result(name: scenario.name, timing: timing, pixels: pixels, freezes: freezes)
    }

    private func measure(
        _ label: String,
        expecting tabIDs: @escaping () -> [TabID],
        capturePixels: Bool,
        duration: TimeInterval,
        action: () -> Void
    ) async -> FrameProbe.Report {
        guard let window else { fatalError("no window") }
        let check = PanePixelCheck(window: window, env: env)
        return await probe.record(
            label: label,
            in: window,
            duration: duration,
            inspect: { [self] in check.defects(for: tabIDs().map(expectation(for:)), capturePixels: capturePixels) },
            action: action
        )
    }

    private func resetToSingle() async {
        if let active = env.activeTabID, let group = env.splitGroup(for: active) {
            env.separateAllTabs(group.id)
            // Panes the keyboard split opened are throwaway blank tabs.
            for id in env.state.tabs.keys where !tabs.contains(id) { env.closeTab(id) }
        }
        env.activateTab(tabs[0])
        await settle(0.5)
    }

    private func scenarios() -> [Scenario] {
        let first = tabs[0]
        return [
            Scenario(
                name: "Switch tab (page kept warm)",
                duration: 0.6,
                prepare: { [self] _ in await resetToSingle() },
                action: { [self] index in env.activateTab(tabs[(index % (tabs.count - 1)) + 1]) },
                expecting: { [self] index in [tabs[(index % (tabs.count - 1)) + 1]] }
            ),
            Scenario(
                name: "Enter split (keyboard, blank pane)",
                duration: 1.0,
                prepare: { [self] _ in await resetToSingle() },
                action: { [self] _ in _ = env.perform(.addSplit) },
                expecting: { [first] _ in [first] },
                cleanup: { [self] _ in await settle(0.3) }
            ),
            Scenario(
                name: "Enter split (two loaded pages)",
                duration: 1.0,
                prepare: { [self] _ in await resetToSingle() },
                action: { [self] _ in env.createSplit(existingTabID: first, newTabID: tabs[1], edge: .right) },
                expecting: { [first] _ in [first] },
                cleanup: { [self] _ in await settle(0.3) }
            ),
            Scenario(
                name: "Leave split (close one pane)",
                duration: 1.0,
                prepare: { [self] _ in
                    await resetToSingle()
                    _ = env.perform(.addSplit)
                    await settle(0.9)
                },
                action: { [self] _ in if let active = env.activeTabID { env.closeSplitPaneTab(active) } },
                expecting: { [first] _ in [first] }
            ),
            Scenario(
                name: "Close the active tab",
                duration: 0.7,
                prepare: { [self] _ in
                    await resetToSingle()
                    let extra = env.openTab(url: url(Self.pages[0]), in: spaceID)
                    try? await waitUntilLoaded(extra)
                    await settle(0.5)
                    closable = extra
                },
                action: { [self] _ in if let closable { env.closeTab(closable) } },
                expecting: { [self] _ in env.activeTabID.map { [$0] } ?? [] }
            ),
        ]
    }

    private var closable: TabID?

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testInteractionsStaySmooth
    func testInteractionsStaySmooth() throws {
        try WebKitLiveEngineHost.runLive(timeout: 240) {
            try await self.openAllPages()
            var results: [Result] = []
            for scenario in self.scenarios() {
                results.append(await self.run(scenario))
                await self.resetToSingle()
            }
            print("SMOOTHNESS ---- results (display \(self.window?.screen?.maximumFramesPerSecond ?? 0)Hz) ----")
            for result in results { print("SMOOTHNESS " + result.line) }
            for result in results where result.stateDefects + result.pixelDefects > 0 {
                print("SMOOTHNESS first defect in \(result.name): \(result.firstDefect)")
            }
            // Frame timing depends on what else the machine is doing, so it is reported, not asserted. These do not.
            for result in results {
                XCTAssertEqual(result.freezes, 0, "\(result.name): a pane was put under the dimmed freeze while its page was live")
                XCTAssertEqual(result.stateDefects, 0, "\(result.name): the page was missing, hidden or collapsed on screen: \(result.firstDefect)")
            }
        }
    }

    // MARK: - The sidebar shows a split as one cell

    private func writeProof(_ name: String) {
        guard let window, let full = WindowPixelCapture.image(of: window) else { return }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORBIT_PROOF_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The sidebar column, full height.
        let sidebar = CGRect(x: 0, y: 0, width: env.effectiveSidebarWidth + 24, height: window.frame.height)
        let image = WindowPixelCapture.crop(full, toWindowRect: sidebar, of: window) ?? full
        WindowPixelCapture.write(image, to: directory.appendingPathComponent("\(name).png"))
        WindowPixelCapture.write(full, to: directory.appendingPathComponent("\(name)-window.png"))
    }

    /// What the sidebar is showing right now, as the rows it built.
    private func sidebarRows() -> (joined: [[TabID]], single: Set<TabID>) {
        (SidebarRowProbe.joinedRows, SidebarRowProbe.tabsWithTheirOwnRow)
    }

    /// A real left click, delivered the way the window server would: through NSApp, so the app's event monitors see it too.
    private func click(at point: NSPoint) async {
        guard let window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) {
                NSApp.sendEvent(event)
            }
            await settle(0.05)
        }
    }

    private func sidebarCatchers() -> [CGRect] {
        guard let content = window?.contentView else { return [] }
        var found: [CGRect] = []
        func walk(_ view: NSView) {
            if view is OrbitActionButtonClickCatchingView {
                let rect = view.convert(view.bounds, to: nil)
                if rect.minX < env.effectiveSidebarWidth, rect.width > 20 { found.append(rect) }
            }
            view.subviews.forEach(walk)
        }
        walk(content)
        return found
    }

    /// The sidebar rows a person can click, as the click targets the rows really have: the two panes of the split (side by side) and the wide rows below them.
    private func clickTargets() -> (panes: [CGRect], rows: [CGRect]) {
        let all = sidebarCatchers()
        let wide = env.effectiveSidebarWidth * 0.8
        let rows = all.filter { $0.width > wide && $0.height < 60 }.sorted { $0.midY > $1.midY }
        let panes = all.filter { $0.width <= wide && $0.height < 60 && $0.width > 60 }.sorted { $0.midX < $1.midX }
        return (panes, rows)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testLeavingASplitAndComingBack
    func testLeavingASplitAndComingBack() throws {
        try WebKitLiveEngineHost.runLive(timeout: 240) {
            SidebarRowProbe.reset()
            try await self.openAllPages()
            let (a, b, c) = (self.tabs[0], self.tabs[1], self.tabs[2])
            self.env.createSplit(existingTabID: a, newTabID: b, edge: .right)
            await self.settle(1.0)
            let group = try XCTUnwrap(self.env.splitGroup(for: a))
            XCTAssertEqual(self.env.activeTabID, a)
            let targets = self.clickTargets()
            print("LEAVE panes=\(targets.panes.map { "\(Int($0.minX)),\(Int($0.midY)),\(Int($0.width))" }) rows=\(targets.rows.map { "\(Int($0.minX)),\(Int($0.midY)),\(Int($0.width))" })")
            let panes = targets.panes.filter { abs($0.midY - (targets.panes.first?.midY ?? 0)) < 4 }
            XCTAssertEqual(panes.count, 2, "the split shows two pane targets in one cell")
            // The wide rows under the split cell, top to bottom: c, d, e, f.
            let splitY = panes.first?.midY ?? 0
            let below = targets.rows.filter { $0.midY < splitY }
            let rowC = try XCTUnwrap(below.first, "the row for the first tab outside the split")
            self.writeProof("leave-1-split-active")

            for step in 0..<3 {
                await self.click(at: NSPoint(x: rowC.midX, y: rowC.midY))
                await self.settle(0.8)
                self.writeProof("leave-2-normal-\(step)")
                XCTAssertEqual(self.env.activeTabID, c, "step \(step): clicking the normal tab selects it")
                XCTAssertNil(self.env.activeSplitGroup, "step \(step): no split is active while a normal tab is")

                // Back to the split, by its second pane, then by its first.
                let pane = panes[step % 2]
                await self.click(at: NSPoint(x: pane.midX, y: pane.midY))
                await self.settle(0.8)
                self.writeProof("leave-3-back-\(step)")
                XCTAssertEqual(self.env.activeTabID, step % 2 == 0 ? a : b, "step \(step): clicking the split's pane selects it")
                XCTAssertEqual(self.env.activeSplitGroup?.id, group.id, "step \(step): the split is active again")
                XCTAssertEqual(self.env.focusedSplitPaneIndex, step % 2, "step \(step): the pane with the focus border is the one the sidebar marks active")
                for tab in [a, b] {
                    let view = try XCTUnwrap(self.env.webContents[tab]?.view)
                    XCTAssertTrue(view.window === self.window)
                    XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "step \(step): the split's pages are showing")
                    XCTAssertGreaterThan(view.bounds.width, 60)
                }
            }
        }
    }

    /// The part of a drag a drop target reads: where it is, and what it carries.
    private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
        var location: NSPoint
        weak var targetWindow: NSWindow?
        init(location: NSPoint, window: NSWindow) { self.location = location; targetWindow = window }
        var draggingDestinationWindow: NSWindow? { targetWindow }
        var draggingSourceOperationMask: NSDragOperation { .every }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testDroppingASidebarTabOnThePageSplits
    func testDroppingASidebarTabOnThePageSplits() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            try await self.openAllPages()
            let (a, b, c) = (self.tabs[0], self.tabs[1], self.tabs[2])
            self.env.activateTab(a)
            await self.settle(1.0)
            let window = try XCTUnwrap(self.window)
            let content = try XCTUnwrap(window.contentView)

            func catchers() -> [SplitPaneDropCatcherView] {
                var found: [SplitPaneDropCatcherView] = []
                func walk(_ view: NSView) {
                    if let catcher = view as? SplitPaneDropCatcherView { found.append(catcher) }
                    view.subviews.forEach(walk)
                }
                walk(content)
                return found
            }
            let before = catchers()
            print("DROP catchers=\(before.count) targets=\(before.map { String($0.targetTabID?.uuidString.prefix(4) ?? "nil") }) frames=\(before.map { NSStringFromRect($0.convert($0.bounds, to: nil)) }) hidden=\(before.map(\.isHiddenOrHasHiddenAncestor)) types=\(before.map { $0.registeredDraggedTypes.count })")
            let catcher = try XCTUnwrap(before.first { $0.targetTabID == a && !$0.isHiddenOrHasHiddenAncestor }, "the visible page has a drop target")

            // A sidebar drag of tab b is in flight, with its payload on the drag pasteboard. All of it runs in one turn: the tear-off detector ends a drag it sees no mouse button held for.
            let payload = SidebarDragPayload(nodeID: b, kind: .todayTab, spaceID: self.spaceID)
            let pasteboard = NSPasteboard(name: .drag)
            let nodeType = NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)
            let rect = catcher.convert(catcher.bounds, to: nil)
            let point = NSPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY)

            // A record left over from an earlier sidebar drag, then a file dragged in from Finder: the page takes it.
            pasteboard.clearContents()
            pasteboard.setString("file:///tmp/outside-drag.png", forType: .fileURL)
            pasteboard.setData(Data([0]), forType: .tiff)
            SidebarDragSession.begin(payload)
            let outside = content.hitTest(content.convert(point, from: nil))
            XCTAssertFalse(outside is SplitPaneDropCatcherView, "a file dragged in from outside reaches the page: got \(String(describing: outside))")

            pasteboard.clearContents()
            pasteboard.setData(try JSONEncoder().encode(payload), forType: nodeType)
            SidebarDragSession.begin(payload)
            let hit = content.hitTest(content.convert(point, from: nil))
            XCTAssertTrue(hit is SplitPaneDropCatcherView, "a drag over the page lands on the split drop target, not the page: got \(String(describing: hit))")

            let info = FakeDraggingInfo(location: point, window: window)
            XCTAssertFalse(catcher.draggingEntered(info).isEmpty, "the target accepts a sidebar tab")
            XCTAssertNotNil(self.env.activeSplitDropZone, "the drop zone highlights")
            XCTAssertTrue(catcher.performDragOperation(info), "the drop is taken")
            await self.settle(1.0)
            XCTAssertEqual(self.env.splitGroup(for: a)?.tabIDs, [a, b], "the dropped tab joins the page's split on its right")

            // Whatever the layout, each visible page's drop target names that page's own tab.
            func visibleTargets() -> Set<TabID> {
                Set(catchers().filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 60 }.compactMap(\.targetTabID))
            }
            XCTAssertEqual(visibleTargets(), [a, b], "a split's two panes each take drops for their own tab")
            self.env.activateTab(c)
            await self.settle(1.0)
            XCTAssertEqual(visibleTargets(), [c], "after leaving the split the one page takes drops for its own tab")
            self.env.activateTab(a)
            await self.settle(1.0)
            XCTAssertEqual(visibleTargets(), [a, b], "back in the split, both panes again")
            self.env.separateAllTabs(try XCTUnwrap(self.env.splitGroup(for: a)).id)
            await self.settle(1.0)
            XCTAssertEqual(visibleTargets(), [a], "separated, the page shown is a")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testCommandDragMovesAPaneWithinASplit
    func testCommandDragMovesAPaneWithinASplit() throws {
        try WebKitLiveEngineHost.runLive(timeout: 240) {
            try await self.openAllPages()
            let (a, b, c) = (self.tabs[0], self.tabs[1], self.tabs[2])
            self.env.createSplit(existingTabID: a, newTabID: b, edge: .right)
            self.env.createSplit(existingTabID: a, newTabID: c, edge: .right)
            await self.settle(1.2)
            XCTAssertEqual(self.env.splitGroup(for: a)?.tabIDs, [a, b, c])
            let window = try XCTUnwrap(self.window)
            let frames = try (0..<3).map { index -> CGRect in
                let view = try XCTUnwrap(self.env.webContents[[a, b, c][index]]?.view)
                return view.convert(view.bounds, to: nil)
            }

            func send(_ type: NSEvent.EventType, at point: NSPoint, command: Bool = true) {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: command ? [.command] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
                ) { NSApp.sendEvent(event) }
            }

            // Drag the first pane onto the right edge of the last one.
            let start = NSPoint(x: frames[0].midX, y: frames[0].midY)
            let end = NSPoint(x: frames[2].maxX - 20, y: frames[2].midY)
            send(.leftMouseDown, at: start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                await self.settle(0.02)
            }
            XCTAssertNotNil(self.env.activeSplitDropZone, "the target side is highlighted while dragging")
            send(.leftMouseUp, at: end)
            await self.settle(1.0)
            XCTAssertEqual(self.env.splitGroup(for: a)?.tabIDs, [b, c, a], "the first pane now sits last")
            XCTAssertNil(self.env.activeSplitDropZone, "the highlight is gone after the drop")

            // A Command press that never moves is left alone: the split keeps its order.
            let page = try XCTUnwrap(self.env.webContents[b]?.view)
            let click = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
            send(.leftMouseDown, at: click)
            send(.leftMouseUp, at: click)
            await self.settle(0.3)
            XCTAssertEqual(self.env.splitGroup(for: a)?.tabIDs, [b, c, a])
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testSplitTabsShareOneSidebarCell
    func testSplitTabsShareOneSidebarCell() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            SidebarRowProbe.reset()
            try await self.openAllPages()
            let (a, b, c) = (self.tabs[0], self.tabs[1], self.tabs[2])
            self.env.activateTab(a)
            await self.settle(1.0)
            let before = self.sidebarRows()
            XCTAssertTrue(before.joined.isEmpty, "no split yet, so no joined cell")
            XCTAssertTrue(before.single.isSuperset(of: [a, b, c]), "every tab has a row of its own before the split")
            self.writeProof("sidebar-1-before-split")

            // The keyboard split opens its blank pane at the end of Today, after b and c. That used to leave the pair apart.
            XCTAssertTrue(self.env.perform(.addSplit))
            await self.settle(1.2)
            let group = try XCTUnwrap(self.env.splitGroup(for: a), "the split exists")
            XCTAssertEqual(group.tabIDs.count, 2)
            let blank = try XCTUnwrap(group.tabIDs.first { $0 != a })

            let during = self.sidebarRows()
            XCTAssertEqual(during.joined.count, 1, "the pair is exactly one joined cell on screen")
            XCTAssertEqual(Set(during.joined.first ?? []), [a, blank], "that cell holds both panes")
            XCTAssertFalse(during.single.contains(a), "the first pane has no row of its own")
            XCTAssertFalse(during.single.contains(blank), "the second pane has no row of its own")
            XCTAssertTrue(during.single.isSuperset(of: [b, c]), "the tabs that were not split keep their own rows")
            self.writeProof("sidebar-2-split-from-keyboard")

            // A third pane joins the same cell.
            XCTAssertTrue(self.env.perform(.addSplit))
            await self.settle(1.2)
            let three = self.sidebarRows()
            XCTAssertEqual(three.joined.count, 1, "three panes are still one cell")
            XCTAssertEqual(three.joined.first?.count, 3)
            self.writeProof("sidebar-3-three-panes")

            // A split built from two tabs that are not neighbours (drop on a pane) is joined too.
            self.env.separateAllTabs(try XCTUnwrap(self.env.splitGroup(for: a)).id)
            await self.settle(0.8)
            XCTAssertTrue(self.sidebarRows().joined.isEmpty, "separating gives every tab its own row again")
            self.env.createSplit(existingTabID: b, newTabID: self.tabs[4], edge: .right)
            await self.settle(1.2)
            let distant = self.sidebarRows()
            XCTAssertEqual(distant.joined.count, 1)
            XCTAssertEqual(Set(distant.joined.first ?? []), [b, self.tabs[4]], "tabs that were far apart in the list share one cell")
            self.writeProof("sidebar-4-distant-tabs-joined")
        }
    }
}
