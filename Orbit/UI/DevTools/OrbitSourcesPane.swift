import AppKit
import SwiftUI

// MARK: - Main pane

struct OrbitSourcesPane: View {
    var session: OrbitInspectSession
    @State private var isFindOpen = false
    @State private var findQuery = ""
    @State private var findCaseSensitive = false
    @State private var findRegex = false
    @State private var findMatches: [NSRange] = []
    @State private var findCurrentIdx = 0
    @State private var isGlobalSearch = false
    @State private var editingSnippetID: String? = nil
    @State private var newSnippetDraft: SourceSnippet? = nil

    private var model: OrbitSourcesModel { session.sources }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width < 520 {
                narrowLayout
            } else {
                wideLayout
            }
        }
        .background(InspectChrome.panel)
        .onAppear { model.rebuildTree() }
    }

    // MARK: - Wide layout (tree | editor)

    private var wideLayout: some View {
        HStack(spacing: 0) {
            if !isGlobalSearch {
                treePanel
                    .frame(minWidth: 160, maxWidth: 300)
                InspectChrome.hairline.frame(width: 1)
            }
            VStack(spacing: 0) {
                if isGlobalSearch {
                    globalSearchPanel
                } else {
                    editorPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Narrow layout (< 520pt: file picker + editor)

    private var narrowLayout: some View {
        VStack(spacing: 0) {
            // Compact file selector row
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Text(activeTabDisplayName)
                    .font(InspectChrome.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                InspectMenuButton(symbol: "filemenu.and.selection", help: "Choose file") {
                    model.files.prefix(50).map { file in
                        InspectMenuItem(title: file.displayName, checked: model.activeTabID == file.id) {
                            model.openFile(id: file.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(InspectChrome.surface)
            InspectChrome.hairline.frame(height: 1)
            editorPanel
        }
    }

    private var activeTabDisplayName: String {
        guard let id = model.activeTabID else { return "No file selected" }
        return model.openTabs.first(where: { $0.id == id })?.displayName ?? id
    }

    // MARK: - Tree panel

    private var treePanel: some View {
        VStack(spacing: 0) {
            treeToolbar
            InspectChrome.hairline.frame(height: 1)
            if model.treeRows.isEmpty {
                InspectEmptyState(
                    symbol: "doc.text",
                    title: "No sources yet",
                    message: "Navigate to a page to see its scripts, stylesheets and documents."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.treeRows) { row in
                            treeRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var treeToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                InspectSearchField(placeholder: "Filter files", text: Binding(
                    get: { model.treeFilter },
                    set: { model.treeFilter = $0; model.rebuildTree() }
                ))
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh file list") {
                    session.command(["op": "src.list"])
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            HStack(spacing: 0) {
                InspectChip("Page", selected: !model.preferOriginalSources) {
                    model.preferOriginalSources = false
                    model.rebuildTree()
                }
                InspectChip("Original", selected: model.preferOriginalSources) {
                    model.preferOriginalSources = true
                    model.rebuildTree()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func treeRow(_ row: SourceTreeItem) -> some View {
        let isSelected: Bool = {
            if case .file(let f) = row.kind { return model.activeTabID == f.id }
            if case .originalFile(let o) = row.kind { return model.activeTabID == o.id }
            if case .snippet(let s) = row.kind { return editingSnippetID == s.id }
            return false
        }()
        SourcesTreeRowView(row: row, isSelected: isSelected, onTap: {
            switch row.kind {
            case .file(let f):
                model.openFile(id: f.id)
            case .originalFile(let o):
                if let gen = model.files.first(where: { $0.url == o.generatedFileID }) {
                    model.openFile(id: o.id)
                } else {
                    model.openFile(id: o.id)
                }
            case .snippet(let s):
                editingSnippetID = s.id
            case .originHeader, .folder, .originalSourceHeader, .snippetsHeader:
                model.toggleExpanded(id: row.id)
            }
        }, onToggle: {
            model.toggleExpanded(id: row.id)
        })
        .contextMenu {
            if case .file(let f) = row.kind {
                Button("Open in \(OrbitInspectEditorLauncher.editor.title)") { model.openInEditor(fileID: f.id) }
                Button("Reveal in Finder") { model.revealInFinder(fileID: f.id) }
                Button("Copy URL") { session.copy(f.url) }
            }
        }
    }

    // MARK: - Editor panel

    private var editorPanel: some View {
        VStack(spacing: 0) {
            if model.openTabs.isEmpty {
                emptyEditorState
            } else {
                // Tab strip
                SourcesTabStrip(
                    tabs: model.openTabs,
                    activeID: model.activeTabID,
                    onSelect: { model.activateTab(id: $0) },
                    onClose: { model.closeTab(id: $0) }
                )
                InspectChrome.hairline.frame(height: 1)
                // Editor toolbar
                if let tab = activeTab {
                    editorToolbar(tab: tab)
                    InspectChrome.hairline.frame(height: 1)
                }
                // Find bar
                if isFindOpen {
                    SourcesFindBar(
                        query: $findQuery,
                        isOpen: $isFindOpen,
                        caseSensitive: findCaseSensitive,
                        useRegex: findRegex,
                        matchCount: findMatches.count,
                        currentMatch: findCurrentIdx + 1,
                        onCaseSensitive: { findCaseSensitive.toggle(); rebuildFindMatches() },
                        onRegex: { findRegex.toggle(); rebuildFindMatches() },
                        onNext: { stepFind(direction: 1) },
                        onPrev: { stepFind(direction: -1) },
                        onClose: { isFindOpen = false; findQuery = "" }
                    )
                    .onChange(of: findQuery) { _, _ in rebuildFindMatches() }
                }
                // Main editor or snippet editor
                if let snippetID = editingSnippetID, let idx = model.snippets.firstIndex(where: { $0.id == snippetID }) {
                    SourceSnippetEditorView(
                        snippet: Binding(
                            get: { model.snippets[idx] },
                            set: { model.snippets[idx] = $0 }
                        ),
                        output: model.lastSnippetOutput,
                        onRun: { model.runSnippet(model.snippets[idx]) },
                        onSave: { model.saveSnippet(model.snippets[idx]) },
                        onDelete: { model.deleteSnippet(id: snippetID); editingSnippetID = nil }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editorContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Status bar
                if let tab = activeTab {
                    editorStatusBar(tab: tab)
                }
            }
        }
    }

    private var emptyEditorState: some View {
        VStack(spacing: 0) {
            InspectEmptyState(
                symbol: "doc.text",
                title: "Select a file",
                message: "Choose a file from the tree to view its source."
            )
            Divider()
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                Text("WebKit does not expose a JS debugger. Breakpoints and stepping are not available.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
                InspectTextButton("Open WebKit Inspector", action: { session.openWebKitInspector() })
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(InspectChrome.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeTab: SourceTab? {
        guard let id = model.activeTabID else { return nil }
        return model.openTabs.first(where: { $0.id == id })
    }

    @ViewBuilder
    private var editorContent: some View {
        if let tabID = model.activeTabID {
            let state = model.loadStates[tabID]
            let tab = model.openTabs.first(where: { $0.id == tabID })
            if let text = model.loadedTextForActiveTab() {
                let lang = languageForTab(tab)
                let isCSS = (tab?.fileType == .stylesheet || tab?.fileType == .inlineStyle || tab?.fileType == .adoptedStylesheet)
                SourcesEditorView(
                    text: text,
                    language: lang,
                    isEditable: isCSS,
                    wordWrap: model.wordWrap,
                    fontSize: model.fontSize,
                    revealLine: tab?.selectedLine,
                    onEdit: isCSS ? { newText in
                        if let url = tab?.url {
                            model.applyCSSOverride(url: url, text: newText)
                        }
                    } : nil
                )
                .id(tabID) // Force recreate when tab changes
            } else if case .loading = state {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .failed(let message) = state {
                InspectEmptyState(
                    symbol: "exclamationmark.triangle",
                    title: "Could not load",
                    message: message
                )
            } else if let ft = tab?.fileType, !ft.isTextSource {
                mediaPreview(fileType: ft, url: tab?.url ?? "")
            } else {
                InspectEmptyState(
                    symbol: "arrow.clockwise",
                    title: "Loading…",
                    message: "Fetching source content."
                )
            }
        }
    }

    @ViewBuilder
    private func mediaPreview(fileType: SourceFileType, url: String) -> some View {
        VStack(spacing: 12) {
            if fileType == .image, let u = URL(string: url) {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFit()
                } placeholder: { ProgressView() }
                .frame(maxWidth: 400, maxHeight: 400)
            } else {
                Image(systemName: fileType.symbol)
                    .font(.system(size: 36))
                    .foregroundStyle(Color.secondary)
            }
            Text(url)
                .font(InspectChrome.mono)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func languageForTab(_ tab: SourceTab?) -> SourceLanguage {
        guard let tab else { return .other }
        return SourceLanguage.detect(url: tab.url, mimeType: tab.fileType.rawValue)
    }

    // MARK: - Editor toolbar

    private func editorToolbar(tab: SourceTab) -> some View {
        let isCSS = (tab.fileType == .stylesheet || tab.fileType == .inlineStyle || tab.fileType == .adoptedStylesheet)
        let isDoc = (tab.fileType == .document)
        return HStack(spacing: 4) {
            // Pretty print
            InspectIconButton(symbol: "wand.and.stars", help: tab.prettyPrinted ? "Show original" : "Pretty print", active: tab.prettyPrinted) {
                model.togglePrettyPrint(tabID: tab.id)
            }
            // Word wrap
            InspectIconButton(symbol: "text.alignleft", help: model.wordWrap ? "Disable word wrap" : "Enable word wrap", active: model.wordWrap) {
                model.wordWrap.toggle()
            }
            if isDoc {
                InspectIconButton(symbol: "curlybraces", help: tab.showDOMSource ? "Show served source" : "Show current DOM", active: tab.showDOMSource) {
                    model.toggleDOMSource(tabID: tab.id)
                }
            }
            if isCSS && model.cssOverrides[tab.url] != nil {
                InspectTextButton("Revert", systemImage: "arrow.uturn.backward") {
                    model.revertCSSOverride(url: tab.url)
                }
            }
            Spacer(minLength: 0)
            // Global search
            InspectIconButton(symbol: "magnifyingglass", help: "Search all sources (Cmd+Shift+F)", active: isGlobalSearch) {
                isGlobalSearch.toggle()
            }
            // Open in editor
            InspectMenuButton(symbol: "square.and.arrow.up", help: "Open in editor") {
                [
                    InspectMenuItem(title: "Open in \(OrbitInspectEditorLauncher.editor.title)") { model.openInEditor(fileID: tab.id) },
                    InspectMenuItem(title: "Reveal in Finder") { model.revealInFinder(fileID: tab.id) },
                    InspectMenuItem.separator,
                ] + OrbitInspectEditor.allCases.map { editor in
                    InspectMenuItem(title: editor.title, checked: OrbitInspectEditorLauncher.editor == editor) {
                        OrbitInspectEditorLauncher.editor = editor
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(InspectChrome.surface)
    }

    // MARK: - Status bar

    private func editorStatusBar(tab: SourceTab) -> some View {
        HStack(spacing: 10) {
            if let state = model.loadStates[tab.id] {
                switch state {
                case .loaded(let text, let encoding, let truncated, let mapURL):
                    Text(OrbitDevToolsFormat.bytes(text.utf8.count))
                        .font(InspectChrome.caption)
                        .foregroundStyle(Color.secondary)
                    Text(encoding)
                        .font(InspectChrome.caption)
                        .foregroundStyle(Color.secondary)
                    if truncated {
                        Text("truncated")
                            .font(InspectChrome.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    if let mapURL {
                        Image(systemName: "map.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                            .orbitTooltip("Source map: \(mapURL)")
                    } else {
                        Image(systemName: "map")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                            .orbitTooltip("No source map")
                    }
                case .inlineContent(let text):
                    Text(OrbitDevToolsFormat.bytes(text.utf8.count))
                        .font(InspectChrome.caption)
                        .foregroundStyle(Color.secondary)
                    Text("inline")
                        .font(InspectChrome.caption)
                        .foregroundStyle(Color.secondary)
                default:
                    EmptyView()
                }
            }
            if tab.prettyPrinted {
                Text("pretty")
                    .font(InspectChrome.caption)
                    .foregroundStyle(Color(nsColor: .systemBlue))
            }
            if tab.isModified {
                Text("modified")
                    .font(InspectChrome.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Spacer(minLength: 0)
            // Add snippet button
            InspectTextButton("+ Snippet", systemImage: "plus") {
                let newSnippet = SourceSnippet(id: UUID().uuidString, name: "Untitled", code: "// Type JavaScript here and press Cmd+Return to run")
                model.saveSnippet(newSnippet)
                editingSnippetID = newSnippet.id
            }
            // Keep overrides toggle
            InspectChip("Keep CSS", selected: model.keepCSSOverrides) {
                model.keepCSSOverrides.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(InspectChrome.surface)
        .overlay(alignment: .top) { InspectChrome.hairline.frame(height: 1) }
    }

    // MARK: - Global search panel

    private var globalSearchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                InspectIconButton(symbol: "chevron.left", help: "Back to sources") { isGlobalSearch = false }
                InspectSearchField(placeholder: "Search all sources", text: Binding(
                    get: { model.globalSearchQuery },
                    set: { model.globalSearchQuery = $0; model.startGlobalSearch(query: $0) }
                ))
                if model.isSearchRunning { ProgressView().scaleEffect(0.6) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(InspectChrome.surface)
            InspectChrome.hairline.frame(height: 1)
            if model.globalSearchResults.isEmpty && !model.globalSearchQuery.isEmpty && !model.isSearchRunning {
                InspectEmptyState(symbol: "magnifyingglass", title: "No results", message: "No matches found in loaded sources.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.globalSearchResults, id: \.fileID) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.secondary)
                                    Text(group.fileDisplayName)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color.primary)
                                    Text("(\(group.matches.count))")
                                        .font(InspectChrome.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(InspectChrome.surface)
                                ForEach(group.matches) { match in
                                    HStack(spacing: 8) {
                                        Text("\(match.line)")
                                            .font(InspectChrome.monoSmall)
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 32, alignment: .trailing)
                                        Text(match.lineText.trimmingCharacters(in: .whitespaces))
                                            .font(InspectChrome.mono)
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                    }
                                    .frame(minHeight: InspectChrome.rowHeight)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .overlay(InspectHitTarget {
                                        isGlobalSearch = false
                                        model.openFile(id: match.fileID, line: match.line)
                                    })
                                }
                                InspectChrome.hairline.frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Find in file

    private func rebuildFindMatches() {
        guard let tabID = model.activeTabID, let text = model.loadedTextForActiveTab(), !findQuery.isEmpty else {
            findMatches = []
            return
        }
        let nsText = text as NSString
        var ranges: [NSRange] = []
        if findRegex, let regex = try? NSRegularExpression(pattern: findQuery) {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
                if let m { ranges.append(m.range) }
            }
        } else {
            var options: NSString.CompareOptions = .literal
            if !findCaseSensitive { options.insert(.caseInsensitive) }
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: findQuery, options: options, range: searchRange)
                if found.location == NSNotFound { break }
                ranges.append(found)
                searchRange.location = NSMaxRange(found)
                searchRange.length = nsText.length - searchRange.location
                if ranges.count > 1000 { break }
            }
        }
        findMatches = ranges
        findCurrentIdx = 0
    }

    private func stepFind(direction: Int) {
        guard !findMatches.isEmpty else { return }
        findCurrentIdx = (findCurrentIdx + direction + findMatches.count) % findMatches.count
    }
}
