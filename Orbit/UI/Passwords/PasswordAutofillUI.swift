import AppKit

/// What the user sees and does around password autofill: the list under a focused field, the right-click submenu and the save prompt.
/// One of each can be on screen at a time, so there is one instance for the app. Passwords never reach a menu entry's title; a fill
/// reads the password from the vault only when its row is chosen.
@MainActor
final class PasswordAutofillUI {
    static let shared = PasswordAutofillUI()

    let suggestions = PasswordSuggestionPresenter()
    let savePrompt = PasswordSavePromptPresenter()

    /// Opens Settings on the Passwords pane. A test replaces it.
    var openManagePasswords: () -> Void = { SettingsWindowController.show(pane: .passwords) }

    private var vault: any PasswordVault { PasswordVaults.shared }
    /// The field the user closed with Escape. Focus reports for it stay quiet until a click on it.
    private var escapedToken: String?

    private init() {
        suggestions.onEscape = { [weak self] token in self?.escapedToken = token }
    }

    // MARK: - Suggestions under a field

    func fieldFocused(_ field: PasswordFieldFocus, contents: WebContents) {
        if field.trigger == .click {
            escapedToken = nil
        } else if field.token == escapedToken {
            return
        }
        let logins = PasswordAutofillPolicy.offerable(vault.logins(matching: field.frameOrigin), frameOrigin: field.frameOrigin)
        let offer = PasswordAutofillPolicy.offer(
            kind: field.kind,
            logins: logins,
            frameOrigin: field.frameOrigin,
            offersAutofill: PasswordSettings.offersToAutofill
        )
        guard offer != .none else {
            suggestions.dismiss()
            return
        }
        if suggestions.isPresented, suggestions.presentedToken == field.token {
            suggestions.move(to: field.screenRect)
            return
        }
        let entries = suggestionEntries(for: field, contents: contents, logins: logins, offer: offer)
        suggestions.present(entries: entries, token: field.token, fieldScreenRect: field.screenRect, anchorView: contents.view)
    }

    func fieldMoved(token: String, to rect: CGRect) {
        guard suggestions.presentedToken == token else { return }
        suggestions.move(to: rect)
    }

    func fieldDismissed() {
        suggestions.dismiss()
    }

    // MARK: - Entries

    func suggestionEntries(
        for field: PasswordFieldFocus,
        contents: WebContents,
        logins: [SavedLogin],
        offer: PasswordOffer
    ) -> [OrbitContextMenuEntry] {
        var entries: [OrbitContextMenuEntry] = []
        let rows = loginRows(for: field, contents: contents, logins: logins)
        switch offer {
        case .none:
            break
        case .insecureWarning:
            entries.append(.section(title: Self.insecureWarning, entries: rows))
        case .suggestions(let showsLogins, let showsStrongPassword):
            if showsLogins { entries.append(contentsOf: rows) }
            if showsStrongPassword { entries.append(strongPasswordEntry(for: field, contents: contents)) }
        }
        guard !entries.isEmpty else { return [] }
        entries.append(.divider())
        entries.append(managePasswordsEntry())
        return entries
    }

    /// The right-click submenu for a classified field, plus the divider that follows it. Empty when autofill is switched off.
    func contextMenuEntries(for field: PasswordFieldFocus, contents: WebContents) -> [OrbitContextMenuEntry] {
        guard PasswordSettings.offersToAutofill else { return [] }
        var children: [OrbitContextMenuEntry] = []
        if field.kind != .newPassword {
            let logins = PasswordAutofillPolicy.offerable(vault.logins(matching: field.frameOrigin), frameOrigin: field.frameOrigin)
            let rows = loginRows(for: field, contents: contents, logins: logins)
            if rows.isEmpty {
                children.append(.item(OrbitContextMenuItem(title: "No Saved Passwords", isEnabled: false)))
            } else if field.isSecure {
                children.append(contentsOf: rows)
            } else {
                children.append(.section(title: Self.insecureWarning, entries: rows))
            }
        } else if field.isSecure {
            children.append(strongPasswordEntry(for: field, contents: contents))
        }
        children.append(.divider())
        children.append(managePasswordsEntry())
        return [
            .item(OrbitContextMenuItem(title: "AutoFill Password", systemImage: "key", submenu: children)),
            .divider(),
        ]
    }

