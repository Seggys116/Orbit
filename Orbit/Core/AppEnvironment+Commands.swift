import AppKit
import Foundation
import SwiftUI

extension AppEnvironment {

    func presentCommandBar(mode: CommandBarMode) {
        commandBarMode = mode
        commandBarPresentationSerial &+= 1
        isCommandBarPresented = true
    }

    // Returning false means "nobody acted on this" — the signal
    // GlobalKeyEventMonitor uses to pass the key event on rather than consume it.
    @discardableResult
    func perform(_ command: ShortcutCommandID) -> Bool {
        // A presented Peek is modal over the page beneath it and gets first
        // refusal — without this, Cmd+W over an open Peek would close the tab
        // the user is reading behind it instead of dismissing the Peek.
        if let handled = performWhilePeekPresented(command) { return handled }

        switch command {
        case .newTabCommandBar:
            presentCommandBar(mode: .newTab)
        case .addressBarCommandBar:
            // A Little Orbit window's address field fires this exact command
            // too, but every case below targets the shared activeTabID,
            // which a Little Orbit tab is never — must route there first.
            if let controller = LittleOrbitWindowController.frontmostController {
                controller.presentAddressCommandBar()
                return true
            }
            presentCommandBar(mode: activeTabID.flatMap(blankPaneMode(for:)) ?? .editURL(activeTab?.url))
        case .newWindow:
            OrbitWindowController.openNewWindow()
        case .newIncognitoWindow:
            openIncognitoWindow()
        case .closeTabOrWindow:
            if let activeTabID {
                closeTab(activeTabID)
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
        case .reopenLastClosedTab:
            reopenLastClosedTab()
        case .hideOrbit:
            NSApp.hide(nil)
        case .hideOthers:
            NSApp.hideOtherApplications(nil)
        case .minimize:
            NSApp.keyWindow?.miniaturize(nil)
        case .quit:
            NSApp.terminate(nil)
        case .toggleSidebar:
            // A Little Orbit window has no sidebar of its own; this is a
            // global shortcut, so without this guard it would silently
            // toggle the main window's sidebar while a Little Orbit window is frontmost.
            guard LittleOrbitWindowController.frontmostController == nil else { return true }
            withAnimation(OrbitMotion.standard) { isSidebarVisible.toggle() }
        case .toggleFullScreen:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case .openSettings:
            SettingsWindowController.show()
        case .askChatGPTCommandBar:
            guard let space = activeSpace else { return false }
            guard ChatGPTCommandBar.isAvailable(featureEnabled: AssistSettings.isChatGPTCommandBarEnabled, isIncognito: isIncognito(space)) else { return false }
            presentCommandBar(mode: .chatGPT)
        case .setAsDefaultBrowser:
            return requestBecomingDefaultBrowser()

        case .pinUnpinTab:
            // Must use activeSpace's active tab, not activeTabID, and must check keyWindowIsUnrelatedSurface, or this can pin the wrong tab from an unrelated window like Settings or Library.
            guard !OrbitWindowController.keyWindowIsUnrelatedSurface else { return false }
            guard let spaceID = activeSpace?.id, let tabID = store.activeTab(in: spaceID)?.id else { return false }
            togglePin(tabID)
        case .clearTodayTabs:
            if let spaceID = activeSpace?.id { clearTodayTabs(in: spaceID) }
        case .previousTab:
            stepThroughOpenTabs(offset: -1)
        case .nextTab:
            stepThroughOpenTabs(offset: 1)
        case .jumpToSidebarItem1: jumpToSidebarItem(0)
        case .jumpToSidebarItem2: jumpToSidebarItem(1)
        case .jumpToSidebarItem3: jumpToSidebarItem(2)
        case .jumpToSidebarItem4: jumpToSidebarItem(3)
        case .jumpToSidebarItem5: jumpToSidebarItem(4)
        case .jumpToSidebarItem6: jumpToSidebarItem(5)
        case .jumpToSidebarItem7: jumpToSidebarItem(6)
        case .jumpToSidebarItem8: jumpToSidebarItem(7)
        case .jumpToSidebarItem9: jumpToSidebarItem(8)
        case .cycleRecentTabs:
            cycleRecentTabs()
        case .pasteAsNewTab:
            pasteClipboardAsNewTab()
        case .duplicateTab:
            return duplicateActiveTab()
        case .renameCurrentItem:
            return renameActiveItem()
        case .newFolder:
            return createFolderInActiveSpace()
        case .collapseAllFolders:
            return setAllFoldersExpanded(false)
        case .expandAllFolders:
            return setAllFoldersExpanded(true)
        case .revealTabInSidebar:
            return revealActiveTabInSidebar()
        case .expandPinnedSection:
            return setPinnedSectionCollapsed(false)
        case .collapsePinnedSection:
            return setPinnedSectionCollapsed(true)
        case .resetTabToOriginalURL:
            return resetActiveTabToPinnedURL()

        case .goBack: activeWebContents?.goBack()
        case .goForward: activeWebContents?.goForward()
        case .refresh: activeWebContents?.reload(ignoringCache: false)
        case .hardRefresh: activeWebContents?.reload(ignoringCache: true)
        case .stopLoading: activeWebContents?.stopLoading()
        case .zoomIn: stepZoom(up: true)
        case .zoomOut: stepZoom(up: false)
        case .resetZoom: activeWebContents?.setZoomFactor(1.0)

        case .findOnPage:
            withAnimation(OrbitMotion.standard) { isFindBarPresented = true }
        case .findNext:
            activeWebContents?.find(findQuery, options: FindOptions(forward: true, findNext: true))
        case .findPrevious:
            activeWebContents?.find(findQuery, options: FindOptions(forward: false, findNext: true))
        case .findAndReplace:
            // No engine hook for in-page replace — must stay unhandled so the
            // key event reaches a focused text view's own Find/Replace instead.
            return false
        case .jumpToSelection:
            Task { try? await activeWebContents?.evaluateJavaScript(
                "document.getSelection()?.anchorNode?.parentElement?.scrollIntoView({behavior:'smooth', block:'center'});"
            ) }
        case .printPage: activeWebContents?.print()
        case .savePageAs: activeWebContents?.savePage()
        case .pasteAndMatchStyle:
            Task { try? await activeWebContents?.evaluateJavaScript("document.execCommand('pasteAndMatchStyle');") }
        case .copyURL: copyActiveURLStrippingTrackers()
        case .copyURLAsMarkdown: copyActiveURLAsMarkdown()
        case .screenCaptureRegion:
            if let activeTabID { extensionPoints.presentCaptureTool?(activeTabID, false) }
        case .viewSource: openViewSource()
        case .inspectElement: activeWebContents?.showDeveloperTools(inspectAt: nil)
        case .javaScriptConsole: activeWebContents?.showDeveloperTools(inspectAt: nil)
        case .toggleDeveloperMode: DeveloperModeSettings.toggle()
        case .openDeveloperTools: activeWebContents?.showDeveloperTools(inspectAt: nil)
        case .captureFullPage:
            return captureActiveTabFullPage()
        case .clearCookiesAndRefresh:
            return clearCookiesForActiveTabAndRefresh()
        case .clearCacheAndRefresh:
            return clearCacheAndRefreshActiveTab()
        case .shareCurrentPage:
            return shareActivePage()
        case .newBoost:
            return presentBoostsEditorForActiveTab(requiringExistingBoost: false)
        case .editBoost:
            return presentBoostsEditorForActiveTab(requiringExistingBoost: true)

        case .nextSpace: withAnimation(OrbitMotion.dramatic) { nextSpace() }
        case .previousSpace: withAnimation(OrbitMotion.dramatic) { previousSpace() }
        case .jumpToSpace1: jumpToSpaceAnimated(0)
        case .jumpToSpace2: jumpToSpaceAnimated(1)
        case .jumpToSpace3: jumpToSpaceAnimated(2)
        case .jumpToSpace4: jumpToSpaceAnimated(3)
        case .jumpToSpace5: jumpToSpaceAnimated(4)
        case .jumpToSpace6: jumpToSpaceAnimated(5)
        case .jumpToSpace7: jumpToSpaceAnimated(6)
        case .jumpToSpace8: jumpToSpaceAnimated(7)
        case .jumpToSpace9: jumpToSpaceAnimated(8)
        case .newSpace:
            return presentNewSpaceFlow()
        case .renameSpace:
            return renameActiveSpace()
        case .editSpaceTheme:
            return presentThemeEditorForActiveSpace()

        case .newLittleOrbit:
            LittleOrbitWindowController.open(url: nil)
        case .openTabInLittleOrbit:
            guard let tab = activeTab else { return false }
            LittleOrbitWindowController.open(url: tab.url)
        case .openIntoMainWindow:
            guard let source = frontmostDetachedTabSource else { return false }
            promote(source, into: nil)
            return true
        case .openInSpacePicker:
            guard let menu = spacePickerMenuForFrontmostDetachedTab() else { return false }
            presentSpacePicker(menu)
            return true

        case .newNote: createAndOpenNote()
        case .newNoteInSplitView: createAndOpenNote(inSplit: true)
        case .newEasel: createAndOpenEasel()

        case .library, .downloads, .archivedTabs, .mediaLibrary, .easelsAndNotesLibrary, .boostsLibrary:
            if let section = AppEnvironment.librarySection(for: command) {
                LibraryWindowController.show(section: section)
            } else {
                LibraryWindowController.toggleVisible()
            }
        case .clearArchive:
            return clearArchiveEverywhere()
        case .history: HistoryWindowController.show()
        case .siteControls:
            // Must route to this window's own detached tab when a Little
            // Orbit window is frontmost — its tab is never any Space's
            // activeTabID, so falling through would open the main window's popover instead.
            if let littleOrbitTabID = LittleOrbitWindowController.frontmostController?.tabID {
                siteControlPresentedTabID = littleOrbitTabID
            } else if let activeTabID {
                siteControlPresentedTabID = activeTabID
            } else {
                return false
            }
        case .readerMode:
            if let activeTabID { Task { await enterReaderMode(activeTabID) } }

        case .addSplit: addSplitToActiveTab()
        case .closeSplit:
            if let activeTabID { closeSplitPane(activeTabID) }
        case .splitPane1: focusSplitPane(index: 0)
        case .splitPane2: focusSplitPane(index: 1)
        case .splitPane3: focusSplitPane(index: 2)
        case .splitPane4: focusSplitPane(index: 3)
        case .focusPreviousPane: focusAdjacentSplitPane(offset: -1)
        case .focusNextPane: focusAdjacentSplitPane(offset: 1)
        case .separateFromSplitView:
            return separateActiveTabFromSplit()
        case .expandCurrentSplit:
            return expandActiveSplitPane()
        }
        return true
    }

    var activeWebContents: (any WebContents)? {
        guard let activeTabID else { return nil }
        return webContents[activeTabID]
    }

    // MARK: - Overlay dismissal and focus hand-back

    // While either overlay is presented, the user is typing into a real
    // editable text field — moving first responder to the page underneath
    // would yank the keyboard out from under them mid-word.
    func focusActivePage() {
        guard !isCommandBarPresented, !isFindBarPresented else { return }
        activeWebContents?.focus()
    }

    // Must clear isCommandBarPresented before handing focus back here, since CommandBarView.activate(_:) navigates before dismissing and activateTab(_:) refuses to focus the page while the flag is still set.
    func dismissCommandBar() {
        withAnimation(OrbitMotion.standard) { isCommandBarPresented = false }
        focusActivePage()
    }

    func blankPaneMode(for tabID: TabID) -> CommandBarMode? {
        guard let tab = tab(tabID) else { return nil }
        switch OrbitScheme.parse(tab.url) {
        case .newTab, .note, .easel: return .blankPane(tabID)
        case .viewSource, .web: return nil
        }
    }

    // Refuses while a bar is already up: a split created from the Command
    // Bar mounts its blank pane mid-dismissal, and re-presenting here would reset the user's query.
    func presentBlankPaneCommandBar(_ tabID: TabID) {
        guard !isCommandBarPresented, !isFindBarPresented else { return }
        guard let mode = blankPaneMode(for: tabID) else { return }
        presentCommandBar(mode: mode)
    }

    func dismissFindBar() {
        activeWebContents?.stopFinding(clearSelection: true)
        findQuery = ""
        withAnimation(OrbitMotion.standard) { isFindBarPresented = false }
        focusActivePage()
    }

    static func librarySection(for command: ShortcutCommandID) -> LibrarySection? {
        switch command {
        case .downloads: return .downloads
        case .archivedTabs: return .archivedTabs
        case .mediaLibrary: return .media
        case .easelsAndNotesLibrary: return .easelsAndNotes
        case .boostsLibrary: return .boosts
        default: return nil
        }
    }

    // MARK: - Peek and detached-tab routing

    // nil means no Peek is up, or it doesn't claim this command — dispatch continues to the main table.
    private func performWhilePeekPresented(_ command: ShortcutCommandID) -> Bool? {
        guard PeekState.shared.activePreview != nil else { return nil }
        switch command {
        case .closeTabOrWindow:
            PeekState.shared.dismiss()
            return true
        case .pinUnpinTab:
            // Claimed here, not left to fall through: the main table would
            // resolve activeTabID (the tab behind the Peek) and pin that
            // instead of the page actually on screen.
            if let previewTabID = PeekState.shared.previewTabID {
                togglePin(previewTabID)
            }
            return true
        case .openIntoMainWindow, .openInSpacePicker:
            return nil
        default:
            return nil
        }
    }

    enum DetachedTabSource {
        case peek(TabID)
        case littleOrbit(LittleOrbitWindowController)

        var tabID: TabID {
            switch self {
            case .peek(let id): return id
            case .littleOrbit(let controller): return controller.tabID
            }
        }
    }

    var frontmostDetachedTabSource: DetachedTabSource? {
        if PeekState.shared.activePreview != nil, let previewTabID = PeekState.shared.previewTabID {
            return .peek(previewTabID)
        }
        if let controller = LittleOrbitWindowController.frontmostController {
            return .littleOrbit(controller)
        }
        return nil
    }

    func promote(_ source: DetachedTabSource, into spaceID: SpaceID?) {
        switch source {
        case .peek(let tabID):
            PeekState.shared.previewTabID = nil // ownership moved; don't tear it down
            promoteDetachedTabToMainWindow(tabID, destinationSpaceID: spaceID)
            PeekState.shared.dismiss()
        case .littleOrbit(let controller):
            controller.relinquishTab()
            promoteDetachedTabToMainWindow(controller.tabID, destinationSpaceID: spaceID)
            controller.close()
        }
    }

    func spacePickerMenuForFrontmostDetachedTab() -> NSMenu? {
        guard let source = frontmostDetachedTabSource, !state.spaces.isEmpty else { return nil }
        let menu = NSMenu(title: "Open In…")
        menu.autoenablesItems = false
        for space in state.spaces {
            menu.addItem(ClosureMenuItem(title: space.name) { [weak self] in
                self?.promote(source, into: space.id)
            })
        }
        return menu
    }

    private func presentSpacePicker(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        let anchor = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        menu.popUp(positioning: nil, at: anchor, in: contentView)
    }

    // MARK: - Helpers

    private func combinedSidebarOrder(in spaceID: SpaceID) -> [TabID] {
        let favoriteTabIDs = favorites(for: spaceID).compactMap(\.liveTabID)
        let pinnedTabIDs = pinnedNodes(in: spaceID).flatMap(\.allTabIDs)
        let todayTabIDs = todayTabs(in: spaceID).map(\.id)
        return favoriteTabIDs + pinnedTabIDs + todayTabIDs
    }

    private func stepThroughOpenTabs(offset: Int) {
        guard let spaceID = activeSpace?.id else { return }
        let order = combinedSidebarOrder(in: spaceID)
        guard !order.isEmpty else { return }
        guard let currentIndex = activeTabID.flatMap({ order.firstIndex(of: $0) }) else {
            activateTab(order[0])
            return
        }
        let count = order.count
        let newIndex = ((currentIndex + offset) % count + count) % count
        activateTab(order[newIndex])
    }

    private func jumpToSidebarItem(_ index: Int) {
        guard let spaceID = activeSpace?.id else { return }
        let order = combinedSidebarOrder(in: spaceID)
        guard index < order.count else { return }
        activateTab(order[index])
    }

    private func cycleRecentTabs() {
        guard let spaceID = activeSpace?.id else { return }
        let recent = (todayTabs(in: spaceID) + pinnedNodes(in: spaceID).flatMap(\.allTabIDs).compactMap(tab))
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            .prefix(5)
        guard let currentIndex = activeTabID.flatMap({ id in recent.firstIndex { $0.id == id } }) else {
            if let first = recent.first { activateTab(first.id) }
            return
        }
        let next = recent[(currentIndex + 1) % recent.count]
        activateTab(next.id)
    }

    private func pasteClipboardAsNewTab() {
        guard let spaceID = activeSpace?.id else { return }
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        guard let url = resolveTypedInput(string) else { return }
        openTab(url: url, in: spaceID)
    }

    private func stepZoom(up: Bool) {
        guard let contents = activeWebContents else { return }
        let next = up ? ZoomStep.stepUp(from: contents.zoomFactor) : ZoomStep.stepDown(from: contents.zoomFactor)
        contents.setZoomFactor(next.rawValue)
    }

    private func copyActiveURLStrippingTrackers() {
        guard let url = activeTab?.url else { return }
        let stripped = AppEnvironment.strippingTrackingParameters(from: url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stripped.absoluteString, forType: .string)
    }

    private func copyActiveURLAsMarkdown() {
        guard let tab = activeTab else { return }
        let stripped = AppEnvironment.strippingTrackingParameters(from: tab.url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(tab.displayTitle)](\(stripped.absoluteString))", forType: .string)
    }

    private static let trackingParameterPrefixes = ["utm_", "fbclid", "gclid", "mc_eid", "igshid", "ref_src"]

    static func strippingTrackingParameters(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }
        let cleaned = items.filter { item in
            !trackingParameterPrefixes.contains { item.name.lowercased().hasPrefix($0) }
        }
        components.queryItems = cleaned.isEmpty ? nil : cleaned
        return components.url ?? url
    }

