//  Never builds a real NSWindow: doing so reliably crashed xctest with
//  SIGSEGV in this host-less sandbox.

import XCTest
import AppKit
import SwiftUI

@MainActor
final class WindowSizingRegressionTests: XCTestCase {

    private struct TallContent: View {
        var body: some View {
            VStack(spacing: 0) {
                ForEach(0..<40, id: \.self) { _ in Color.clear.frame(height: 50) }
            }
        }
    }

    private func makeTallHostingView(sizingOptions: NSHostingSizingOptions) -> NSHostingView<TallContent> {
        let hosting = NSHostingView(rootView: TallContent())
        hosting.sizingOptions = sizingOptions
        return hosting
    }

    func test_withoutTheFix_defaultSizingOptions_fittingSizeReflectsTallContentHeight() {
        let hosting = makeTallHostingView(sizingOptions: .standardBounds)
        XCTAssertGreaterThan(
            hosting.fittingSize.height, 1500,
            "Expected the unfixed configuration (default NSHostingView.sizingOptions, .standardBounds) to report a fittingSize.height reflecting the tall SwiftUI content's own ideal height (40 * 50pt = 2000pt) — found \(hosting.fittingSize.height)pt, meaning AppKit's default sizing behaviour no longer reproduces the mechanism this test documents."
        )
    }

    func test_withTheFix_emptySizingOptions_fittingSizeNoLongerReflectsTallContentHeight() {
        let hosting = makeTallHostingView(sizingOptions: [])
        XCTAssertLessThan(
            hosting.fittingSize.height, 1500,
            "P0 regression: OrbitWindowController.configure() sets hosting.sizingOptions = [] specifically so the hosting view never publishes the SwiftUI content's own tall ideal height as its fittingSize — found \(hosting.fittingSize.height)pt, still reflecting the tall content."
        )
    }

    func test_fittingSizeHeight_isSubstantiallySmallerWithTheFixThanWithoutIt() {
        let withoutFix = makeTallHostingView(sizingOptions: .standardBounds).fittingSize.height
        let withFix = makeTallHostingView(sizingOptions: []).fittingSize.height
        XCTAssertLessThan(
            withFix, withoutFix / 2,
            "Expected sizingOptions = [] to report a substantially smaller fittingSize.height (\(withFix)pt) than the default .standardBounds configuration (\(withoutFix)pt) for the exact same tall content — if these converge, the fix no longer isolates the mechanism this P0 depended on."
        )
    }
}
