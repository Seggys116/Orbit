import Foundation
import WebKit

@MainActor
@Observable
final class OrbitConsoleModel: OrbitInspectModule {

    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> { ["con.batch"] }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard type == "con.batch" else { return }
        let dicts = OrbitInspectDecode.objects(object, "entries")
        guard !dicts.isEmpty else { return }
        ingest(dicts)
    }

    func pageDidReset(preservingLog: Bool) {
        pageCounter += 1
        currentGroupDepth = 0
        if !preservingLog {
            entries.removeAll()
            collapsedGroupIds.removeAll()
            _errorCount = 0
            _errorMessages.removeAll()
            expandedProps.removeAll()
        } else if let url = session?.pageURL, !url.isEmpty {
            append(ConEntry.navigation(id: "nav_\(pageCounter)", url: url))
        }
        updateDisplay()
    }

    func panelDidAppear(force: Bool) {
        if force { updateDisplay() }
        inputFocusRequested = true
    }


    /// Newest 5000 entries, oldest first. A ring buffer, so a full log trims in O(1) per append.
    private(set) var entries = OrbitRingBuffer<ConEntry>(capacity: 5000)
    private(set) var displayEntries: [ConEntry] = []
    private(set) var levelCounts: [ConFilterLevel: Int] = [:]

    var filterLevel: ConFilterLevel = .all {
        didSet { if filterLevel != oldValue { updateDisplay() } }
    }
    var filterText: String = "" {
        didSet { if filterText != oldValue { updateDisplay() } }
    }
    var groupSimilar: Bool = true {
        didSet { if groupSimilar != oldValue { updateDisplay() } }
    }
    var showTimestamps: Bool = false
    var collapsedGroupIds: Set<String> = []
    var inputFocusRequested: Bool = false
    var expandedProps: [Int: ConExpandedState] = [:]


    private var _errorCount: Int = 0
    private var _errorMessages: [String] = []
    var errorCount: Int { _errorCount }
    var errorMessages: [String] { _errorMessages }


    var inputText: String = ""
    @ObservationIgnored var history = ConHistory()
    @ObservationIgnored private var replSeq = 0


    @ObservationIgnored private var pageCounter: Int = 0
    @ObservationIgnored private var currentGroupDepth: Int = 0

    /// Batches can land several times per frame, so the filtered display list is rebuilt once per frame.
    @ObservationIgnored private var displayDirty = false
    @ObservationIgnored private var displayFlushScheduled = false
    private static let flushDelay: Duration = .milliseconds(16)


    func clear() {
        entries.removeAll()
        collapsedGroupIds.removeAll()
        _errorCount = 0
        _errorMessages.removeAll()
        expandedProps.removeAll()
        currentGroupDepth = 0
        displayEntries.removeAll()
        levelCounts = [:]
        session?.command(["op": "con.clear"])
    }

    func requestInputFocus() {
        inputFocusRequested = true
    }


    private func ingest(_ dicts: [[String: Any]]) {
        var added: [ConEntry] = []

        for dict in dicts {
            let lvl = OrbitInspectDecode.string(dict, "level")
            if lvl == "clear" {
                entries.removeAll()
                collapsedGroupIds.removeAll()
                _errorCount = 0
                _errorMessages.removeAll()
                added.removeAll()
                currentGroupDepth = 0
                continue
            }

            guard var entry = ConEntry.decode(dict, groupDepth: &currentGroupDepth, pageCounter: pageCounter) else { continue }
            if entry.isGroupEnd { continue }

            if groupSimilar {
                let lastEntry = added.last ?? entries.last
                if let last = lastEntry,
                   let key = OrbitConsoleLogic.repeatKey(level: entry.level, plainText: entry.plainText),
                   OrbitConsoleLogic.repeatKey(level: last.level, plainText: last.plainText) == key {
                    if !added.isEmpty {
                        added[added.count - 1].repeatCount += 1
                    } else if !entries.isEmpty {
                        entries[entries.count - 1].repeatCount += 1
                    }
                    if entry.level.isError { _errorCount += 1 }
                    continue
                }
            }

            if entry.level.isError || entry.level == .assert_ {
                _errorCount += 1
                _errorMessages.append(entry.plainText)
                if _errorMessages.count > 200 {
                    _errorMessages.removeFirst(_errorMessages.count - 200)
                }
            }

            added.append(entry)
        }

        // A repeat-count bump above changes an existing row without adding one, so always refresh.
        for entry in added { entries.append(entry) }
        scheduleDisplayUpdate()
    }

    private func append(_ entry: ConEntry) {
        entries.append(entry)
        scheduleDisplayUpdate()
    }


    private func scheduleDisplayUpdate() {
        displayDirty = true
        guard !displayFlushScheduled else { return }
        displayFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            self?.displayFlushScheduled = false
            self?.flushDisplayIfDirty()
        }
    }

    func flushDisplayIfDirty() {
        if displayDirty { updateDisplay() }
    }

    func updateDisplay() {
        displayDirty = false
        let query = OrbitConsoleLogic.parseFilterQuery(filterText)
        var result: [ConEntry] = []
        var collapseStack: [Int] = []

        for entry in entries {
            while let top = collapseStack.last, entry.groupDepth <= top {
                collapseStack.removeLast()
            }
            if let top = collapseStack.last, entry.groupDepth > top { continue }
            if filterLevel != .all && !filterLevel.matches(entry.level) { continue }
            if !query.isEmpty {
                let searchText = entry.plainText + " " + entry.sourceURL
                if !OrbitConsoleLogic.matches(text: searchText, query: query) { continue }
            }
            result.append(entry)
            if entry.isGroupStart && collapsedGroupIds.contains(entry.id) {
                collapseStack.append(entry.groupDepth)
            }
        }
        displayEntries = result
        levelCounts = OrbitConsoleLogic.levelCounts(of: entries)
    }

    func toggleGroup(_ id: String) {
        if collapsedGroupIds.contains(id) { collapsedGroupIds.remove(id) }
        else { collapsedGroupIds.insert(id) }
        updateDisplay()
    }

    func count(for level: ConFilterLevel) -> Int {
        guard level != .all else { return entries.count }
        return levelCounts[level] ?? 0
    }


    func submitInput() {
        let code = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        history.push(code)
        inputText = ""
        replSeq += 1
        let cmdId = "repl_cmd_\(pageCounter)_\(replSeq)"
        append(ConEntry.command(id: cmdId, text: code, depth: currentGroupDepth))
        Task { await evaluateREPL(code, seqId: replSeq) }
    }

    /// Completion-handler form of callAsyncJavaScript: the Swift `async` overload returns `()` instead of the script's value on current WebKit.
    private static func callAsync(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func isSyntaxError(_ error: NSError) -> Bool {
        let message = (error.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
        return message.contains("SyntaxError") || message.contains("Unexpected") || message.contains("Expected")
    }

    private func evaluateREPL(_ code: String, seqId: Int) async {
        guard let webView = session?.contents?.webView else {
            appendReplError(seqId: seqId, message: "No page loaded", stack: ""); return
        }
        let depth = currentGroupDepth
        // Expression mode runs inside an async function, so `await` works and the page CSP never sees an eval.
        let body = """
        const __h = window.__orbitInspect || {};
        var $ = (typeof window.$ === 'function') ? window.$ : function(s, r){ return (r || document).querySelector(s); };
        var $$ = (typeof window.$$ === 'function') ? window.$$ : function(s, r){ return Array.from((r || document).querySelectorAll(s)); };
        var $x = function(p, c){
          var r = document.evaluate(p, c || document, null, XPathResult.ANY_TYPE, null), items = [], n;
          while ((n = r.iterateNext())) items.push(n);
          return items;
        };
        var $0 = __h.el_selectedElement ? __h.el_selectedElement() : null;
        var $r = __h.fw_selectedComponent ? __h.fw_selectedComponent() : null;
        var $_ = __h.con_lastResult;
        var __res;
        try {
          __res = await (\(code)
          );
        } catch (e_) {
          // Only a parse failure of the whole body may reach Swift; rethrowing a runtime SyntaxError would run the input twice.
          return { __error: true, msg: String(e_ && e_.message || e_), stack: String((e_ && e_.stack) || '') };
        }
        __h.con_lastResult = __res;
        return __h.con_serResult ? __h.con_serResult(__res) : null;
        """
        do {
            var raw: Any?
            var ranAsStatements = false
            do {
                raw = try await Self.callAsync(webView, body)
            } catch let error as NSError where Self.isSyntaxError(error) {
                // Not an expression (`const a = 1`, `if (...) {}`): run it as a script at global scope like a classic REPL.
                ranAsStatements = true
                raw = try await webView.evaluateJavaScript(code)
            }
            let resultId = "repl_res_\(pageCounter)_\(seqId)"
            if ranAsStatements {
                let value: ConSerializedValue = raw == nil || raw is NSNull ? .undefined_ : .string_(String(describing: raw!))
                append(ConEntry.result(id: resultId, value: value, depth: depth))
            } else
            if let dict = raw as? [String: Any], OrbitInspectDecode.bool(dict, "__error") {
                let msg   = OrbitInspectDecode.string(dict, "msg")
                let stack = OrbitInspectDecode.string(dict, "stack")
                append(ConEntry.errorResult(id: resultId, message: msg, stack: stack, depth: depth))
            } else {
                let value: ConSerializedValue
                if let dict = raw as? [String: Any] { value = ConSerializedValue.decode(dict) }
                else if raw == nil { value = .undefined_ }
                else { value = .string_(String(describing: raw!)) }
                append(ConEntry.result(id: resultId, value: value, depth: depth))
            }
        } catch {
            appendReplError(seqId: seqId, message: error.localizedDescription, stack: "")
        }
    }

    private func appendReplError(seqId: Int, message: String, stack: String) {
        let id = "repl_err_\(pageCounter)_\(seqId)"
        append(ConEntry.errorResult(id: id, message: message, stack: stack, depth: currentGroupDepth))
        _errorCount += 1
        _errorMessages.append(message)
    }


    func requestExpansion(registryId: Int) {
        guard expandedProps[registryId] == nil else { return }
        expandedProps[registryId] = .loading
        Task { await fetchProps(registryId: registryId) }
    }

    private func fetchProps(registryId: Int) async {
        guard let webView = session?.contents?.webView else {
            expandedProps[registryId] = .error("No page loaded"); return
        }
        let body = """
        if(!window.__orbitInspect||!window.__orbitInspect.con_getProps)return null;
        return window.__orbitInspect.con_getProps(\(registryId));
        """
        do {
            let raw = try await Self.callAsync(webView, body)
            if let dict = raw as? [String: Any] {
                let own   = (dict["own"] as? [[String: Any]] ?? []).compactMap { ConPropDescriptor.decode($0) }
                let proto = (dict["proto"] as? [String: Any]).map { ConSerializedValue.decode($0) }
                expandedProps[registryId] = .loaded(own: own, proto: proto)
            } else {
                expandedProps[registryId] = .error("Object not in registry")
            }
        } catch {
            expandedProps[registryId] = .error(error.localizedDescription)
        }
    }


    func fetchCompletions(path: [String], prefix: String) async -> [String] {
        guard let webView = session?.contents?.webView else { return [] }
        // jsonLiteral wraps values in an array first: JSONSerialization raises an uncatchable exception for a top-level string.
        guard let pathJSON = OrbitInspectDecode.jsonLiteral(path),
              let prefJSON = OrbitInspectDecode.jsonLiteral(prefix) else { return [] }
        let body = """
        if(!window.__orbitInspect||!window.__orbitInspect.con_completeAt)return[];
        return window.__orbitInspect.con_completeAt(\(pathJSON),\(prefJSON));
        """
        let raw = try? await Self.callAsync(webView, body)
        let candidates = raw as? [String] ?? []
        return OrbitConsoleLogic.rankCompletions(candidates, prefix: prefix)
    }


    func copyEntry(_ entry: ConEntry) {
        session?.copy(entry.args.map { $0.plainText }.joined(separator: " "))
    }

    func copyEntryStack(_ entry: ConEntry) {
        let text = entry.stackFrames
            .map { "\($0.displayName) @ \($0.url):\($0.line):\($0.column)" }
            .joined(separator: "\n")
        session?.copy(text.isEmpty ? entry.plainText : text)
    }

    func copyEntryAsJSON(_ entry: ConEntry) {
        guard let id = entry.args.first?.registryId else { copyEntry(entry); return }
        Task {
            guard let webView = session?.contents?.webView else { return }
            let body = """
            var o=window.__orbitInspect&&window.__orbitInspect._con_reg&&window.__orbitInspect._con_reg.get(\(id));
            try{return JSON.stringify(o,null,2);}catch(e){return String(o);}
            """
            let raw = try? await Self.callAsync(webView, body)
            if let text = raw as? String { session?.copy(text) }
        }
    }

    /// Copies what the log currently shows, so the filter and group collapsing decide the content.
    func copyAllEntries() {
        guard !displayEntries.isEmpty else { return }
        session?.copy(OrbitConsoleLogic.allMessagesText(displayEntries))
    }

    func copyAllEntriesAsJSON() {
        let shown = displayEntries
        guard !shown.isEmpty else { return }
        let ids = Array(Set(shown.compactMap { $0.args.first?.registryId }))
        Task {
            // One page round trip for every object, with the same serialisation as the per-row "Copy as JSON".
            var serialised: [String: String] = [:]
            if !ids.isEmpty,
               let webView = session?.contents?.webView,
               let idsJSON = OrbitInspectDecode.jsonLiteral(ids) {
                let body = """
                var reg=window.__orbitInspect&&window.__orbitInspect._con_reg;
                var out={};
                \(idsJSON).forEach(function(id){
                  var o=reg&&reg.get(id);
                  try{var s=JSON.stringify(o,null,2);if(typeof s==='string')out[id]=s;}catch(e){out[id]=String(o);}
                });
                return out;
                """
                if let raw = try? await Self.callAsync(webView, body) as? [String: String] {
                    serialised = raw
                }
            }
            let items = shown.map { entry -> OrbitConsoleLogic.JSONCopyItem in
                if let id = entry.args.first?.registryId, let text = serialised[String(id)] { return .json(text) }
                return .text(entry.args.map { $0.plainText }.joined(separator: " "))
            }
            session?.copy(OrbitConsoleLogic.jsonArrayText(items))
        }
    }

    func storeAsGlobal(_ entry: ConEntry) {
        guard let id = entry.args.first?.registryId else { return }
        session?.command(["op": "con.storeGlobal", "id": id])
    }

    func exportLog() {
        let lines = entries.map { e -> String in
            let lvl  = e.level.rawValue.uppercased()
            let body = e.args.map { $0.plainText }.joined(separator: " ")
            let src  = e.sourceURL.isEmpty ? "" : " [\(e.shortSource)]"
            return "[\(lvl)]\(src) \(body)"
        }
        OrbitConsoleExport.savePanel(text: lines.joined(separator: "\n"))
    }
}