    private func openViewSource() {
        guard let spaceID = activeSpace?.id, let url = activeTab?.url else { return }
        var components = URLComponents()
        components.scheme = "view-source"
        components.host = ""
        components.path = url.absoluteString
        let sourceURL = URL(string: "view-source:\(url.absoluteString)") ?? url
        _ = components
        openTab(url: sourceURL, in: spaceID)
    }

    // self, not AppEnvironment.shared: correct whether the shortcut was
    // pressed in an ordinary window or an already-Incognito one.
    private func openIncognitoWindow() {
        OrbitWindowController.openIncognitoWindow(on: self)
    }

    private func jumpToSpaceAnimated(_ index: Int) {
        withAnimation(OrbitMotion.dramatic) { jumpToSpace(index: index) }
    }

    // MARK: - Notes / Easels

    private func createAndOpenNote(inSplit: Bool = false) {
        guard let spaceID = activeSpace?.id else { return }
        let note = noteStore.createNote()
        let url = URL(string: "orbit://note/\(note.id.uuidString)")!
        let tabID = openTab(url: url, in: spaceID, section: .pinned)
        if inSplit, let currentActive = activeTabID, currentActive != tabID {
            createSplit(existingTabID: currentActive, newTabID: tabID, edge: .right)
        }
    }

