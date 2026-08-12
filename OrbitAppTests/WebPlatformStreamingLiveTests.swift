//  Live coverage for streamed delivery: chunked-transfer fetch() read progressively via the
//  Streams API, and byte-range (206) loading. Real inter-chunk delays make single-read pass vacuously.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebPlatformStreamingLiveTests: XCTestCase {

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

    // MARK: - Chunked transfer encoding

    func testChunkedTransferEncodedFetchArrivesAsMultipleReadsAndReassemblesCorrectly() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (readCount, body, firstToLastGapMillis) = try LiveChromiumEngineHost.runLive { () -> (Int, String, Double) in
            let chunkTexts = ["orbit-chunk-one;", "orbit-chunk-two;", "orbit-chunk-three;", "orbit-chunk-four;"]
            let server = try LiveHTTPTestServer(
                routes: [
                    "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-chunked-test</body></html>"),
                ],
                chunkedRoutes: [
                    "/stream": LiveHTTPTestServer.ChunkedRoute(contentType: "text/plain", chunks: chunkTexts, interChunkDelay: 0.2),
                ]
            )
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitStreamDone = false;
            window.__orbitStreamReadCount = 0;
            window.__orbitStreamBody = '';
            window.__orbitStreamTimestamps = [];
            fetch('/stream').then(function(response) {
              var reader = response.body.getReader();
              var decoder = new TextDecoder();
              function pump() {
                return reader.read().then(function(step) {
                  if (step.done) { window.__orbitStreamDone = true; return; }
                  window.__orbitStreamReadCount += 1;
                  window.__orbitStreamTimestamps.push(performance.now());
                  window.__orbitStreamBody += decoder.decode(step.value, { stream: true });
                  return pump();
                });
              }
              return pump();
            }).catch(function(e) { window.__orbitStreamError = String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitStreamDone === true || !!window.__orbitStreamError", timeout: .seconds(15))

            let readCountResult = try await contents.evaluateJavaScript("window.__orbitStreamReadCount")
            let bodyResult = try await contents.evaluateJavaScript("window.__orbitStreamBody")
            let timestamps = try await contents.evaluateJavaScript("window.__orbitStreamTimestamps")
            let timestampArray = (timestamps as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            let gap = (timestampArray.last ?? 0) - (timestampArray.first ?? 0)
            return ((readCountResult as? NSNumber)?.intValue ?? 0, (bodyResult as? String) ?? "", gap)
        }

        XCTAssertGreaterThan(readCount, 1, "a chunked response with real inter-chunk delays produced only a single Streams API read -- the network stack buffered it instead of delivering it progressively")
        XCTAssertEqual(body, "orbit-chunk-one;orbit-chunk-two;orbit-chunk-three;orbit-chunk-four;", "the reassembled chunked body did not match the real chunks the server wrote")
        XCTAssertGreaterThan(firstToLastGapMillis, 300, "the first and last chunk reads should be separated by roughly the server's real inter-chunk delay (3 gaps x 200ms); a near-zero gap means the body was delivered all at once, not streamed")
    }

    // MARK: - Range requests: a resource loaded progressively in pieces

    func testByteRangeRequestsLoadAResourceProgressivelyInTwoPieces() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let fullBody = String(repeating: "0123456789", count: 50) // 500 bytes, deterministic content
        let (firstStatus, secondStatus, reassembled) = try LiveChromiumEngineHost.runLive { () -> (Int, Int, String) in
            let rangedServer = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-range-test</body></html>"),
                "/resource.bin": LiveHTTPTestServer.Route(
                    contentType: "application/octet-stream", data: Data(fullBody.utf8), supportsRangeRequests: true
                ),
            ])
            defer { rangedServer.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(rangedServer.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitRangeResult = null;
            Promise.all([
              fetch('/resource.bin', { headers: { Range: 'bytes=0-249' } }),
              fetch('/resource.bin', { headers: { Range: 'bytes=250-499' } })
            ]).then(function(responses) {
              return Promise.all([responses[0].status, responses[1].status, responses[0].text(), responses[1].text()]);
            }).then(function(results) {
              window.__orbitRangeResult = { first: results[0], second: results[1], combined: results[2] + results[3] };
            }).catch(function(e) { window.__orbitRangeResult = { error: String(e) }; });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitRangeResult !== null")

            let result = try await contents.evaluateJavaScript("window.__orbitRangeResult")
            let dictionary = result as? [String: Any] ?? [:]
            let first = (dictionary["first"] as? NSNumber)?.intValue ?? -1
            let second = (dictionary["second"] as? NSNumber)?.intValue ?? -1
            let combined = dictionary["combined"] as? String ?? ""
            return (first, second, combined)
        }

        XCTAssertEqual(firstStatus, 206, "a Range request for the first half must get 206 Partial Content")
        XCTAssertEqual(secondStatus, 206, "a Range request for the second half must get 206 Partial Content")
        XCTAssertEqual(reassembled, fullBody, "the two range-requested halves did not reassemble into the original resource -- progressive range loading is broken")
    }
}
