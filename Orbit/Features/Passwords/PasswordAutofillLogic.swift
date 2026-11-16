import CoreGraphics
import Foundation

// Foundation-only decisions behind password autofill: what a field message may claim, whether a frame may be
// filled, what the suggestion panel offers, what a captured sign-in leads to, and where a field sits on screen.
// Compiled into OrbitTests, so nothing here may reach AppKit, WebKit or the app's models beyond SavedLogin,
// PasswordOrigin and PublicSuffixList (the one definition of "same site" for passwords).

// MARK: - Values shared by the engine and the app

nonisolated public enum PasswordFieldKind: String, Sendable, Equatable {
    case username
    case currentPassword
    case newPassword
}

/// What made the page report the field: gaining focus, or a click on a field that already had it.
nonisolated public enum PasswordFieldTrigger: String, Sendable, Equatable {
    case focus
    case click
}

/// A classified field the user is on. It carries no credentials; a fill names it by `token`.
nonisolated public struct PasswordFieldFocus: Sendable, Equatable {
    public var token: String
    public var kind: PasswordFieldKind
    public var trigger: PasswordFieldTrigger
    /// `scheme://host[:port]` of the frame that holds the field. Logins are matched against this, never against anything the page says.
    public var frameOrigin: URL
    public var pageURL: URL?
    public var isMainFrame: Bool
    /// AppKit screen coordinates (origin bottom-left).
    public var screenRect: CGRect
    /// True for https and for http on localhost; anything else needs an explicit choice and a warning.
    public var isSecure: Bool
    /// The username filled in the previous step of a multi-step sign-in on this site, so its login is offered first.
    public var preferredUsername: String?

    public init(
        token: String,
        kind: PasswordFieldKind,
        trigger: PasswordFieldTrigger = .focus,
        frameOrigin: URL,
        pageURL: URL? = nil,
        isMainFrame: Bool = true,
        screenRect: CGRect = .zero,
        isSecure: Bool,
        preferredUsername: String? = nil
    ) {
        self.token = token
        self.kind = kind
        self.trigger = trigger
        self.frameOrigin = frameOrigin
        self.pageURL = pageURL
        self.isMainFrame = isMainFrame
        self.screenRect = screenRect
        self.isSecure = isSecure
        self.preferredUsername = preferredUsername
    }
}

/// A sign-in the page performed, as typed by the user. Holds a password: never log or describe it.
nonisolated public struct PasswordSubmission: Sendable, Equatable, CustomStringConvertible {
    public var origin: URL
    public var username: String
    public var password: String
    /// The password is one the user chose for a new or changed password rather than one they entered to sign in.
    public var isNewPassword: Bool

    public init(origin: URL, username: String, password: String, isNewPassword: Bool) {
        self.origin = origin
        self.username = username
        self.password = password
        self.isNewPassword = isNewPassword
    }

    public var description: String { "PasswordSubmission(\(origin.absoluteString), <password withheld>)" }
}

/// The login to put into a page. The engine checks the frame against the origin the login was saved for: its site and its scheme.
nonisolated public struct PasswordFillCredentials: Sendable, Equatable, CustomStringConvertible {
    /// `SavedLogin.origin`: where the login was saved.
    public var origin: URL
    public var username: String
    public var password: String

    public init(origin: URL, username: String, password: String) {
        self.origin = origin
        self.username = username
        self.password = password
    }

    public var siteKey: String { PasswordAutofillPolicy.siteKey(of: origin) ?? "" }

    public var description: String { "PasswordFillCredentials(\(origin.absoluteString), <password withheld>)" }
}

nonisolated public enum PasswordFillOutcome: Equatable, Sendable {
    case filled(username: Bool, password: Bool)
    /// The frame's own registrable domain is not the one the login was saved for, or the frame is no longer on the origin that reported the field (it navigated after the field was reported).
    case refusedSiteMismatch
    /// The login was saved on https and the frame is plain http.
    case refusedInsecure
    /// The field is gone or was never reported by this page.
    case fieldUnavailable
    case unsupported

    public var didFill: Bool {
        if case .filled(let username, let password) = self { return username || password }
        return false
    }
}

// MARK: - Policy

nonisolated enum PasswordOffer: Equatable {
    case none
    case suggestions(showsLogins: Bool, showsStrongPassword: Bool)
    /// A plain-http page with saved logins: only an explicit choice, under a warning.
    case insecureWarning
}

nonisolated enum PasswordPromptDecision: Equatable {
    case nothing
    case save(username: String, password: String)
    case update(existing: SavedLogin, password: String)
}

nonisolated enum PasswordSubmissionStep: String, Equatable {
    /// A username and a password, or a password the page needs no username for.
    case full
    /// The first step of a multi-step sign-in: a username or email and no password yet.
    case username
    /// A password with no username field on the page.
    case password
}

