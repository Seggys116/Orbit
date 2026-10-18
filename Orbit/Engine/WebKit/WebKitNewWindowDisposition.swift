import AppKit
import WebKit

/// How a WebKit link click or window.open maps onto Orbit's new-content dispositions, as Chrome's
/// ui::DispositionFromClick and window.open popup rules do. Pure so it can be tested without a web view.
extension NewContentDisposition {
    /// macOS reports the button index: 0 left, 1 right, 2 middle. iOS reports a mask, where middle is 4.
    static let webKitMiddleButtonNumber = 2
    static let webKitMiddleButtonMask = 4

    /// Window features that make window.open a popup rather than a tab.
    struct WebKitWindowFeatures: Equatable, Sendable {
        var hasPosition = false
        var hasSize = false
        var hidesMenuBar = false
        var hidesToolbars = false
        var hidesStatusBar = false

        var requestsPopup: Bool { hasPosition || hasSize || hidesMenuBar || hidesToolbars || hidesStatusBar }

        init(hasPosition: Bool = false, hasSize: Bool = false, hidesMenuBar: Bool = false, hidesToolbars: Bool = false, hidesStatusBar: Bool = false) {
            self.hasPosition = hasPosition
            self.hasSize = hasSize
            self.hidesMenuBar = hidesMenuBar
            self.hidesToolbars = hidesToolbars
            self.hidesStatusBar = hidesStatusBar
        }

        init(_ features: WKWindowFeatures) {
            self.init(
                hasPosition: features.x != nil || features.y != nil,
                hasSize: features.width != nil || features.height != nil,
                hidesMenuBar: features.menuBarVisibility?.boolValue == false,
                hidesToolbars: features.toolbarsVisibility?.boolValue == false,
                hidesStatusBar: features.statusBarVisibility?.boolValue == false
            )
        }
    }

    /// nil is an ordinary navigation in the same tab. Cmd or middle-click opens a background tab,
    /// Cmd+Shift a foreground one and Shift a window. Option is left alone: it is the download and Little Orbit gesture.
    static func forLinkClick(modifiers: NSEvent.ModifierFlags, buttonNumber: Int) -> NewContentDisposition? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.option), !flags.contains(.control) else { return nil }
        let wantsTab = flags.contains(.command)
            || buttonNumber == webKitMiddleButtonNumber
            || buttonNumber == webKitMiddleButtonMask
        if wantsTab { return flags.contains(.shift) ? .newForegroundTab : .newBackgroundTab }
        if flags.contains(.shift) { return .newWindow }
        return nil
    }

    /// A page-created window: the click gesture wins, then window features, else a foreground tab.
    static func forNewWindow(
        modifiers: NSEvent.ModifierFlags,
        buttonNumber: Int,
        features: WebKitWindowFeatures
    ) -> NewContentDisposition {
        if let click = forLinkClick(modifiers: modifiers, buttonNumber: buttonNumber) { return click }
        return features.requestsPopup ? .popup : .newForegroundTab
    }
}