    private func createAndOpenEasel() {
        guard let spaceID = activeSpace?.id else { return }
        let easel = easelStore.createEasel()
        let url = URL(string: "orbit://easel/\(easel.id.uuidString)")!
        openTab(url: url, in: spaceID, section: .pinned)
    }

    // MARK: - Split view entry from the keyboard

    private func addSplitToActiveTab() {
        guard let spaceID = activeSpace?.id, let currentActive = activeTabID else {
            presentCommandBar(mode: .newTab)
            return
        }
        if let group = activeSplitGroup, group.tabIDs.count >= SplitGroup.maximumPanes { return }
        let blankTabID = openTab(url: URL(string: "orbit://new-tab")!, in: spaceID, section: .today, activate: false)
        if let groupID = state.tabs[currentActive]?.splitGroupID {
            // Edge follows the group's existing axis, not always .right — a
            // hard-coded .right would flip a top-and-bottom split to side-by-side on every extend.
            let edge: SplitEdge = state.splitGroups[groupID]?.axis == .vertical ? .bottom : .right
            addToSplit(tabID: blankTabID, groupID: groupID, edge: edge)
        } else {
            createSplit(existingTabID: currentActive, newTabID: blankTabID, edge: .right)
        }
        activateTab(blankTabID)
    }

    // MARK: - Reader mode

