import Foundation
import XCTest
@testable import Orbit

/// A single-page app changes the address without loading a document. The address field and the tab must follow it, or clicking the URL bar shows an older page until a reload.
@MainActor
final class SameDocumentNavigationLiveTests: XCTestCase {

    @MainActor
    private final class StateRecorder: WebContentsDelegate {
        private(set) var urls: [URL] = []

        func webContentsDidChangeNavigationState(_ contents: WebContents) {
            if let url = contents.navigationState.url { urls.append(url) }
        }
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(description)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPushStateAndHashChangesUpdateTheTabAddressAndHistoryAvailability() throws {
        try WebKitLiveEngineHost.runLive {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>spa</body></html>"),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            let recorder = StateRecorder()
            contents.delegate = recorder
            defer { contents.close() }

            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("history.pushState({}, '', '/products/42'); 0")
            try await self.waitUntil("pushState to reach the engine state") { contents.navigationState.url?.path == "/products/42" }
            XCTAssertTrue(recorder.urls.contains { $0.path == "/products/42" }, "The delegate was never told the address changed.")
            try await self.waitUntil("pushState to enable Back") { contents.navigationState.canGoBack }

            _ = try await contents.evaluateJavaScript("location.hash = 'reviews'; 0")
            try await self.waitUntil("the hash change to reach the engine state") { contents.navigationState.url?.fragment == "reviews" }

            contents.goBack()
            try await self.waitUntil("going back to the pushState entry") {
                contents.navigationState.url?.path == "/products/42" && contents.navigationState.url?.fragment == nil
            }
            try await self.waitUntil("going back to enable Forward") { contents.navigationState.canGoForward }
        }
    }
}
