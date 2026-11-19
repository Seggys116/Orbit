//  Regression cover: the reload button used to swap its glyph between reload and stop in a single frame, with no
//  response to the click, so it read as stiff.

import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ToolbarReloadButtonTests: XCTestCase {

    func test_clickingReloadWhileIdle_turnsTheGlyphOnce() {
        var motion = ReloadGlyphMotion()
        motion.clicked(isLoading: false)
        XCTAssertEqual(motion.turns, 1)
        XCTAssertEqual(motion.degrees, 360)
        motion.clicked(isLoading: false)
        XCTAssertEqual(motion.degrees, 720, "Each reload must turn the glyph again rather than snapping back.")
    }

    func test_clickingStopWhileLoading_doesNotSpinTheGlyph() {
        var motion = ReloadGlyphMotion()
        motion.clicked(isLoading: true)
        XCTAssertEqual(motion.turns, 0, "The stop button has nothing to reload.")
    }

    func test_theGlyphIsTheStopMarkOnlyWhileLoading() {
        XCTAssertEqual(ReloadGlyphMotion.symbolName(isLoading: false), "arrow.clockwise")
        XCTAssertEqual(ReloadGlyphMotion.symbolName(isLoading: true), "xmark")
    }

    func test_reduceMotionDropsTheSpin_butKeepsTheSwap() {
        XCTAssertNil(ReloadGlyphMotion.turnAnimation(reduceMotion: true))
        XCTAssertNotNil(ReloadGlyphMotion.turnAnimation(reduceMotion: false))
    }

    func test_theReloadButtonRendersItsGlyph() {
        let hosting = NSHostingView(rootView: ToolbarReloadButton(isLoading: false, foreground: .white, hoverFill: .gray) {})
        hosting.frame = NSRect(x: 0, y: 0, width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, OrbitToolbarMetrics.navIconSize)
        XCTAssertEqual(hosting.fittingSize.height, OrbitToolbarMetrics.navIconSize)
    }
}
