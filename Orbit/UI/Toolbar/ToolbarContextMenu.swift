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
            .divider()
        ]
        let profileEntries = siteProfileEntries(in: env)
        if !profileEntries.isEmpty {
            entries += profileEntries
            entries.append(.divider())
        }
        entries.append(.item(OrbitContextMenuItem(title: fullURLRowTitle) { settings.toggleFullURL() }))
        entries.append(.item(OrbitContextMenuItem(title: settings.visibilityMenuTitle) { settings.toggleVisible() }))

        if developerModeSettings.isEnabled, let screenSize = screenSizeEntries(in: env) {
            entries.append(.divider())
            entries.append(screenSize)
        }
        return entries
    }

    static let makeProfiledPageTitle = "Make Profiled Page..."

    static func newProfileTitle(forSite siteKey: String) -> String { "New Profile for \(siteKey)..." }

    static let switchProfileTitle = "Switch Profile"

    // Empty when the tab cannot have Site Profiles, which is every non-http(s) page and everything in an Incognito Space.
    @MainActor
    func siteProfileEntries(in env: AppEnvironment) -> [OrbitContextMenuEntry] {
        let tabID = tab.id
        guard env.store.canOfferSiteProfiles(forTab: tabID) else { return [] }
        guard let siteKey = env.store.siteProfileDropdownSiteKey(forTab: tabID) else {
            return [.item(OrbitContextMenuItem(title: Self.makeProfiledPageTitle) { env.promptToCreateSiteProfile(forTab: tabID) })]
        }
        return [
            .item(OrbitContextMenuItem(title: Self.newProfileTitle(forSite: siteKey)) { env.promptToCreateSiteProfile(forTab: tabID) }),
            .item(OrbitContextMenuItem(title: Self.switchProfileTitle, submenu: Self.siteProfileSwitchEntries(forTab: tabID, siteKey: siteKey, in: env))),
        ]
    }

    @MainActor
    static func siteProfileSwitchEntries(forTab tabID: TabID, siteKey: String, in env: AppEnvironment) -> [OrbitContextMenuEntry] {
        let boundID = env.store.boundSiteProfile(forTab: tabID)?.id
        var entries: [OrbitContextMenuEntry] = [
            .item(OrbitContextMenuItem(title: SiteProfile.defaultName, isChecked: boundID == nil) {
                env.switchSiteProfile(tabID: tabID, to: nil)
            })
        ]
        for profile in env.store.siteProfiles(forSiteKey: siteKey) {
            let profileID = profile.id
            entries.append(.item(OrbitContextMenuItem(title: profile.name, isChecked: boundID == profileID) {
                env.switchSiteProfile(tabID: tabID, to: profileID)
            }))
        }
        return entries
    }

    @MainActor
    static func siteProfileDropdownEntries(forTab tabID: TabID, in env: AppEnvironment) -> [OrbitContextMenuEntry] {
        guard let siteKey = env.store.siteProfileDropdownSiteKey(forTab: tabID) else { return [] }
        var entries = siteProfileSwitchEntries(forTab: tabID, siteKey: siteKey, in: env)
        entries.append(.divider())
        if env.store.canOfferSiteProfiles(forTab: tabID) {
            entries.append(.item(OrbitContextMenuItem(title: "New Profile...") { env.promptToCreateSiteProfile(forTab: tabID) }))
        }
        if let bound = env.store.boundSiteProfile(forTab: tabID) {
            let boundID = bound.id
            entries.append(.item(OrbitContextMenuItem(title: "Rename Profile...") { env.promptToRenameSiteProfile(boundID) }))
            entries.append(.item(OrbitContextMenuItem(title: "Delete Profile", isDestructive: true) { env.confirmDeleteSiteProfile(boundID) }))
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
                OrbitDevToolsStore.shared.session(for: contents)?.device.deactivate()
                mode.setPreset(preset, for: contents)
            })
        }
        let widths: [OrbitContextMenuEntry] = InspectorDeviceMode.widths.map { width in
            let isCurrent = current == .responsive && mode.responsiveWidth(for: contents) == width
            return .item(OrbitContextMenuItem(title: "\(Int(width))", isChecked: isCurrent) {
                guard !isCurrent else { return }
                OrbitDevToolsStore.shared.session(for: contents)?.device.deactivate()
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
