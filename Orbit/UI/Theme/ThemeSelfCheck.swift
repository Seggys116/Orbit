#if DEBUG

import AppKit
import OSLog
import SwiftUI

enum ThemeSelfCheck {
    // Read back with: log show --predicate 'subsystem == "com.orbit.browser"' --last 5m
    private static let logger = Logger(subsystem: "com.orbit.browser", category: "theme")
    private static var didRun = false

    private static let sidebarTarget = (red: 0x2A...0x2E, green: 0x25...0x28, blue: 0x32...0x36)
    private static let surroundTarget = (red: 0x33...0x38, green: 0x2C...0x31, blue: 0x3A...0x3F)

    private static let toleranceUnits: Double = 8

    @MainActor
    static func runOnce() {
        guard !didRun else { return }
        didRun = true

        let theme = SpaceTheme()
        logger.log(
            "Self-check: SpaceTheme() default — style=\(String(describing: theme.style), privacy: .public) angle=\(theme.angle, privacy: .public) stops=\(theme.colors.count, privacy: .public)"
        )

        for scheme: ColorScheme in [.dark, .light] {
            let adapted = theme.adaptedColors(for: scheme)
            guard let sidebar = adapted.first, let surround = adapted.last else {
                logger.error("Self-check FAILED: adaptedColors(for:) returned no stops for \(String(describing: scheme), privacy: .public)")
                continue
            }
            let sidebarComponents = sidebar.srgbComponents
            let surroundComponents = surround.srgbComponents
            logger.log("[\(String(describing: scheme), privacy: .public)] sidebar background  = \(describe(sidebarComponents), privacy: .public)")
            logger.log("[\(String(describing: scheme), privacy: .public)] content surround    = \(describe(surroundComponents), privacy: .public)")

            guard scheme == .dark else { continue }

            checkComponent(sidebarComponents.red, target: sidebarTarget.red, label: "sidebar R (dark)")
            checkComponent(sidebarComponents.green, target: sidebarTarget.green, label: "sidebar G (dark)")
            checkComponent(sidebarComponents.blue, target: sidebarTarget.blue, label: "sidebar B (dark)")
            checkComponent(surroundComponents.red, target: surroundTarget.red, label: "surround R (dark)")
            checkComponent(surroundComponents.green, target: surroundTarget.green, label: "surround G (dark)")
            checkComponent(surroundComponents.blue, target: surroundTarget.blue, label: "surround B (dark)")

            let sidebarSum = sidebarComponents.red + sidebarComponents.green + sidebarComponents.blue
            let surroundSum = surroundComponents.red + surroundComponents.green + surroundComponents.blue
            if surroundSum <= sidebarSum {
                logger.fault("Self-check FAILED: content-surround tone (\(surroundSum, privacy: .public)) should read lighter than the sidebar tone (\(sidebarSum, privacy: .public))")
            }
        }

        let fg = theme.readableForeground.srgbComponents
        let fgSecondary = theme.readableSecondaryForeground.srgbComponents
        logger.log("readableForeground          = \(describe(fg), privacy: .public)")
        logger.log("readableSecondaryForeground = \(describe(fgSecondary), privacy: .public)")

        checkClose(fg.red, target: 1.0, tolerance: 0.02, label: "readableForeground stays neutral white")
        checkClose(fg.alpha, target: 0.90, tolerance: 0.05, label: "readableForeground alpha")
        checkClose(fgSecondary.alpha, target: 0.55, tolerance: 0.05, label: "readableSecondaryForeground alpha")

        checkPresets()

        logger.log("Self-check complete.")
    }

    private static let presetPrimaryContrastTarget: Double = 7.0
    private static let presetSecondaryContrastTarget: Double = 3.0

    @MainActor
    private static func checkPresets() {
        for (index, preset) in SpaceThemePalette.presets.enumerated() {
            guard preset.isDarkSurface else {
                logger.fault("Self-check FAILED: SpaceThemePalette.presets[\(index, privacy: .public)] does not read as a dark surface, which readableForeground's fixed white-at-90%-alpha treatment assumes.")
                continue
            }

            let fg = ThemeColor(NSColor(preset.readableForeground))
            let fgSecondary = ThemeColor(NSColor(preset.readableSecondaryForeground))

            for scheme: ColorScheme in [.dark, .light] {
                for stop in preset.adaptedColors(for: scheme) {
                    let background = ThemeColor(NSColor(stop))
                    let primaryContrast = fg.composited(over: background).contrastRatio(against: background)
                    let secondaryContrast = fgSecondary.composited(over: background).contrastRatio(against: background)

                    let backgroundComponents = (red: background.red, green: background.green, blue: background.blue, alpha: background.alpha)

                    if primaryContrast < presetPrimaryContrastTarget {
                        logger.fault("Self-check FAILED: presets[\(index, privacy: .public)] primary contrast \(primaryContrast, privacy: .public) below \(presetPrimaryContrastTarget, privacy: .public) in \(String(describing: scheme), privacy: .public) over \(describe(backgroundComponents), privacy: .public)")
                    }

                    if secondaryContrast < presetSecondaryContrastTarget {
                        logger.fault("Self-check FAILED: presets[\(index, privacy: .public)] secondary contrast \(secondaryContrast, privacy: .public) below \(presetSecondaryContrastTarget, privacy: .public) in \(String(describing: scheme), privacy: .public) over \(describe(backgroundComponents), privacy: .public)")
                    }
                }
            }
        }
        logger.log("Self-check: checked \(SpaceThemePalette.presets.count, privacy: .public) SpaceThemePalette presets for dark-surface + contrast compliance.")
    }

    private static func describe(_ c: (red: Double, green: Double, blue: Double, alpha: Double)) -> String {
        let r = Int((c.red * 255).rounded())
        let g = Int((c.green * 255).rounded())
        let b = Int((c.blue * 255).rounded())
        return String(format: "#%02X%02X%02X (r=%.4f g=%.4f b=%.4f alpha=%.2f)", r, g, b, c.red, c.green, c.blue, c.alpha)
    }

    private static func checkComponent(_ value: Double, target: ClosedRange<Int>, label: String) {
        let lower = (Double(target.lowerBound) - toleranceUnits) / 255.0
        let upper = (Double(target.upperBound) + toleranceUnits) / 255.0
        let unit255 = Int((value * 255).rounded())
        let passed = value >= lower && value <= upper
        if !passed {
            logger.fault(
                "Self-check FAILED: \(label, privacy: .public) = \(unit255, privacy: .public), expected \(target.lowerBound, privacy: .public)...\(target.upperBound, privacy: .public) +/- \(Int(toleranceUnits), privacy: .public)"
            )
        }
    }

    private static func checkClose(_ value: Double, target: Double, tolerance: Double, label: String) {
        let passed = abs(value - target) <= tolerance
        if !passed {
            logger.fault("Self-check FAILED: \(label, privacy: .public) = \(value, privacy: .public), expected ~\(target, privacy: .public) +/- \(tolerance, privacy: .public)")
        }
    }
}

#endif
