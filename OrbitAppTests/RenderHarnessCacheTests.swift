import AppKit
import SwiftUI
import XCTest

private struct FlatColorProbe: View {
    let fill: Color
    var body: some View { fill }
}

@MainActor
final class RenderHarnessCacheTests: XCTestCase {

    private static let probeSize = CGSize(width: 40, height: 24)

    func test_twoRendersOfTheSameViewTypeAndSize_returnTheirOwnContent() {
        let first = render(FlatColorProbe(fill: .blue), size: Self.probeSize)
        let second = render(FlatColorProbe(fill: .red), size: Self.probeSize)

        let firstCentre = first.color(atX: 20, y: 12)
        let secondCentre = second.color(atX: 20, y: 12)

        XCTAssertGreaterThan(firstCentre.b, firstCentre.r, "test precondition: the first render is the blue one")
        XCTAssertGreaterThan(
            secondCentre.r, secondCentre.b,
            """
            The second render of FlatColorProbe at the same size came back blue — i.e. it was served \
            the first render's cached bitmap. Any render test that rasterises one view type at one \
            size more than once per process is then asserting on a stale image and passing without \
            testing anything. See RenderHarness.swift's header.
            """
        )
    }

    func test_screenshotRenderer_alsoReturnsItsOwnContentForARepeatedTypeAndSize() async {
        let first = await renderForScreenshot(FlatColorProbe(fill: .green), size: Self.probeSize, settlePasses: 1, settleDelayNanoseconds: 1_000_000)
        let second = await renderForScreenshot(FlatColorProbe(fill: .red), size: Self.probeSize, settlePasses: 1, settleDelayNanoseconds: 1_000_000)

        let firstCentre = first.color(atX: 20, y: 12)
        let secondCentre = second.color(atX: 20, y: 12)

        XCTAssertGreaterThan(firstCentre.g, firstCentre.r, "test precondition: the first screenshot render is the green one")
        XCTAssertGreaterThan(
            secondCentre.r, secondCentre.g,
            "renderForScreenshot served a cached bitmap from an earlier render of the same view type and size."
        )
    }

    func test_theReturnedBitmapIsAlwaysExactlyTheRequestedSize() {
        for index in 0..<8 {
            let size = CGSize(width: 40, height: 24)
            let rendered = render(FlatColorProbe(fill: .orange), size: size)

            XCTAssertEqual(rendered.pointSize, size, "render #\(index) reported a point size other than the one requested")
            XCTAssertEqual(
                rendered.bitmap.pixelsWide, Int(size.width * rendered.scale),
                "render #\(index) came back \(rendered.bitmap.pixelsWide)px wide for a \(size.width)pt request at scale \(rendered.scale) — the cache-busting padding was not cropped off, so every x coordinate in every pixel assertion is now shifted."
            )
            XCTAssertEqual(
                rendered.bitmap.pixelsHigh, Int(size.height * rendered.scale),
                "render #\(index) came back \(rendered.bitmap.pixelsHigh)px high for a \(size.height)pt request at scale \(rendered.scale) — the cache-busting padding was not cropped off."
            )
        }
    }

    func test_theViewStillStartsAtTheBitmapsTopLeftCorner() {
        for _ in 0..<4 {
            let size = CGSize(width: 60, height: 40)
            let rendered = render(FlatColorProbe(fill: .white), size: size)

            for (x, y) in [(0, 0), (Int(size.width) - 1, 0), (0, Int(size.height) - 1), (Int(size.width) - 1, Int(size.height) - 1)] {
                let sample = rendered.color(atX: x, y: y)
                XCTAssertGreaterThan(
                    sample.a, 0.5,
                    "(\(x), \(y)) is transparent — the cache-busting padding, not the view, is occupying part of the returned bitmap."
                )
            }
        }
    }
}
