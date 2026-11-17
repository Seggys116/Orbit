import AppKit
import XCTest
@testable import Orbit

/// Pure tests of how a favicon's brightness and colour decide whether it is inverted: no window, no view.
final class FaviconLegibilityTests: XCTestCase {

    private func icon(_ color: NSColor, opaque: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        if opaque {
            color.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        }
        image.unlockFocus()
        return image
    }

    func test_aBlackIconIsDarkAndGrey() throws {
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(.black)))

        XCTAssertLessThan(tone.luminance, 0.05)
        XCTAssertLessThan(tone.saturation, 0.05)
    }

    func test_aWhiteIconIsLightAndGrey() throws {
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(.white)))

        XCTAssertGreaterThan(tone.luminance, 0.95)
        XCTAssertLessThan(tone.saturation, 0.05)
    }

    func test_aMonochromeDarkIconInvertsOnADarkBackgroundOnly() throws {
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(.black)))

        XCTAssertTrue(FaviconLegibility.shouldInvert(tone, onDarkBackground: true))
        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: false))
    }

    func test_aMonochromeLightIconInvertsOnALightBackgroundOnly() throws {
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(.white)))

        XCTAssertTrue(FaviconLegibility.shouldInvert(tone, onDarkBackground: false))
        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: true))
    }

    func test_aColouredIconIsNeverInverted_evenWhenItIsDark() throws {
        let navy = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.45, alpha: 1)
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(navy)))

        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: true))
        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: false))
    }

    func test_aMidGreyIconIsLeftAloneOnBothBackgrounds() throws {
        let tone = try XCTUnwrap(FaviconLegibility.tone(of: icon(NSColor(white: 0.5, alpha: 1))))

        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: true))
        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: false))
    }

    func test_aFullyTransparentIconHasNoToneAndIsNotInverted() {
        let tone = FaviconLegibility.tone(of: icon(.black, opaque: false))

        XCTAssertNil(tone)
        XCTAssertFalse(FaviconLegibility.shouldInvert(tone, onDarkBackground: true))
        XCTAssertFalse(FaviconLegibility.shouldInvert(nil, onDarkBackground: false))
    }
}
