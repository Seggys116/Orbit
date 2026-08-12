import AppKit
import SwiftUI

// NSMenu.autoenablesItems defaults true and silently re-enables items without validateMenuItem(_:).
// Still used by SiteControlPopoverView's permission (Allow/Block/Ask) dropdown -- an NSMenu-backed
// picker, not the page context menu below.
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

    // Presents Orbit's own borderless menu, never NSMenu/NSPopover -- see
    // OrbitContextMenuPresenter for why. Point is flipped from context.location's top-left WebContents coordinates to the anchor view's AppKit coordinates.
    func presentContextMenu(for contents: WebContents, context: ContextMenuContext) {
        let entries = buildContextMenuEntries(for: contents, context: context)
        let view = contents.view
        let point = NSPoint(x: context.location.x, y: view.bounds.height - context.location.y)
        OrbitContextMenuPresenter.shared.present(entries: entries, anchorView: view, at: point)
    }

    // Resolved via tabID(for:), never contents.id — unrelated identifiers.
    func buildContextMenuEntries(
        for contents: WebContents,
        context: ContextMenuContext,
        capabilities: EngineCapabilities? = nil
    ) -> [OrbitContextMenuEntry] {
        let capabilities = capabilities ?? engineCapabilities
        var entries: [OrbitContextMenuEntry] = []

        if let linkURL = context.linkURL {
            entries.append(.item(OrbitContextMenuItem(title: "Open Link in New Tab", systemImage: "arrow.up.forward.square") { [weak self] in
                guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                self.openTab(url: linkURL, in: tab.spaceID, section: .today, activate: false)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Open Link in Little Orbit", systemImage: "rectangle.inset.filled") {
                LittleOrbitWindowController.open(url: linkURL)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(linkURL.absoluteString, forType: .string)
            }))
            entries.append(.divider())
        }

        if context.mediaKind == .image, let sourceURL = context.sourceURL {
            entries.append(.item(OrbitContextMenuItem(title: "Open Image in New Tab", systemImage: "photo") { [weak self] in
                guard let self, let tabID = self.tabID(for: contents), let tab = self.state.tabs[tabID] else { return }
                self.openTab(url: sourceURL, in: tab.spaceID)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Save Image", systemImage: "square.and.arrow.down") {
                OrbitContextMenuActions.saveImage(from: sourceURL)
            }))
            entries.append(.item(OrbitContextMenuItem(title: "Copy Image Address", systemImage: "doc.on.clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sourceURL.absoluteString, forType: .string)
            }))
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

        entries.append(.divider())
        entries.append(.item(inspectElementItem(for: contents, context: context, capabilities: capabilities)))

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
            contents.showDeveloperTools(inspectAt: context.location)
        }
    }
}

// Kept free of AppEnvironment: this is a one-shot fetch-and-save, not a
// browsing action any test needs to intercept via the environment.
enum OrbitContextMenuActions {
    // NSSavePanel.begin(completionHandler:) is asynchronous and returns
    // immediately -- never .runModal(), which would enter a nested run loop.
    static func saveImage(from url: URL, session: URLSession = .shared, fileManager: FileManager = .default) {
        Task {
            guard let (data, response) = try? await session.data(from: url) else { return }
            let suggested = response.suggestedFilename ?? url.lastPathComponent
            await MainActor.run {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggested.isEmpty ? "image" : suggested
                panel.begin { result in
                    guard result == .OK, let targetURL = panel.url else { return }
                    try? data.write(to: targetURL)
                }
            }
        }
    }
}
