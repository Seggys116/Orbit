import AppKit
import SwiftUI

enum OrbitInternalPageChrome {

    static let addressText = "untitled"

    static var surfaceNSColor: NSColor { .textBackgroundColor }

    static func surfaceColor(for colorScheme: ColorScheme) -> ThemeColor {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
        var resolved = ThemeColor(red: 1, green: 1, blue: 1)
        appearance.performAsCurrentDrawingAppearance {
            resolved = ThemeColor(surfaceNSColor)
        }
        return resolved
    }

    // Route through here, not AppearanceSettings.shared directly — every
    // participating surface must resolve the same appearance or they can disagree.
    static func documentColorScheme(system: ColorScheme) -> ColorScheme {
        AppearanceSettings.shared.documentColorScheme(system: system)
    }

    // Re-derived here rather than via OrbitScheme.parse (a view file); must
    // stay in sync with OrbitScheme's own two document cases.
    static func isDocumentPage(_ url: URL) -> Bool {
        guard url.scheme == "orbit" else { return false }
        switch url.host() {
        case "note", "easel": return UUID(uuidString: url.lastPathComponent) != nil
        default: return false
        }
    }
}
