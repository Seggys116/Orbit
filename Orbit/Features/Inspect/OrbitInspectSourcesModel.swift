import AppKit
import Foundation
import WebKit

struct SourceTab: Identifiable, Equatable {
    var id: String          // == file.id
    var url: String
    var displayName: String
    var fileType: SourceFileType
    var isModified: Bool
    var prettyPrinted: Bool
    var showDOMSource: Bool   // for documents: show live DOM instead of served source
    var selectedLine: Int?    // 1-based line to jump to next time the tab is activated
    var selectedColumn: Int?
}

enum SourceLoadState {
    case idle
    case loading
    case loaded(text: String, encoding: String, wasTruncated: Bool, sourceMappingURL: String?)
    case domLoaded(html: String)
    case failed(message: String)
    case inlineContent(text: String) // content came from the JS page-agent

    var text: String? {
        switch self {
        case .loaded(let t, _, _, _): return t
        case .domLoaded(let h):       return h
        case .inlineContent(let t):   return t
        default:                       return nil
        }
    }

    var isLoading: Bool { if case .loading = self { return true }; return false }
    var hasContent: Bool { text != nil }
}


struct SourceSearchMatch: Identifiable, Sendable {
    var id: String
    var fileID: String
    var fileDisplayName: String
    var line: Int       // 1-based
    var lineText: String
    var matchRange: Range<String.Index>
}

struct SourceSearchResult: Sendable {
    var fileID: String
    var fileDisplayName: String
    var matches: [SourceSearchMatch]
}

