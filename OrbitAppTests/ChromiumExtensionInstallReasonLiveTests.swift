//  Regression: routing every startup load through UnpackedInstaller wiped
//  serviceworkerevents, so onInstalled always fired "install" and onStartup never fired.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionInstallReasonLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeLifecycleExtension(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-InstallReason-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        try writeManifest(version: "1.0", named: name, into: directory)

        // Both listeners registered at top level, which is what makes them
        // persist into the serviceworkerevents pref a re-install wiped.
        let background = """
        // Serialised: onInstalled and onStartup can land milliseconds apart on
        // startup, and overlapping read-modify-writes would drop one.
        var writes = Promise.resolve();
        function record(entry) {
          writes = writes.then(function () {
            return chrome.storage.local.get('orbitLifecycleLog').then(function (data) {
              var log = data.orbitLifecycleLog || [];
              log.push(entry);
              return chrome.storage.local.set({ orbitLifecycleLog: log });
            });
          });
          return writes;
        }

        chrome.runtime.onInstalled.addListener(function (details) {
          record('installed:' + details.reason + (details.previousVersion ? ':' + details.previousVersion : ''));
        });

        chrome.runtime.onStartup.addListener(function () {
          record('startup');
        });

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'orbit-lifecycle-log') {
            chrome.storage.local.get('orbitLifecycleLog', function (data) {
              sendResponse(JSON.stringify(data.orbitLifecycleLog || []));
            });
            return true;
          }
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probe = """
        <!DOCTYPE html>
        <html><head><title>Orbit Lifecycle Probe</title></head>
        <body><script src="probe.js"></script></body></html>
        """
        try probe.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        // Re-asks on its own timer so a phase needs exactly ONE WebContents:
        // a fresh one per poll attempt raced the worker start and could drop onInstalled.
        let probeScript = """
        function refresh() {
          chrome.runtime.sendMessage('orbit-lifecycle-log', function (response) {
            document.documentElement.setAttribute('data-orbit-lifecycle-log',
              chrome.runtime.lastError ? 'error:' + chrome.runtime.lastError.message : String(response));
          });
        }
        refresh();
        setInterval(refresh, 250);
        """
        try probeScript.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func writeManifest(version: String, named name: String, into directory: URL) throws {
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "\(version)",
          "permissions": ["storage"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Reading the worker's own record back

    /// Kept apart so a timeout can distinguish "worker never answered" from
    /// "worker answered but never recorded this" -- different bugs.
    private enum ProbeAnswer {
        case silent
        case failed(String)
        case log([String])

        var description: String {
            switch self {
            case .silent: "the worker never answered the probe page at all"
            case .failed(let text): "the worker answered with \(text)"
            case .log(let entries): "the worker's recorded log was \(entries)"
            }
        }
    }

    /// One probe page per phase, opened once and polled in place.
    private func openProbe(extensionID: String, engine: ChromiumEngine, phase: String) async throws -> ChromiumWebContents {
        let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
        contents.load(URL(string: "chrome-extension://\(extensionID)/probe.html")!)
        do {
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
        } catch {
            contents.close()
            throw EngineError(
                code: .engineUnavailable,
                underlyingDescription: "\(phase): the extension's own probe page never finished loading over chrome-extension://"
            )
        }
        return contents
    }

    private func readAnswer(from contents: ChromiumWebContents) async throws -> ProbeAnswer {
        guard let raw = try await contents.evaluateJavaScript(
            "document.documentElement.getAttribute('data-orbit-lifecycle-log')"
        ) as? String else {
            return .silent
        }
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return .failed(raw)
        }
        return .log(decoded)
    }

    /// `phase`/`expectation` name what stalled on timeout. `settle` gives
    /// phases asserting nothing-else-recorded a window to misbehave first.
    private func waitForLog(
        extensionID: String,
        engine: ChromiumEngine,
        phase: String,
        expecting expectation: String,
        timeout: Duration = .seconds(15),
        settle: Duration = .zero,
        until predicate: ([String]) -> Bool
    ) async throws -> [String] {
        let contents = try await openProbe(extensionID: extensionID, engine: engine, phase: phase)
        defer { contents.close() }

        var last: ProbeAnswer = .silent
        let deadline = ContinuousClock.now + timeout
        while true {
            last = try await readAnswer(from: contents)
            if case .log(let entries) = last, predicate(entries) {
                guard settle > .zero else { return entries }
                try await Task.sleep(for: settle)
                if case .log(let settled) = try await readAnswer(from: contents) {
                    return settled
                }
                return entries
            }
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "\(phase): timed out after \(timeout) waiting for \(expectation) — \(last.description)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func installEntries(_ log: [String]) -> [String] {
        log.filter { $0.hasPrefix("installed:") }
    }

    private func startupEntries(_ log: [String]) -> [String] {
        log.filter { $0 == "startup" }
    }

    // MARK: - The whole contract, in one extension's own words

    // Explicit runLive budget: four phases at up to 15s each must not hit
    // the 30s default, which would replace a phase-naming failure with a bare timeout.
    func testOnInstalledFiresOnceForARealInstallAndOnStartupFiresOnARestartWithoutReinstalling() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeLifecycleExtension(named: "Orbit Install Reason Test")

            // 1. Genuine first install.
            let installed = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            var log = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 1 (first install)",
                expecting: "runtime.onInstalled to record one entry"
            ) { !$0.isEmpty }
            XCTAssertEqual(
                log, ["installed:install"],
                "a first install must fire runtime.onInstalled exactly once, with reason \"install\" and no previousVersion"
            )

            // 2. A user action reloading unchanged bytes (disable/enable, not
            // an install). Waits for any answer, then asserts on it.
            engine.unloadExtension(id: installed.id, session: engine.defaultSession)
            _ = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            log = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 2 (user-action reload of unchanged bytes)",
                expecting: "the worker to report its log back",
                settle: .milliseconds(750)
            ) { _ in true }
            XCTAssertEqual(
                self.installEntries(log).count, 1,
                "re-enabling an already-installed extension re-fired runtime.onInstalled: \(log)"
            )
            XCTAssertTrue(
                self.startupEntries(log).isEmpty,
                "a user-action reload is not a browser start: \(log)"
            )

            // 3. Browser restart: onStartup must arrive at a non-running
            // worker (proving persisted event registration survived); onInstalled must not.
            engine.unloadExtension(id: installed.id, session: engine.defaultSession)
            _ = try await engine.loadExtension(
                at: directory, session: engine.defaultSession, reason: .browserStartup
            )
            log = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 3 (browser restart)",
                expecting: "runtime.onStartup to record \"startup\"",
                settle: .milliseconds(750)
            ) { $0.contains("startup") }
            XCTAssertEqual(
                self.installEntries(log).count, 1,
                "a browser restart re-fired runtime.onInstalled -- every extension is redoing its first-run setup on every launch: \(log)"
            )
            XCTAssertEqual(
                self.startupEntries(log).count, 1,
                "runtime.onStartup fired the wrong number of times across one restart: \(log)"
            )

            // 4. Version changed while closed: both onStartup and onInstalled
            // (update) must fire. Only counts are asserted, not order: Chrome
            // emits startup first, Orbit emits the update first (discovered at load time).
            engine.unloadExtension(id: installed.id, session: engine.defaultSession)
            try self.writeManifest(version: "2.0", named: "Orbit Install Reason Test", into: directory)
            let updated = try await engine.loadExtension(
                at: directory, session: engine.defaultSession, reason: .browserStartup
            )
            defer { engine.unloadExtension(id: updated.id, session: engine.defaultSession) }
            XCTAssertEqual(updated.version, "2.0")
            XCTAssertEqual(updated.id, installed.id, "a version bump must not change an unpacked extension's id")

            log = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 4 (version changed while closed)",
                expecting: "runtime.onInstalled to record an update and runtime.onStartup a second \"startup\""
            ) {
                self.installEntries($0).count == 2 && self.startupEntries($0).count == 2
            }
            XCTAssertEqual(
                self.installEntries(log), ["installed:install", "installed:update:1.0"],
                "a genuine version change must fire runtime.onInstalled with reason \"update\" and previousVersion 1.0: \(log)"
            )
        }
    }

    // MARK: - The same update, applied while the browser is running

    func testInstallingANewVersionWhileRunningReportsAnUpdateNotAFreshInstall() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 90) {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeLifecycleExtension(named: "Orbit In-Session Update Reason Test")

            let installed = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            _ = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 1 (first install)",
                expecting: "runtime.onInstalled to record one entry"
            ) { !$0.isEmpty }

            // Mirrors ExtensionStore.install: unload the running copy, then
            // load the new version. This unload used to make the registry forget the outgoing version.
            engine.unloadExtension(id: installed.id, session: engine.defaultSession)
            try self.writeManifest(version: "3.0", named: "Orbit In-Session Update Reason Test", into: directory)
            let updated = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: updated.id, session: engine.defaultSession) }

            let log = try await self.waitForLog(
                extensionID: installed.id, engine: engine,
                phase: "phase 2 (in-session update)",
                expecting: "runtime.onInstalled to record a second entry for the update"
            ) {
                self.installEntries($0).count == 2
            }
            XCTAssertEqual(
                self.installEntries(log), ["installed:install", "installed:update:1.0"],
                "an in-session update reported the wrong runtime.onInstalled reason: \(log)"
            )
            XCTAssertTrue(
                self.startupEntries(log).isEmpty,
                "an in-session update is not a browser start: \(log)"
            )
        }
    }
}
