//  Orbit drops Manage Extensions… (and its separator): both engine backends exclude the .extensions capability, so there is no real action to drive.

import AppKit
import SwiftUI

struct ToolbarContextMenu: View {
    @Environment(AppEnvironment.self) private var env

    var tab: Tab
    var settings: ToolbarSettings
    var developerModeSettings: DeveloperModeSettings

    var body: some View {
        Button("Copy URL") { ToolbarContextMenuAction.copyURL(tab.url) }

        ShareLink("Share", item: tab.url)

        Button("Capture...") { env.extensionPoints.presentCaptureTool?(tab.id, false) }
        Button("Capture Full Page") { env.extensionPoints.presentCaptureTool?(tab.id, true) }

        Divider()

        fullURLRow
        Button(settings.visibilityMenuTitle) { settings.toggleVisible() }
    }

    // Developer Mode forces the full URL on regardless of settings.showsFullURL, so the row must not claim "Hide Full URL" when pressing it would not actually hide anything; it still toggles the real preference (which takes over once Developer Mode is off), just states when it's currently masked.
    private var fullURLRow: some View {
        Button(fullURLRowTitle) { settings.toggleFullURL() }
    }

    var fullURLRowTitle: String {
        guard developerModeSettings.isEnabled, settings.showsFullURL else {
            return settings.fullURLMenuTitle
        }
        return "Hide Full URL (Forced On by Developer Mode)"
    }
}

enum ToolbarContextMenuAction {
    static func copyURL(_ url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}