    static let insecureWarning = "This page is not secure"

    private func loginRows(for field: PasswordFieldFocus, contents: WebContents, logins: [SavedLogin]) -> [OrbitContextMenuEntry] {
        PasswordAutofillPolicy.ordered(logins, preferredUsername: field.preferredUsername).map { login in
            .item(OrbitContextMenuItem(title: login.username, systemImage: "person.crop.circle") { [weak self, weak contents] in
                guard let self, let contents else { return }
                self.fill(login, into: field, contents: contents)
            })
        }
    }

    private func strongPasswordEntry(for field: PasswordFieldFocus, contents: WebContents) -> OrbitContextMenuEntry {
        .item(OrbitContextMenuItem(title: "Use Strong Password", systemImage: "key.fill") { [weak self, weak contents] in
            guard let self, let contents else { return }
            self.fillStrongPassword(into: field, contents: contents)
        })
    }

    private func managePasswordsEntry() -> OrbitContextMenuEntry {
        .item(OrbitContextMenuItem(title: "Manage Passwords…", systemImage: "gearshape") { [weak self] in
            self?.openManagePasswords()
        })
    }

    // MARK: - Filling

    /// The password is read from the login only here, and only as far as the engine call. The engine refuses a frame of another site, and an
    /// https login in an http frame, from the login's own origin; the row of an insecure page (an http login on an http page) is the explicit choice.
    func fill(_ login: SavedLogin, into field: PasswordFieldFocus, contents: WebContents) {
        guard let origin = URL(string: login.origin) else { return }
        let vault = self.vault
        Task { @MainActor in
            let outcome = await contents.fillPassword(
                into: field.token,
                credentials: PasswordFillCredentials(origin: origin, username: login.username, password: login.password)
            )
            if outcome.didFill { vault.markUsed(id: login.id) }
        }
    }

    func fillStrongPassword(into field: PasswordFieldFocus, contents: WebContents) {
        let password = PasswordGenerator.secure.generate(PasswordGenerator.Options.safariLike)
        Task { @MainActor in
            _ = await contents.fillGeneratedPassword(password, into: field.token)
        }
    }

    // MARK: - Save and update prompt

    func submissionCaptured(_ submission: PasswordSubmission, contents: WebContents) {
        // A login typed over plain http is not offered for saving: saving it would only set it up to be offered again on an insecure page.
        guard PasswordAutofillPolicy.isSecureForFill(origin: submission.origin),
              let siteKey = PasswordAutofillPolicy.siteKey(of: submission.origin),
              contents.view.window != nil
        else { return }
        let vault = self.vault
        let decision = PasswordAutofillPolicy.promptDecision(
            submission: submission,
            existing: vault.logins(matching: submission.origin),
            isNeverSave: vault.isNeverSave(siteKey: siteKey),
            offersToSave: PasswordSettings.offersToSave
        )
        let site = PasswordAutofillPolicy.displayOrigin(submission.origin.absoluteString)
        let origin = submission.origin
        switch decision {
        case .nothing:
            return
        case .save(let username, let password):
            savePrompt.present(
                PasswordSavePromptModel(kind: .save, site: site, username: username),
                anchorView: contents.view,
                onPrimary: { vault.save(origin: origin, username: username, password: password) },
                onNever: { vault.setNeverSave(true, forSiteKey: siteKey) }
            )
        case .update(let existing, let password):
            // The decision only ever picks the login of this exact origin, so the prompt names the origin that will change.
            savePrompt.present(
                PasswordSavePromptModel(kind: .update, site: PasswordAutofillPolicy.displayOrigin(existing.origin), username: existing.username),
                anchorView: contents.view,
                onPrimary: {
                    var updated = existing
                    updated.password = password
                    updated.updatedAt = Date()
                    vault.update(updated)
                },
                onNever: {}
            )
        }
    }
}
