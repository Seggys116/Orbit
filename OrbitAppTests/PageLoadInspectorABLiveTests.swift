//  Does having the inspector open change how fast a page loads? Real window, real engine, a page of 400 subresources from a local server, loaded repeatedly with the inspector closed, with the Network inspector open, and with the Performance panel's live sampler running (its frame and timer loops). The medians are printed; the assertions only check that every load completed and that an open inspector does not make loads much slower.
//
//  Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PageLoadInspectorABLiveTests: LiveEnvironmentTestCase {

    private var server: LiveHTTPTestServer!
    private var window: NSWindow?
    private var controller: OrbitWindowController?

    private static let subresources = 400

    override func setUpWithError() throws {
        try super.setUpWithError()
        var routes: [String: LiveHTTPTestServer.Route] = [:]
        let half = Self.subresources / 2
        let scripts = (0..<half).map { "<script src=\"/s/\($0).js\"></script>" }.joined()
        let images = (0..<half).map { "<img width=\"4\" height=\"4\" src=\"/i/\($0).svg\">" }.joined()
        routes["/page"] = .init(contentType: "text/html; charset=utf-8", body: "<!doctype html><html><head><title>load</title></head><body>\(scripts)\(images)<p>done</p></body></html>")
        for index in 0..<half {
            routes["/s/\(index).js"] = .init(contentType: "application/javascript", body: "window.n=(window.n||0)+1;")
            routes["/i/\(index).svg"] = .init(contentType: "image/svg+xml", body: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\" fill=\"#36c\"/></svg>")
        }
        server = try LiveHTTPTestServer(routes: routes)
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

    private func openRealWindow() {
        let window = OrbitWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        let controller = OrbitWindowController(window: window)
        controller.adopt(WindowSession.standard(on: env))
        window.delegate = controller
        controller.installContentView(window: window)
        WindowPixelCapture.moveToBestScreen(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        self.controller = controller
    }

    /// Milliseconds from asking for the page to the engine reporting it finished.
    private func timedLoad(_ contents: WebKitWebContents, tag: String) async throws -> Double {
        let url = server.baseURL.appendingPathComponent("page").appending(queryItems: [URLQueryItem(name: "r", value: tag)])
        let started = ContinuousClock.now
        contents.load(url)
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            let state = contents.navigationState
            if state.url?.query == "r=\(tag)", !state.isLoading, state.progress >= 1 { break }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "load \(tag) never finished")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    }

    nonisolated private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func series(_ contents: WebKitWebContents, label: String, runs: Int) async throws -> [Double] {
        var times: [Double] = []
        for index in 0..<runs {
            times.append(try await timedLoad(contents, tag: "\(label)-\(index)"))
            try await Task.sleep(for: .milliseconds(300))
        }
        return times
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTheIdleNetworkLogCostIsReportedOnARealRunner
    func testTheIdleNetworkLogCostIsReportedOnARealRunner() {
        // The assertions live in NetworkModelIdleCostTests; this prints the same measurement where the live run's log is kept.
        print("NETWORK-IDLE-COST \(NetworkModelIdleCostTests.measure().summary)")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAHeavyPageLoadsNoSlowerWithTheInspectorOpen
    func testAHeavyPageLoadsNoSlowerWithTheInspectorOpen() throws {
        try WebKitLiveEngineHost.runLive(timeout: 420) {
            self.env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
            self.openRealWindow()
            try await Task.sleep(for: .seconds(1))
            let spaceID = self.env.createSpace(name: "Load", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: self.env.createDefaultProfileIfNeeded())
            self.env.selectSpace(spaceID)
            let tabID = self.env.openTab(url: self.server.baseURL.appendingPathComponent("page"), in: spaceID)
            let contents = try XCTUnwrap(self.env.webContents[tabID] as? WebKitWebContents)
            _ = try await self.timedLoad(contents, tag: "warm")
            try await Task.sleep(for: .seconds(1))

            var closed = try await self.series(contents, label: "closed", runs: 8)

            OrbitDevToolsStore.shared.open(contents, panel: .network, inspectAt: nil, armPicker: false)
            try await Task.sleep(for: .seconds(1))
            let networkOpen = try await self.series(contents, label: "network", runs: 8)

            OrbitDevToolsStore.shared.open(contents, panel: .performance, inspectAt: nil, armPicker: false)
            try await Task.sleep(for: .seconds(1))
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            let live = OrbitPerformanceLiveModel()
            let sampler = Task { @MainActor in await live.run(session: session) }
            try await Task.sleep(for: .seconds(2))
            let performanceOpen = try await self.series(contents, label: "performance", runs: 8)
            sampler.cancel()

            OrbitDevToolsStore.shared.close(contents)
            try await Task.sleep(for: .seconds(1))
            closed += try await self.series(contents, label: "closed-again", runs: 8)

            @MainActor func line(_ name: String, _ values: [Double]) -> String {
                "\(name): median \(String(format: "%.0f", Self.median(values))) ms, runs \(values.map { String(format: "%.0f", $0) }.joined(separator: ","))"
            }
            print("PAGELOAD-AB \(Self.subresources) subresources")
            print("PAGELOAD-AB \(line("inspector closed", closed))")
            print("PAGELOAD-AB \(line("network inspector open", networkOpen))")
            print("PAGELOAD-AB \(line("performance panel open and sampling", performanceOpen))")

            XCTAssertLessThan(Self.median(networkOpen), Self.median(closed) * 2 + 200, "an open Network inspector does not make loads much slower")
            XCTAssertLessThan(Self.median(performanceOpen), Self.median(closed) * 2 + 200, "nor does the Performance panel's sampler")
        }
    }
}
