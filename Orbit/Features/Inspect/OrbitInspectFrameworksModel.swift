import Foundation


enum FWTab: String, CaseIterable, Identifiable {
    case components = "Components"
    case data = "Data"
    case routes = "Routes"
    case devServer = "Dev Server"
    case technologies = "Technologies"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .components: return "square.3.layers.3d"
        case .data: return "doc.text.magnifyingglass"
        case .routes: return "arrow.triangle.branch"
        case .devServer: return "server.rack"
        case .technologies: return "shippingbox"
        }
    }
}


@MainActor
@Observable
final class OrbitFrameworksModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?


    var messageTypes: Set<String> {
        ["fw.evidence", "fw.tree", "fw.data", "fw.routes", "fw.hmr",
         "fw.overlay", "fw.editResult", "fw.globalStored", "fw.launchResult"]
    }


    var primaryName: String? { OrbitFrameworksLogic.primary(among: detections) }


    var detections: [FWDetected] = []
    var techFilter: String = ""
    var isScanning: Bool = false

    var filteredDetections: [FWDetected] {
        guard !techFilter.isEmpty else { return detections }
        let q = techFilter.lowercased()
        return detections.filter { $0.name.lowercased().contains(q) || $0.category.rawValue.lowercased().contains(q) }
    }


    var componentNodes: [FWComponentNode] = []
    var componentRoots: [Int] = []
    var selectedNodeID: Int?
    var componentFilter: String = ""
    var showHostNodes: Bool = false
    var minifiedBanner: Bool = false
    var componentFramework: String?
    var componentsCapped: Bool = false
    var isTreeLoading: Bool = false
    var treeLoadError: String?

    var filteredNodeIDs: Set<Int>? {
        guard !componentFilter.isEmpty else { return nil }
        let q = componentFilter.lowercased()
        let matching = componentNodes.filter {
            $0.name.lowercased().contains(q) ||
            $0.props.values.contains(where: { $0.lowercased().contains(q) })
        }
        return Set(matching.map(\.id))
    }

    var selectedNode: FWComponentNode? {
        guard let id = selectedNodeID else { return nil }
        return componentNodes.first { $0.id == id }
    }


    var dataItems: [FWDataItem] = []
    var selectedDataID: String?
    var isDataLoading: Bool = false

    var selectedDataItem: FWDataItem? {
        guard let id = selectedDataID else { return nil }
        return dataItems.first { $0.id == id }
    }


    var routes: [FWRoute] = []
    var routeFilter: String = ""
    var isRoutesLoading: Bool = false

    var filteredRoutes: [FWRoute] {
        guard !routeFilter.isEmpty else { return routes }
        let q = routeFilter.lowercased()
        return routes.filter { $0.path.lowercased().contains(q) || $0.source.lowercased().contains(q) }
    }


    var hmrStatus: FWHMRStatus = FWHMRStatus()
    var overlayInfo: FWOverlayInfo?
    var editResultMessage: String?


    var launchAttemptActive: Bool = false
    var launchError: String?


    var tab: FWTab = .technologies


    @ObservationIgnored private var pollTask: Task<Void, Never>?


    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard frame.isMain else { return }
        switch type {
        case "fw.evidence":
            handleEvidence(object)
        case "fw.tree":
            handleTree(object)
        case "fw.data":
            handleData(object)
        case "fw.routes":
            handleRoutes(object)
        case "fw.hmr":
            handleHMR(object)
        case "fw.overlay":
            handleOverlay(object)
        case "fw.editResult":
            let ok = OrbitInspectDecode.bool(object, "ok")
            let err = OrbitInspectDecode.string(object, "err")
            editResultMessage = ok ? "Applied." : "Could not apply: \(err)"
        case "fw.globalStored":
            let name = OrbitInspectDecode.string(object, "name")
            editResultMessage = "Stored component as \(name) in the console."
        case "fw.launchResult":
            launchAttemptActive = false
            if OrbitInspectDecode.bool(object, "ok") {
                launchError = nil
            } else {
                let status = OrbitInspectDecode.integer(object, "status")
                launchError = status == 0 ? "Dev server didn't respond." : "Dev server returned HTTP \(status)."
            }
        default:
            break
        }
    }

    func pageDidReset(preservingLog: Bool) {
        detections = []
        componentNodes = []
        componentRoots = []
        selectedNodeID = nil
        componentFilter = ""
        minifiedBanner = false
        componentFramework = nil
        componentsCapped = false
        isTreeLoading = false
        treeLoadError = nil
        dataItems = []
        selectedDataID = nil
        isDataLoading = false
        routes = []
        isRoutesLoading = false
        hmrStatus = FWHMRStatus()
        overlayInfo = nil
        editResultMessage = nil
        launchError = nil
        isScanning = false
        stopPoll()
    }

    func panelDidAppear(force: Bool) {
        refresh()
    }


    func refresh() {
        guard let session else { return }
        isScanning = true
        isTreeLoading = true
        isDataLoading = true
        isRoutesLoading = true
        session.command(["op": "fw.scan"])
        session.command(["op": "fw.tree"])
        session.command(["op": "fw.data"])
        session.command(["op": "fw.routes"])
        startPoll()
    }


    func selectTab(_ newTab: FWTab) {
        tab = newTab
    }


    func selectComponent(id: Int) {
        selectedNodeID = id
        if let node = componentNodes.first(where: { $0.id == id }),
           let domID = node.domNodeID {
            session?.highlight(nodeID: domID)
        }
    }

    func revealComponentInElements(id: Int) {
        if let node = componentNodes.first(where: { $0.id == id }),
           let domID = node.domNodeID {
            session?.reveal(nodeID: domID)
        }
    }

    /// Called by Elements when the element selection changes; finds the nearest component.
    func elementSelectionChanged(nodeID: Int) {
        let match = componentNodes.first { $0.domNodeID == nodeID }
        if let match {
            selectedNodeID = match.id
        }
    }

    func openSourceForComponent(id: Int) {
        guard let node = componentNodes.first(where: { $0.id == id }),
              let file = node.sourceFile, !file.isEmpty else { return }
        // Try dev server launch endpoint first, then fall back to editor launcher
        let isNext = detections.contains(where: { $0.name == "Next.js" })
        let isVite = detections.contains(where: { $0.name == "Vite" })
        let isDevServer = !hmrStatus.kind.isNilOrEmpty
        if isDevServer {
            let devserver = isNext ? "next" : (isVite ? "vite" : "")
            if !devserver.isEmpty {
                launchAttemptActive = true
                launchError = nil
                session?.command([
                    "op": "fw.launch",
                    "file": file,
                    "line": node.sourceLine ?? 1,
                    "col": node.sourceCol ?? 1,
                    "devserver": devserver
                ] as [String: Any])
                return
            }
        }
        guard let session else { return }
        session.reveal(sourceURL: file, line: node.sourceLine, column: node.sourceCol)
    }

    func openInEditorForComponent(id: Int) {
        guard let node = componentNodes.first(where: { $0.id == id }),
              let file = node.sourceFile, !file.isEmpty,
              let session else { return }
        OrbitInspectEditorLauncher.open(sourceURL: file, line: node.sourceLine, column: node.sourceCol, session: session)
    }

    func copyComponentProps(id: Int) {
        guard let node = componentNodes.first(where: { $0.id == id }) else { return }
        let json = JSONSerialization.isValidJSONObject(node.props)
            ? try? JSONSerialization.data(withJSONObject: node.props, options: [.prettyPrinted, .sortedKeys])
            : nil
        if let json, let text = String(data: json, encoding: .utf8) {
            session?.copy(text)
        }
    }

    func storeComponentAsGlobal() {
        session?.command(["op": "fw.global"])
    }

    func editProp(domNodeID: Int, name: String, value: String) {
        editResultMessage = nil
        session?.command(["op": "fw.edit", "domId": domNodeID, "kind": "prop", "name": name, "value": value] as [String: Any])
    }

    func editHookState(domNodeID: Int, hookIndex: Int, value: String) {
        editResultMessage = nil
        session?.command(["op": "fw.edit", "domId": domNodeID, "kind": "hook", "hookIndex": hookIndex, "value": value] as [String: Any])
    }


    func openRoute(path: String) {
        guard let session else { return }
        Task {
            _ = try? await session.evaluate("location.href = \(JSON.quote(path));")
        }
    }


    func selectData(id: String) {
        selectedDataID = id
    }

    func copyDataItem(id: String) {
        guard let item = dataItems.first(where: { $0.id == id }),
              let json = item.rawJSON else { return }
        session?.copy(json)
    }


    private func handleEvidence(_ object: [String: Any]) {
        isScanning = false
        var e = FWEvidenceBundle()
        e.globals = Set(OrbitInspectDecode.strings(object, "globals"))

        if let versions = OrbitInspectDecode.object(object, "globalVersions") {
            for (k, v) in versions { if let s = v as? String { e.globalVersions[k] = s } }
        }
        e.domMarkers = Set(OrbitInspectDecode.strings(object, "domMarkers"))
        e.scriptURLs = OrbitInspectDecode.strings(object, "scriptURLs")
        e.linkURLs = OrbitInspectDecode.strings(object, "linkURLs")
        e.metaGenerators = OrbitInspectDecode.strings(object, "metaGenerators")
        e.hostname = OrbitInspectDecode.string(object, "hostname")
        e.pageURL = session?.pageURL ?? ""

        // Response headers come from the Network tool's records, not from the page script.
        e.responseHeaders = OrbitFrameworksLogic.responseHeaders(from: session?.network.records ?? [])

        detections = OrbitFrameworksLogic.detect(evidence: e)

        let newHMR = OrbitFrameworksLogic.hmrStatus(from: session?.network.records ?? [])
        if newHMR.kind != nil || newHMR.wsURL != nil {
            hmrStatus = newHMR
        }
    }

    private func handleTree(_ object: [String: Any]) {
        isTreeLoading = false
        guard let result = OrbitInspectDecode.object(object, "result") else {
            treeLoadError = nil
            return
        }
        componentFramework = OrbitInspectDecode.optionalString(result, "framework")
        minifiedBanner = OrbitInspectDecode.bool(result, "minified")
        componentsCapped = OrbitInspectDecode.bool(result, "capped")

        let rawNodes = OrbitInspectDecode.objects(result, "nodes")
        componentNodes = rawNodes.compactMap { decodeComponentNode($0) }
        // Roots arrive as an array of plain integers from the JS
        if let arr = result["roots"] as? [Any] {
            componentRoots = arr.compactMap { jsonInt($0) }
        } else {
            componentRoots = []
        }
        treeLoadError = nil
    }

    private func handleData(_ object: [String: Any]) {
        isDataLoading = false
        let rawItems = OrbitInspectDecode.objects(object, "items")
        dataItems = rawItems.compactMap { decodeDataItem($0) }
        if selectedDataID == nil || !dataItems.contains(where: { $0.id == selectedDataID }) {
            selectedDataID = dataItems.first?.id
        }
    }

    private func handleRoutes(_ object: [String: Any]) {
        isRoutesLoading = false
        let rawRoutes = OrbitInspectDecode.objects(object, "routes")
        routes = rawRoutes.compactMap { decodeRoute($0) }
    }

    private func handleHMR(_ object: [String: Any]) {
        let kind = OrbitInspectDecode.optionalString(object, "kind")
        let wsURL = OrbitInspectDecode.optionalString(object, "wsURL")
        let connected = OrbitInspectDecode.bool(object, "connected")
        hmrStatus = FWHMRStatus(kind: kind, wsURL: wsURL, connected: connected)
    }

    private func handleOverlay(_ object: [String: Any]) {
        let visible = OrbitInspectDecode.bool(object, "visible")
        if !visible {
            overlayInfo = nil
            return
        }
        let message = OrbitInspectDecode.string(object, "message")
        let file = OrbitInspectDecode.optionalString(object, "file")
        let line = OrbitInspectDecode.integer(object, "line") == 0 ? nil : OrbitInspectDecode.integer(object, "line") as Int?
        let source = OrbitInspectDecode.string(object, "source")
        overlayInfo = FWOverlayInfo(message: message, file: file, line: line, col: nil, source: source)
    }


    private func decodeComponentNode(_ d: [String: Any]) -> FWComponentNode? {
        guard let rawID = d["id"], let id = jsonInt(rawID), id > 0 else { return nil }
        var node = FWComponentNode(id: id)
        node.name = d["name"] as? String ?? "?"
        node.isHost = (d["isHost"] as? Bool) ?? false
        node.key = d["key"] as? String
        node.domNodeID = (d["domId"] as? NSNumber).map(\.intValue)
        node.sourceFile = (d["src"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        node.sourceLine = (d["srcLine"] as? NSNumber).map(\.intValue)
        node.sourceCol = (d["srcCol"] as? NSNumber).map(\.intValue)
        node.ownerName = d["owner"] as? String
        if let rawProps = d["props"] as? [String: Any] {
            for (k, v) in rawProps { node.props[k] = v as? String ?? "\(v)" }
        }
        if let rawHooks = d["hooks"] as? [[String: Any]] {
            node.hooks = rawHooks.compactMap { h in
                guard let rawIdx = h["i"], let i = jsonInt(rawIdx),
                      let l = h["l"] as? String,
                      let v = h["v"] as? String else { return nil }
                return FWHookItem(index: i, label: l, value: v, approximate: true)
            }
        }
        if let arr = d["children"] as? [Any] { node.childIDs = arr.compactMap { jsonInt($0) } }
        node.framework = d["framework"] as? String ?? "react"
        node.minified = (d["minified"] as? Bool) ?? false
        return node
    }

    private func jsonInt(_ v: Any) -> Int? {
        OrbitInspectDecode.integer(v)
    }

    private func decodeDataItem(_ d: [String: Any]) -> FWDataItem? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let label = d["label"] as? String ?? id
        let kindStr = d["kind"] as? String ?? "json"
        let kind: FWDataKind = FWDataKind(rawValue: kindStr) ?? .json
        var item = FWDataItem(id: id, label: label, kind: kind)
        item.rawJSON = d["json"] as? String
        item.framework = d["framework"] as? String

        if kind == .flight, let chunks = d["chunks"] as? [String] {
            item.flightRows = OrbitFrameworksLogic.parseFlightPayload(chunks)
        } else if kind == .flight, let chunk = d["json"] as? String {
            item.flightRows = OrbitFrameworksLogic.parseFlightPayload([chunk])
        }

        if kind == .globals, let rawGlobals = d["globals"] as? [[String: Any]] {
            item.globals = rawGlobals.compactMap { g in
                guard let name = g["name"] as? String else { return nil }
                return FWGlobalEntry(name: name, preview: g["preview"] as? String ?? "")
            }
        }

        return item
    }

    private func decodeRoute(_ d: [String: Any]) -> FWRoute? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let path = d["path"] as? String ?? id
        var route = FWRoute(id: id, path: path, source: d["source"] as? String ?? "")
        route.isCurrent = d["current"] as? Bool ?? false
        route.isDynamic = d["dynamic"] as? Bool ?? false
        if let rawParams = d["params"] as? [String: String] { route.params = rawParams }
        return route
    }


    private func startPoll() {
        guard pollTask == nil else { return }
        session?.command(["op": "fw.start", "interval": 3000] as [String: Any])
        pollTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self, self.session != nil else { return }
                    // Only refresh tree while panel is the frameworks panel
                    if self.session?.panel == .frameworks {
                        self.session?.command(["op": "fw.tree"])
                        count += 1
                        if count % 5 == 0 { self.session?.command(["op": "fw.scan"]) }
                    }
                }
            }
        }
    }

    private func stopPoll() {
        session?.command(["op": "fw.stop"])
        pollTask?.cancel()
        pollTask = nil
    }
}


private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self == nil || self!.isEmpty }
}

private enum JSON {
    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
