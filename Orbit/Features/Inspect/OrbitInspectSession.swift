// One session per page lives as long as the page, so console and network history exist before the panel is opened.

import AppKit
import WebKit

enum OrbitInspectPreferences {
    private static let dockKey = "orbit.inspect.dock"
    private static let breadthKey = "orbit.inspect.breadth"
    private static let panelKey = "orbit.inspect.panel"

    static var dock: OrbitInspectDock {
        get { OrbitDefaults.standard.string(forKey: dockKey).flatMap(OrbitInspectDock.init(rawValue:)) ?? .right }
        set { OrbitDefaults.standard.set(newValue.rawValue, forKey: dockKey) }
    }

    static var breadth: CGFloat {
        get {
            let stored = OrbitDefaults.standard.double(forKey: breadthKey)
            return stored >= 280 ? CGFloat(stored) : 520
        }
        set { OrbitDefaults.standard.set(Double(newValue), forKey: breadthKey) }
    }

    static var panel: OrbitInspectPanel {
        get { OrbitDefaults.standard.string(forKey: panelKey).flatMap(OrbitInspectPanel.init(rawValue:)) ?? .elements }
        set { OrbitDefaults.standard.set(newValue.rawValue, forKey: panelKey) }
    }
}

@MainActor
@Observable
final class OrbitDevToolsStore {
    static let shared = OrbitDevToolsStore()

    private var sessions: [ObjectIdentifier: OrbitInspectSession] = [:]

    private init() {}

    func session(for contents: any WebContents) -> OrbitInspectSession? {
        sessions[ObjectIdentifier(contents)]
    }

    func ensureSession(for contents: WebKitWebContents) -> OrbitInspectSession {
        let key = ObjectIdentifier(contents)
        if let existing = sessions[key] { return existing }
        let created = OrbitInspectSession(contents: contents)
        sessions[key] = created
        return created
    }

    func open(
        _ contents: WebKitWebContents,
        panel: OrbitInspectPanel,
        inspectAt point: CGPoint?,
        armPicker: Bool
    ) {
        guard !contents.isClosed else { return }
        let session = ensureSession(for: contents)
        session.isPresented = true
        if session.pageURL.isEmpty, let url = contents.webView.url { session.pageURL = url.absoluteString }
        // The closed-page stub sends no hello, so the title comes from WebKit.
        if let title = contents.webView.title { session.pageTitle = title }
        session.installFullAgentScript()
        session.attachAgentIfNeeded()
        session.command(["op": "present", "on": true])
        session.attachSubframeAgents()
        session.security.prefetchConnection()
        session.select(panel: panel)
        if panel == .console { session.console.requestInputFocus() }
        if let point {
            session.inspect(at: point)
        } else if armPicker {
            session.startPicker()
        }
        if session.dock == .undocked {
            OrbitInspectWindowController.present(session)
        }
    }

    func close(_ contents: any WebContents) {
        guard let session = sessions[ObjectIdentifier(contents)] else { return }
        session.isPresented = false
        session.device.deactivate()
        session.picking = false
        session.command(["op": "detach"])
        session.detachSubframeAgents()
        session.removeFullAgentScript()
        session.attachPolicy.didDetach()
        session.windowController?.relinquish()
    }

    func pageClosed(_ contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        sessions[key]?.windowController?.relinquish()
        sessions.removeValue(forKey: key)
    }

    func receive(_ body: Any, webView: WKWebView?, isMainFrame: Bool, frameURL: String?, frameInfo: WKFrameInfo? = nil) {
        guard let webView, let contents = WebKitLiveContents.all.first(where: { $0.webView === webView }) else { return }
        guard let object = Self.jsonObject(from: body), let type = object["t"] as? String else { return }
        let session = ensureSession(for: contents)
        if type == "hello", !isMainFrame, let frameInfo { session.noteSubframe(frameInfo) }
        session.receive(
            type: type,
            object: object,
            frame: OrbitInspectFrame(url: frameURL ?? "", isMain: isMainFrame)
        )
    }

