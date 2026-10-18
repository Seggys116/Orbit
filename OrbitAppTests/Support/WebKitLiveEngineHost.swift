// Live suites run on system WebKit.

import Foundation
@testable import Orbit

@MainActor
enum WebKitLiveEngineHost {

    private static var engine: WebKitEngine?

    /// The engine this process started, or nil. Synchronous, unlike
    /// `sharedEngine()`, so tearDown can restore state without starting an engine that never existed.
    static var startedEngine: WebKitEngine? { engine }

    /// Idempotent: the first live test starts the engine, every one after
    /// reuses it.
    static func sharedEngine() async -> WebKitEngine {
        setenv("ORBIT_LIVE_ENGINE", "1", 0)
        if let engine {
            return engine
        }
        // .isolated: private per-process dir like .ephemeral, but with
        // persistent sessions extensions need -- .ephemeral's non-persistent session is Orbit's incognito flag.
        let created = WebKitEngine(storage: .isolated)
        do {
            try created.start()
        } catch {
            fatalError("WebKitLiveEngineHost: engine start failed: \(error)")
        }
        engine = created
        return created
    }

    /// A new engine of its own, started here and shut down afterwards, for a test whose subject is engine start-up.
    /// The command dispatcher `start()` installs is put back so the shared engine keeps receiving extension commands.
    static func withFreshEngine<T>(_ body: (WebKitEngine) async throws -> T) async throws -> T {
        setenv("ORBIT_LIVE_ENGINE", "1", 0)
        let dispatch = ExtensionCommandRegistry.shared.dispatch
        let fresh = WebKitEngine(storage: .isolated)
        try fresh.start()
        defer {
            _ = fresh.shutdown()
            ExtensionCommandRegistry.shared.dispatch = dispatch
        }
        return try await body(fresh)
    }

    // MARK: - Shared helpers for every live suite

    /// A real WebKitWebContents loaded to about:blank and settled. Pass
    /// `engine` explicitly only to register a user script before this contents' RenderFrameHost exists.
    static func makeContents(engine passedEngine: WebKitEngine? = nil) async throws -> WebKitWebContents {
        let engine = if let passedEngine { passedEngine } else { await sharedEngine() }
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        guard let webKitContents = contents as? WebKitWebContents else {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "EngineFactory produced a non-WebKit WebContents")
        }
        webKitContents.load(URL(string: "about:blank")!)
        do {
            try await waitUntilStoppedLoading(webKitContents)
        } catch {
            // Nobody owns it yet, so nobody else can close it, and a tab left
            // open here keeps posting into the rest of the pass.
            webKitContents.close()
            throw error
        }
        return webKitContents
    }

    /// A tab a previous live test never closed stays in chrome.tabs for the rest of the process.
    private static func closeDanglingTabs() {
        guard let engine else { return }
        let tabs = engine.openTabs
        for tab in tabs where !tab.isClosed {
            tab.close()
        }
    }

    static func waitUntilStoppedLoading(_ contents: WebKitWebContents, timeout: Duration = .seconds(10)) async throws {
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
                Self.closeDanglingTabs()
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
        switch outcome! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
