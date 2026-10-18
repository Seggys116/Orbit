//  Real Chrome native messaging against a real host: a shell script that speaks Chrome's
//  framing, registered with a host manifest in Orbit's own NativeMessagingHosts directory.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitNativeMessagingLiveTests: XCTestCase {

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    // MARK: - Host

    /// Echoes every message back with the origin it was launched for, and exits on {"exit": true}.
    /// `dd bs=1` reads exactly the bytes a frame declares, never into the next one.
    private static let hostScript = #"""
    #!/bin/sh
    while :; do
      header=$(dd bs=1 count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
      [ -z "$header" ] && exit 0
      body=$(dd bs=1 count="$header" 2>/dev/null)
      case "$body" in
        *'"exit"'*) exit 0 ;;
      esac
      reply="{\"echo\":$body,\"origin\":\"$1\"}"
      len=$(printf '%s' "$reply" | wc -c | tr -d ' ')
      printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((len & 255)) $(((len >> 8) & 255)) $(((len >> 16) & 255)) $(((len >> 24) & 255)))"
      printf '%s' "$reply"
    done
    """#

    private func installHost(named name: String, allowedExtensionIDs: [String]) throws {
        let hostDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-NativeHost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        temporaryURLs.append(hostDirectory)
        let script = hostDirectory.appendingPathComponent("host.sh")
        try Self.hostScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let manifestDirectory = OrbitDataRoot.processDefault.url
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifestFile = manifestDirectory.appendingPathComponent("\(name).json")
        let manifest: [String: Any] = [
            "name": name,
            "description": "Orbit native messaging test host",
            "type": "stdio",
            "path": script.path,
            "allowed_origins": allowedExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manifestFile)
        temporaryURLs.append(manifestFile)
    }

    // MARK: - Fixture

    private func writeExtension(declaresNativeMessaging: Bool, hostName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-NativeMessaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURLs.append(directory)

        let permissions = declaresNativeMessaging ? "[\"nativeMessaging\"]" : "[]"
        try """
        {
          "manifest_version": 3,
          "name": "Orbit Native Messaging Test",
          "version": "1.0",
          "permissions": \(permissions),
          "background": { "service_worker": "background.js" }
        }
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try """
        var HOST = \(JavaScriptLiteral.string(hostName));
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'one-shot' || message === 'missing-host') {
            var name = message === 'missing-host' ? 'orbit.no_such_host' : HOST;
            chrome.runtime.sendNativeMessage(name, { ping: 'orbit-one-shot' }, function (response) {
              sendResponse(JSON.stringify({
                response: response === undefined ? null : response,
                error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
              }));
            });
            return true;
          }
          if (message === 'port') {
            var port = chrome.runtime.connectNative(HOST);
            var replies = [];
            port.onMessage.addListener(function (reply) {
              replies.push(reply);
              if (replies.length === 2) { port.postMessage({ exit: true }); }
            });
            port.onDisconnect.addListener(function () {
              sendResponse(JSON.stringify({
                replies: replies,
                error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
              }));
            });
            port.postMessage({ ping: 'orbit-port-1' });
            port.postMessage({ ping: 'orbit-port-2' });
            return true;
          }
        });
        """.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        try """
        <!DOCTYPE html>
        <html><head><title>Orbit Native Messaging Probe</title></head>
        <body><script src="probe.js"></script></body></html>
        """.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        try """
        var question = new URL(location.href).searchParams.get('ask');
        chrome.runtime.sendMessage(question, function (response) {
          document.documentElement.setAttribute('data-orbit-answer',
            chrome.runtime.lastError ? 'error:' + chrome.runtime.lastError.message : String(response));
        });
        """.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private static func pollUntil(timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func ask(_ question: String, extensionID: String, engine: WebKitEngine) async throws -> [String: Any] {
        let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        contents.load(URL(string: "chrome-extension://\(extensionID)/probe.html?ask=\(question)")!)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        try await Self.pollUntil {
            try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-answer')") as? String != nil
        }
        let raw = try await contents.evaluateJavaScript("document.documentElement.getAttribute('data-orbit-answer')") as? String ?? ""
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        return try XCTUnwrap(parsed, "the worker answered \(question) with \(raw)")
    }

    private func hostName() -> String {
        "com.orbit.test_host_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Tests

    func testSendNativeMessageLaunchesTheHostWithTheCallersOriginAndReturnsItsReply() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let name = self.hostName()
            let directory = try self.writeExtension(declaresNativeMessaging: true, hostName: name)
            let id = ChromeExtensionID.id(forUnpackedPath: directory)
            try self.installHost(named: name, allowedExtensionIDs: [id])
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            XCTAssertEqual(loaded.id, id)

            let answer = try await self.ask("one-shot", extensionID: loaded.id, engine: engine)
            XCTAssertTrue(answer["error"] is NSNull, "sendNativeMessage failed: \(answer)")
            let response = try XCTUnwrap(answer["response"] as? [String: Any], "the host's reply never arrived: \(answer)")
            XCTAssertEqual((response["echo"] as? [String: Any])?["ping"] as? String, "orbit-one-shot",
                           "the host must receive exactly the message the extension sent")
            XCTAssertEqual(response["origin"] as? String, "chrome-extension://\(id)/",
                           "Chrome passes the caller's origin as the host's first argument")
        }
    }

    func testConnectNativeRelaysEveryMessageAndClosesThePortWhenTheHostExits() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let name = self.hostName()
            let directory = try self.writeExtension(declaresNativeMessaging: true, hostName: name)
            try self.installHost(named: name, allowedExtensionIDs: [ChromeExtensionID.id(forUnpackedPath: directory)])
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let answer = try await self.ask("port", extensionID: loaded.id, engine: engine)
            let replies = answer["replies"] as? [[String: Any]] ?? []
            XCTAssertEqual(
                replies.compactMap { ($0["echo"] as? [String: Any])?["ping"] as? String },
                ["orbit-port-1", "orbit-port-2"],
                "a native port must relay each message, in order, for as long as the host runs: \(answer)"
            )
            XCTAssertTrue((answer["error"] as? String ?? "").contains("Native host has exited"),
                          "the port must disconnect with Chrome's error once the host exits: \(answer)")
        }
    }

    func testAHostWhoseAllowedOriginsOmitTheExtensionIsForbidden() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let name = self.hostName()
            let directory = try self.writeExtension(declaresNativeMessaging: true, hostName: name)
            try self.installHost(named: name, allowedExtensionIDs: ["abcdefghijklmnopabcdefghijklmnop"])
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let answer = try await self.ask("one-shot", extensionID: loaded.id, engine: engine)
            let error = answer["error"] as? String ?? ""
            XCTAssertTrue(error.contains("forbidden"), "allowed_origins must be enforced: \(answer)")
            XCTAssertTrue(answer["response"] is NSNull)
        }
    }

    func testAnUnregisteredHostIsNotFound() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let directory = try self.writeExtension(declaresNativeMessaging: true, hostName: self.hostName())
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let answer = try await self.ask("missing-host", extensionID: loaded.id, engine: engine)
            let error = answer["error"] as? String ?? ""
            XCTAssertTrue(error.contains("Specified native messaging host not found"), "got \(answer)")
        }
    }

    /// WebKit binds sendNativeMessage from the context's grant, which Orbit's transport needs, so the
    /// gate is the host itself: one the extension never declared it may talk to is refused.
    func testAnExtensionThatDidNotDeclareNativeMessagingCannotReachAHostThatAllowsIt() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let name = self.hostName()
            let silent = try self.writeExtension(declaresNativeMessaging: false, hostName: name)
            try self.installHost(named: name, allowedExtensionIDs: [ChromeExtensionID.id(forUnpackedPath: silent)])
            let loaded = try await engine.loadExtension(at: silent, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let answer = try await self.ask("one-shot", extensionID: loaded.id, engine: engine)
            XCTAssertTrue(answer["response"] is NSNull, "the host must never be launched for it: \(answer)")
            XCTAssertTrue((answer["error"] as? String ?? "").contains("forbidden"), "got \(answer)")

            let port = try await self.ask("port", extensionID: loaded.id, engine: engine)
            XCTAssertEqual((port["replies"] as? [Any])?.count, 0, "connectNative must not reach the host either: \(port)")

            let manifest = try String(contentsOf: silent.appendingPathComponent("manifest.json"), encoding: .utf8)
            XCTAssertFalse(manifest.contains("nativeMessaging"),
                           "the extension's manifest must keep the permissions it declared, with nothing added")
        }
    }
}