    private static func jsonObject(from body: Any) -> [String: Any]? {
        if let object = body as? [String: Any] { return object }
        guard let text = body as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

@MainActor
@Observable
final class OrbitInspectSession {
    weak var contents: WebKitWebContents?
    weak var windowController: OrbitInspectWindowController?

    var isPresented = false
    var panel: OrbitInspectPanel
    var dock: OrbitInspectDock
    var breadth: CGFloat
    var pageTitle = ""
    var pageURL = ""
    var notice: String?
    var picking = false
    var preserveLog = false
    var agentReady = false

    @ObservationIgnored let elements = OrbitElementsModel()
    @ObservationIgnored let console = OrbitConsoleModel()
    @ObservationIgnored let sources = OrbitSourcesModel()
    @ObservationIgnored let network = OrbitNetworkModel()
    @ObservationIgnored let performance = OrbitPerformanceModel()
    @ObservationIgnored let animations = OrbitAnimationsModel()
    @ObservationIgnored let application = OrbitApplicationModel()
    @ObservationIgnored let lighthouse = OrbitLighthouseModel()
    @ObservationIgnored let security = OrbitSecurityModel()
    @ObservationIgnored let frameworks = OrbitFrameworksModel()
    @ObservationIgnored lazy var device = OrbitInspectDeviceModel(
        webView: { [weak self] in self?.contents?.webView },
        baseUserAgent: { [weak self] in self?.contents?.webKitSession.userAgent },
        subframes: { [weak self] in self?.subframes ?? [] }
    )

    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored var attachPolicy = OrbitInspectAttachPolicy()
    /// WebKit offers no list of a page's frames and main-frame evaluation never reaches a cross-origin child, so these hello handles are kept.
    @ObservationIgnored private(set) var subframes: [WKFrameInfo] = []
    private static let maxTrackedSubframes = 64

    func noteSubframe(_ frame: WKFrameInfo) {
        subframes.append(frame)
        if subframes.count > Self.maxTrackedSubframes { subframes.removeFirst(subframes.count - Self.maxTrackedSubframes) }
    }

    var modules: [any OrbitInspectModule] {
        [elements, console, sources, network, performance, animations, application, lighthouse, security, frameworks]
    }

    var windowTitle: String {
        pageTitle.isEmpty ? "Inspect" : "Inspect — \(pageTitle)"
    }

    init(contents: WebKitWebContents) {
        self.contents = contents
        self.panel = OrbitInspectPreferences.panel
        self.dock = OrbitInspectPreferences.dock
        self.breadth = OrbitInspectPreferences.breadth
        for module in modules { module.session = self }
    }


    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        switch type {
        case "hello":
            // Anything in this message is the page's word, so the URL and the evidence reset come only from WebKit's commit (documentDidCommit).
            guard frame.isMain else { return }
            attachPolicy.didHello(agentAttached: OrbitInspectDecode.bool(object, "attached"))
            agentReady = OrbitInspectDecode.integer(object, "version") >= OrbitInspectAgent.version
            pageTitle = OrbitInspectDecode.string(object, "title")
            windowController?.updateTitle()
            if isPresented {
                command(["op": "present", "on": true])
                refresh(force: false)
            }
        case "navigate":
            guard frame.isMain else { return }
            if let url = contents?.webView.url?.absoluteString { pageURL = url }
            pageTitle = OrbitInspectDecode.string(object, "title")
            windowController?.updateTitle()
        case "picking":
            picking = OrbitInspectDecode.bool(object, "on")
        case "agentError":
            notice = "\(OrbitInspectDecode.string(object, "op")): \(OrbitInspectDecode.string(object, "message"))"
        default:
            for module in modules where module.messageTypes.contains(type) {
                module.receive(type: type, object: object, frame: frame)
            }
        }
    }

    /// The URL is WebKit's and a page cannot trigger this by posting a message, so it, not the agent's hello, starts a new page in every tool.
    func documentDidCommit(url: URL?) {
        pageURL = url?.absoluteString ?? ""
        subframes.removeAll()
        // A closed inspector's pages carry only the early-capture stub, so the next command has to inject the agent itself.
        if !isPresented { agentReady = false }
        for module in modules { module.pageDidReset(preservingLog: preserveLog) }
        picking = false
    }

    private var userContentController: WKUserContentController? {
        contents?.webView.configuration.userContentController
    }

    /// While open, every document in this tab gets the full agent at document start, so reloads and navigations are fully instrumented.
    func installFullAgentScript() {
        guard let controller = userContentController else { return }
        OrbitInspectAgent.setFullAgentScript(true, on: controller)
    }

    func removeFullAgentScript() {
        guard let controller = userContentController else { return }
        OrbitInspectAgent.setFullAgentScript(false, on: controller)
    }

    /// Frames already loaded when the inspector opens only have the stub, so the agent is loaded into the ones that said hello.
    func attachSubframeAgents() {
        guard let webView = contents?.webView, !subframes.isEmpty else { return }
        let frames = subframes
        guard let attach = Self.invocation(["op": "attach"], inject: false),
              let attachWithAgent = Self.invocation(["op": "attach"], inject: true) else { return }
        Task { @MainActor in
            for frame in frames {
                let loaded = try? await webView.evaluateJavaScript("!!window.__orbitInspect", in: frame, contentWorld: .page)
                _ = try? await webView.evaluateJavaScript((loaded as? Bool) == true ? attach : attachWithAgent, in: frame, contentWorld: .page)
            }
        }
    }

    /// Frames get no commands of their own, so closing detaches their agents here to stop the work in them.
    func detachSubframeAgents() {
        guard let webView = contents?.webView, !subframes.isEmpty,
              let detach = Self.invocation(["op": "detach"], inject: false) else { return }
        let frames = subframes
        Task { @MainActor in
            for frame in frames {
                _ = try? await webView.evaluateJavaScript(detach, in: frame, contentWorld: .page)
            }
        }
    }

    /// Commands run in order, so the snapshot requests that follow via panelDidAppear reach a fully attached agent.
    func attachAgentIfNeeded() {
        if attachPolicy.takeAttachRequest() { command(["op": "attach"]) }
    }

    func select(panel: OrbitInspectPanel) {
        self.panel = panel
        OrbitInspectPreferences.panel = panel
        module(for: panel).panelDidAppear(force: false)
    }

    func refresh(force: Bool) {
        module(for: panel).panelDidAppear(force: force)
    }

    func module(for panel: OrbitInspectPanel) -> any OrbitInspectModule {
        switch panel {
        case .elements: elements
        case .console: console
        case .sources: sources
        case .network: network
        case .performance: performance
        case .animations: animations
        case .application: application
        case .lighthouse: lighthouse
        case .security: security
        case .frameworks: frameworks
        }
    }


    func setDock(_ dock: OrbitInspectDock) {
        self.dock = dock
        OrbitInspectPreferences.dock = dock
        if dock == .undocked {
            OrbitInspectWindowController.present(self)
        } else {
            windowController?.relinquish()
        }
    }

    func setBreadth(_ breadth: CGFloat) {
        self.breadth = breadth
        OrbitInspectPreferences.breadth = breadth
    }

    func dismiss() {
        guard let contents else { return }
        OrbitDevToolsStore.shared.close(contents)
    }

    func closeFromWindow() {
        windowController = nil
        dismiss()
    }

    func openWebKitInspector() {
        contents?.showDeveloperTools(inspectAt: nil)
    }


    func startPicker() {
        picking = true
        select(panel: .elements)
        command(["op": "pick", "on": true])
    }

    func togglePicker() {
        if picking {
            picking = false
            command(["op": "pick", "on": false])
        } else {
            startPicker()
        }
    }

    /// `point` is in web-view points with a top-left origin, as `ContextMenuContext.location` carries it.
    func inspect(at point: CGPoint) {
        select(panel: .elements)
        let zoom = contents?.webView.pageZoom ?? 1
        let scale = zoom > 0 ? zoom : 1
        command(["op": "inspect", "x": Double(point.x / scale), "y": Double(point.y / scale)])
    }

    @ObservationIgnored private var hoveredNodeID: Int?

    func highlight(nodeID: Int) {
        guard hoveredNodeID != nodeID else { return }
        hoveredNodeID = nodeID
        command(["op": "highlight", "id": nodeID])
    }

    func clearHighlight() {
        guard hoveredNodeID != nil else { return }
        hoveredNodeID = nil
        command(["op": "clearHighlight"])
    }

    func reveal(nodeID: Int) {
        select(panel: .elements)
        elements.select(nodeID: nodeID)
    }

    func reveal(sourceURL: String, line: Int? = nil, column: Int? = nil) {
        select(panel: .sources)
        sources.reveal(url: sourceURL, line: line, column: column)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func command(_ object: [String: Any]) {
        guard let contents, !contents.isClosed else { return }
        let inject = !agentReady
        if inject { agentReady = true }
        guard let script = Self.invocation(object, inject: inject) else { return }
        commandTail = Task { [weak self, weak contents, commandTail] in
            await commandTail?.value
            guard let self, let contents, !contents.isClosed else { return }
            do {
                _ = try await contents.evaluateJavaScript(script)
                if self.notice == "This page didn't run the inspector." { self.notice = nil }
            } catch {
                self.agentReady = false
                if self.isPresented { self.notice = "This page didn't run the inspector." }
            }
        }
    }

    func evaluate(_ script: String) async throws -> Any? {
        guard let contents, !contents.isClosed else { return nil }
        return try await contents.evaluateJavaScript(script)
    }

    func reloadPage(ignoringCache: Bool = false) {
        guard let webView = contents?.webView else { return }
        if ignoringCache { webView.reloadFromOrigin() } else { webView.reload() }
    }

    private static func invocation(_ object: [String: Any], inject: Bool) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8),
              let literal = jsStringLiteral(json) else { return nil }
        let call = "window.__orbitInspect&&window.__orbitInspect.cmd(\(literal));"
        if inject { return OrbitInspectAgent.source + "\n" + call }
        return call
    }

