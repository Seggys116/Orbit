//  Live coverage for streamed delivery: chunked-transfer fetch() read progressively via the
//  Streams API, and byte-range (206) loading. Real inter-chunk delays make single-read pass vacuously.

import AppKit
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

    // MARK: - PDF handling (no plugin viewer implemented; reports observed behaviour, asserts nothing about it)

    private static func minimalPDFData() -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n",
        ]
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(body.utf8.count)
            body += object
        }
        let xrefOffset = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { body += String(format: "%010d 00000 n \n", offset) }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF"
        return Data(body.utf8)
    }

    func testNavigatingToAPDFReportsWhatOrbitActuallyDoesWithIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-PDFNavigationProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pdfBytes = Self.minimalPDFData()

        let readings = try LiveChromiumEngineHost.runLive { () -> [String: String] in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-pdf-navigation-probe</body></html>"),
                "/document.pdf": LiveHTTPTestServer.Route(contentType: "application/pdf", data: pdfBytes),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            let recorder = DownloadRecordingDelegate(destinationDirectory: scratch)
            contents.delegate = recorder

            contents.load(server.baseURL.appendingPathComponent("document.pdf"))
            let settleDeadline = ContinuousClock.now + .seconds(10)
            while recorder.willBeginDownloadCall == nil && contents.navigationState.isLoading {
                guard ContinuousClock.now < settleDeadline else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            if recorder.willBeginDownloadCall != nil {
                let downloadDeadline = ContinuousClock.now + .seconds(10)
                while recorder.finalState == nil || recorder.finalState == .pending || recorder.finalState == .inProgress {
                    guard ContinuousClock.now < downloadDeadline else { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                try await Task.sleep(for: .milliseconds(300))
            }

            var out: [String: String] = [:]
            out["serverSawRequest"] = String(server.requestLog.first(path: "/document.pdf") != nil)
            out["didBeginDownload"] = String(recorder.willBeginDownloadCall != nil)
            out["downloadMimeType"] = recorder.willBeginDownloadCall?.mimeType ?? "<none>"
            out["downloadSuggestedName"] = recorder.willBeginDownloadCall?.suggestedName ?? "<none>"
            out["downloadFinalState"] = recorder.finalState?.rawValue ?? "<none>"
            let downloadedFile = recorder.destinationURL.flatMap { try? Data(contentsOf: $0) }
            out["downloadedFileExists"] = String(downloadedFile != nil)
            out["downloadedByteCount"] = String(downloadedFile?.count ?? -1)
            out["sourceByteCount"] = String(pdfBytes.count)
            out["finalNavigationURL"] = contents.navigationState.url?.absoluteString ?? "<none>"
            out["isLoadingAfterSettle"] = String(contents.navigationState.isLoading)
            out["documentContentType"] = (try? await contents.evaluateJavaScript("document.contentType")) as? String ?? "<js-failed>"
            return out
        }

        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-PDF-NAVIGATION \(key)=\(value)")
        }

        XCTAssertEqual(readings["serverSawRequest"], "true", "the local server never saw the PDF request -- the navigation never left the test harness")
    }

    func testEmbeddingAPDFReportsWhatOrbitActuallyInstantiates() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let pdfBytes = Self.minimalPDFData()

        let readings = try LiveChromiumEngineHost.runLive { () -> [String: String] in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><embed id=\"probe\" type=\"application/pdf\" src=\"/document.pdf\" width=\"200\" height=\"200\"></body></html>"
                ),
                "/document.pdf": LiveHTTPTestServer.Route(contentType: "application/pdf", data: pdfBytes),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            let recorder = DownloadRecordingDelegate(destinationDirectory: nil)
            contents.delegate = recorder

            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300)) // let a late plugin-placeholder swap settle

            var out: [String: String] = [:]
            out["serverSawEmbedRequest"] = String(server.requestLog.first(path: "/document.pdf") != nil)
            out["didBeginDownloadForEmbed"] = String(recorder.willBeginDownloadCall != nil)
            out["embedOuterHTML"] = (try? await contents.evaluateJavaScript(
                "document.getElementById('probe') ? document.getElementById('probe').outerHTML : '<removed>'"
            )) as? String ?? "<js-failed>"
            let offsetWidth = try? await contents.evaluateJavaScript(
                "document.getElementById('probe') ? document.getElementById('probe').offsetWidth : -1"
            )
            out["embedOffsetWidth"] = String((offsetWidth as? NSNumber)?.intValue ?? -1)
            let offsetHeight = try? await contents.evaluateJavaScript(
                "document.getElementById('probe') ? document.getElementById('probe').offsetHeight : -1"
            )
            out["embedOffsetHeight"] = String((offsetHeight as? NSNumber)?.intValue ?? -1)
            out["documentReadyState"] = (try? await contents.evaluateJavaScript("document.readyState")) as? String ?? "<js-failed>"
            return out
        }

        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-PDF-EMBED \(key)=\(value)")
        }

        XCTAssertEqual(readings["documentReadyState"], "complete", "the host page around the <embed> never finished loading -- nothing to report about the plugin")
    }
}

/// Records the real content::DownloadManagerDelegate callback Chromium fires
/// -- see ChromiumWebContents.willBeginDownloadTrampoline. `destinationDirectory`
/// nil declines the download (still records that it was offered).
@MainActor
private final class DownloadRecordingDelegate: WebContentsDelegate {
    struct Call {
        let suggestedName: String
        let mimeType: String
        let totalBytes: Int64
        let sourceURL: URL
    }

    private(set) var willBeginDownloadCall: Call?
    private(set) var finalState: DownloadState?
    private(set) var destinationURL: URL?
    private let destinationDirectory: URL?

    init(destinationDirectory: URL?) {
        self.destinationDirectory = destinationDirectory
    }

    func webContents(
        _ contents: WebContents,
        willBeginDownload suggestedName: String,
        mimeType: String,
        totalBytes: Int64,
        sourceURL: URL,
        downloadID: UUID
    ) async -> URL? {
        willBeginDownloadCall = Call(suggestedName: suggestedName, mimeType: mimeType, totalBytes: totalBytes, sourceURL: sourceURL)
        guard let destinationDirectory else { return nil }
        let destination = destinationDirectory.appendingPathComponent(suggestedName.isEmpty ? "download.pdf" : suggestedName)
        destinationURL = destination
        return destination
    }

    func webContents(_ contents: WebContents, download id: UUID, didUpdate progress: DownloadProgress) {
        finalState = progress.state
    }
}
