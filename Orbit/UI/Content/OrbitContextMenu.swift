import AppKit
import SwiftUI
import UniformTypeIdentifiers

// NSMenu.autoenablesItems defaults true and silently re-enables items without validateMenuItem(_:); used by the main menu and its Import submenu.
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void

    private let isPermitted: Bool

    init(title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        self.isPermitted = enabled
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        guard isPermitted else { return }
        handler()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isPermitted }
}

extension AppEnvironment {

    // Presents Orbit's own borderless menu, never NSMenu/NSPopover (see OrbitContextMenuPresenter for why).
    func presentContextMenu(for contents: WebContents, context: ContextMenuContext) {
        let entries = buildContextMenuEntries(for: contents, context: context)
        let view = contents.view
        // location is measured from the top; a flipped view (WKWebView) already counts that way.
        let point = NSPoint(x: context.location.x, y: view.isFlipped ? context.location.y : view.bounds.height - context.location.y)
        OrbitContextMenuPresenter.shared.present(entries: entries, anchorView: view, at: point)
    }

    // Resolved via tabID(for:), never contents.id — unrelated identifiers.
    func buildContextMenuEntries(
        for contents: WebContents,
        context: ContextMenuContext,
        capabilities: EngineCapabilities? = nil,
        extensionGroups: [ExtensionContextMenuGroup]? = nil
    ) -> [OrbitContextMenuEntry] {
        let capabilities = capabilities ?? engineCapabilities
        let extensionGroups = extensionGroups ?? contents.extensionContextMenuGroups()
        var entries: [OrbitContextMenuEntry] = []

        if let linkURL = context.linkURL {
            entries.append(.item(OrbitContextMenuItem(title: "Open Link in New Tab", systemImage: "arrow.up.forward.square") { [weak self] in
                guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                self.openTab(url: linkURL, in: tab.spaceID, section: .today, activate: false)
            }))
            if let tabID = tabID(for: contents), LinkDropLogic.splitAllowed(paneCountInGroup: splitGroup(for: tabID)?.tabIDs.count) {
                entries.append(.item(OrbitContextMenuItem(title: "Open Link in Split View", systemImage: "rectangle.split.2x1") { [weak self] in
                    guard let self, let tab = self.state.tabs[tabID] else { return }
                    let newTabID = self.openTab(url: linkURL, in: tab.spaceID, section: .today, activate: false)
                    self.createSplit(existingTabID: tabID, newTabID: newTabID, edge: self.preferredSplitEdge())
                    self.activateTab(newTabID)
                }))
            }
            entries.append(.item(OrbitContextMenuItem(title: "Open Link in Little Orbit", systemImage: "rectangle.inset.filled") {
                LittleOrbitWindowController.open(url: linkURL)
            }))
            entries.append(.divider())
            if OrbitContextMenuActions.isDownloadable(linkURL) {
                entries.append(.item(OrbitContextMenuItem(title: "Download Linked File", systemImage: "arrow.down.circle") { [weak contents] in
                    contents?.downloadResource(linkURL)
                }))
            }
            entries.append(.item(OrbitContextMenuItem(title: "Copy Link", systemImage: "link") {
                OrbitContextMenuActions.copy(linkURL)
            }))
            entries.append(.divider())
        }

        if context.mediaKind == .image, let sourceURL = context.sourceURL {
            entries.append(.item(OrbitContextMenuItem(title: "Open Image in New Tab", systemImage: "photo") { [weak self] in
                guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                self.openTab(url: sourceURL, in: tab.spaceID, section: .today, activate: false)
            }))
            entries.append(.divider())
            entries.append(.item(OrbitContextMenuItem(title: "Save Image to Downloads", systemImage: "square.and.arrow.down") { [weak contents] in
                guard let contents else { return }
                OrbitContextMenuActions.saveImageToDownloads(from: sourceURL, using: contents)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Save Image As…", systemImage: "square.and.arrow.down.on.square") { [weak contents] in
                guard let contents else { return }
                OrbitContextMenuActions.saveImage(from: sourceURL, using: contents)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Copy Image", systemImage: "doc.on.doc") { [weak contents] in
                guard let contents else { return }
                OrbitContextMenuActions.copyImage(from: sourceURL, using: contents)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Copy Image Address", systemImage: "doc.on.clipboard") {
                OrbitContextMenuActions.copy(sourceURL)
            }))
            entries.append(.divider())
        }

        if context.mediaKind == .video || context.mediaKind == .audio {
            let noun = context.mediaKind == .video ? "Video" : "Audio"
            if let sourceURL = context.sourceURL, OrbitContextMenuActions.isDownloadable(sourceURL) {
                entries.append(.item(OrbitContextMenuItem(title: "Open \(noun) in New Tab", systemImage: context.mediaKind == .video ? "play.rectangle" : "waveform") { [weak self] in
                    guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                    self.openTab(url: sourceURL, in: tab.spaceID, section: .today, activate: false)
                }))
                entries.append(.item(OrbitContextMenuItem(title: "Save \(noun) to Downloads", systemImage: "square.and.arrow.down") { [weak contents] in
                    contents?.downloadResource(sourceURL)
                }))
                entries.append(.item(OrbitContextMenuItem(title: "Copy \(noun) Address", systemImage: "doc.on.clipboard") {
                    OrbitContextMenuActions.copy(sourceURL)
                }))
            }
            if context.mediaKind == .video {
                entries.append(.item(OrbitContextMenuItem(title: "Picture in Picture", systemImage: "pip.enter") { [weak contents] in
                    contents?.togglePictureInPicture()
                }))
            }
            entries.append(.divider())
        }

        if let selection = context.selectionText, !selection.isEmpty {
            entries.append(.item(OrbitContextMenuItem(title: "Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }))
            let truncated = selection.count > 28 ? String(selection.prefix(28)) + "…" : selection
            entries.append(.item(OrbitContextMenuItem(title: "Search \(searchEngine.displayName) for “\(truncated)”", systemImage: "magnifyingglass") { [weak self] in
                guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                guard let url = self.searchEngine(forSpace: tab.spaceID).searchURL(for: selection) else { return }
                self.openTab(url: url, in: tab.spaceID)
            }))
            entries.append(.divider())
        }

        entries.append(contentsOf: passwordContextMenuEntries(for: contents, context: context))

        if context.isEditable {
            let hasSelection = !(context.selectionText ?? "").isEmpty
            let canPaste = NSPasteboard.general.string(forType: .string) != nil
            entries.append(.item(OrbitContextMenuItem(
                title: "Cut", systemImage: "scissors", isEnabled: hasSelection
            ) { contents.cut() }))
            entries.append(.item(OrbitContextMenuItem(
                title: "Paste", systemImage: "doc.on.clipboard.fill", isEnabled: canPaste
            ) { contents.paste() }))
            entries.append(.item(OrbitContextMenuItem(title: "Select All", systemImage: "selection.pin.in.out") {
                contents.selectAll()
            }))
            entries.append(.divider())
        }

        let navigationState = contents.navigationState
        entries.append(.item(OrbitContextMenuItem(
            title: "Back", systemImage: "chevron.left", isEnabled: navigationState.canGoBack
        ) { contents.goBack() }))
        entries.append(.item(OrbitContextMenuItem(
            title: "Forward", systemImage: "chevron.right", isEnabled: navigationState.canGoForward
        ) { contents.goForward() }))
        entries.append(.item(OrbitContextMenuItem(title: "Reload", systemImage: "arrow.clockwise") {
            contents.reload(ignoringCache: false)
        }))
        entries.append(.item(OrbitContextMenuItem(title: "Open Tab in Little Orbit", systemImage: "rectangle.inset.filled") { [weak self] in
            guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
            LittleOrbitWindowController.open(url: tab.url)
        }))

        let extensionEntries = extensionMenuEntries(for: contents, groups: extensionGroups)
        if !extensionEntries.isEmpty {
            entries.append(.divider())
            entries.append(contentsOf: extensionEntries)
        }

        entries.append(.divider())
        entries.append(.item(inspectElementItem(for: contents, context: context, capabilities: capabilities)))

        return entries
    }

    // One plain top-level item shows under its own title; anything else groups under the extension's name, as ContextMenuMatcher::AppendExtensionItems does.
    private func extensionMenuEntries(
        for contents: WebContents,
        groups: [ExtensionContextMenuGroup]
    ) -> [OrbitContextMenuEntry] {
        groups.compactMap { group -> OrbitContextMenuEntry? in
            let entries = extensionItemEntries(for: contents, items: group.items)
            guard !entries.isEmpty else { return nil }
            if group.items.count == 1, group.items[0].type == .normal {
                return entries[0]
            }
            return .item(OrbitContextMenuItem(title: group.extensionName, submenu: entries))
        }
    }

    private func extensionItemEntries(
        for contents: WebContents,
        items: [ExtensionContextMenuItem]
    ) -> [OrbitContextMenuEntry] {
        var entries: [OrbitContextMenuEntry] = []
        var lastEntryIsDivider = true
        var previousWasRadio = false

        func appendDivider() {
            guard !lastEntryIsDivider else { return }
            entries.append(.divider())
            lastEntryIsDivider = true
        }

        for item in items {
            // A radio "group" is a run of adjacent radio items; upstream fences each run with separators.
            let isRadio = item.type == .radio
            if isRadio != previousWasRadio { appendDivider() }
            previousWasRadio = isRadio

            if item.type == .separator {
                appendDivider()
                continue
            }

            let children = extensionItemEntries(for: contents, items: item.children)
            let id = item.id
            entries.append(.item(OrbitContextMenuItem(
                title: item.title,
                isEnabled: item.isEnabled,
                isChecked: item.isChecked,
                submenu: children.isEmpty ? nil : children,
                action: children.isEmpty
                    ? { [weak contents] in
                        guard let contents else { return }
                        if let webKit = contents as? WebKitWebContents {
                            webKit.performCapturedExtensionContextMenuItem(id)
                        } else {
                            contents.performExtensionContextMenuItem(id)
                        }
                    }
                    : nil
            )))
            lastEntryIsDivider = false
        }

        while let last = entries.last, case .divider = last {
            entries.removeLast()
        }
        return entries
    }

    private func inspectElementItem(
        for contents: WebContents,
        context: ContextMenuContext,
        capabilities: EngineCapabilities
    ) -> OrbitContextMenuItem {
        let canOpenInspector = capabilities.contains(.developerTools)
        let tooltip = canOpenInspector ? nil : EngineCapabilityCopy.developerToolsUnavailable
        return OrbitContextMenuItem(
            title: "Inspect Element",
            systemImage: "chevron.left.forwardslash.chevron.right",
            isEnabled: canOpenInspector,
            tooltip: tooltip
        ) {
            contents.showInspectElement(at: context.location)
        }
    }
}

// Kept free of AppEnvironment: one-shot fetch, copy and save actions no test needs to intercept via the environment.
@MainActor
enum OrbitContextMenuActions {
    /// blob: and data: sources only exist inside the page; Orbit's download store cannot resume or name them.
    static func isDownloadable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "file"
    }

    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    static func copyImage(from url: URL, using contents: WebContents, to pasteboard: NSPasteboard = .general) {
        Task { @MainActor in
            guard let data = await contents.loadResourceData(url) else { return }
            writeImage(data, sourceURL: url, to: pasteboard)
        }
    }

    /// Keeps the original encoding (a GIF stays animated, a PNG keeps its alpha) alongside a TIFF every app can paste.
    @discardableResult
    static func writeImage(_ data: Data, sourceURL: URL?, to pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(data: data), image.isValid else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        if let type = imageType(of: data), type != .tiff {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if let sourceURL, isDownloadable(sourceURL) {
            pasteboard.setString(sourceURL.absoluteString, forType: .URL)
        }
        return true
    }

    static func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// Web images go through Orbit's downloads so they show in the Downloads list; page-only data and blob images are written straight to the folder.
    static func saveImageToDownloads(from url: URL, using contents: WebContents) {
        if isDownloadable(url) {
            contents.downloadResource(url)
            return
        }
        Task { @MainActor in
            guard let data = await contents.loadResourceData(url) else { return }
            let target = DownloadStore.uniqueDestination(
                in: WebKitDownloads.downloadsDirectory, suggestedName: suggestedImageName(for: url, data: data)
            )
            try? data.write(to: target, options: .withoutOverwriting)
        }
    }

    // NSSavePanel.begin(completionHandler:) returns immediately; never .runModal(), which would enter a nested run loop.
    static func saveImage(from url: URL, using contents: WebContents) {
        Task { @MainActor in
            guard let data = await contents.loadResourceData(url) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedImageName(for: url, data: data)
            panel.directoryURL = WebKitDownloads.downloadsDirectory
            panel.begin { result in
                guard result == .OK, let targetURL = panel.url else { return }
                try? data.write(to: targetURL)
            }
        }
    }

    static func suggestedImageName(for url: URL, data: Data) -> String {
        let last = url.scheme?.lowercased() == "data" ? "" : url.deletingPathExtension().lastPathComponent
        let base = last.isEmpty || last == "/" ? "image" : last
        let ext = imageType(of: data)?.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        return base + "." + ext
    }
}
