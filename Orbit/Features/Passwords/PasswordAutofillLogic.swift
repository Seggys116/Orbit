import CoreGraphics
import Foundation

// Foundation-only decisions behind password autofill: what a field message may claim, whether a frame may be
// filled, what a captured sign-in leads to, and where a field sits on screen. Compiled into OrbitTests, so nothing
// here may reach AppKit, WebKit or the app's models beyond PublicSuffixList (the one definition of "same site").

// MARK: - Values shared by the engine and the app

nonisolated public enum PasswordFieldKind: String, Sendable, Equatable {
    case username
    case currentPassword
    case newPassword
    case oneTimeCode
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

/// The login to put into a page. The engine checks the frame against the origin the login belongs to: its site and its scheme.
nonisolated public struct PasswordFillCredentials: Sendable, Equatable, CustomStringConvertible {
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
    /// The frame's own registrable domain is not the one the login belongs to, or the frame is no longer on the origin that reported the field (it navigated after the field was reported).
    case refusedSiteMismatch
    /// The login belongs to https and the frame is plain http.
    case refusedInsecure
    /// The field is gone or was never reported by this page.
    case fieldUnavailable
    case unsupported

    public var didFill: Bool {
        if case .filled(let username, let password) = self { return username || password }
        return false
    }
}

/// An origin as `scheme://host[:port]` in lower case, with no path, credentials, or default port.
nonisolated struct PasswordOrigin: Equatable, Sendable {
    let origin: String
    /// The registrable domain of the host by the Public Suffix List, so tenants of a shared suffix such as github.io are separate sites.
    let siteKey: String

    var isHTTPS: Bool { origin.hasPrefix("https://") }

    /// Nil unless `url` is http or https and has a usable host.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased()
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // A rooted name and its unrooted form are the same site.
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "%" || CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        var origin = "\(scheme)://" + (host.contains(":") ? "[\(host)]" : host)
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { origin += ":\(port)" }
        self.origin = origin
        self.siteKey = PublicSuffixList.registrableDomain(ofHost: host)
    }

    init?(origin string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }
}

// MARK: - Policy

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
    static let maxOneTimeCodeLength = 32
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

    /// Letters and digits only, and short: a code from Passwords is never anything else, and nothing else may reach a page through this path.
    static func isValidOneTimeCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= maxOneTimeCodeLength else { return false }
        return code.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
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

    /// Nil when a login that belongs to `credentialOrigin` may be put into a field of a frame with this origin: the same registrable domain, and
    /// never an https login into an http frame (even localhost). No caller flag can widen this.
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

    /// Logins from Passwords are offered only in a secure frame (https, or http on this Mac), and only on a sign-in field.
    static func offersLogins(kind: PasswordFieldKind, frameOrigin: URL) -> Bool {
        (kind == .username || kind == .currentPassword) && isSecureForFill(origin: frameOrigin)
    }

    /// A sign-up form's new password field is offered the way Passwords makes an account, in a secure frame.
    static func offersAccountCreation(kind: PasswordFieldKind, frameOrigin: URL) -> Bool {
        kind == .newPassword && isSecureForFill(origin: frameOrigin)
    }

    static func offersOneTimeCodes(kind: PasswordFieldKind, frameOrigin: URL) -> Bool {
        kind == .oneTimeCode && isSecureForFill(origin: frameOrigin)
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

    /// The origin as a prompt names it: the full host and any non-default port.
    static func displayOrigin(_ origin: String) -> String {
        guard let parsed = PasswordOrigin(origin: origin), let url = URL(string: parsed.origin), var host = url.host() else { return origin }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = url.port { return "\(host):\(port)" }
        return host
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
