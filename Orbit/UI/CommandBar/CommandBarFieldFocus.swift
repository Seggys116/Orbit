import AppKit

@MainActor
enum CommandBarFieldFocus {
    static let settleInterval = Duration.milliseconds(10)
    static let maximumAttempts = 12

    // Scans key, then main, then every other window: an app that is not frontmost has no key window even though one of its windows may still own the responder.
    static var focusedFieldEditor: NSTextView? {
        var seen: [NSWindow] = []
        if let key = NSApp.keyWindow { seen.append(key) }
        if let main = NSApp.mainWindow { seen.append(main) }
        seen.append(contentsOf: NSApp.windows)
        for window in seen {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return editor }
        }
        return nil
    }

    static func selectAll(in editor: NSTextView) {
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    }

    static func selectAll() {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }

    // Waits for the field editor's text to match text() so a re-present over an already-open bar doesn't select stale text.
    static func claim(
        showing text: @escaping () -> String,
        isFocused: @escaping () -> Bool,
        requestFocus: @escaping () -> Void
    ) async {
        // Re-presenting over an already-open bar starts out focused: the field editor is
        // already attached and interactive, so re-verifying isKeyWindow below would only be
        // re-proving something already true. Acquiring focus for the first time (e.g. right
        // after a non-activating menu panel closes) is the risky case that check exists for.
        let wasAlreadyFocused = isFocused()
        for _ in 0..<maximumAttempts {
            if Task.isCancelled { return }
            ensureAKeyWindowExists()
            requestFocus()
            // editor.window?.isKeyWindow is load-bearing when focus is being newly acquired,
            // not redundant with the scan order above: AppKit will assign a field editor as
            // firstResponder on a window that isn't key, but a non-key window never receives
            // the keystrokes that follow, so that would be reporting a claim that didn't
            // actually happen.
            if isFocused(), let editor = focusedFieldEditor,
               wasAlreadyFocused || editor.window?.isKeyWindow == true,
               editor.string == text() {
                selectAll(in: editor)
                return
            }
            try? await Task.sleep(for: settleInterval)
        }
    }

    // Setting @FocusState with no key window is a no-op AppKit silently drops: a
    // non-activating child panel (e.g. the sidebar's "+" menu) can close without handing
    // key status back to its owner, leaving NSApp.keyWindow nil for this whole retry loop.
    static func ensureAKeyWindowExists() {
        guard NSApp.keyWindow == nil else { return }
        if let main = NSApp.mainWindow, main.canBecomeKey {
            main.makeKey()
            return
        }
        guard let candidate = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeKey && $0.level == .normal
        }) else { return }
        candidate.makeKeyAndOrderFront(nil)
    }
}