    private static func jsStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              var wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2 else { return nil }
        wrapped.removeFirst()
        wrapped.removeLast()
        return wrapped
    }
}

extension WebKitWebContents {
    func showInspectElement(at point: CGPoint?) {
        OrbitDevToolsStore.shared.open(self, panel: .elements, inspectAt: point, armPicker: point == nil)
    }

    func showJavaScriptConsole() {
        OrbitDevToolsStore.shared.open(self, panel: .console, inspectAt: nil, armPicker: false)
    }

    func showOrbitDeveloperTools() {
        let session = OrbitDevToolsStore.shared.ensureSession(for: self)
        OrbitDevToolsStore.shared.open(self, panel: session.panel, inspectAt: nil, armPicker: false)
    }
}

enum OrbitInspectEditor: String, CaseIterable, Identifiable {
    case cursor, vscode, zed, xcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .xcode: "Xcode"
        }
    }

    func url(forFile path: String, line: Int?, column: Int?) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var suffix = ""
        if let line { suffix += ":\(line)" }
        if line != nil, let column { suffix += ":\(column)" }
        switch self {
        case .cursor: return URL(string: "cursor://file\(encoded)\(suffix)")
        case .vscode: return URL(string: "vscode://file\(encoded)\(suffix)")
        case .zed: return URL(string: "zed://file\(encoded)\(suffix)")
        case .xcode:
            var query = "file=\(encoded)"
            if let line { query += "&line=\(line)" }
            return URL(string: "xcode://open?\(query)")
        }
    }
}

