//  Starts one real ChromiumEngine per test process, shared by every live suite.
//  Gated on ORBIT_LIVE_ENGINE so an ordinary `xcodebuild test` skips these.

import Foundation
@testable import Orbit

@MainActor
enum LiveChromiumEngineHost {

    /// False for every ordinary test run -- see the file comment. Read this
    /// (or a `try XCTSkipUnless` wrapping it) at the top of every live test.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORBIT_LIVE_ENGINE"] != nil
    }

    private static var engine: ChromiumEngine?

    /// Whether `sharedEngine()` has already run `ChromiumEngine.start()` in
    /// this process; start-up is unrepeatable, so a start-up test must know it will cause it.
    static var hasStartedEngine: Bool { engine != nil }

    /// The engine this process started, or nil. Synchronous, unlike
    /// `sharedEngine()`, so tearDown can restore state without starting an engine that never existed.
    static var startedEngine: ChromiumEngine? { engine }

    /// Idempotent: the first live test starts the engine, every one after
    /// reuses it. Never call unless `isEnabled`.
    static func sharedEngine() async -> ChromiumEngine {
        if let engine {
            return engine
        }
        // .isolated: private per-process dir like .ephemeral, but with
        // persistent sessions extensions need -- .ephemeral's non-persistent session is Orbit's incognito flag.
        let created = ChromiumEngine(storage: .isolated)
        do {
            try created.start()
        } catch {
            fatalError("LiveChromiumEngineHost: ChromiumEngine.start() failed: \(error)")
        }
        await waitUntilReady()
        engine = created
        return created
    }

    /// engine.start() only schedules OrbitMain on the next run-loop turn; the
    /// browser isn't ready until PreMainMessageLoopRun runs asynchronously. Times out rather than hanging forever.
    private static func waitUntilReady(timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while !OrbitChromiumBridge.shared.isReady {
            if ContinuousClock.now >= deadline {
                fatalError("LiveChromiumEngineHost: engine did not become ready within \(timeout)")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Shared helpers for every live suite

    /// A real ChromiumWebContents loaded to about:blank and settled. Pass
    /// `engine` explicitly only to register a user script before this contents' RenderFrameHost exists.
    static func makeContents(engine passedEngine: ChromiumEngine? = nil) async throws -> ChromiumWebContents {
        let engine = if let passedEngine { passedEngine } else { await sharedEngine() }
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        guard let chromiumContents = contents as? ChromiumWebContents else {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "EngineFactory produced a non-Chromium WebContents")
        }
        chromiumContents.load(URL(string: "about:blank")!)
        do {
            try await waitUntilStoppedLoading(chromiumContents)
        } catch {
            // Nobody owns it yet, so nobody else can close it, and a tab left
            // open here keeps posting into the rest of the pass.
            chromiumContents.close()
            throw error
        }
        return chromiumContents
    }

    static func waitUntilStoppedLoading(_ contents: ChromiumWebContents, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while contents.navigationState.isLoading || contents.navigationState.url == nil {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "navigation never settled")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Pumps this thread's run loop directly in `.defaultMode`: an ordinary
    /// `async throws` test method hangs under XCTest's own nested pump, so every live test calls this instead.
    static func runLive<T>(timeout: TimeInterval = 30, _ operation: @escaping () async throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        Task { @MainActor in
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil {
            guard Date() < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "runLive timed out after \(timeout)s")
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        return try outcome!.get()
    }
}
