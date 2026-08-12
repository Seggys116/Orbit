import AppKit

@MainActor
enum MainMenuBuilder {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(orbitMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(spacesMenuItem())
        main.addItem(tabsMenuItem())
        main.addItem(archiveMenuItem())
        main.addItem(extensionsMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    // MARK: Orbit

    private static func orbitMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Orbit")
        menu.addItem(ClosureMenuItem(title: "About Orbit") { AboutWindowController.show() })
        menu.addItem(.separator())
        menu.addItem(command("Settings…", .openSettings))
        menu.addItem(command("Set as Default Browser", .setAsDefaultBrowser) { !DefaultBrowserStatus.isDefault })
        menu.addItem(.separator())
        menu.addItem(ImportSubmenuController.shared.menuItem())
        menu.addItem(.separator())
        menu.addItem(servicesMenuItem())
        menu.addItem(.separator())
        menu.addItem(command("Hide Orbit", .hideOrbit))
        menu.addItem(command("Hide Others", .hideOthers))
        menu.addItem(ClosureMenuItem(title: "Show All") { NSApp.unhideAllApplications(nil) })
        menu.addItem(.separator())
        menu.addItem(command("Quit Orbit", .quit))
        item.submenu = menu
        return item
    }

    private static func servicesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }

    // MARK: File

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(command("New Tab", .newTabCommandBar))
        menu.addItem(command("New Window", .newWindow))
        menu.addItem(command("New Incognito Window", .newIncognitoWindow))
        menu.addItem(command("New Little Orbit", .newLittleOrbit))
        menu.addItem(command("Open Tab in Little Orbit", .openTabInLittleOrbit) { hasActiveTab })
        menu.addItem(command("Reopen Last Closed Tab", .reopenLastClosedTab))
        menu.addItem(.separator())
        menu.addItem(command("Open Command Bar", .addressBarCommandBar))
        menu.addItem(.separator())
        menu.addItem(command("New Boost", .newBoost) { activeHost != nil })
        menu.addItem(command("Edit Boost", .editBoost) { hostHasBoosts })
        menu.addItem(command("New Note", .newNote))
        menu.addItem(command("New Note (in Split)", .newNoteInSplitView))
        menu.addItem(command("New Easel", .newEasel))
        menu.addItem(.separator())
        menu.addItem(command("Close Tab / Window", .closeTabOrWindow))
        menu.addItem(.separator())
        menu.addItem(command("Share…", .shareCurrentPage) { canShareActivePage })
        menu.addItem(command("Capture…", .screenCaptureRegion) { hasActiveTab })
        menu.addItem(command("Capture Full Page", .captureFullPage) { hasActiveTab })
        menu.addItem(command("Save Page As…", .savePageAs))
        menu.addItem(command("Print…", .printPage))
        item.submenu = menu
        return item
    }

    // MARK: Edit

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(command("Copy URL", .copyURL))
        menu.addItem(command("Copy URL as Markdown", .copyURLAsMarkdown))
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(command("Paste and Match Style", .pasteAndMatchStyle))
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(findMenuItem())
        menu.addItem(StandardEditSubmenus.spellingAndGrammarMenuItem())
        menu.addItem(StandardEditSubmenus.substitutionsMenuItem())
        menu.addItem(StandardEditSubmenus.transformationsMenuItem())
        menu.addItem(StandardEditSubmenus.speechMenuItem())
        menu.addItem(StandardEditSubmenus.formatMenuItem())
        item.submenu = menu
        return item
    }

    // Uses a ShortcutRefreshingMenu because Find and Replace's target is nil
    // on purpose (so a focused Note editor handles it), which means it
    // cannot re-read its own binding through validateMenuItem(_:) like every other row here.
    private static func findMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let menu = ShortcutRefreshingMenu(title: "Find")
        menu.addItem(command("Find or Ask", .findOnPage))
        menu.addItem(TextFinderMenuItem(
            title: "Find and Replace",
            action: #selector(NSResponder.performTextFinderAction(_:)),
            tag: .showReplaceInterface,
            command: .findAndReplace
        ))
        menu.addItem(command("Find Next", .findNext))
        menu.addItem(command("Find Previous", .findPrevious))
        menu.addItem(command("Jump to Selection", .jumpToSelection))
        item.submenu = menu
        return item
    }

    // MARK: View

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(appearanceMenuItem())
        menu.addItem(.separator())
        menu.addItem(command("Show/Hide Sidebar", .toggleSidebar))
        menu.addItem(ToolbarVisibilityMenuItem())
        menu.addItem(command("Expand Pinned Section", .expandPinnedSection) { hasActiveSpace })
        menu.addItem(command("Collapse Pinned Section", .collapsePinnedSection) { hasActiveSpace })
        menu.addItem(.separator())
        menu.addItem(command("Stop", .stopLoading))
        menu.addItem(command("Reload", .refresh))
        menu.addItem(command("Hard Refresh", .hardRefresh))
        menu.addItem(command("Clear Cookies and Refresh", .clearCookiesAndRefresh) { hasLiveWebContents })
        menu.addItem(command("Clear Cache (Entire Session) and Refresh", .clearCacheAndRefresh) { hasLiveWebContents && hasEngine })
        menu.addItem(.separator())
        menu.addItem(command("Add Split", .addSplit))
        menu.addItem(command("Close Split", .closeSplit))
        menu.addItem(command("Separate Page from Split View", .separateFromSplitView) { activeTabIsInASplit })
        menu.addItem(command("Expand Current Split", .expandCurrentSplit) { activeTabIsInASplit })
        menu.addItem(.separator())
        menu.addItem(command("Actual Size", .resetZoom))
        menu.addItem(command("Zoom In", .zoomIn))
        menu.addItem(command("Zoom Out", .zoomOut))
        menu.addItem(.separator())
        menu.addItem(developerMenuItem())
        menu.addItem(.separator())
        menu.addItem(command("Toggle Full Screen", .toggleFullScreen))
        item.submenu = menu
        return item
    }

    private static func appearanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Appearance")
        menu.addItem(NSMenuItem(title: AppearanceSettings.captionTitle, action: nil, keyEquivalent: ""))
        for appearance in AppearanceSettings.Appearance.allCases {
            menu.addItem(AppearanceMenuItem(appearance))
        }
        item.submenu = menu
        return item
    }

    private static func developerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Developer")
        menu.addItem(command("View Source", .viewSource))
        menu.addItem(command("Inspect Element", .inspectElement))
        menu.addItem(command("JavaScript Console", .javaScriptConsole))
        menu.addItem(command("Toggle Developer Mode", .toggleDeveloperMode))
        item.submenu = menu
        return item
    }

    // MARK: Spaces

    private static func spacesMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Spaces")
        menu.addItem(command("New Space…", .newSpace))
        menu.addItem(command("Edit Theme…", .editSpaceTheme) { hasActiveSpace })
        menu.addItem(command("Rename Space", .renameSpace) { hasActiveSpace })
        menu.addItem(ClosureMenuItem(title: "Change Profile") {
            SettingsWindowController.show(pane: .profiles)
        })
        menu.addItem(.separator())
        menu.addItem(command("Next Space", .nextSpace))
        menu.addItem(command("Previous Space", .previousSpace))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Manage Spaces…") {
            LibraryWindowController.show(section: .spaces)
        })
        item.submenu = menu
        return item
    }

    // MARK: Tabs

    private static func tabsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Tabs")
        menu.addItem(command("New Tab", .newTabCommandBar))
        menu.addItem(command("Ask ChatGPT", .askChatGPTCommandBar))
        menu.addItem(JoinMeetingMenuItem { url in
            let env = AppEnvironment.processRoot
            guard let spaceID = env.activeSpace?.id else { return }
            _ = env.openTab(url: url, in: spaceID)
        })
        menu.addItem(command("Pin / Unpin Current Tab", .pinUnpinTab))
        menu.addItem(command("New Folder…", .newFolder) { hasActiveSpace })
        menu.addItem(command("Duplicate", .duplicateTab) { hasActiveTab })
        menu.addItem(command("Rename Current Item", .renameCurrentItem) { activeTabIsPinned })
        menu.addItem(command("Collapse All Folders", .collapseAllFolders) { activeSpaceHasFolders })
        menu.addItem(command("Expand All Folders", .expandAllFolders) { activeSpaceHasFolders })
        menu.addItem(.separator())
        menu.addItem(command("Next Tab", .nextTab))
        menu.addItem(command("Previous Tab", .previousTab))
        menu.addItem(command("Cycle Recent Tabs", .cycleRecentTabs))
        menu.addItem(command("Reveal Tab in Sidebar", .revealTabInSidebar) { hasRenderedActiveTab })
        menu.addItem(.separator())
        menu.addItem(command("Clear All Today Tabs", .clearTodayTabs))
        menu.addItem(command("Reset Tab to Original URL", .resetTabToOriginalURL) { activeTabHasSomethingToResetTo })
        item.submenu = menu
        return item
    }

    // MARK: Archive

    private static func archiveMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Archive")
        menu.addItem(command("Go Back", .goBack))
        menu.addItem(command("Go Forward", .goForward))
        menu.addItem(.separator())
        menu.addItem(command("View History", .history))
        menu.addItem(command("Show Archived Tabs", .archivedTabs))
        menu.addItem(command("Clear Archive", .clearArchive) { hasArchivedTabs })
        menu.addItem(.separator())
        menu.addItem(ImportSubmenuController.shared.menuItem())
        item.submenu = menu
        return item
    }

    // MARK: Extensions

    private static func extensionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Extensions")
        menu.addItem(ClosureMenuItem(title: "Add Extension…") {
            SettingsWindowController.show(pane: .extensions, focusing: .extensionInstallField)
        })
        menu.addItem(ClosureMenuItem(title: "Manage Extensions…") {
            SettingsWindowController.show(pane: .extensions)
        })
        item.submenu = menu
        return item
    }

    // MARK: Window

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(command("Minimize", .minimize))
        menu.addItem(ClosureMenuItem(title: "Zoom") { NSApp.keyWindow?.zoom(nil) })
        menu.addItem(.separator())
        menu.addItem(command("View Library", .library))
        menu.addItem(command("View Downloads", .downloads))
        menu.addItem(command("View Easels & Notes", .easelsAndNotesLibrary))
        menu.addItem(command("View Media", .mediaLibrary))
        menu.addItem(command("View Boosts", .boostsLibrary))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Bring All to Front") { NSApp.arrangeInFront(nil) })
        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    // MARK: Help

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(ClosureMenuItem(title: "Keybinds") { SettingsWindowController.show(pane: .shortcuts) })
        menu.addItem(ClosureMenuItem(title: "About Orbit") { AboutWindowController.show() })
        menu.addItem(ClosureMenuItem(title: "Restore Data") { RestoreDataWindowController.show() })
        menu.addItem(.separator())
        menu.addItem(troubleshootingMenuItem())
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }

    private static func troubleshootingMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = "Troubleshooting"
        let menu = NSMenu(title: "Troubleshooting")
        menu.addItem(ClosureMenuItem(title: "Open Task Manager") { TaskManagerWindowController.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Reveal Orbit Data") {
            TroubleshootingMenuActions.revealOrbitData(env: AppEnvironment.frontmost)
        })
        menu.addItem(ClosureMenuItem(title: "Copy Orbit Info") {
            TroubleshootingMenuActions.copyOrbitInfo(env: AppEnvironment.frontmost)
        })
        item.submenu = menu
        return item
    }

    // MARK: Helper

    private static func command(
        _ title: String,
        _ id: ShortcutCommandID,
        isAvailable: @escaping () -> Bool = { true }
    ) -> NSMenuItem {
        CommandMenuItem(title: title, command: id, isAvailable: isAvailable)
    }

    // MARK: Availability

    // Every predicate below reads AppEnvironment.frontmost, the same
    // environment CommandMenuItem dispatches into — asking .shared here
    // would grey a row out based on a document the user isn't looking at.

    private static var env: AppEnvironment { .frontmost }

    private static var hasActiveTab: Bool { env.activeTabID != nil }

    private static var hasActiveSpace: Bool { env.activeSpace != nil }

    private static var hasEngine: Bool { env.engine != nil }

    private static var hasLiveWebContents: Bool {
        guard let tabID = env.activeTabID else { return false }
        return env.webContents[tabID] != nil
    }

    private static var hasRenderedActiveTab: Bool {
        guard let spaceID = env.activeSpace?.id else { return false }
        return env.store.activeTab(in: spaceID) != nil
    }

    private static var activeTabIsPinned: Bool {
        env.activeTabID.flatMap { env.tab($0) }?.section == .pinned
    }

    private static var activeTabIsInASplit: Bool {
        guard let tabID = env.activeTabID else { return false }
        return env.splitGroup(for: tabID) != nil
    }

    private static var activeTabHasSomethingToResetTo: Bool {
        guard let tabID = env.activeTabID, let tab = env.tab(tabID) else { return false }
        guard let origin = tab.pinnedURL else { return false }
        return origin != tab.url
    }

    private static var activeSpaceHasFolders: Bool {
        guard let spaceID = env.activeSpace?.id else { return false }
        return env.pinnedNodes(in: spaceID).contains { node in
            if case .folder = node { return true }
            return false
        }
    }

    private static var hasArchivedTabs: Bool { !env.archivedTabs().isEmpty }

    private static var activeHost: String? {
        guard let host = env.activeTab?.url.host(), !host.isEmpty else { return nil }
        return host
    }

    private static var hostHasBoosts: Bool {
        guard let host = activeHost else { return false }
        return !env.boostStore.boosts(forHost: host).isEmpty
    }

    private static var canShareActivePage: Bool {
        guard let url = env.activeTab?.url else { return false }
        switch OrbitScheme.parse(url) {
        case .newTab, .note, .easel: return false
        case .viewSource, .web: return true
        }
    }
}
