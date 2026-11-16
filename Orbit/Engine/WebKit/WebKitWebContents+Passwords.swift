import AppKit
import WebKit

/// The page side of password autofill: a script in every frame, in its own content world, that reports sign-in fields and sign-ins and fills a
/// field when asked. See `PasswordAutofillScript`. Everything the page reports is validated here, and the origin a login is matched against
/// is always the reporting frame's own security origin as WebKit knows it, never a URL or domain the message claims.
@MainActor
enum WebKitPasswordAutofill {
    static var world: WKContentWorld { WKContentWorld.world(name: PasswordAutofillScript.worldName) }

    private static let instrumented = NSHashTable<WKUserContentController>.weakObjects()

    /// Idempotent: safe after the engine's own script reinstall, and for controllers a popup shares with its opener.
    /// Installed before the context-menu probe so its `contextmenu` listener runs first.
    static func install(on controller: WKUserContentController) {
        if !instrumented.contains(controller) {
            controller.add(WebKitPasswordsBridge.shared, contentWorld: world, name: PasswordAutofillScript.handlerName)
            instrumented.add(controller)
        }
        let source = PasswordAutofillScript.source
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        ))
    }
}

/// Routes password messages to whichever web view posted them, so a popup that shares its opener's user content controller still reports to itself.
@MainActor
final class WebKitPasswordsBridge: NSObject, WKScriptMessageHandler {
    static let shared = WebKitPasswordsBridge()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let owner = (message.webView as? OrbitWebView)?.menuOwner else { return }
        owner.handlePasswordMessage(message.body, from: message.frameInfo)
    }
}

/// Stored state for password autofill on one page, kept on `WebKitContentsExtras`.
@MainActor
final class WebKitPasswordsState {

    struct Field {
        var token: String
        var kind: PasswordFieldKind
        var trigger: PasswordFieldTrigger
        var frame: WKFrameInfo
        var origin: URL
        var isMainFrame: Bool
        /// CSS pixels in the top frame's viewport. Unknown for a frame's field until the top frame relays it.
        var rect: CGRect?
        var presented = false
    }

    struct Pending {
        var submission: PasswordSubmission
        var date: Date
        var committed = false
    }

    private static let fieldLimit = 64

    var fields: [String: Field] = [:]
    private var order: [String] = []
    /// A relayed box that arrived before the frame's own focus message, keyed by token.
    var earlyRects: [String: CGRect] = [:]
    var activeToken: String?
    var contextToken: String?
    var pending: Pending?
    var stepMemory: PasswordStepMemory?
    var sawLoginForm = false
    /// Bumped to cancel a delayed dismissal.
    var blurTicket = 0
    /// Bumped to cancel a delayed decision about a captured sign-in.
    var decisionTicket = 0

    func store(_ field: Field) {
        if fields[field.token] == nil {
            order.append(field.token)
            if order.count > Self.fieldLimit, let oldest = order.first {
                order.removeFirst()
                fields[oldest] = nil
            }
        }
        fields[field.token] = field
    }

    /// A new document has none of the old one's fields.
    func resetDocument() {
        fields.removeAll()
        order.removeAll()
        earlyRects.removeAll()
        activeToken = nil
        contextToken = nil
    }

    func reset() {
        resetDocument()
        pending = nil
        stepMemory = nil
        sawLoginForm = false
        blurTicket += 1
        decisionTicket += 1
    }
}

extension WebKitWebContents {

    private var passwordState: WebKitPasswordsState { extras.passwords }

    /// Nothing is read, offered or saved for a non-persistent session, an extension page, or a page whose owner says no.
    var passwordAutofillPermitted: Bool {
        !isClosed && !isExtensionPage && session.isPersistent && delegate?.webContentsAllowsPasswordAutofill(self) == true
    }

    // MARK: - Messages from the page

