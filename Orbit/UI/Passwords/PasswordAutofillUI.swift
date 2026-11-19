import AppKit
import OSLog

/// What the user sees and does around password autofill: the list under a focused field, the right-click submenu and the save prompt,
/// all backed by the system password manager. One of each can be on screen at a time, so there is one instance for the app. Passwords
/// never reach a menu entry's title; a fill asks Passwords for the password only when its row is chosen, and macOS asks the person to
/// authenticate first.
@MainActor
final class PasswordAutofillUI {
    static let shared = PasswordAutofillUI()

    let suggestions = PasswordSuggestionPresenter()
    let savePrompt = PasswordSavePromptPresenter()

    /// The system password manager. A test replaces it.
    var passwords: any SystemPasswordsProviding = SystemPasswords.shared
    /// Seconds since a fixed point; a test replaces it.
    var now: () -> Date = { Date() }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "PasswordAutofill")

    /// The field the user closed with Escape. Focus reports for it stay quiet until a click on it.
    private var escapedToken: String?
    /// The field whose list is being fetched, so a late answer for a field the user has left is dropped.
    private var awaitedToken: String?
    private var lastFill: SystemPasswordFillRecord?

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
        if suggestions.isPresented, suggestions.presentedToken == field.token {
            suggestions.move(to: field.screenRect)
            return
        }
        awaitedToken = nil

        if PasswordAutofillPolicy.offersLogins(kind: field.kind, frameOrigin: field.frameOrigin) {
            offerLogins(for: field, contents: contents)
        } else if PasswordAutofillPolicy.offersOneTimeCodes(kind: field.kind, frameOrigin: field.frameOrigin) {
            offerOneTimeCodes(for: field, contents: contents)
        } else {
            suggestions.dismiss()
        }
    }

    func fieldMoved(token: String, to rect: CGRect) {
        guard suggestions.presentedToken == token else { return }
        suggestions.move(to: rect)
    }

    func fieldDismissed() {
        awaitedToken = nil
        suggestions.dismiss()
    }

    private func offerLogins(for field: PasswordFieldFocus, contents: WebContents) {
        guard let host = SystemPasswordPolicy.host(of: field.frameOrigin) else {
            suggestions.dismiss()
            return
        }
        switch passwords.state {
        case .paired:
            if let cached = passwords.cachedLogins(forHost: host) {
                presentLogins(cached, for: field, contents: contents)
                return
            }
            awaitedToken = field.token
            Task { [weak self, weak contents] in
                guard let self else { return }
                let logins: [SystemPasswordLogin]
                do {
                    logins = try await self.passwords.logins(forHost: host)
                } catch {
                    Self.logger.info("Passwords listed nothing for a field: \(String(describing: error), privacy: .public)")
                    logins = []
                }
                guard self.awaitedToken == field.token, let contents else { return }
                self.awaitedToken = nil
                self.presentLogins(logins, for: field, contents: contents)
            }
        case .notPaired, .unavailable:
            // Only a click asks to pair, so tabbing through a form never raises a list the person has not asked for.
            guard field.trigger == .click else {
                suggestions.dismiss()
                return
            }
            present([pairEntry(contents: contents), .divider(), openPasswordsEntry()], for: field, contents: contents)
        default:
            suggestions.dismiss()
        }
    }

    private func presentLogins(_ logins: [SystemPasswordLogin], for field: PasswordFieldFocus, contents: WebContents) {
        let rows = loginRows(for: field, contents: contents, logins: logins)
        guard !rows.isEmpty else {
            suggestions.dismiss()
            return
        }
        present(rows + [.divider(), openPasswordsEntry()], for: field, contents: contents)
    }

    private func offerOneTimeCodes(for field: PasswordFieldFocus, contents: WebContents) {
        guard passwords.state == .paired, passwords.canFillOneTimeCodes else {
            suggestions.dismiss()
            return
        }
        let pageURL = field.pageURL ?? field.frameOrigin
        awaitedToken = field.token
        Task { [weak self, weak contents] in
            guard let self else { return }
            let codes = (try? await self.passwords.oneTimeCodes(pageURL: pageURL, username: field.preferredUsername)) ?? []
            guard self.awaitedToken == field.token, let contents else { return }
            self.awaitedToken = nil
            let rows = codes.map { code in self.codeRow(code, field: field, pageURL: pageURL, contents: contents) }
            guard !rows.isEmpty else {
                self.suggestions.dismiss()
                return
            }
            self.present(rows, for: field, contents: contents)
        }
    }

    private func present(_ entries: [OrbitContextMenuEntry], for field: PasswordFieldFocus, contents: WebContents) {
        suggestions.present(entries: entries, token: field.token, fieldScreenRect: field.screenRect, anchorView: contents.view)
    }

    // MARK: - Entries

    /// The right-click submenu for a sign-in field, plus the divider that follows it. Empty when Passwords cannot be used.
    func contextMenuEntries(for field: PasswordFieldFocus, contents: WebContents) -> [OrbitContextMenuEntry] {
        guard PasswordAutofillPolicy.offersLogins(kind: field.kind, frameOrigin: field.frameOrigin),
              let host = SystemPasswordPolicy.host(of: field.frameOrigin)
        else { return [] }
        var children: [OrbitContextMenuEntry] = []
        switch passwords.state {
        case .paired:
            if let cached = passwords.cachedLogins(forHost: host) {
                let rows = loginRows(for: field, contents: contents, logins: cached)
                if rows.isEmpty {
                    children.append(.item(OrbitContextMenuItem(title: "No Saved Passwords", isEnabled: false)))
                } else {
                    children.append(contentsOf: rows)
                }
            } else {
                children.append(.item(OrbitContextMenuItem(title: "Show Saved Passwords", systemImage: "person.crop.circle") { [weak self, weak contents] in
                    guard let self, let contents else { return }
                    self.escapedToken = nil
                    self.offerLogins(for: field, contents: contents)
                }))
            }
        case .notPaired, .unavailable:
            children.append(pairEntry(contents: contents))
        default:
            return []
        }
        children.append(.divider())
        children.append(openPasswordsEntry())
        return [
            .item(OrbitContextMenuItem(title: "AutoFill Password", systemImage: "key", submenu: children)),
            .divider(),
        ]
    }

    private func loginRows(for field: PasswordFieldFocus, contents: WebContents, logins: [SystemPasswordLogin]) -> [OrbitContextMenuEntry] {
        SystemPasswordPolicy.ordered(logins, preferredUsername: field.preferredUsername).map { login in
            .item(OrbitContextMenuItem(title: SystemPasswordPolicy.rowTitle(for: login), systemImage: "person.crop.circle") { [weak self, weak contents] in
                guard let self, let contents else { return }
                self.fill(login, into: field, contents: contents)
            })
        }
    }

    private func codeRow(_ code: SystemPasswordOneTimeCode, field: PasswordFieldFocus, pageURL: URL, contents: WebContents) -> OrbitContextMenuEntry {
        let source = code.source ?? code.domain
        let title = source.map { "\(code.code) from \($0)" } ?? code.code
        return .item(OrbitContextMenuItem(title: title, systemImage: "ellipsis.rectangle") { [weak self, weak contents] in
            guard let self, let contents else { return }
            self.fillCode(code, into: field, pageURL: pageURL, contents: contents)
        })
    }

    private func pairEntry(contents: WebContents) -> OrbitContextMenuEntry {
        .item(OrbitContextMenuItem(title: "Use Passwords…", systemImage: "key") { [weak self, weak contents] in
            self?.passwords.requestPairing(over: contents?.view.window)
        })
    }

    private func openPasswordsEntry() -> OrbitContextMenuEntry {
        .item(OrbitContextMenuItem(title: "Open Passwords", systemImage: "arrow.up.forward.app") { [weak self] in
            self?.passwords.openPasswordsApp()
        })
    }

    // MARK: - Filling

    /// Passwords asks the person to authenticate before it hands over the password, which goes no further than the engine call. The engine
    /// refuses a frame of another site, and any frame that has left the origin that reported the field.
    func fill(_ login: SystemPasswordLogin, into field: PasswordFieldFocus, contents: WebContents) {
        guard let host = SystemPasswordPolicy.host(of: field.frameOrigin) else { return }
        let passwords = self.passwords
        Task { @MainActor [weak self, weak contents] in
            let password: String
            do {
                password = try await passwords.password(forUsername: login.username, host: host)
            } catch {
                Self.logger.info("Passwords gave no password for a fill: \(String(describing: error), privacy: .public)")
                return
            }
            guard let contents else { return }
            let outcome = await contents.fillPassword(
                into: field.token,
                credentials: PasswordFillCredentials(origin: field.frameOrigin, username: login.username, password: password)
            )
            guard outcome.didFill, let self else { return }
            self.lastFill = SystemPasswordFillRecord(origin: field.frameOrigin, username: login.username, password: password, date: self.now())
        }
    }

    func fillCode(_ code: SystemPasswordOneTimeCode, into field: PasswordFieldFocus, pageURL: URL, contents: WebContents) {
        let passwords = self.passwords
        Task { @MainActor [weak contents] in
            guard let contents else { return }
            let outcome = await contents.fillOneTimeCode(code.code, into: field.token, frameOrigin: field.frameOrigin)
            guard outcome.didFill else { return }
            await passwords.didFillOneTimeCode(pageURL: pageURL, username: code.username ?? "")
        }
    }

    // MARK: - Save and update prompt

    func submissionCaptured(_ submission: PasswordSubmission, contents: WebContents) {
        // A login typed over plain http is not offered for saving: saving it would only set it up to be offered again on an insecure page.
        guard PasswordAutofillPolicy.isSecureForFill(origin: submission.origin),
              let host = SystemPasswordPolicy.host(of: submission.origin),
              passwords.state == .paired,
              contents.view.window != nil
        else { return }
        let passwords = self.passwords
        Task { @MainActor [weak self, weak contents] in
            let known: [String]
            do {
                known = try await passwords.logins(forHost: host).map(\.username)
            } catch {
                return
            }
            guard let self, let contents, contents.view.window != nil else { return }
            let decision = SystemPasswordPolicy.saveDecision(submission: submission, knownUsernames: known, filled: self.lastFill, now: self.now())
            self.presentPrompt(for: decision, submission: submission, host: host, contents: contents)
        }
    }

    private func presentPrompt(for decision: SystemPasswordSaveDecision, submission: PasswordSubmission, host: String, contents: WebContents) {
        let site = PasswordAutofillPolicy.displayOrigin(submission.origin.absoluteString)
        let passwords = self.passwords
        let password = submission.password
        let kind: PasswordSavePromptModel.Kind
        let username: String
        switch decision {
        case .nothing: return
        case .save(let name):
            kind = .save
            username = name
        case .update(let name):
            kind = .update
            username = name
        }
        savePrompt.present(
            PasswordSavePromptModel(kind: kind, site: site, username: username),
            anchorView: contents.view,
            onPrimary: {
                Task { @MainActor in
                    do {
                        let outcome = try await passwords.save(username: username, password: password, host: host)
                        if outcome == .unconfirmed {
                            Self.logger.info("Passwords did not confirm a saved password")
                        }
                    } catch {
                        Self.logger.error("Passwords could not save a password: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        )
    }
}
