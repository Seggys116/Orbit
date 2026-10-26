//  Orbit drops Manage Extensions… (and its separator): both engine backends exclude the .extensions capability, so there is no real action to drive.

import AppKit
import SwiftUI

struct ToolbarContextMenu {
    var tab: Tab
    var settings: ToolbarSettings
    var developerModeSettings: DeveloperModeSettings

    @MainActor
    func entries(in env: AppEnvironment) -> [OrbitContextMenuEntry] {
        let tab = tab
        let settings = settings
        var entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: "Copy URL") { ToolbarContextMenuAction.copyURL(tab.url) }),
            .item(OrbitContextMenuItem(title: "Share") { MenuSharePresenter.shared.present(items: [tab.url]) }),
            .item(OrbitContextMenuItem(title: "Capture...") { env.extensionPoints.presentCaptureTool?(tab.id, false) }),
            .item(OrbitContextMenuItem(title: "Capture Full Page") { env.extensionPoints.presentCaptureTool?(tab.id, true) }),
            .divider(),
            .item(OrbitContextMenuItem(title: fullURLRowTitle) { settings.toggleFullURL() }),
            .item(OrbitContextMenuItem(title: settings.visibilityMenuTitle) { settings.toggleVisible() })
        ]

        if developerModeSettings.isEnabled, let screenSize = screenSizeEntries(in: env) {
            entries.append(.divider())
            entries.append(screenSize)
        }
        return entries
    }

    @MainActor
    private func screenSizeEntries(in env: AppEnvironment) -> OrbitContextMenuEntry? {
        guard let contents = env.webContents[tab.id] as? WebKitWebContents else { return nil }
        let mode = InspectorDeviceMode.shared
        let current = mode.preset(for: contents)

        let presets: [OrbitContextMenuEntry] = InspectorDeviceMode.Preset.devices.map { preset in
            .item(OrbitContextMenuItem(title: preset.title, isChecked: current == preset) {
                guard current != preset else { return }
                mode.setPreset(preset, for: contents)
            })
        }
        let widths: [OrbitContextMenuEntry] = InspectorDeviceMode.widths.map { width in
            let isCurrent = current == .responsive && mode.responsiveWidth(for: contents) == width
            return .item(OrbitContextMenuItem(title: "\(Int(width))", isChecked: isCurrent) {
                guard !isCurrent else { return }
                mode.setResponsiveWidth(width, for: contents)
                mode.setPreset(.responsive, for: contents)
            })
        }

        return .item(OrbitContextMenuItem(
            title: "Screen Size",
            submenu: presets + [.divider(), .item(OrbitContextMenuItem(title: "Width", submenu: widths))]
        ))
    }

    // Developer Mode forces the full URL on, so the row must not claim "Hide Full URL" while that masks the preference.
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
