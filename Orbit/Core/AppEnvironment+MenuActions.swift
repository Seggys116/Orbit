import AppKit
import Foundation
import SwiftUI

extension AppEnvironment {

    // MARK: - Capture

    func captureActiveTabFullPage() -> Bool {
        guard let tabID = activeTabID, let present = extensionPoints.presentCaptureTool else { return false }
        present(tabID, true)
        return true
    }

    // MARK: - Site data

    // Reload must wait for the delete to complete (deleteCookies(for:) hops
    // to the IO thread) or it races and can resend the cookies just cleared.
    func clearCookiesForActiveTabAndRefresh() -> Bool {
        guard let tabID = activeTabID, let tab = tab(tabID) else { return false }
        guard let contents = webContents[tabID] else { return false }
        let session = contents.session
        let origin = tab.url
        Task { @MainActor in
            await session.deleteCookies(for: origin)
            contents.reload(ignoringCache: false)
        }
        return true
    }

    // ignoringCache as well: the renderer keeps its own copy.
    func clearCacheAndRefreshActiveTab() -> Bool {
        guard let tabID = activeTabID, let contents = webContents[tabID], let engine else { return false }
        let session = contents.session
        Task { @MainActor in
            await engine.clearBrowsingData(.cache, session: session, since: nil)
            contents.reload(ignoringCache: true)
        }
        return true
    }

    // MARK: - Pinned section

    @discardableResult
    func setPinnedSectionCollapsed(_ collapsed: Bool) -> Bool {
        guard let spaceID = activeSpace?.id else { return false }
        withAnimation(OrbitMotion.standard) {
            store.mutateSpace(spaceID) { $0.isPinnedSectionCollapsed = collapsed }
        }
        return true
    }

    // MARK: - Reveal

    // Does not scroll — Orbit's sidebar has no scroll-to machinery. Expanding
    // collapsed ancestors is the substantive half of "reveal", since that's
    // the only part that can make a row not exist on screen at all.
    func revealActiveTabInSidebar() -> Bool {
        guard let spaceID = activeSpace?.id, let tabID = store.activeTab(in: spaceID)?.id else { return false }

        withAnimation(OrbitMotion.standard) {
            if !isSidebarVisible { isSidebarVisible = true }

            let ancestors = AppEnvironment.ancestorFolderIDs(of: tabID, in: store.pinnedNodes(in: spaceID))
            guard let ancestors else { return }

            store.mutateSpace(spaceID) { space in
                space.isPinnedSectionCollapsed = false
            }
            for folderID in ancestors {
                store.setFolderExpanded(folderID, expanded: true, in: spaceID)
            }
        }
        return true
    }

    // nil means nodeID is not in this forest; an empty array means present
    // at the root, distinct from nil.
    private static func ancestorFolderIDs(of nodeID: UUID, in nodes: [SidebarNode]) -> [FolderID]? {
        for node in nodes {
            if node.id == nodeID { return [] }
            guard case .folder(let folder) = node else { continue }
            if let deeper = ancestorFolderIDs(of: nodeID, in: folder.children) {
                return [folder.id] + deeper
            }
        }
        return nil
    }

    // MARK: - Folders

    func createFolderInActiveSpace() -> Bool {
        guard let spaceID = activeSpace?.id else { return false }
        createFolder(name: "New Folder", in: spaceID)
        return true
    }

    // One mutateSpace over a recursively rewritten forest, not one
    // setFolderExpanded call per folder — the latter would push n state
    // generations through Observation for a single gesture.
    func setAllFoldersExpanded(_ expanded: Bool) -> Bool {
        guard let spaceID = activeSpace?.id else { return false }
        let roots = store.pinnedNodes(in: spaceID)
        guard roots.contains(where: { if case .folder = $0 { return true } else { return false } }) else { return false }
        store.mutateSpace(spaceID) { space in
            space.pinned = AppEnvironment.settingFoldersExpanded(expanded, in: space.pinned)
        }
        return true
    }

    private static func settingFoldersExpanded(_ expanded: Bool, in nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.map { node in
            guard case .folder(var folder) = node else { return node }
            folder.isExpanded = expanded
            folder.children = settingFoldersExpanded(expanded, in: folder.children)
            return .folder(folder)
        }
    }

    // MARK: - Tabs

    func duplicateActiveTab() -> Bool {
        guard let tabID = activeTabID, let copyID = store.duplicateTab(tabID) else { return false }
        activateTab(copyID)
        return true
    }

