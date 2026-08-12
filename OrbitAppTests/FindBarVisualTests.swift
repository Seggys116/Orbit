//  FindBarView had zero coverage before this file. Covers its declared size,
//  its two anchored controls, and that its match-count/chevron/Ask state actually tracks env, not a permanently fixed render.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class FindBarVisualTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // Generous margin around the bar's own declared 320x34 frame so its shadow (radius 10, y: 4)
    // never gets clipped by the render canvas itself and mistaken for missing content.
    private static let canvasSize = CGSize(width: 360, height: 70)

    private func view() -> some View {
        FindBarView().environment(env)
    }

    // MARK: - Declared size and anchored controls

    func test_findBar_paintsItsTwoAnchoredControls_inBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(view(), size: Self.canvasSize, appearance: appearance)

            let background = rendered.color(atX: 0, y: 0)
            let leadingIconBand = CGRect(x: 12, y: 8, width: 20, height: 18)
            let trailingDismissBand = CGRect(x: 296, y: 8, width: 20, height: 18)

            XCTAssertTrue(
                rendered.containsNonBackgroundPixels(in: leadingIconBand, background: background),
                "appearance \(appearance.rawValue): the magnifying-glass icon, always the bar's leading element, painted nothing at its fixed offset."
            )
            XCTAssertTrue(
                rendered.containsNonBackgroundPixels(in: trailingDismissBand, background: background),
                "appearance \(appearance.rawValue): the dismiss (x) button, always the bar's trailing element regardless of query/match state, painted nothing at its fixed offset."
            )
        }
    }

    func test_findBar_doesNotFillTheWholeRenderCanvas() {
        let rendered = render(view(), size: Self.canvasSize, appearance: .darkAqua)
        let farCorner = rendered.color(atX: Int(Self.canvasSize.width) - 2, y: Int(Self.canvasSize.height) - 2)
        XCTAssertEqual(
            farCorner.a, 0, accuracy: 0.05,
            "The far corner of a canvas well outside the bar's declared 320x34 frame was not transparent — FindBarView is not staying inside its own bounds."
        )
    }

    // MARK: - The match-count label appears only once there is a query

    func test_matchCountLabel_appearsOnlyWithANonEmptyQuery() {
        env.findQuery = ""
        env.currentFindResult = .none
        let empty = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        env.findQuery = "orbit"
        env.currentFindResult = FindResult(activeMatchOrdinal: 1, matchCount: 3, isFinalUpdate: true)
        let withMatches = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(empty, withMatches, size: Self.canvasSize),
            "Typing a query that has matches did not change anything rendered — the '1/3' label is not reachable."
        )
    }

    func test_matchCountLabel_readsDifferentlyForNoResultsThanForRealMatches() {
        env.findQuery = "orbit"
        env.currentFindResult = FindResult(activeMatchOrdinal: 0, matchCount: 0, isFinalUpdate: true)
        let noResults = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        env.currentFindResult = FindResult(activeMatchOrdinal: 1, matchCount: 5, isFinalUpdate: true)
        let fiveMatches = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(noResults, fiveMatches, size: Self.canvasSize),
            "'No results' and '1/5' rendered pixel-identical for the same query."
        )
    }

    // MARK: - The Ask affordance is gated on both zero matches and a configured provider

    func test_askButton_appearsOnlyWhenThereAreNoMatchesAndAProviderIsConfigured() {
        env.findQuery = "a phrase not on the page"
        env.currentFindResult = .none

        env.hasConfiguredAIProvider = false
        let withoutProvider = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        env.hasConfiguredAIProvider = true
        let withProvider = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withoutProvider, withProvider, size: Self.canvasSize),
            "Configuring an AI provider while a query has zero matches did not change anything rendered — the Ask button is not reachable."
        )
    }

    func test_askButton_neverAppearsWhenThereAreRealMatches_evenWithAProviderConfigured() {
        env.hasConfiguredAIProvider = true
        env.findQuery = "orbit"

        env.currentFindResult = FindResult(activeMatchOrdinal: 0, matchCount: 0, isFinalUpdate: true)
        let zeroMatches = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        env.currentFindResult = FindResult(activeMatchOrdinal: 1, matchCount: 2, isFinalUpdate: true)
        let realMatches = render(view(), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(zeroMatches, realMatches, size: Self.canvasSize),
            "Zero matches (Ask button visible) and two real matches (Ask button gone, chevrons enabled) rendered identically for the same provider-configured, non-empty query."
        )
    }

    // MARK: - Helpers

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 3
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}