    func handlePasswordMessage(_ body: Any, from frame: WKFrameInfo) {
        guard passwordAutofillPermitted,
              let message = body as? [String: Any],
              let type = message["t"] as? String,
              let origin = Self.passwordOrigin(of: frame)
        else { return }
        switch type {
        case "focus":
            guard let field = recordPasswordField(message, frame: frame, origin: origin) else { return }
            passwordState.blurTicket += 1
            passwordState.activeToken = field.token
            if field.isMainFrame {
                presentPasswordField(field)
            } else if let early = passwordState.earlyRects.removeValue(forKey: field.token) {
                var placed = field
                placed.rect = early
                passwordState.store(placed)
                presentPasswordField(placed)
            }
        case "contextField":
            guard let field = recordPasswordField(message, frame: frame, origin: origin) else { return }
            passwordState.contextToken = field.token
        case "blur":
            guard PasswordAutofillPolicy.isValidToken(message["token"]), message["token"] as? String == passwordState.activeToken else { return }
            scheduleBlurDismissal()
        case "move":
            guard frame.isMainFrame, let token = message["token"] as? String, token == passwordState.activeToken,
                  var field = passwordState.fields[token], field.isMainFrame,
                  let rect = PasswordAutofillPolicy.rect(from: message["rect"])
            else { return }
            field.rect = rect
            passwordState.store(field)
            movePasswordField(field)
        case "rect":
            // Only the top frame relays a frame's field, and only to place it; it cannot create or change a field.
            guard frame.isMainFrame, PasswordAutofillPolicy.isValidToken(message["token"]), let token = message["token"] as? String,
                  let rect = PasswordAutofillPolicy.rect(from: message["rect"])
            else { return }
            guard var field = passwordState.fields[token], !field.isMainFrame else {
                if passwordState.earlyRects.count < 16 { passwordState.earlyRects[token] = rect }
                return
            }
            field.rect = rect
            passwordState.store(field)
            guard token == passwordState.activeToken else { return }
            if field.presented { movePasswordField(field) } else { presentPasswordField(field) }
        case "scrolled":
            // A frame's field is placed from a box that goes stale as soon as the top frame scrolls.
            guard frame.isMainFrame, let token = passwordState.activeToken, passwordState.fields[token]?.isMainFrame == false else { return }
            dismissActivePasswordField()
        case "submit":
            notePasswordSubmission(message, origin: origin)
        case "page":
            guard frame.isMainFrame, message["loginForm"] as? Bool == true else { return }
            // A sign-in form on the page the sign-in led to means it did not succeed.
            passwordState.sawLoginForm = true
            if passwordState.pending?.committed == true { passwordState.pending = nil }
        default:
            break
        }
    }