    private func enterReaderMode(_ tabID: TabID) async {
        guard let contents = webContents[tabID] else { return }
        let extractionScript = """
        (function() {
          function textDensity(el) {
            const text = el.innerText || '';
            const tagCount = el.getElementsByTagName('*').length || 1;
            return text.length / tagCount;
          }
          const candidates = Array.from(document.querySelectorAll('article, main, [role=main], body *'));
          let best = document.body, bestScore = 0;
          for (const el of candidates) {
            if (!el || !el.innerText || el.innerText.length < 200) continue;
            const score = textDensity(el);
            if (score > bestScore) { bestScore = score; best = el; }
          }
          const title = document.title || '';
          return JSON.stringify({ title: title, html: best ? best.innerHTML : '' });
        })();
        """
        guard let raw = try? await contents.evaluateJavaScript(extractionScript) as? String,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        let title = parsed["title"] ?? ""
        let bodyHTML = parsed["html"] ?? "<p>Reader mode couldn't find readable content on this page.</p>"
        let styledHTML = """
        <html><head><meta charset="utf-8">
        <style>
          body { font: 19px/1.6 -apple-system, 'SF Pro Text', sans-serif; max-width: 680px; margin: 64px auto; padding: 0 24px; color: #1c1c1e; }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          h1 { font-size: 30px; margin-bottom: 24px; }
          a { color: #3b6ff2; }
          @media (prefers-color-scheme: dark) { body { color: #f2f2f7; background: #1c1c1e; } a { color: #7aa2ff; } }
        </style></head>
        <body><h1>\(title)</h1>\(bodyHTML)</body></html>
        """
        contents.loadHTML(styledHTML, baseURL: activeTab?.url)
    }
}
