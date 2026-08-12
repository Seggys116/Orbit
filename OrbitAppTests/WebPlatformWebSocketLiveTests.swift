//  Live coverage for a real WebSocket: open, bidirectional messages, clean close, and sequential
//  server pushes. LiveHTTPTestServer speaks real RFC 6455 -- not a mock.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebPlatformWebSocketLiveTests: XCTestCase {

    private func waitUntilTrue(
        _ contents: ChromiumWebContents,
        _ expression: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let result = try await contents.evaluateJavaScript(expression)
            if (result as? Bool) == true { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "'\(expression)' never became true")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testWebSocketOpensExchangesMessagesBothWaysAndClosesCleanly() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let events = try LiveChromiumEngineHost.runLive { () -> [String] in
            let server = try LiveHTTPTestServer(
                routes: ["/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-websocket-test</body></html>")],
                webSocketRoutes: ["/ws": .echo(greeting: "server-hello")]
            )
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitWSEvents = [];
            window.__orbitWSClosed = false;
            var ws = new WebSocket('ws://127.0.0.1:\(server.port)/ws');
            ws.onopen = function() { window.__orbitWSEvents.push('open'); };
            ws.onmessage = function(e) {
              window.__orbitWSEvents.push('message:' + e.data);
              if (e.data === 'server-hello') { ws.send('ping-from-client'); }
              else if (e.data === 'echo:ping-from-client') { ws.close(); }
            };
            ws.onclose = function(e) { window.__orbitWSEvents.push('close:' + e.wasClean); window.__orbitWSClosed = true; };
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitWSClosed === true", timeout: .seconds(15))

            let result = try await contents.evaluateJavaScript("window.__orbitWSEvents")
            return (result as? [Any])?.compactMap { $0 as? String } ?? []
        }

        XCTAssertEqual(
            events,
            ["open", "message:server-hello", "message:echo:ping-from-client", "close:true"],
            "a real WebSocket did not go through open -> server-initiated message -> client-initiated message-and-echo -> clean close in order"
        )
    }

    func testWebSocketReceivesMultipleSequentialServerPushedMessagesInOrder() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (messages, wasClean) = try LiveChromiumEngineHost.runLive { () -> ([String], Bool) in
            let server = try LiveHTTPTestServer(
                routes: ["/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-websocket-push-test</body></html>")],
                webSocketRoutes: ["/ws-push": .serverPush(messages: ["orbit-1", "orbit-2", "orbit-3"], interval: 0.1)]
            )
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitWSMessages = [];
            window.__orbitWSPushClosed = null;
            var ws = new WebSocket('ws://127.0.0.1:\(server.port)/ws-push');
            ws.onmessage = function(e) {
              window.__orbitWSMessages.push(e.data);
              if (window.__orbitWSMessages.length === 3) { ws.close(); }
            };
            ws.onclose = function(e) { window.__orbitWSPushClosed = e.wasClean; };
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitWSPushClosed !== null", timeout: .seconds(15))

            let messagesResult = try await contents.evaluateJavaScript("window.__orbitWSMessages")
            let closedResult = try await contents.evaluateJavaScript("window.__orbitWSPushClosed")
            let messageArray = (messagesResult as? [Any])?.compactMap { $0 as? String } ?? []
            return (messageArray, (closedResult as? Bool) ?? false)
        }

        XCTAssertEqual(messages, ["orbit-1", "orbit-2", "orbit-3"], "three sequential server-pushed messages did not arrive in order")
        XCTAssertTrue(wasClean, "the client-initiated close after receiving all server-pushed messages did not close cleanly")
    }
}
