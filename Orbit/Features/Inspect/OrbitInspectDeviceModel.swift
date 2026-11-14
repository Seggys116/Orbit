// Pure decisions live in OrbitInspectDeviceLogic.swift; this file only talks to WebKit.

import AppKit
import WebKit

@MainActor
@Observable
final class OrbitInspectDeviceModel {
    private(set) var isActive = false
    private(set) var settings: OrbitDeviceSettings
    private(set) var zoom: OrbitDeviceZoom
    private(set) var customDevices: [OrbitDeviceProfile]
    private(set) var needsReload = false
    private(set) var scale: CGFloat = 1

    @ObservationIgnored private let preferences: OrbitDevicePreferences
    @ObservationIgnored private let webViewProvider: () -> WKWebView?
    /// Read when needed, not captured at activation, so a user agent change made meanwhile is honoured.
    @ObservationIgnored private let baseUserAgent: () -> String?
    @ObservationIgnored private let subframes: () -> [WKFrameInfo]
    @ObservationIgnored private var appliedState: OrbitDeviceAppliedState?
    @ObservationIgnored private var appliedEmulation: OrbitDeviceEmulationConfig?
    @ObservationIgnored private var documentState = OrbitDeviceAppliedState.untouched
    @ObservationIgnored private var skipNextLoadFinish = false
    @ObservationIgnored private var loadObservation: NSKeyValueObservation?
    @ObservationIgnored private var resizeStart: OrbitDeviceSettings?
    @ObservationIgnored private var resizeScale: CGFloat = 1

    init(
        preferences: OrbitDevicePreferences = OrbitDevicePreferences(defaults: OrbitDefaults.standard),
        webView: @escaping () -> WKWebView?,
        baseUserAgent: @escaping () -> String? = { nil },
        subframes: @escaping () -> [WKFrameInfo] = { [] }
    ) {
        self.preferences = preferences
        self.webViewProvider = webView
        self.baseUserAgent = baseUserAgent
        self.subframes = subframes
        self.settings = preferences.restoredSettings()
        self.zoom = preferences.zoom
        self.customDevices = preferences.customDevices
    }


    var currentProfile: OrbitDeviceProfile? {
        settings.profileID.flatMap { OrbitDeviceCatalog.profile(id: $0, custom: customDevices) }
    }

    var sections: [OrbitDeviceCatalog.Section] {
        OrbitDeviceCatalog.sections(custom: customDevices)
    }

    var deviceTitle: String { currentProfile?.name ?? "Responsive" }

    func layout(in stage: CGSize) -> OrbitDeviceLayout {
        OrbitDeviceLayout.make(content: settings.size, zoom: zoom, stage: stage)
    }

    func reportScale(_ value: CGFloat) {
        if abs(scale - value) > 0.0005 { scale = value }
    }


    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    func activate() {
        guard !isActive, let webView = webViewProvider() else { return }
        isActive = true
        documentState = .untouched
        appliedState = nil
        appliedEmulation = nil
        skipNextLoadFinish = false
        observeLoads(of: webView)
        apply()
    }

