import AppKit

// The engine's password autofill callbacks. Everything that decides whether a page may be offered or saved logins at all lives here:
// a tab in a non-persistent Profile or an ephemeral (Incognito) Space gets nothing, and so does a page that is not one of this window's tabs.
extension AppEnvironment {

    func webContentsAllowsPasswordAutofill(_ contents: WebContents) -> Bool {
        guard contents.session.isPersistent, let tabID = tabID(for: contents), let tab = state.tabs[tabID] else { return false }
        return !isPrivateBrowsingContext(spaceID: tab.spaceID, profileID: profileID(for: tab.spaceID))
    }

    func webContents(_ contents: WebContents, didFocusPasswordField field: PasswordFieldFocus) {
        PasswordAutofillUI.shared.fieldFocused(field, contents: contents)
    }

    func webContents(_ contents: WebContents, didMovePasswordField token: String, toScreenRect rect: CGRect) {
        PasswordAutofillUI.shared.fieldMoved(token: token, to: rect)
    }

    func webContentsDidDismissPasswordField(_ contents: WebContents) {
        PasswordAutofillUI.shared.fieldDismissed()
    }

    func webContents(_ contents: WebContents, didCapturePasswordSubmission submission: PasswordSubmission) {
        guard webContentsAllowsPasswordAutofill(contents) else { return }
        PasswordAutofillUI.shared.submissionCaptured(submission, contents: contents)
    }

    /// The "AutoFill Password" submenu, and the divider after it, for a right-click on a classified sign-in field; nothing for any other click.
    func passwordContextMenuEntries(for contents: WebContents, context: ContextMenuContext) -> [OrbitContextMenuEntry] {
        guard let field = context.passwordField, webContentsAllowsPasswordAutofill(contents) else { return [] }
        return PasswordAutofillUI.shared.contextMenuEntries(for: field, contents: contents)
    }
}
