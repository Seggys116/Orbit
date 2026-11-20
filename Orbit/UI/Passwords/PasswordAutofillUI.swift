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
    var passwords: any SystemPasswordsProviding = SystemPasswords.shared {
        didSet { recentCodes.removeAll() }
    }
    /// Seconds since a fixed point; a test replaces it.
    var now: () -> Date = { Date() }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "PasswordAutofill")

    /// The field the user closed with Escape. Focus reports for it stay quiet until a click on it.
    private var escapedToken: String?
    /// The field whose list is being fetched, so a late answer for a field the user has left is dropped.
    private var awaitedToken: String?
    private var lastFill: SystemPasswordFillRecord?
    /// Codes listed for a page a moment ago. A page that focuses its code box again and again must not make the person wait on Passwords each time, and an answer must not be lost to the next report for the same field.
    private var recentCodes: [String: (codes: [SystemPasswordOneTimeCode], fetched: Date)] = [:]
    private static let codeCacheLifetime: TimeInterval = 20

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
        } else if PasswordAutofillPolicy.offersAccountCreation(kind: field.kind, frameOrigin: field.frameOrigin) {
            offerAccountCreation(for: field, contents: contents)
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

    /// On a sign-up form: one row that has Passwords make the account, so its own generator and its own sheet do the work.
    private func offerAccountCreation(for field: PasswordFieldFocus, contents: WebContents) {
        guard passwords.state == .paired, passwords.canCreateAccount else {
            suggestions.dismiss()
            return
        }
        present([accountCreationRow(for: field, contents: contents)], for: field, contents: contents)
    }

    private func accountCreationRow(for field: PasswordFieldFocus, contents: WebContents) -> OrbitContextMenuEntry {
        let pageURL = field.pageURL ?? field.frameOrigin
        let site = SystemPasswordPolicy.host(of: field.frameOrigin) ?? "this site"
        return .item(OrbitContextMenuItem(title: "Create Account for \(site) in Passwords…", systemImage: "key.fill") { [weak self] in
            guard let self else { return }
            Task { await self.passwords.createAccount(pageURL: pageURL) }
        })
    }

    private func offerOneTimeCodes(for field: PasswordFieldFocus, contents: WebContents) {
        guard passwords.state == .paired, passwords.canFillOneTimeCodes else {
            Self.logger.info("a code field was focused but codes are not on offer: paired=\(self.passwords.state == .paired) helperFillsCodes=\(self.passwords.canFillOneTimeCodes)")
            suggestions.dismiss()
            return
        }
        let pageURL = field.pageURL ?? field.frameOrigin
        let cacheKey = pageURL.absoluteString
        if let cached = recentCodes[cacheKey], now().timeIntervalSince(cached.fetched) < Self.codeCacheLifetime, !cached.codes.isEmpty {
            present(cached.codes.map { codeRow($0, field: field, pageURL: pageURL, contents: contents) }, for: field, contents: contents)
            return
        }
        awaitedToken = field.token
        Task { [weak self, weak contents] in
            guard let self else { return }
            let codes: [SystemPasswordOneTimeCode]
            do {
                codes = try await self.passwords.oneTimeCodes(pageURL: pageURL, username: field.preferredUsername)
            } catch {
                Self.logger.info("Passwords listed no codes for a field: \(String(describing: error), privacy: .public)")
                codes = []
            }
            if !codes.isEmpty { self.recentCodes[cacheKey] = (codes, self.now()) }
            guard self.awaitedToken == field.token, let contents else { return }
            self.awaitedToken = nil
            let rows = codes.map { code in self.codeRow(code, field: field, pageURL: pageURL, contents: contents) }
            guard !rows.isEmpty else {
                Self.logger.info("Passwords had no code for this site")
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
        // A code field has no login to list; the person can still ask for its code by hand when the offer did not appear by itself.
        if PasswordAutofillPolicy.offersOneTimeCodes(kind: field.kind, frameOrigin: field.frameOrigin), passwords.state == .paired {
            return [
                .item(OrbitContextMenuItem(title: "AutoFill Code", systemImage: "ellipsis.rectangle") { [weak self, weak contents] in
                    guard let self, let contents else { return }
                    self.escapedToken = nil
                    self.offerOneTimeCodes(for: field, contents: contents)
                }),
                .divider(),
            ]
        }
        if PasswordAutofillPolicy.offersAccountCreation(kind: field.kind, frameOrigin: field.frameOrigin),
           passwords.state == .paired, passwords.canCreateAccount {
            return [accountCreationRow(for: field, contents: contents), .divider()]
        }
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
        // A code Passwords has not handed over yet is named by whose it is; its digits are fetched when it is chosen.
        let label = code.isHidden ? (code.username ?? "Verification code") : code.code
        let title = source.map { "\(label) from \($0)" } ?? label
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
            var digits = code.code
            if code.isHidden {
                do {
                    digits = try await passwords.revealOneTimeCode(pageURL: pageURL, username: code.username)
                } catch {
                    Self.logger.info("Passwords gave no code for a fill: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            let outcome = await contents.fillOneTimeCode(digits, into: field.token, frameOrigin: field.frameOrigin)
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
