import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class TempInvertedGlyphVisualCheck: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        PaneHeaderColorResolver.shared._test_reset()
    }

    private func makeTab(url: String = "https://news.ycombinator.com/newest") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    func test_writeHeaderPNGsForVisualInspection() {
        let outputDirectory = "/private/tmp/claude-501/-Users-zaknoble-clarke-Projects-XCode-Orbit/83215bf3-b4a8-4608-8040-e48cec5e50d3/scratchpad"

        let cases: [(name: String, color: ThemeColor?)] = [
            ("01-hn-orange-ff6600", ThemeColor(red: 1, green: 0.4, blue: 0)),
            ("02-white-page", ThemeColor(red: 1, green: 1, blue: 1)),
            ("03-github-dark-0d1117", ThemeColor(red: 0.051, green: 0.067, blue: 0.09)),
            ("04-saturated-blue-0000ff", ThemeColor(red: 0, green: 0, blue: 1)),
            ("05-mid-grey-808080", ThemeColor(red: 0.502, green: 0.502, blue: 0.502)),
            ("06-no-page-colour-neutral-fallback", nil),
        ]

        let size = CGSize(width: 520, height: OrbitToolbarMetrics.totalHeight)

        for scheme: NSAppearance.Name in [.darkAqua, .aqua] {
            for testCase in cases {
                let tab = makeTab()
                defer { env.state.tabs.removeValue(forKey: tab.id) }
                env.navigationStates[tab.id] = NavigationState(
                    canGoBack: true,
                    canGoForward: false,
                    isLoading: false,
                    security: .secure
                )
                if let color = testCase.color {
                    env.themeColors[tab.id] = color
                } else {
                    env.themeColors.removeValue(forKey: tab.id)
                }

                let rendered = render(
                    ToolbarView(tab: tab).environment(env),
                    size: size,
                    appearance: scheme
                )
                let suffix = scheme == .darkAqua ? "dark" : "light"
                rendered.writePNG(
                    to: URL(fileURLWithPath: "\(outputDirectory)/header-\(testCase.name)-\(suffix).png")
                )
                env.themeColors.removeValue(forKey: tab.id)
                env.navigationStates.removeValue(forKey: tab.id)
            }
        }
    }
}