    // An empty answer clears the custom name rather than setting one, so the dialog can undo itself.
    func renameActiveItem() -> Bool {
        guard let tabID = activeTabID, let tab = tab(tabID), tab.section == .pinned else { return false }
        guard let answer = MenuPrompt.text(
            title: "Rename Tab",
            message: "Give this pinned tab a name of your own. Leave it empty to go back to the page's own title.",
            defaultValue: tab.customTitle ?? tab.displayTitle,
            acceptTitle: "Rename"
        ) else { return false }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.resetTabName(tabID)
        } else {
            renameTab(tabID, to: trimmed)
        }
        return true
    }

    func resetActiveTabToPinnedURL() -> Bool {
        guard let tabID = activeTabID, let tab = tab(tabID) else { return false }
        guard let origin = tab.pinnedURL, origin != tab.url else { return false }
        resetPinnedTab(tabID)
        return true
    }

    // Permanently removes an archived Tab — every other destructive command
    // in this app is recoverable, this one is not, hence the confirmation.
    func clearArchiveEverywhere() -> Bool {
        let archived = store.archivedTabs()
        guard !archived.isEmpty else { return false }
        let noun = archived.count == 1 ? "1 archived tab" : "\(archived.count) archived tabs"
        guard MenuPrompt.confirmDestructive(
            title: "Clear the archive?",
            message: "This permanently deletes \(noun). It cannot be undone, and Reopen Last Closed Tab will not bring them back.",
            acceptTitle: "Clear Archive"
        ) else { return false }
        store.clearArchive()
        return true
    }

    // MARK: - Spaces

    func presentNewSpaceFlow() -> Bool {
        NotificationCenter.default.post(name: .orbitPresentNewSpaceFlow, object: nil)
        return true
    }

    func renameActiveSpace() -> Bool {
        guard let space = activeSpace else { return false }
        guard let answer = MenuPrompt.text(
            title: "Rename Space",
            message: "What should this Space be called?",
            defaultValue: space.name,
            acceptTitle: "Rename"
        ) else { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        renameSpace(space.id, to: trimmed)
        return true
    }

    // self, not AppEnvironment.shared: an Incognito window's own
    // WindowSession root must edit its own document, not the shared one.
    func presentThemeEditorForActiveSpace() -> Bool {
        guard let spaceID = activeSpace?.id else { return false }
        return SpaceThemeEditorWindowController.show(spaceID: spaceID, env: self) != nil
    }

    // MARK: - Boosts

    func presentBoostsEditorForActiveTab(requiringExistingBoost: Bool) -> Bool {
        guard let host = activeTab?.url.host(), !host.isEmpty else { return false }
        if requiringExistingBoost {
            guard !boostStore.boosts(forHost: host).isEmpty else { return false }
            BoostsEditorWindowController.show(host: host)
        } else {
            NotificationCenter.default.post(name: .orbitPresentBoostsEditor, object: host)
        }
        return true
    }

    // MARK: - Share

    func shareActivePage() -> Bool {
        guard let url = activeTab?.url else { return false }
        switch OrbitScheme.parse(url) {
        case .newTab, .note, .easel: return false
        case .viewSource, .web: break
        }
        return MenuSharePresenter.shared.present(items: [url])
    }

    // MARK: - Default browser

    func requestBecomingDefaultBrowser() -> Bool {
        guard !DefaultBrowser.isDefault else { return false }
        DefaultBrowser.requestBecomingDefault()
        return true
    }

    // MARK: - Split view

    func separateActiveTabFromSplit() -> Bool {
        guard let tabID = activeTabID, let tab = tab(tabID), splitGroup(for: tabID) != nil else { return false }
        SplitLayoutOption.perform(.separateThisTab, forPaneOf: tab, in: self)
        return true
    }

    func expandActiveSplitPane() -> Bool {
        guard let tabID = activeTabID, let tab = tab(tabID), splitGroup(for: tabID) != nil else { return false }
        SplitLayoutOption.perform(.expandThisPane, forPaneOf: tab, in: self)
        return true
    }
}

// MARK: - Asking the user something a menu item cannot carry

// runModal() blocks the run loop until a button is pressed, and
// xcodebuild test presses nothing — isRunningUnderTests must gate every
// alert here or a hosted test run hangs until the whole suite times out.
enum MenuPrompt {

    private static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // nil under a test run, where nobody can cancel or type.
    @MainActor
    static func text(title: String, message: String, defaultValue: String, acceptTitle: String) -> String? {
        guard !isRunningUnderTests else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: acceptTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        // Without this the accessory field never becomes first responder — the alert's own buttons take it.
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // true under a test run: the confirmation is a safeguard for a person, not part of the operation.
    @MainActor
    static func confirmDestructive(title: String, message: String, acceptTitle: String) -> Bool {
        guard !isRunningUnderTests else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let accept = alert.addButton(withTitle: acceptTitle)
        accept.hasDestructiveAction = true
        accept.keyEquivalent = ""
        // NSAlert.addButton gives the first button "\r" automatically —
        // must clear it here or Return still fires the destructive button.
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Sharing from a menu item

// A purely local let picker = NSSharingServicePicker(...) has nothing
// holding it past the call that created it — must be retained here until
// sharingServicePicker(_:didChoose:) clears it.
@MainActor
final class MenuSharePresenter: NSObject, NSSharingServicePickerDelegate {

    static let shared = MenuSharePresenter()

    private var activePicker: NSSharingServicePicker?

    private override init() { super.init() }

    @discardableResult
    func present(items: [Any]) -> Bool {
        guard !items.isEmpty else { return false }
        guard let contentView = NSApp.keyWindow?.contentView else { return false }

        let bounds = contentView.bounds
        let anchor = NSRect(x: bounds.midX - 8, y: bounds.maxY - 16, width: 16, height: 16)

        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        activePicker = picker
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
        return true
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        activePicker = nil
    }
}
