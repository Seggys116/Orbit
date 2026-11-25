//  A primary button's label must stay readable on whatever accent it is filled with, including the near-white accent a dark space theme gives.

import SwiftUI
import XCTest
@testable import Orbit

final class OrbitButtonPrimaryForegroundTests: XCTestCase {

    private func brightness(_ color: Color) -> Double { color.srgbComponents.red }

    func test_aLightAccentGetsDarkText() {
        for accent in [Color.white, Color(.sRGB, red: 0.9, green: 0.9, blue: 0.92, opacity: 1), Color.yellow] {
            XCTAssertLessThan(brightness(OrbitButton.primaryForeground(onAccent: accent)), 0.3, "light accent \(accent) got light text")
        }
    }

    func test_aDarkOrSaturatedAccentKeepsWhiteText() {
        for accent in [Color.black, Color.blue, Color(.sRGB, red: 0, green: 0.48, blue: 1, opacity: 1), Color(.sRGB, red: 0.1, green: 0.3, blue: 0.3, opacity: 1)] {
            XCTAssertGreaterThan(brightness(OrbitButton.primaryForeground(onAccent: accent)), 0.9, "dark accent \(accent) got dark text")
        }
    }

    func test_theDarkThemeAccentThePasswordPromptUsesIsReadable() {
        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.0, green: 0.2, blue: 0.24)])
        XCTAssertTrue(theme.isDarkSurface)
        let chrome = SpaceThemeChrome(theme: theme, colorScheme: .dark)
        XCTAssertLessThan(brightness(OrbitButton.primaryForeground(onAccent: chrome.accent)), 0.3)
    }
}
