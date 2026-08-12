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
        for _ in 0..<maximumAttempts {
            if Task.isCancelled { return }
            requestFocus()
            if isFocused(), let editor = focusedFieldEditor, editor.string == text() {
                selectAll(in: editor)
                return
            }
            try? await Task.sleep(for: settleInterval)
        }
    }
}