/// What an earlier step of a multi-step sign-in on a site learned.
nonisolated struct PasswordStepMemory: Equatable {
    var siteKey: String
    var username: String
    var date: Date
}

nonisolated enum PasswordAutofillPolicy {

    static let maxUsernameLength = 512
    static let maxPasswordLength = 4096
    static let maxTokenLength = 64
    /// A captured sign-in older than this is not offered for saving.
    static let submissionLifetime: TimeInterval = 30
    /// How long a username entered in one step is remembered for the password step.
    static let stepLifetime: TimeInterval = 600

    // MARK: Message validation

    /// The frame's origin from WebKit's own security origin, not from anything the page sent. Nil for any scheme but http(s).
    static func origin(scheme: String, host: String, port: Int) -> URL? {
        let scheme = scheme.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var text = "\(scheme)://\(bracketed)"
        if port > 0 { text += ":\(port)" }
        guard let url = URL(string: text), let normalized = PasswordOrigin(url: url) else { return nil }
        return URL(string: normalized.origin)
    }

    static func isValidToken(_ value: Any?) -> Bool {
        guard let token = value as? String, (8...maxTokenLength).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    static func kind(from value: Any?) -> PasswordFieldKind? {
        (value as? String).flatMap(PasswordFieldKind.init(rawValue:))
    }

    static func trigger(from value: Any?) -> PasswordFieldTrigger {
        (value as? String).flatMap(PasswordFieldTrigger.init(rawValue:)) ?? .focus
    }

    /// A rectangle in CSS pixels. Nil when a number is missing, not finite, absurdly large or the box is empty.
    static func rect(from value: Any?) -> CGRect? {
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) < 1_000_000 else { return nil }
            return value
        }
        guard let x = number("x"), let y = number("y"), let width = number("w"), let height = number("h"),
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func boundedString(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, text.count <= limit else { return nil }
        return text
    }

    // MARK: Filling

    static func isSecureForFill(origin: URL) -> Bool {
        guard let scheme = origin.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = origin.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func siteKey(of origin: URL) -> String? {
        guard let host = origin.host()?.lowercased(), !host.isEmpty else { return nil }
        return PublicSuffixList.registrableDomain(ofHost: host)
    }

    /// Nil when the login saved for `credentialOrigin` may be put into a field of a frame with this origin: the same registrable domain, and
    /// never an https login into an http frame (even localhost). An http login in an http frame is allowed because the person chose its row
    /// under the insecure-page warning; no caller flag can widen this.
    static func refusal(credentialOrigin: URL, frameOrigin: URL) -> PasswordFillOutcome? {
        guard let credentialSite = siteKey(of: credentialOrigin), let frameSite = siteKey(of: frameOrigin), credentialSite == frameSite else {
            return .refusedSiteMismatch
        }
        guard let credentialScheme = credentialOrigin.scheme?.lowercased(), let frameScheme = frameOrigin.scheme?.lowercased(),
              credentialScheme == "http" || credentialScheme == "https", frameScheme == "http" || frameScheme == "https"
        else { return .refusedSiteMismatch }
        if credentialScheme == "https", frameScheme != "https" { return .refusedInsecure }
        return nil
    }

    // MARK: Offering

    /// The logins that may be offered in a frame: those `refusal` would let through. Applied again here so the list shown never depends on the vault alone.
    static func offerable(_ logins: [SavedLogin], frameOrigin: URL) -> [SavedLogin] {
        logins.filter { login in
            guard let origin = URL(string: login.origin) else { return false }
            return refusal(credentialOrigin: origin, frameOrigin: frameOrigin) == nil
        }
    }

    static func offer(kind: PasswordFieldKind, logins: [SavedLogin], frameOrigin: URL, offersAutofill: Bool) -> PasswordOffer {
        guard offersAutofill else { return .none }
        let loginCount = offerable(logins, frameOrigin: frameOrigin).count
        guard isSecureForFill(origin: frameOrigin) else {
            return kind != .newPassword && loginCount > 0 ? .insecureWarning : .none
        }
        if kind == .newPassword { return .suggestions(showsLogins: false, showsStrongPassword: true) }
        return loginCount > 0 ? .suggestions(showsLogins: true, showsStrongPassword: false) : .none
    }

    /// The login for the username the previous step filled comes first; the rest keep the vault's order.
    static func ordered(_ logins: [SavedLogin], preferredUsername: String?) -> [SavedLogin] {
        guard let preferredUsername, !preferredUsername.isEmpty else { return logins }
        let preferred = logins.filter { $0.username == preferredUsername }
        return preferred + logins.filter { $0.username != preferredUsername }
    }

    /// The remembered username applies to a password step on the same site shortly after it was entered.
    static func preferredUsername(for origin: URL, memory: PasswordStepMemory?, now: Date) -> String? {
        guard let memory, let site = siteKey(of: origin), site == memory.siteKey,
              now.timeIntervalSince(memory.date) <= stepLifetime
        else { return nil }
        return memory.username
    }

    // MARK: Captured sign-ins

    /// A username-only step is remembered and never saved; a password-only step borrows the remembered username.
    static func mergedSubmission(
        origin: URL,
        username: String,
        password: String,
        isNewPassword: Bool,
        step: PasswordSubmissionStep,
        memory: PasswordStepMemory?,
        now: Date
    ) -> PasswordSubmission? {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step {
        case .username:
            return nil
        case .full:
            return password.isEmpty ? nil : PasswordSubmission(origin: origin, username: username, password: password, isNewPassword: isNewPassword)
        case .password:
            guard !password.isEmpty else { return nil }
            let borrowed = username.isEmpty ? preferredUsername(for: origin, memory: memory, now: now) ?? "" : username
            return PasswordSubmission(origin: origin, username: borrowed, password: password, isNewPassword: isNewPassword)
        }
    }

    /// The step memory a username-only submission leaves behind.
    static func stepMemory(origin: URL, username: String, now: Date) -> PasswordStepMemory? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let site = siteKey(of: origin) else { return nil }
        return PasswordStepMemory(siteKey: site, username: trimmed, date: now)
    }

    /// `existing` is what the vault holds for the submission's origin (`logins(matching:)`), which can include other origins of the same site.
    /// An update is only ever for the login saved for this exact origin and username: a login of another origin of the site is never changed
    /// by a sign-in on this one, so a username that exists only elsewhere is offered as a new entry for this origin.
    static func promptDecision(
        submission: PasswordSubmission,
        existing: [SavedLogin],
        isNeverSave: Bool,
        offersToSave: Bool
    ) -> PasswordPromptDecision {
        guard offersToSave, !isNeverSave, !submission.password.isEmpty else { return .nothing }
        let origin = submission.origin.absoluteString
        let sameOrigin = existing.filter { $0.origin == origin }
        var username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty {
            // A change-password page has no username field: it can only mean the one login this origin has.
            guard submission.isNewPassword, sameOrigin.count == 1, let only = sameOrigin.first else { return .nothing }
            username = only.username
        }
        guard let match = sameOrigin.first(where: { $0.username == username }) else {
            return .save(username: username, password: submission.password)
        }
        return match.password == submission.password ? .nothing : .update(existing: match, password: submission.password)
    }

    /// The origin as the save prompt names it: the full host (a "www." or "accounts." login is another login than the bare domain's) and any non-default port.
    static func displayOrigin(_ origin: String) -> String {
        guard let parsed = PasswordOrigin(origin: origin), let url = URL(string: parsed.origin), var host = url.host() else { return origin }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    // MARK: Editing

    /// The origin a login typed into the settings pane is saved for: "example.com" means https://example.com. Nil for anything that is not an http(s) site.
    static func parseWebsite(_ text: String) -> PasswordOrigin? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return nil }
        return PasswordOrigin(url: url)
    }

    // MARK: Listing

    /// Host as shown in the settings list: lower case, without a leading "www.".
    static func displayHost(ofOrigin origin: String) -> String {
        guard let host = URL(string: origin)?.host()?.lowercased() else { return origin }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Logins whose site or username contains every word of `query`, ordered by site then username.
    static func filter(_ logins: [SavedLogin], query: String) -> [SavedLogin] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = words.isEmpty ? logins : logins.filter { login in
            let haystack = (login.origin + " " + login.username).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.sorted { lhs, rhs in
            let left = displayHost(ofOrigin: lhs.origin)
            let right = displayHost(ofOrigin: rhs.origin)
            if left != right { return left < right }
            return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
        }
    }
}

// MARK: - Geometry

nonisolated enum PasswordFieldGeometry {

    /// A field's box from the page, in CSS pixels relative to the top frame's visible viewport (so any scroll is already applied), as a rectangle on screen.
    /// `viewFrameOnScreen` is the web view's bounds in AppKit screen coordinates (origin bottom-left); one CSS pixel is `zoom` points.
    /// Nil when the field lies wholly outside the view.
    static func screenRect(cssRect: CGRect, zoom: Double, viewFrameOnScreen: CGRect) -> CGRect? {
        let scale = CGFloat(zoom.isFinite && zoom > 0 ? zoom : 1)
        let width = cssRect.width * scale
        let height = cssRect.height * scale
        let rect = CGRect(
            x: viewFrameOnScreen.minX + cssRect.minX * scale,
            y: viewFrameOnScreen.maxY - (cssRect.minY * scale + height),
            width: width,
            height: height
        )
        return rect.intersects(viewFrameOnScreen) ? rect : nil
    }
}