/// Project roots are remembered per site, so the folder is chosen once. Nothing here is specific to one framework or dev server.
@MainActor
enum OrbitInspectEditorLauncher {
    private static let editorKey = "orbit.inspect.editor"
    private static let rootsKey = "orbit.inspect.projectRoots"

    static var editor: OrbitInspectEditor {
        get { OrbitDefaults.standard.string(forKey: editorKey).flatMap(OrbitInspectEditor.init(rawValue:)) ?? .cursor }
        set { OrbitDefaults.standard.set(newValue.rawValue, forKey: editorKey) }
    }

    static func projectRoots(forSite site: String) -> [String] {
        let all = OrbitDefaults.standard.dictionary(forKey: rootsKey) as? [String: [String]] ?? [:]
        return all[site] ?? []
    }

    static func addProjectRoot(_ root: String, forSite site: String) {
        var all = OrbitDefaults.standard.dictionary(forKey: rootsKey) as? [String: [String]] ?? [:]
        var roots = all[site] ?? []
        roots.removeAll { $0 == root }
        roots.insert(root, at: 0)
        all[site] = Array(roots.prefix(5))
        OrbitDefaults.standard.set(all, forKey: rootsKey)
    }

    static func resolveFile(sourceURL: String, site: String) -> String? {
        let resolved = OrbitInspectEditorPaths.resolve(sourceURL)
        let fileManager = FileManager.default
        if let absolute = resolved.absolute, fileManager.fileExists(atPath: absolute) { return absolute }
        for root in projectRoots(forSite: site) {
            for relative in resolved.relatives {
                let candidate = (root as NSString).appendingPathComponent(relative)
                if fileManager.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    @discardableResult
    static func open(sourceURL: String, line: Int?, column: Int?, session: OrbitInspectSession) -> Bool {
        let site = URL(string: session.pageURL)?.host ?? "local"
        var file = resolveFile(sourceURL: sourceURL, site: site)
        if file == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Use as Project Folder"
            panel.message = "Choose the folder that contains this project's source files, so Orbit can open \(sourceURL) in \(editor.title)."
            guard panel.runModal() == .OK, let root = panel.url?.path else { return false }
            addProjectRoot(root, forSite: site)
            file = resolveFile(sourceURL: sourceURL, site: site)
        }
        guard let file, let url = editor.url(forFile: file, line: line, column: column) else {
            session.notice = "Couldn't find \(sourceURL) in the project folder."
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
