import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ProfilesSettingsPaneLayoutTests: XCTestCase {

    func test_profilesDetailColumn_fitsInsideProductionContentWidth_andDeleteProfileRenders() {
        let env = AppEnvironment.demo
        let width = SettingsMetrics.contentMaxWidth

        let rendered = render(
            ProfilesSettingsPane()
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
                .padding(SettingsMetrics.contentHorizontalPadding)
                .frame(maxWidth: width, alignment: .leading),
            size: CGSize(width: width, height: 1400)
        )

        guard let box = rendered.boundingBoxOfContent() else {
            rendered.writeDiagnosticPNG(named: "ProfilesSettingsPaneLayoutTests_empty")
            XCTFail("ProfilesSettingsPane drew nothing at the production content width (\(width)pt).")
            return
        }

        XCTAssertLessThanOrEqual(
            box.maxX, width + 1,
            "ProfilesSettingsPane must not draw past its own right edge at the production content width (\(width)pt) — got content extending to \(box.maxX)pt. This is finding 1's regression: the detail column overflowing its real interior and clipping (the Search engine popup, \"Archive tabs after\"'s picker, the storage identifier, \"Add a Space\", and \"Delete Profile\" all sit at or near this trailing edge)."
        )

        XCTAssertLessThanOrEqual(
            box.maxY, SettingsMetrics.windowDefaultHeight,
            "ProfilesSettingsPane's rendered content reaches \(box.maxY)pt, past the real Settings window's own default height (\(SettingsMetrics.windowDefaultHeight)pt) — this is finding 3's regression: a description squeezed into a narrow column beside a wide trailing control wraps to enough extra lines to overflow the window vertically at its default size, even though nothing is horizontally clipped."
        )

        let deleteProfileBand = CGRect(
            x: width - SettingsMetrics.contentHorizontalPadding - 140,
            y: box.maxY - 40,
            width: 140,
            height: 40
        )
        let hasDeleteProfileControl = rendered.containsNonBackgroundPixels(in: deleteProfileBand, background: .clear)
        if !hasDeleteProfileControl {
            rendered.writeDiagnosticPNG(named: "ProfilesSettingsPaneLayoutTests_noDeleteProfile")
        }
        XCTAssertTrue(
            hasDeleteProfileControl,
            "expected a control (\"Delete Profile\") flush to the pane's bottom-right corner at the production content width, found nothing there — this is exactly what finding 1's overflow silently dropped from the rendered window."
        )
    }

    func test_orbitSettingsRow_descriptionUsesFullRowWidth_neitherTruncatedNorSqueezedNarrow() {
        let width = ProfilesSettingsPane.cardInteriorWidth
        let fontSize = OrbitControlMetrics.settingsRowDescriptionFontSize

        let cases: [(name: String, title: String, description: String)] = [
            (
                "Archive tabs after",
                "Archive tabs after",
                "Applies to every Space on this Profile. The tab you are looking at, tabs in a Split View, and tabs playing media are never archived."
            ),
            (
                "Add a Space",
                "Add a Space",
                "Moves the Space onto this Profile. Its cookies, logins, history and extensions become this Profile's, effective immediately."
            ),
        ]

        for testCase in cases {
            let baselineDescription = "."

            let canvasSize = CGSize(width: width + 20, height: 400)

            let baseline = render(
                OrbitSettingsRow(title: testCase.title, description: baselineDescription) {
                    OrbitToggle(accessibilityLabel: "\(testCase.name) test control", isOn: .constant(true))
                }
                .frame(width: width, alignment: .leading)
                .environment(\.orbitScreenshotModeDragDisabled, true),
                size: canvasSize
            )
            let real = render(
                OrbitSettingsRow(title: testCase.title, description: testCase.description) {
                    OrbitToggle(accessibilityLabel: "\(testCase.name) test control", isOn: .constant(true))
                }
                .frame(width: width, alignment: .leading)
                .environment(\.orbitScreenshotModeDragDisabled, true),
                size: canvasSize
            )

            guard let baselineBox = baseline.boundingBoxOfContent(), let realBox = real.boundingBoxOfContent() else {
                baseline.writeDiagnosticPNG(named: "OrbitSettingsRowTests_\(testCase.name)_baseline_empty")
                real.writeDiagnosticPNG(named: "OrbitSettingsRowTests_\(testCase.name)_real_empty")
                XCTFail("\(testCase.name): OrbitSettingsRow drew nothing at width \(width)pt.")
                continue
            }

            XCTAssertLessThanOrEqual(
                realBox.maxX, width + 1,
                "\(testCase.name): OrbitSettingsRow must not draw past its own declared width (\(width)pt) — got content extending to \(realBox.maxX)pt."
            )

            let measuredDescriptionHeight = realBox.height - baselineBox.height
            let expectedFullWidthHeight = wrappedTextHeight(testCase.description, width: width, fontSize: fontSize)
                - wrappedTextHeight(baselineDescription, width: width, fontSize: fontSize)

            XCTAssertEqual(
                measuredDescriptionHeight, expectedFullWidthHeight, accuracy: 14,
                "\(testCase.name): the description's own rendered wrap height is \(measuredDescriptionHeight)pt; wrapping it correctly at this row's real width (\(width)pt) should cost about \(expectedFullWidthHeight)pt. A much SMALLER number means the description is truncated (finding 2's \"Moves the Space…\" defect); a much LARGER number means it is still being squeezed into a column narrower than \(width)pt beside the trailing control (finding 3's multi-line-ribbon defect)."
            )

            let squeezedColumnWidth: CGFloat = 150
            let squeezedHeight = wrappedTextHeight(testCase.description, width: squeezedColumnWidth, fontSize: fontSize)
                - wrappedTextHeight(baselineDescription, width: squeezedColumnWidth, fontSize: fontSize)
            XCTAssertLessThan(
                measuredDescriptionHeight, squeezedHeight - 14,
                "\(testCase.name): rendered description wrap height (\(measuredDescriptionHeight)pt) is not clearly shorter than what the old ~150pt squeezed column beside the trailing control would cost (\(squeezedHeight)pt) — this is finding 3's ribbon defect this test exists to catch."
            )
        }
    }

    private func wrappedTextHeight(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return bounds.height.rounded(.up)
    }
}