@MainActor
@Observable
final class OrbitSourcesModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    var files: [SourceFile] = []
    var originalFiles: [OriginalSourceFile] = []

    var openTabs: [SourceTab] = []
    var activeTabID: String? = nil

    // Not @ObservationIgnored, so SwiftUI tracks content arrival and re-renders the editor.
    var loadStates: [String: SourceLoadState] = [:]

    @ObservationIgnored var parsedMaps: [String: ParsedMappings] = [:]

    var preferOriginalSources = false
    var wordWrap = true
    var fontSize: CGFloat = 11.5

    var treeFilter = ""
    var expandedIDs: Set<String> = ["origin:"] // expand first origin by default
    var treeRows: [SourceTreeItem] = []

    var cssOverrides: [String: String] = [:]   // url -> edited text
    var keepCSSOverrides = false

    var globalSearchQuery = ""
    var globalSearchResults: [SourceSearchResult] = []
    var isGlobalSearchActive = false
    var isSearchRunning = false
    @ObservationIgnored private var searchTask: Task<Void, Never>? = nil

    var snippets: [SourceSnippet] = []
    var lastSnippetOutput: String? = nil

    @ObservationIgnored private var pendingReveal: (url: String, line: Int?, column: Int?)?


    var messageTypes: Set<String> {
        ["src.files", "src.fileUpdate", "src.outerHTML", "src.jsResult", "src.cssResult", "src.htmlApplied"]
    }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        switch type {
        case "src.files":
            handleFileList(object)
        case "src.outerHTML":
            if let html = object["html"] as? String, let id = pendingOuterHTMLRequest {
                loadStates[id] = .domLoaded(html: html)
                pendingOuterHTMLRequest = nil
            }
        case "src.jsResult":
            let result = OrbitInspectDecode.string(object, "result")
            let error = OrbitInspectDecode.optionalString(object, "error")
            lastSnippetOutput = error.map { "Error: \($0)" } ?? result
        case "src.cssResult":
            break // no extra action needed; the override is tracked in cssOverrides
        default:
            break
        }
    }

    @ObservationIgnored private var pendingOuterHTMLRequest: String? = nil

    func pageDidReset(preservingLog: Bool) {
        files = []
        originalFiles = []
        openTabs = []
        activeTabID = nil
        loadStates = [:]
        parsedMaps = [:]
        treeRows = []
        expandedIDs = []
        lastSnippetOutput = nil
        pendingReveal = nil
        pendingOuterHTMLRequest = nil
        cancelGlobalSearch()
        globalSearchResults = []
        snippets = SourceSnippetsStore.load()
        expandedIDs.insert("section:snippets")
        if keepCSSOverrides, let site = session.map({ URL(string: $0.pageURL)?.host ?? "local" }) {
            let stored = SourceOverridesStore.load(forSite: site)
            if !stored.isEmpty {
                cssOverrides = stored
                var overridesArg: [String: Any] = [:]
                stored.forEach { overridesArg[$0.key] = $0.value }
                session?.command(["op": "src.reApplyOverrides", "overrides": overridesArg])
            }
        } else {
            cssOverrides = [:]
        }
    }

    func panelDidAppear(force: Bool) {
        snippets = SourceSnippetsStore.load()
        if expandedIDs.isEmpty { expandedIDs.insert("section:snippets") }
        session?.command(["op": "src.list"])
        if let pending = pendingReveal {
            pendingReveal = nil
            openFile(id: pending.url, line: pending.line, column: pending.column)
        }
    }

    func reveal(url: String, line: Int?, column: Int?) {
        // Without a session the reveal is parked in pendingReveal and replayed by panelDidAppear.
        guard session != nil else { pendingReveal = (url, line, column); return }
        session?.select(panel: .sources)
        openFile(id: url, line: line, column: column)
    }

    func openFile(id: String, line: Int? = nil, column: Int? = nil) {
        let file = files.first(where: { $0.id == id || $0.url == id })
        if var existing = openTabs.first(where: { $0.id == id || $0.url == id }) {
            if let line { existing.selectedLine = line; existing.selectedColumn = column }
            if let idx = openTabs.firstIndex(where: { $0.id == existing.id }) {
                openTabs[idx] = existing
            }
            activeTabID = existing.id
        } else {
            let ft = file?.fileType ?? SourceFileType.from(mimeType: "", url: id)
            let name = file?.displayName ?? (URL(string: id)?.lastPathComponent ?? id)
            var tab = SourceTab(id: id, url: id, displayName: name, fileType: ft, isModified: false, prettyPrinted: false, showDOMSource: false, selectedLine: line, selectedColumn: column)
            openTabs.append(tab)
            activeTabID = id
        }
        // Start loading unless content is already there or a load is in flight.
        if loadStates[id] == nil || loadStates[id]?.isLoading == false && loadStates[id]?.hasContent == false {
            if let file, (file.fileType == .inlineScript || file.fileType == .inlineStyle || file.fileType == .adoptedStylesheet), case .some(.inlineContent) = loadStates[id] {
            } else {
                loadContent(for: id, file: file)
            }
        }
        if let file {
            expandedIDs.insert("origin:\(file.origin)")
            rebuildTree()
        }
    }

    func closeTab(id: String) {
        openTabs.removeAll { $0.id == id }
        if activeTabID == id {
            activeTabID = openTabs.last?.id
        }
    }

    func activateTab(id: String) {
        activeTabID = id
        loadContent(for: id, file: files.first(where: { $0.id == id || $0.url == id }))
    }

    func togglePrettyPrint(tabID: String) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[idx].prettyPrinted.toggle()
    }

    func toggleDOMSource(tabID: String) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[idx].showDOMSource.toggle()
        if openTabs[idx].showDOMSource {
            pendingOuterHTMLRequest = tabID
            session?.command(["op": "src.outerHTML"])
        }
    }


    func applyCSSOverride(url: String, text: String) {
        cssOverrides[url] = text
        session?.command(["op": "src.cssApply", "url": url, "text": text])
        if let idx = openTabs.firstIndex(where: { $0.url == url }) {
            openTabs[idx].isModified = true
        }
        if keepCSSOverrides, let site = session.map({ URL(string: $0.pageURL)?.host ?? "local" }) {
            SourceOverridesStore.save(cssOverrides, forSite: site)
        }
    }

    func revertCSSOverride(url: String) {
        cssOverrides.removeValue(forKey: url)
        session?.command(["op": "src.cssRevert", "url": url])
        if let idx = openTabs.firstIndex(where: { $0.url == url }) {
            openTabs[idx].isModified = false
        }
        if keepCSSOverrides, let site = session.map({ URL(string: $0.pageURL)?.host ?? "local" }) {
            SourceOverridesStore.save(cssOverrides, forSite: site)
        }
    }

    func revertAllCSSOverrides() {
        let urls = Array(cssOverrides.keys)
        for url in urls { revertCSSOverride(url: url) }
    }


    func runSnippet(_ snippet: SourceSnippet) {
        lastSnippetOutput = "Running…"
        session?.command(["op": "src.jsRun", "code": snippet.code, "id": snippet.id])
    }

    func saveSnippet(_ snippet: SourceSnippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
        } else {
            snippets.append(snippet)
        }
        SourceSnippetsStore.save(snippets)
        rebuildTree()
    }

    func deleteSnippet(id: String) {
        snippets.removeAll { $0.id == id }
        SourceSnippetsStore.save(snippets)
        rebuildTree()
    }


    func startGlobalSearch(query: String) {
        cancelGlobalSearch()
        guard !query.isEmpty else { globalSearchResults = []; return }
        isSearchRunning = true
        globalSearchResults = []
        let allFiles = files
        let allLoadStates = loadStates
        searchTask = Task { [weak self] in
            let results = await Self.searchFiles(allFiles, loadStates: allLoadStates, query: query)
            self?.globalSearchResults = results
            self?.isSearchRunning = false
        }
    }

    @concurrent
    private nonisolated static func searchFiles(
        _ allFiles: [SourceFile], loadStates allLoadStates: [String: SourceLoadState], query: String
    ) async -> [SourceSearchResult] {
        var results: [SourceSearchResult] = []
        let isRegex = query.hasPrefix("/") && query.count > 2
        let matchFn: (String, String) -> [Range<String.Index>]
        if isRegex, let rx = try? NSRegularExpression(pattern: String(query.dropFirst().dropLast())) {
            matchFn = { text, _ in
                rx.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .compactMap { Range($0.range, in: text) }
            }
        } else {
            matchFn = { text, q in
                var ranges: [Range<String.Index>] = []
                var searchFrom = text.startIndex
                while let r = text.range(of: q, options: .caseInsensitive, range: searchFrom..<text.endIndex) {
                    ranges.append(r)
                    searchFrom = r.upperBound
                    if ranges.count > 500 { break }
                }
                return ranges
            }
        }
        for file in allFiles {
            guard Task.isCancelled == false else { break }
            guard let state = allLoadStates[file.id], let text = state.text else { continue }
            let ranges = matchFn(text, query)
            if ranges.isEmpty { continue }
            var matches: [SourceSearchMatch] = []
            for r in ranges.prefix(50) {
                let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let lineEnd = text[r.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
                let lineText = String(text[lineStart..<lineEnd])
                let lineNumber = text[..<r.lowerBound].filter { $0 == "\n" }.count + 1
                matches.append(SourceSearchMatch(id: "\(file.id):\(lineNumber):\(r.lowerBound)", fileID: file.id, fileDisplayName: file.displayName, line: lineNumber, lineText: lineText, matchRange: r))
            }
            results.append(SourceSearchResult(fileID: file.id, fileDisplayName: file.displayName, matches: matches))
        }
        return results
    }

    func cancelGlobalSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearchRunning = false
    }


    func openInEditor(fileID: String) {
        guard let session else { return }
        let file = files.first(where: { $0.id == fileID })
        let url = file?.declaredSourceURL ?? file?.url ?? fileID
        let activeTab = openTabs.first(where: { $0.id == fileID })
        let line = activeTab?.selectedLine
        let col = activeTab?.selectedColumn
        OrbitInspectEditorLauncher.open(sourceURL: url, line: line, column: col, session: session)
    }

    func revealInFinder(fileID: String) {
        guard let session else { return }
        let file = files.first(where: { $0.id == fileID })
        let url = file?.declaredSourceURL ?? file?.url ?? fileID
        let site = URL(string: session.pageURL)?.host ?? "local"
        if let path = OrbitInspectEditorLauncher.resolveFile(sourceURL: url, site: site) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }


    func rebuildTree() {
        treeRows = SourceTreeBuilder.buildFlatRows(
            files: files,
            originalFiles: originalFiles,
            snippets: snippets,
            expandedIDs: expandedIDs,
            filterQuery: treeFilter,
            preferOriginals: preferOriginalSources
        )
    }

    func toggleExpanded(id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) }
        else { expandedIDs.insert(id) }
        rebuildTree()
    }


    func loadedTextForActiveTab() -> String? {
        guard let tabID = activeTabID else { return nil }
        guard let tab = openTabs.first(where: { $0.id == tabID }) else { return nil }
        let state = loadStates[tabID]
        if tab.showDOMSource, case .domLoaded(let html) = state { return html }
        guard let rawText = state?.text else { return nil }
        if tab.prettyPrinted {
            return prettyPrint(text: rawText, tabID: tabID)
        }
        return rawText
    }

    @ObservationIgnored private var prettyCache: [String: PrettyResult] = [:]

    private func prettyPrint(text: String, tabID: String) -> String {
        if let cached = prettyCache[tabID] { return cached.text }
        let file = files.first(where: { $0.id == tabID })
        let url = file?.url ?? tabID
        let lang = SourceLanguage.detect(url: url, mimeType: file?.mimeType ?? "")
        let result: PrettyResult
        switch lang {
        case .json:
            result = SourcePrettyPrinter.json(text)
        case .css, .scss:
            result = SourcePrettyPrinter.css(text)
        case .html, .xml, .svg:
            result = SourcePrettyPrinter.html(text)
        default:
            result = SourcePrettyPrinter.js(text)
        }
        prettyCache[tabID] = result
        return result.text
    }

    func prettyResult(for tabID: String) -> PrettyResult? { prettyCache[tabID] }

    func originalLine(prettyLine: Int, tabID: String) -> Int? {
        guard let result = prettyCache[tabID] else { return nil }
        return result.reverseLinemap[prettyLine - 1].map { $0 + 1 }
    }

    func revealWithMapTranslation(url: String, line: Int?, column: Int?) {
        if preferOriginalSources, let line, let mappings = parsedMaps[url] {
            let col = (column ?? 1) - 1
            let genLine = (line - 1)
            if let orig = mappings.originalPosition(line: genLine, column: max(0, col)) {
                let origID = orig.source
                if let origFile = originalFiles.first(where: { $0.id == origID }) {
                    openOriginalFile(id: origFile.id, line: orig.line + 1, column: orig.column + 1)
                    return
                }
            }
        }
        openFile(id: url, line: line, column: column)
    }

    private func openOriginalFile(id: String, line: Int?, column: Int?) {
        let file = originalFiles.first(where: { $0.id == id })
        let name = file?.displayName ?? id
        if var existing = openTabs.first(where: { $0.id == id }) {
            existing.selectedLine = line
            existing.selectedColumn = column
            if let idx = openTabs.firstIndex(where: { $0.id == id }) { openTabs[idx] = existing }
            activeTabID = id
        } else {
            let tab = SourceTab(id: id, url: id, displayName: name, fileType: .script, isModified: false, prettyPrinted: false, showDOMSource: false, selectedLine: line, selectedColumn: column)
            openTabs.append(tab)
            activeTabID = id
        }
        if loadStates[id] == nil {
            for (_, mappings) in parsedMaps {
                if let idx = mappings.sources.firstIndex(of: id) ?? mappings.sources.firstIndex(where: { src in
                    let full = mappings.sourceRoot.isEmpty ? src : (mappings.sourceRoot.hasSuffix("/") ? mappings.sourceRoot + src : mappings.sourceRoot + "/" + src)
                    return full == id
                }) {
                    if idx < mappings.sourcesContent.count, let content = mappings.sourcesContent[idx] {
                        loadStates[id] = .inlineContent(text: content)
                        return
                    }
                }
            }
        }
    }


    private func loadContent(for id: String, file: SourceFile?) {
        // Inline content already arrived from the page agent, and a loaded file is not fetched again.
        if case .inlineContent = loadStates[id] { return }
        if case .loaded = loadStates[id] { return }
        guard let webView = session?.contents?.webView else { return }
        guard let urlString = file?.url ?? (id.hasPrefix("http") ? id : nil) else { return }
        // "(inline" and "(adopted" are virtual names with nothing to fetch.
        if urlString.hasPrefix("(inline") || urlString.hasPrefix("(adopted") { return }
        loadStates[id] = .loading
        Task {
            do {
                let result = try await SourceFetcher.shared.fetch(urlString: urlString, webView: webView)
                let smURL = SourceMapParser.sourceMappingURL(in: result.text)
                let headerSMURL = SourceMapHeaderDetector.headerURL(from: result.responseHeaders)
                let finalSMURL = headerSMURL ?? smURL
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loadStates[id] = .loaded(text: result.text, encoding: result.encoding, wasTruncated: result.wasTruncated, sourceMappingURL: finalSMURL)
                    self.prettyCache.removeValue(forKey: id)
                    if let smURLStr = finalSMURL {
                        self.loadSourceMap(mapURLString: smURLStr, generatedURL: urlString, webView: webView)
                    }
                }
            } catch SourceFetchError.binary {
                await MainActor.run { [weak self] in
                    self?.loadStates[id] = .failed(message: "Binary file — no text preview")
                }
            } catch SourceFetchError.badStatus(let code) {
                await MainActor.run { [weak self] in
                    self?.loadStates[id] = .failed(message: "HTTP \(code)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.loadStates[id] = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    private func loadSourceMap(mapURLString: String, generatedURL: String, webView: WKWebView) {
        Task {
            let resolvedURL: String
            if mapURLString.hasPrefix("data:") {
                resolvedURL = mapURLString
            } else if mapURLString.hasPrefix("http://") || mapURLString.hasPrefix("https://") {
                resolvedURL = mapURLString
            } else if let base = URL(string: generatedURL), let resolved = URL(string: mapURLString, relativeTo: base) {
                resolvedURL = resolved.absoluteString
            } else {
                return
            }
            do {
                let mapText: String
                if resolvedURL.hasPrefix("data:") {
                    mapText = Self.decodeDataURI(resolvedURL)
                } else {
                    let result = try await SourceFetcher.shared.fetch(urlString: resolvedURL, webView: webView)
                    mapText = result.text
                }
                guard let mapData = mapText.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: mapData) as? [String: Any],
                      let mapV3 = SourceMapParser.parse(json: json) else { return }
                let parsed = SourceMapParser.parseMappings(mapV3)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.parsedMaps[generatedURL] = parsed
                    for (idx, source) in parsed.sources.enumerated() {
                        let sourceID = parsed.sourceRoot.isEmpty ? source : (parsed.sourceRoot.hasSuffix("/") ? parsed.sourceRoot + source : parsed.sourceRoot + "/" + source)
                        if !self.originalFiles.contains(where: { $0.id == sourceID }) {
                            let parts = sourceID.split(separator: "/").map(String.init)
                            let name = parts.last ?? sourceID
                            let pathComps = parts.count > 1 ? Array(parts.dropLast()) : []
                            let origin = sourceID.hasPrefix("webpack://") ? "webpack://" : (sourceID.hasPrefix("vite://") ? "vite://" : (URL(string: sourceID)?.host ?? "original"))
                            let origFile = OriginalSourceFile(id: sourceID, displayPath: sourceID, origin: origin, pathComponents: pathComps, displayName: name, generatedFileID: generatedURL)
                            self.originalFiles.append(origFile)
                            if idx < parsed.sourcesContent.count, let content = parsed.sourcesContent[idx] {
                                self.loadStates[sourceID] = .inlineContent(text: content)
                            }
                        }
                    }
                    self.rebuildTree()
                }
            } catch {}
        }
    }

    private static func decodeDataURI(_ uri: String) -> String {
        // A data URI is "data:" then metadata up to the first comma; slicing past a comma before index 5 would trap.
        guard uri.hasPrefix("data:"), let commaIdx = uri.firstIndex(of: ","),
              commaIdx >= uri.index(uri.startIndex, offsetBy: 5) else { return "{}" }
        let meta = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<commaIdx])
        let content = String(uri[uri.index(after: commaIdx)...])
        if meta.contains("base64") {
            if let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        }
        return content.removingPercentEncoding ?? content
    }


    private func handleFileList(_ object: [String: Any]) {
        guard let rawFiles = object["files"] as? [[String: Any]] else { return }
        let pageURL = OrbitInspectDecode.string(object, "href")
        var newFiles: [SourceFile] = []
        for raw in rawFiles {
            let id = OrbitInspectDecode.string(raw, "id")
            let url = OrbitInspectDecode.string(raw, "url")
            let kind = OrbitInspectDecode.string(raw, "kind")
            let mime = OrbitInspectDecode.string(raw, "mime")
            let line = OrbitInspectDecode.number(raw, "line").map { Int(clamping: $0) }
            let index = OrbitInspectDecode.number(raw, "index").map { Int(clamping: $0) }
            let sourceURL = OrbitInspectDecode.optionalString(raw, "sourceURL")
            let content = OrbitInspectDecode.optionalString(raw, "content")
            let ft: SourceFileType
            switch kind {
            case "document":           ft = .document
            case "script":             ft = .script
            case "stylesheet":         ft = .stylesheet
            case "inline-script":      ft = .inlineScript
            case "inline-style":       ft = .inlineStyle
            case "adopted-stylesheet": ft = .adoptedStylesheet
            case "worker":             ft = .workerScript
            default:                   ft = SourceFileType.from(mimeType: mime, url: url)
            }
            let file = SourceFile.make(url: url, mimeType: mime, inlineLine: line, inlineIndex: index, declaredSourceURL: sourceURL, type: ft)
            let finalFile: SourceFile
            if file.id != id {
                finalFile = SourceFile(id: id, url: url, displayName: file.displayName, origin: file.origin, pathComponents: file.pathComponents, fileType: ft, mimeType: mime, inlineLine: line, inlineIndex: index, declaredSourceURL: sourceURL)
            } else {
                finalFile = file
            }
            newFiles.append(finalFile)
            if let content {
                if loadStates[id] == nil {
                    loadStates[id] = .inlineContent(text: content)
                }
            }
        }
        let networkFiles = filesFromNetworkRecords()
        var merged = newFiles
        for nf in networkFiles {
            if !merged.contains(where: { $0.id == nf.id }) { merged.append(nf) }
        }
        files = merged
        if expandedIDs.isEmpty || expandedIDs == ["section:snippets"] {
            if let firstOrigin = merged.first?.origin {
                expandedIDs.insert("origin:\(firstOrigin)")
            }
        }
        rebuildTree()
    }

    private func filesFromNetworkRecords() -> [SourceFile] {
        guard let records = session?.network.records else { return [] }
        return records.compactMap { record -> SourceFile? in
            guard !record.url.isEmpty, record.url != "about:blank" else { return nil }
            guard record.resourceType == "script" || record.resourceType == "stylesheet" || record.resourceType == "document" else { return nil }
            let ft: SourceFileType
            switch record.resourceType {
            case "script":     ft = .script
            case "stylesheet": ft = .stylesheet
            case "document":   ft = .document
            default:           ft = .other
            }
            return SourceFile.make(url: record.url, mimeType: record.mimeType, type: ft)
        }
    }
}
