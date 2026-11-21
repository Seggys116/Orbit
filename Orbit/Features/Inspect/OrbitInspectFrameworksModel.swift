import Foundation
import WebKit


enum FWTab: String, CaseIterable, Identifiable {
    case devServer = "Dev Server"
    case components = "Components"
    case data = "Data"
    case routes = "Routes"
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
         "fw.overlay", "fw.editResult", "fw.globalStored", "fw.launchResult",
         "fw.devSocket", "fw.devFrame", "fw.devEvent", "fw.devProbe", "fw.devActionResult", "fw.devEnv"]
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
    /// Why there is no tree, in terms of what the page has; nil when there is one or none has been asked for yet.
    var treeNote: String?
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


    /// Dev server surface: sockets, decoded events and issues come from the page's HMR traffic, signals from its globals.
    var devState = FWDevState()
    var devProbe = FWDevProbe()
    var devActionMessage: String?
    var devActionSucceeded = true
    var devBusyAction: String?
    var devEnvEntries: [FWDevEnvEntry] = []
    var devEnvMessage: String?
    var devEnvLoading = false
    var routeNavigationMessage: String?
    var draftCookiePresent = false
    @ObservationIgnored private var devOrigin: String?
    @ObservationIgnored private var pendingLaunch: (file: String, line: Int?, column: Int?)?

    /// The probe plus what only the browser's cookie store can say.
    var effectiveProbe: FWDevProbe {
        var probe = devProbe
        if draftCookiePresent { probe.signals.insert(FWSignal.draftModeCookie.rawValue) }
        return probe
    }

    var devResolution: FWDevResolution {
        FWDevLogic.resolve(detections: detections, probe: effectiveProbe, state: devState)
    }

    var devControls: [FWDevLogic.ControlState] {
        FWDevLogic.controls(resolution: devResolution, probe: effectiveProbe)
    }

    var devRenderInfo: [FWDevLogic.InfoRow] {
        FWDevLogic.renderInfo(resolution: devResolution, probe: effectiveProbe, state: devState,
                              headers: OrbitFrameworksLogic.responseHeaders(from: session?.network.records ?? []))
    }

    var devEnvironment: [FWDevEnvEntry] { devProbe.env + devEnvEntries }

    /// Vite is the only server that injects import.meta.env where a page can read it back.
    var canLoadViteEnv: Bool { devProbe.has(.viteClient) }


    var tab: FWTab = .devServer


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
            handleLaunchResult(object)
        case "fw.devSocket":
            handleDevSocket(object)
        case "fw.devFrame":
            handleDevFrame(object)
        case "fw.devEvent":
            handleDevEvent(object)
        case "fw.devProbe":
            handleDevProbe(object)
        case "fw.devActionResult":
            handleDevActionResult(object)
        case "fw.devEnv":
            handleDevEnv(object)
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
        treeNote = nil
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
        resetDevSurface()
        stopPoll()
    }

    func panelDidAppear(force: Bool) {
        guard session?.isPanelVisible == true else { return }
        refresh()
    }

    func panelDidDisappear() {
        stopPoll()
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
        session.command(["op": "fw.devProbe"])
        refreshDraftMode()
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
        // The dev server's own launch endpoint first, then the editor Orbit is configured with.
        if launchThroughDevServer(file: file, line: node.sourceLine, column: node.sourceCol) { return }
        session?.reveal(sourceURL: file, line: node.sourceLine, column: node.sourceCol)
    }

    /// Asks the detected dev server to open a file. False when no endpoint is known, so the caller falls back.
    @discardableResult
    func launchThroughDevServer(file: String, line: Int?, column: Int?) -> Bool {
        let resolution = devResolution
        guard resolution.mode == .development,
              file.hasPrefix("/") || file.hasPrefix("./") || file.hasPrefix("../") || file.contains(":\\") else { return false }
        let requests = FWDevLogic.editorRequests(adapter: resolution.adapter, file: file, line: line, column: column)
        guard !requests.isEmpty, let session else { return false }
        launchAttemptActive = true
        launchError = nil
        pendingLaunch = (file, line, column)
        session.command(["op": "fw.launch", "requests": requests] as [String: Any])
        return true
    }

    private func handleLaunchResult(_ object: [String: Any]) {
        launchAttemptActive = false
        let pending = pendingLaunch
        pendingLaunch = nil
        if OrbitInspectDecode.bool(object, "ok") {
            launchError = nil
            return
        }
        let status = OrbitInspectDecode.integer(object, "status")
        let reason = status == 0 ? "The dev server didn't respond." : "The dev server returned HTTP \(status)."
        guard let pending, let session else { launchError = reason; return }
        // Falling back keeps "open in editor" working for servers without a launch route.
        let opened = OrbitInspectEditorLauncher.open(sourceURL: pending.file, line: pending.line, column: pending.column, session: session)
        launchError = opened ? nil : reason + " No local editor could open it either."
    }

    /// Build errors carry file paths, runtime errors usually carry script URLs; the former go to the editor, the latter to Sources.
    func openIssueInEditor(_ issue: FWDevIssue) {
        guard let file = issue.file, let session else { return }
        if launchThroughDevServer(file: file, line: issue.line, column: issue.column) { return }
        _ = OrbitInspectEditorLauncher.open(sourceURL: file, line: issue.line, column: issue.column, session: session)
    }

    func revealIssueInSources(_ issue: FWDevIssue) {
        guard let file = issue.file else { return }
        session?.reveal(sourceURL: file, line: issue.line, column: issue.column)
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


    /// Goes through the framework's own router when the page exposes one, so the route changes without a page load.
    func openRoute(path: String) {
        guard let session else { return }
        routeNavigationMessage = nil
        let strategy = FWDevLogic.navigationStrategy(adapterID: devResolution.adapter?.id, probe: effectiveProbe)
        session.command(["op": "fw.devAction", "action": "navigate", "path": path, "strategy": strategy.rawValue] as [String: Any])
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
        e.classTokens = Set(OrbitInspectDecode.strings(object, "classTokens"))
        e.cssVariablePrefixes = Set(OrbitInspectDecode.strings(object, "cssVariablePrefixes"))
        e.hostname = OrbitInspectDecode.string(object, "hostname")
        e.pageURL = session?.pageURL ?? ""

        // Response headers come from the Network tool's records, not from the page script.
        e.responseHeaders = OrbitFrameworksLogic.responseHeaders(from: session?.network.records ?? [])

        detections = OrbitFrameworksLogic.detect(evidence: e)

        let newHMR = OrbitFrameworksLogic.hmrStatus(from: session?.network.records ?? [])
        // The page's own socket observations are exact; the Network log is only a fallback for sockets opened before Orbit attached.
        if devState.primarySocket == nil, newHMR.kind != nil || newHMR.wsURL != nil {
            hmrStatus = newHMR
        }
    }

    private func handleTree(_ object: [String: Any]) {
        isTreeLoading = false
        treeNote = OrbitInspectDecode.optionalString(object, "note")
        guard let result = OrbitInspectDecode.object(object, "result") else {
            componentNodes = []
            componentRoots = []
            componentFramework = nil
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


    // MARK: Dev server

    private static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Epoch milliseconds from the page; anything outside a plausible range is the page's mistake, so the receive time stands in.
    private func timestamp(_ object: [String: Any]) -> Double {
        guard let at = OrbitInspectDecode.number(object, "at"), at > 0, at < 4_102_444_800_000 else { return Self.now() }
        return at
    }

    private static func origin(of urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), let host = url.host else { return nil }
        return "\(url.scheme ?? "")://\(host):\(url.port ?? 0)"
    }

    /// A new document drops sockets and issues; the timeline survives a reload of the same origin so the reload itself shows up.
    private func resetDevSurface() {
        let origin = Self.origin(of: session?.pageURL)
        let keep = origin != nil && origin == devOrigin
        devOrigin = origin
        devState.resetForNewDocument(keepHistory: keep)
        if keep { devState.addEvent(kind: .navigation, title: "Page loaded", at: Self.now()) }
        devProbe = FWDevProbe()
        devActionMessage = nil
        devBusyAction = nil
        devEnvEntries = []
        devEnvMessage = nil
        devEnvLoading = false
        routeNavigationMessage = nil
        draftCookiePresent = false
        pendingLaunch = nil
        launchAttemptActive = false
    }

    private func handleDevSocket(_ object: [String: Any]) {
        let id = OrbitInspectDecode.integer(object, "id")
        guard id > 0 else { return }
        let at = timestamp(object)
        let host = URL(string: session?.pageURL ?? "")?.host ?? ""
        let hints: Set<FWWireProtocol> = OrbitInspectDecode.string(object, "hint") == "parcel" ? [.parcel] : []
        devState.socketOpened(id: id, url: OrbitInspectDecode.string(object, "url"),
                              subprotocols: OrbitInspectDecode.strings(object, "protocols"),
                              transport: OrbitInspectDecode.string(object, "transport"),
                              pageHost: host, hints: hints, at: at)
        let code = object["code"].flatMap { OrbitInspectDecode.integer($0) }
        switch OrbitInspectDecode.string(object, "state") {
        case "open": devState.socketState(id: id, state: .open, code: nil, at: at)
        case "closed": devState.socketState(id: id, state: .closed, code: code, at: at)
        case "error": devState.socketState(id: id, state: .failed, code: nil, at: at)
        default: break
        }
        syncHMRStatus()
    }

    private func handleDevFrame(_ object: [String: Any]) {
        let id = OrbitInspectDecode.integer(object, "id")
        let binary = OrbitInspectDecode.bool(object, "binary")
        devState.receiveFrame(socketID: id, text: OrbitInspectDecode.string(object, "data"),
                              binaryLength: binary ? OrbitInspectDecode.integer(object, "len") : nil,
                              at: timestamp(object))
        syncHMRStatus()
    }

    private func handleDevEvent(_ object: [String: Any]) {
        let line = object["line"].flatMap { OrbitInspectDecode.integer($0) }
        let column = object["col"].flatMap { OrbitInspectDecode.integer($0) }
        guard let event = FWDevWire.decodePageEvent(
            name: OrbitInspectDecode.string(object, "name"),
            detail: OrbitInspectDecode.optionalString(object, "detail"),
            message: OrbitInspectDecode.optionalString(object, "message"),
            file: OrbitInspectDecode.optionalString(object, "file"),
            line: line, column: column,
            stack: OrbitInspectDecode.optionalString(object, "stack")) else { return }
        devState.apply(event, at: timestamp(object))
    }

    private func handleDevProbe(_ object: [String: Any]) {
        var probe = FWDevProbe()
        probe.signals = Set(OrbitInspectDecode.strings(object, "signals"))
        probe.facts = OrbitInspectDecode.stringMap(object, "facts")
        probe.overlayHosts = OrbitInspectDecode.strings(object, "overlays")
        probe.overlayHidden = OrbitInspectDecode.bool(object, "overlayHidden")
        probe.serviceWorkers = OrbitInspectDecode.integer(object, "serviceWorkers")
        probe.cacheEntries = OrbitInspectDecode.integer(object, "cacheEntries")
        probe.pathname = OrbitInspectDecode.string(object, "pathname")
        probe.env = OrbitInspectDecode.objects(object, "env").compactMap { entry in
            guard let key = entry["key"] as? String, !key.isEmpty else { return nil }
            return FWDevEnvEntry(key: key, value: entry["value"] as? String ?? "", source: entry["source"] as? String ?? "")
        }
        devProbe = probe
    }

    private func handleDevActionResult(_ object: [String: Any]) {
        let action = OrbitInspectDecode.string(object, "action")
        let message = OrbitInspectDecode.string(object, "message")
        let ok = OrbitInspectDecode.bool(object, "ok")
        if action == "navigate" {
            routeNavigationMessage = message
            return
        }
        devActionMessage = message.isEmpty ? nil : message
        devActionSucceeded = ok
        if OrbitInspectDecode.bool(object, "pending") { return }
        devBusyAction = nil
        if action == "toggleOverlay" || action == "clearCaches" { session?.command(["op": "fw.devProbe"]) }
    }

    private func handleDevEnv(_ object: [String: Any]) {
        devEnvLoading = false
        devEnvEntries = OrbitInspectDecode.objects(object, "entries").compactMap { entry in
            guard let key = entry["key"] as? String, !key.isEmpty else { return nil }
            return FWDevEnvEntry(key: key, value: entry["value"] as? String ?? "", source: entry["source"] as? String ?? "")
        }
        devEnvMessage = OrbitInspectDecode.optionalString(object, "message")
    }

    /// The legacy HMR status mirrors the newest observed socket.
    private func syncHMRStatus() {
        guard let socket = devState.primarySocket, let protocolID = socket.protocolID else { return }
        hmrStatus = FWHMRStatus(kind: protocolID.title, wsURL: socket.url, connected: socket.state == .open)
    }

    func loadViteEnv() {
        guard let session, !devEnvLoading else { return }
        devEnvLoading = true
        devEnvMessage = nil
        session.command(["op": "fw.devEnv"])
    }

    func clearDevTimeline() { devState.clearTimeline() }
    func clearRuntimeIssues() { devState.clearRuntimeIssues() }

    /// Runs one control from the Dev Server tab. Controls the logic reports as unavailable never reach the page.
    func runControl(_ control: FWDevControl) {
        guard let session, devBusyAction == nil,
              devControls.first(where: { $0.control == control })?.enabled == true else { return }
        let resolution = devResolution
        let probe = effectiveProbe
        devActionMessage = nil
        func send(_ object: [String: Any]) {
            devBusyAction = control.rawValue
            session.command(object)
        }
        switch control {
        case .reload:
            session.reloadPage()
        case .hardReload:
            send(["op": "fw.devAction", "action": control.rawValue])
        case .clearCaches, .toggleOverlay, .hmrRefresh:
            send(["op": "fw.devAction", "action": control.rawValue])
        case .softRefresh:
            guard let strategy = FWDevLogic.refreshStrategy(adapterID: resolution.adapter?.id, probe: probe) else { return }
            send(["op": "fw.devAction", "action": control.rawValue, "strategy": strategy.rawValue])
        case .restartServer, .restartClearCache:
            guard case .endpoint(let endpoint)? = resolution.adapter?.restart else { return }
            send(["op": "fw.devRestart", "action": control.rawValue,
                  "requestPath": FWDevLogic.restartRequest(endpoint, clearCache: control == .restartClearCache),
                  "statusPath": endpoint.statusPath])
        case .rebuild:
            send(["op": "fw.devAction", "action": control.rawValue, "path": FWDevLogic.webpackInvalidatePath])
        case .refreshSourceData:
            send(["op": "fw.devAction", "action": control.rawValue, "path": FWDevLogic.gatsbyRefreshPath])
        case .exitDraftMode:
            exitDraftMode()
        }
    }

    // MARK: Draft mode

    /// The draft-mode cookies are httpOnly, so page scripts cannot see them; the browser's cookie store can.
    func refreshDraftMode() {
        guard let store = session?.contents?.webView.configuration.websiteDataStore.httpCookieStore,
              let host = URL(string: session?.pageURL ?? "")?.host else { return }
        store.getAllCookies { [weak self] cookies in
            let present = cookies.contains { Self.isDraftCookie($0, host: host) }
            Task { @MainActor [weak self] in self?.draftCookiePresent = present }
        }
    }

    nonisolated private static func isDraftCookie(_ cookie: HTTPCookie, host: String) -> Bool {
        guard FWDevLogic.draftModeCookieNames.contains(cookie.name) else { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    private func exitDraftMode() {
        guard let session,
              let store = session.contents?.webView.configuration.websiteDataStore.httpCookieStore,
              let host = URL(string: session.pageURL)?.host else { return }
        devBusyAction = FWDevControl.exitDraftMode.rawValue
        Task { @MainActor [weak self] in
            let cookies = await store.allCookies()
            var removed = 0
            for cookie in cookies where Self.isDraftCookie(cookie, host: host) {
                await store.deleteCookie(cookie)
                removed += 1
            }
            guard let self else { return }
            self.draftCookiePresent = false
            self.devBusyAction = nil
            self.devActionSucceeded = removed > 0
            self.devActionMessage = removed > 0 ? "Draft mode cookies removed. Reloading." : "No draft mode cookies were found."
            if removed > 0 { self.session?.reloadPage() }
        }
    }


    private func startPoll() {
        guard pollTask == nil, session?.isPanelVisible == true, session?.panel == .frameworks else { return }
        session?.command(["op": "fw.start", "interval": 3000] as [String: Any])
        pollTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(300))
                guard !Task.isCancelled, let self, let session = self.session else { break }
                if self.tab == .components { session.command(["op": "fw.tree"]) }
                count += 1
                if count % 5 == 0 { self.refreshDraftMode() }
            }
        }
    }

    private func stopPoll() {
        guard let pollTask else { return }
        pollTask.cancel()
        self.pollTask = nil
        session?.command(["op": "fw.stop"])
    }
}
