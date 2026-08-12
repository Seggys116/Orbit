//  The whole self-sizing path against a real browser process: Swift's
//  enableContentSizing -> renderer layout -> didChangePreferredSize.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumAutoResizeLiveTests: XCTestCase {

    private final class SizeRecorder: WebContentsDelegate {
        private(set) var reported: [CGSize] = []

        func webContents(_ contents: WebContents, didChangePreferredSize size: CGSize) {
            reported.append(size)
        }
    }

    private static func document(width: Int, height: Int) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; padding: 0; }
        #box { width: \(width)px; height: \(height)px; background: #cccccc; }
        </style></head><body><div id="box"></div></body></html>
        """
    }

    private func waitForPreferredSize(
        _ recorder: SizeRecorder,
        timeout: Duration = .seconds(10)
    ) async throws -> CGSize {
        let deadline = ContinuousClock.now + timeout
        while recorder.reported.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "the renderer never reported a preferred size"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // One more settle pass: the first report can precede the final layout.
        try await Task.sleep(for: .milliseconds(300))
        return recorder.reported.last!
    }

    func testAutoResizeReportsTheDocumentsOwnSizeNotTheHostsSize() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive {
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            // The host view is deliberately far larger than the document: the
            // reported size must come from the document, not from this.
            contents.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            contents.enableContentSizing(
                minimum: ExtensionActionPopupSupport.popupMinimumSize,
                maximum: ExtensionActionPopupSupport.popupMaximumSize
            )
            contents.loadHTML(Self.document(width: 213, height: 137), baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let size = try await self.waitForPreferredSize(recorder)
            XCTAssertEqual(size.width, 213, accuracy: 4, "reported width should be the document's own")
            XCTAssertEqual(size.height, 137, accuracy: 4, "reported height should be the document's own")
            _ = recorder
        }
    }

    func testAutoResizeNeverReportsMoreThanTheMaximumItWasGiven() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive {
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            contents.enableContentSizing(
                minimum: ExtensionActionPopupSupport.popupMinimumSize,
                maximum: ExtensionActionPopupSupport.popupMaximumSize
            )
            contents.loadHTML(Self.document(width: 2400, height: 2400), baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let size = try await self.waitForPreferredSize(recorder)
            XCTAssertLessThanOrEqual(size.width, ExtensionActionPopupSupport.popupMaximumSize.width)
            XCTAssertLessThanOrEqual(size.height, ExtensionActionPopupSupport.popupMaximumSize.height)
            _ = recorder
        }
    }

    func testAWebContentsWithoutContentSizingNeverReportsAPreferredSize() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE is not set")
        try LiveChromiumEngineHost.runLive {
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            contents.loadHTML(Self.document(width: 213, height: 137), baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(500))

            XCTAssertTrue(
                recorder.reported.isEmpty,
                "an ordinary tab must stay laid out at its host's size, never self-size"
            )
            _ = recorder
        }
    }
}
