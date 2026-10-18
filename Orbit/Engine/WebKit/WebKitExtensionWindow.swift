import AppKit
import Foundation
import WebKit

/// One Orbit window as chrome.windows sees it: the AppEnvironment behind it owns the tabs, the
/// NSWindow supplies state and frame. A window with no environment is the engine's placeholder
/// before the first Orbit window registers, or a synthetic one a test opened.
@MainActor
final class WebKitExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var engine: WebKitEngine?
    weak var environment: AppEnvironment? {
        didSet {
            if environment != nil { hasHadEnvironment = true }
            // Recorded at bind time: dispose clears isWindowScoped before the window-closed
            // notification, and that is the signal that this entry has to leave chrome.windows.
            if environment?.isWindowScoped == true { closesWithEnvironment = true }
        }
    }
    let number: Int
    /// The first window; it adopts the first standard environment that registers.
    var isDefault = false
    /// Opened with no Orbit window behind it, by a caller that wanted a bare window.
    var isSynthetic = false
    /// True once an environment has been bound, so a nil one afterwards means that window is gone.
    private(set) var hasHadEnvironment = false
    /// Bound to a window-scoped environment, which does not outlive its NSWindow.
    var closesWithEnvironment = false
    /// Stands in for the NSWindow's own state when there is none to read.
    var extensionWindowState: WKWebExtension.WindowState = .normal
    weak var lastActiveTab: WebKitWebContents?

    init(number: Int) {
        self.number = number
        super.init()
    }

    /// The NSWindow behind this entry: the key one when several standard windows share the environment.
    var nsWindow: NSWindow? {
        guard let environment else { return nil }
        return OrbitWindowController.window(for: environment)
    }

    var currentState: WKWebExtension.WindowState {
        guard let window = nsWindow else { return extensionWindowState }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "com.orbit.extension.window", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let engine else { return [] }
        let tabs = engine.extensionTabs(in: self)
        engine.installTabQueryConformance()
        return tabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let engine else { return nil }
        let tabs = engine.extensionTabs(in: self)
        guard !tabs.isEmpty else {
            lastActiveTab = nil
            return nil
        }
        // WebKit requires the active tab to be one of the window's tabs. A nil active
        // tab, or one that just left the array, makes content-script messaging lose the tab.
        if let active = engine.extensionActiveTab(in: self) as? WebKitWebContents,
           tabs.contains(where: { $0 === active }) {
            return active
        }
        let fallback = tabs[tabs.count - 1]
        lastActiveTab = fallback
        return fallback
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        currentState
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        extensionWindowState = state
        guard let window = nsWindow else {
            completionHandler(nil)
            return
        }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        switch state {
        case .minimized:
            if !window.isMiniaturized { window.miniaturize(nil) }
        case .fullscreen:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !isFullScreen { window.toggleFullScreen(nil) }
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if isFullScreen { window.toggleFullScreen(nil) }
            if !window.isZoomed { window.zoom(nil) }
        default:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if isFullScreen { window.toggleFullScreen(nil) }
            if window.isZoomed { window.zoom(nil) }
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        environment?.extensionWindowIsPrivate ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        guard let screen = nsWindow?.screen ?? NSScreen.main else { return .null }
        return screen.frame
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = nsWindow else {
            completionHandler(failure("This window has no frame to change."))
            return
        }
        var target = window.frame
        // NaN components were not specified; keep what the window has.
        if !frame.origin.x.isNaN { target.origin.x = frame.origin.x }
        if !frame.origin.y.isNaN { target.origin.y = frame.origin.y }
        if !frame.size.width.isNaN { target.size.width = frame.size.width }
        if !frame.size.height.isNaN { target.size.height = frame.size.height }
        window.setFrame(target, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window = nsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        if let engine {
            engine.promoteExtensionWindowToFront(self)
            engine.focusExtensionWindow(self)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = nsWindow else {
            completionHandler(failure("This window cannot be closed."))
            return
        }
        window.close()
        completionHandler(nil)
    }
}