    /// The page keeps what it loaded under the emulated user agent until it reloads; nothing reloads automatically.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        loadObservation = nil
        resizeStart = nil
        needsReload = false
        appliedState = nil
        appliedEmulation = nil
        guard let webView = webViewProvider() else { return }
        webView.customUserAgent = baseUserAgent()
        Self.replaceUserScript(nil, on: webView.configuration.userContentController)
        evaluateInEveryFrame(OrbitDeviceEmulationScript.remove, on: webView)
    }

    func reinstallUserScript() {
        guard isActive, let emulation = appliedEmulation, !emulation.isEmpty, let webView = webViewProvider() else { return }
        Self.replaceUserScript(
            OrbitDeviceEmulationScript.install(emulation),
            on: webView.configuration.userContentController
        )
    }

    func reloadNow() {
        webViewProvider()?.reload()
    }


    func selectResponsive() {
        change(settings.asResponsive())
    }

    func select(_ profile: OrbitDeviceProfile) {
        change(OrbitDeviceSettings(profile: profile))
    }

    func setSize(width: Int, height: Int) {
        change(settings.resized(width: width, height: height))
    }

    func rotate() {
        change(settings.rotated())
    }

    func setDPR(_ dpr: Double?) {
        change(settings.withDPR(dpr))
    }

    func setType(_ type: OrbitDeviceType) {
        change(settings.withType(type))
    }

    func setZoom(_ zoom: OrbitDeviceZoom) {
        self.zoom = zoom
        preferences.zoom = zoom
    }


    /// The drag keeps the scale it began with: under fit zoom the scale shrinks as the frame grows and the frame would run from the pointer.
    func beginResize() {
        resizeStart = settings
        resizeScale = scale
    }

    func dragResize(translation: CGSize, handle: OrbitDeviceResizeHandle) {
        guard let start = resizeStart else { return }
        let size = OrbitDeviceGeometry.resized(
            width: start.width, height: start.height,
            translation: translation, scale: resizeScale, handle: handle
        )
        change(start.resized(width: size.width, height: size.height), persist: false)
    }

    func endResize() {
        resizeStart = nil
        preferences.saveSelection(settings)
    }


    @discardableResult
    func saveCustomDevice(
        id: String? = nil,
        name: String,
        width: Int,
        height: Int,
        dpr: Double,
        userAgent: String,
        mobile: Bool,
        touch: Bool
    ) -> OrbitDeviceProfile? {
        let profile: OrbitDeviceProfile?
        if let id {
            profile = OrbitDeviceProfile.makeCustom(
                id: id, name: name, width: width, height: height, dpr: dpr,
                userAgent: userAgent, mobile: mobile, touch: touch
            )
        } else {
            profile = OrbitDeviceProfile.makeCustom(
                name: name, width: width, height: height, dpr: dpr,
                userAgent: userAgent, mobile: mobile, touch: touch
            )
        }
        guard let profile else { return nil }
        customDevices = OrbitDeviceCatalog.upserting(profile, into: customDevices)
        preferences.customDevices = customDevices
        select(profile)
        return profile
    }

    func removeCustomDevice(id: String) {
        customDevices = OrbitDeviceCatalog.removing(id: id, from: customDevices)
        preferences.customDevices = customDevices
        if settings.profileID == id { change(settings.asResponsive()) }
    }


    private func change(_ next: OrbitDeviceSettings, persist: Bool = true) {
        settings = next
        if persist { preferences.saveSelection(next) }
        apply()
    }

    private func apply() {
        guard isActive, let webView = webViewProvider() else { return }
        let state = settings.applied
        let emulation = settings.emulation

        if state != appliedState {
            webView.customUserAgent = state.userAgent ?? baseUserAgent()
            appliedState = state
            // A load already in flight started under the old user agent, so its end says nothing about the new one.
            if webView.isLoading { skipNextLoadFinish = true }
        }

        if emulation != appliedEmulation {
            appliedEmulation = emulation
            let controller = webView.configuration.userContentController
            if emulation.isEmpty {
                Self.replaceUserScript(nil, on: controller)
                evaluateInEveryFrame(OrbitDeviceEmulationScript.remove, on: webView)
            } else {
                let source = OrbitDeviceEmulationScript.install(emulation)
                Self.replaceUserScript(source, on: controller)
                evaluateInEveryFrame(source, on: webView)
            }
        }

        needsReload = OrbitDeviceAppliedState.needsReload(document: documentState, target: state)
    }

    /// The user script covers future documents; already-loaded frames, cross-origin ones included, get the change directly.
    private func evaluateInEveryFrame(_ source: String, on webView: WKWebView) {
        webView.evaluateJavaScript(source, completionHandler: nil)
        for frame in subframes() {
            webView.evaluateJavaScript(source, in: frame, in: .page) { _ in }
        }
    }

    private func observeLoads(of webView: WKWebView) {
        loadObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor [weak self] in self?.documentDidFinishLoading() }
        }
    }

    private func documentDidFinishLoading() {
        guard isActive else { return }
        if skipNextLoadFinish {
            skipNextLoadFinish = false
            return
        }
        documentState = settings.applied
        needsReload = OrbitDeviceAppliedState.needsReload(document: documentState, target: settings.applied)
    }

    /// WKUserContentController can only remove every script at once, so the others are put straight back.
    private static func replaceUserScript(_ source: String?, on controller: WKUserContentController) {
        let existing = controller.userScripts
        let kept = existing.filter { !$0.source.hasPrefix(OrbitDeviceEmulationScript.marker) }
        guard kept.count != existing.count || source != nil else { return }
        controller.removeAllUserScripts()
        for script in kept { controller.addUserScript(script) }
        if let source {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }
}

extension WebKitWebContents {
    func toggleDeviceToolbar() {
        let session = OrbitDevToolsStore.shared.ensureSession(for: self)
        if !session.isPresented {
            OrbitDevToolsStore.shared.open(self, panel: session.panel, inspectAt: nil, armPicker: false)
        }
        session.toggleDeviceToolbar()
    }
}

extension OrbitInspectSession {
    /// The older Screen Size menu (InspectorDeviceMode) also drives user agent and page size, so it is reset to desktop when this toolbar turns on.
    func toggleDeviceToolbar() {
        if !device.isActive, let contents, InspectorDeviceMode.shared.preset(for: contents) != .desktop {
            InspectorDeviceMode.shared.setPreset(.desktop, for: contents)
        }
        device.toggle()
    }
}