    private static func passwordOrigin(of frame: WKFrameInfo) -> URL? {
        let origin = frame.securityOrigin
        return PasswordAutofillPolicy.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    private func recordPasswordField(_ message: [String: Any], frame: WKFrameInfo, origin: URL) -> WebKitPasswordsState.Field? {
        guard PasswordAutofillPolicy.isValidToken(message["token"]), let token = message["token"] as? String,
              let kind = PasswordAutofillPolicy.kind(from: message["kind"]),
              let rect = PasswordAutofillPolicy.rect(from: message["rect"])
        else { return nil }
        let field = WebKitPasswordsState.Field(
            token: token,
            kind: kind,
            trigger: PasswordAutofillPolicy.trigger(from: message["trigger"]),
            frame: frame,
            origin: origin,
            isMainFrame: frame.isMainFrame,
            rect: frame.isMainFrame ? rect : nil
        )
        passwordState.store(field)
        return field
    }

    // MARK: - Placing a field

    /// Top-left-origin CSS pixels of the top frame's viewport to AppKit screen coordinates, honouring page zoom.
    func passwordScreenRect(forCSSRect rect: CGRect) -> CGRect? {
        guard let window = webView.window else { return nil }
        let viewOnScreen = window.convertToScreen(webView.convert(webView.bounds, to: nil))
        return PasswordFieldGeometry.screenRect(cssRect: rect, zoom: Double(webView.pageZoom), viewFrameOnScreen: viewOnScreen)
    }

    private func passwordFocus(for field: WebKitPasswordsState.Field, screenRect: CGRect) -> PasswordFieldFocus {
        PasswordFieldFocus(
            token: field.token,
            kind: field.kind,
            trigger: field.trigger,
            frameOrigin: field.origin,
            pageURL: navigationState.url ?? webView.url,
            isMainFrame: field.isMainFrame,
            screenRect: screenRect,
            isSecure: PasswordAutofillPolicy.isSecureForFill(origin: field.origin),
            preferredUsername: PasswordAutofillPolicy.preferredUsername(for: field.origin, memory: passwordState.stepMemory, now: Date())
        )
    }

    private func presentPasswordField(_ field: WebKitPasswordsState.Field) {
        guard let rect = field.rect, let screen = passwordScreenRect(forCSSRect: rect) else {
            dismissActivePasswordField()
            return
        }
        var shown = field
        shown.presented = true
        passwordState.store(shown)
        delegate?.webContents(self, didFocusPasswordField: passwordFocus(for: shown, screenRect: screen))
    }

    private func movePasswordField(_ field: WebKitPasswordsState.Field) {
        guard let rect = field.rect, let screen = passwordScreenRect(forCSSRect: rect) else {
            dismissActivePasswordField()
            return
        }
        delegate?.webContents(self, didMovePasswordField: field.token, toScreenRect: screen)
    }

    func dismissActivePasswordField() {
        passwordState.blurTicket += 1
        guard passwordState.activeToken != nil else { return }
        passwordState.activeToken = nil
        delegate?.webContentsDidDismissPasswordField(self)
    }

    /// Moving between two fields blurs one just before focusing the next; a short delay keeps the panel from flickering.
    private func scheduleBlurDismissal() {
        passwordState.blurTicket += 1
        let ticket = passwordState.blurTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, self.passwordState.blurTicket == ticket else { return }
                self.dismissActivePasswordField()
            }
        }
    }

    /// The field the last right-click landed on, if password autofill classified it.
    func passwordFieldForContextMenu() -> PasswordFieldFocus? {
        guard passwordAutofillPermitted, let token = passwordState.contextToken, let field = passwordState.fields[token] else { return nil }
        let screen = field.rect.flatMap { passwordScreenRect(forCSSRect: $0) } ?? .zero
        return passwordFocus(for: field, screenRect: screen)
    }

    // MARK: - Captured sign-ins

    private func notePasswordSubmission(_ message: [String: Any], origin: URL) {
        guard let username = PasswordAutofillPolicy.boundedString(message["username"], limit: PasswordAutofillPolicy.maxUsernameLength),
              let password = PasswordAutofillPolicy.boundedString(message["password"], limit: PasswordAutofillPolicy.maxPasswordLength),
              let step = PasswordSubmissionStep(rawValue: message["step"] as? String ?? "")
        else { return }
        let now = Date()
        let isNew = message["newPassword"] as? Bool ?? false
        if step == .username {
            if let memory = PasswordAutofillPolicy.stepMemory(origin: origin, username: username, now: now) {
                passwordState.stepMemory = memory
            }
            return
        }
        guard var submission = PasswordAutofillPolicy.mergedSubmission(
            origin: origin, username: username, password: password, isNewPassword: isNew,
            step: step, memory: passwordState.stepMemory, now: now
        ) else { return }
        if message["via"] as? String == "removed" {
            // The page took its password field away: the sign-in is over. A submit event moments earlier may know the username this report lost.
            if let pending = passwordState.pending, pending.submission.password == submission.password, submission.username.isEmpty {
                submission = pending.submission
            }
            passwordState.pending = nil
            delegate?.webContents(self, didCapturePasswordSubmission: submission)
            return
        }
        passwordState.pending = WebKitPasswordsState.Pending(submission: submission, date: now)
    }

    // MARK: - Navigation

    func passwordNavigationStarted() {
        dismissActivePasswordField()
        passwordState.resetDocument()
    }

    /// The document the sign-in led to is up. Whether it was a success is only known once that page has had a moment to show a sign-in form of its own.
    func passwordNavigationCommitted() {
        passwordState.resetDocument()
        guard var pending = passwordState.pending else { return }
        guard Date().timeIntervalSince(pending.date) <= PasswordAutofillPolicy.submissionLifetime else {
            passwordState.pending = nil
            return
        }
        pending.committed = true
        passwordState.pending = pending
        passwordState.sawLoginForm = false
        scheduleSubmissionDecision(after: 8)
    }

    func passwordNavigationFinished() {
        guard passwordState.pending?.committed == true else { return }
        // The page script looks for a sign-in form about 0.7s after load.
        scheduleSubmissionDecision(after: 1.0)
    }

    private func scheduleSubmissionDecision(after delay: TimeInterval) {
        passwordState.decisionTicket += 1
        let ticket = passwordState.decisionTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, self.passwordState.decisionTicket == ticket else { return }
                self.resolvePendingPasswordSubmission()
            }
        }
    }

    private func resolvePendingPasswordSubmission() {
        guard let pending = passwordState.pending, pending.committed else { return }
        passwordState.pending = nil
        guard !passwordState.sawLoginForm else { return }
        delegate?.webContents(self, didCapturePasswordSubmission: pending.submission)
    }

    // MARK: - Filling

    func fillPassword(into token: String, credentials: PasswordFillCredentials) async -> PasswordFillOutcome {
        guard let field = fillableField(token) else { return .fieldUnavailable }
        if let refusal = PasswordAutofillPolicy.refusal(credentialOrigin: credentials.origin, frameOrigin: field.origin) {
            return refusal
        }
        let result: (username: Bool, password: Bool)
        switch await runPasswordFill(field, mode: "login", username: credentials.username, password: credentials.password) {
        case .filled(let username, let password): result = (username, password)
        case .originChanged: return .refusedSiteMismatch
        case .unavailable: return .fieldUnavailable
        }
        if result.username, !result.password {
            // The first step of a multi-step sign-in: the password step that follows should offer this login first.
            passwordState.stepMemory = PasswordAutofillPolicy.stepMemory(origin: field.origin, username: credentials.username, now: Date())
        } else if result.password {
            passwordState.stepMemory = nil
        }
        return .filled(username: result.username, password: result.password)
    }

    func fillGeneratedPassword(_ password: String, into token: String) async -> PasswordFillOutcome {
        guard let field = fillableField(token), field.kind == .newPassword,
              password.count <= PasswordAutofillPolicy.maxPasswordLength
        else { return .fieldUnavailable }
        switch await runPasswordFill(field, mode: "generated", username: "", password: password) {
        case .filled(_, let filled): return .filled(username: false, password: filled)
        case .originChanged: return .refusedSiteMismatch
        case .unavailable: return .fieldUnavailable
        }
    }

    /// The reported field. A `WKFrameInfo` is a snapshot, so its security origin cannot say whether the frame has navigated since: the
    /// fill script compares the frame's live `location.origin` with `field.origin` instead (see `runPasswordFill`).
    private func fillableField(_ token: String) -> WebKitPasswordsState.Field? {
        guard passwordAutofillPermitted, let field = passwordState.fields[token] else { return nil }
        return field
    }

    private enum PasswordFillRun {
        case filled(username: Bool, password: Bool)
        /// The frame is no longer on the origin that reported the field; nothing was touched.
        case originChanged
        case unavailable
    }

    private func runPasswordFill(
        _ field: WebKitPasswordsState.Field, mode: String, username: String, password: String
    ) async -> PasswordFillRun {
        do {
            let value = try await webView.callAsyncJavaScript(
                "return window.__orbitPasswords ? window.__orbitPasswords.fill(token, username, password, mode, expectedOrigin) : null;",
                arguments: [
                    "token": field.token, "username": username, "password": password, "mode": mode,
                    "expectedOrigin": field.origin.absoluteString,
                ],
                in: field.frame,
                contentWorld: WebKitPasswordAutofill.world
            )
            guard let result = value as? [String: Any] else { return .unavailable }
            if result["reason"] as? String == PasswordAutofillScript.originChangedReason { return .originChanged }
            guard result["ok"] as? Bool == true else { return .unavailable }
            return .filled(username: result["username"] as? Bool ?? false, password: result["password"] as? Bool ?? false)
        } catch {
            return .unavailable
        }
    }
}
