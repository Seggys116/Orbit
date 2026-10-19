//  The whole self-sizing path against a real browser process: Swift's
//  enableContentSizing -> renderer layout -> didChangePreferredSize.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitAutoResizeLiveTests: XCTestCase {

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
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
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
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let size = try await self.waitForPreferredSize(recorder)
            XCTAssertEqual(size.width, 213, accuracy: 4, "reported width should be the document's own")
            XCTAssertEqual(size.height, 137, accuracy: 4, "reported height should be the document's own")
            _ = recorder
        }
    }

    func testAutoResizeNeverReportsMoreThanTheMaximumItWasGiven() throws {
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            contents.enableContentSizing(
                minimum: ExtensionActionPopupSupport.popupMinimumSize,
                maximum: ExtensionActionPopupSupport.popupMaximumSize
            )
            contents.loadHTML(Self.document(width: 2400, height: 2400), baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let size = try await self.waitForPreferredSize(recorder)
            XCTAssertLessThanOrEqual(size.width, ExtensionActionPopupSupport.popupMaximumSize.width)
            XCTAssertLessThanOrEqual(size.height, ExtensionActionPopupSupport.popupMaximumSize.height)
            _ = recorder
        }
    }

    // The shape of iCloud Passwords' popup: an author-declared body width, a margin on the body, padding, and nowrap rows whose text is far wider than the body. The popup must be as wide as the author asked (the body's margin box), not as wide as its longest unwrapped row, and as tall as the whole document including the body's margins.
    private static let declaredWidthDocument = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    body { position: relative; margin: 8px 8px 0 8px; padding: 32px 8px 0 8px; min-height: 100px; font: 15px -apple-system, sans-serif; }
    body.popup { width: 344px; }
    ul { list-style: none; margin: 10px -16px 0 -16px; padding: 0; }
    li { height: 44px; padding: 2px 24px; }
    li p { margin: 0; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; display: inherit; }
    #tall { height: 200px; }
    </style></head><body class="popup">
    <div id="tall"></div>
    <ul><li><p>an-extremely-long-address-that-would-never-fit-on-one-line-of-this-popup@some-very-long-domain-name.example.com and then a good deal more text after it</p></li></ul>
    </body></html>
    """

    func testAutoResizeHonoursAnAuthorDeclaredBodyWidthAndKeepsTheBodysMargins() throws {
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            contents.view.frame = NSRect(origin: .zero, size: ExtensionActionPopupSupport.popupLoadingSize)
            contents.enableContentSizing(
                minimum: ExtensionActionPopupSupport.popupMinimumSize,
                maximum: ExtensionActionPopupSupport.popupMaximumSize
            )
            contents.loadHTML(Self.declaredWidthDocument, baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let size = try await self.waitForPreferredSize(recorder)
            // 344 declared + 16 padding + 16 margin.
            XCTAssertEqual(size.width, 376, accuracy: 2, "A body that declares its width must keep it, not widen to its longest nowrap row. Reported \(size).")
            // 8 margin + 32 padding + 200 + 10 list margin + 48 row (44 + 2 + 2 padding).
            XCTAssertEqual(size.height, 298, accuracy: 2, "The body's own margins are part of the document and must not be clipped. Reported \(size).")
        }
    }

    func testTheFallbackMeasurementAgreesWithTheLiveObserver() throws {
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }

            contents.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            contents.loadHTML(Self.declaredWidthDocument, baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let measured = await ExtensionActionPopupSupport.measuredContentSize(in: contents)
            let size = try XCTUnwrap(measured, "The measuring script returned nothing.")
            XCTAssertEqual(size.width, 376, accuracy: 2, "Reported \(size).")
            XCTAssertEqual(size.height, 298, accuracy: 2, "Reported \(size).")
        }
    }

    func testAWebContentsWithoutContentSizingNeverReportsAPreferredSize() throws {
        try WebKitLiveEngineHost.runLive {
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }

            let recorder = SizeRecorder()
            contents.delegate = recorder
            contents.loadHTML(Self.document(width: 213, height: 137), baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(500))

            XCTAssertTrue(
                recorder.reported.isEmpty,
                "an ordinary tab must stay laid out at its host's size, never self-size"
            )
            _ = recorder
        }
    }
}
