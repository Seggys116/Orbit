import CryptoKit
import Foundation

nonisolated enum SystemPasswordSaveDecision: Equatable, Sendable {
    case nothing
    case save(username: String)
    case update(username: String)
}

/// The record of a login Orbit filled from Passwords, kept only as long as a sign-in with it might follow. Holds a digest, never the password.
nonisolated struct SystemPasswordFillRecord: Equatable, Sendable {
    var siteKey: String
    var username: String
    var passwordDigest: [UInt8]
    var date: Date

    static let lifetime: TimeInterval = 600

    init(origin: URL, username: String, password: String, date: Date) {
        siteKey = PasswordAutofillPolicy.siteKey(of: origin) ?? ""
        self.username = username
        passwordDigest = SystemPasswordPolicy.digest(password)
        self.date = date
    }
}

/// What Orbit offers around Passwords, as pure decisions.
nonisolated enum SystemPasswordPolicy {

    /// The host Passwords is asked about: the frame's own host, lower case, with no port and no trailing dot.
    static func host(of origin: URL) -> String? {
        guard var host = origin.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : host
    }

    static func digest(_ password: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(password.utf8)))
    }

    /// The login for the username the previous step filled comes first; the rest keep the order Passwords gave.
    static func ordered(_ logins: [SystemPasswordLogin], preferredUsername: String?) -> [SystemPasswordLogin] {
        guard let preferredUsername, !preferredUsername.isEmpty else { return logins }
        let preferred = logins.filter { $0.username == preferredUsername }
        return preferred + logins.filter { $0.username != preferredUsername }
    }

    /// The title of a login's row: the username, or Passwords' own title for a login saved without one.
    static func rowTitle(for login: SystemPasswordLogin) -> String {
        if !login.username.isEmpty { return login.username }
        return login.customTitle ?? "Password with no user name"
    }

    /// A fill record that still applies to a sign-in on `origin` at `now`.
    static func liveRecord(_ record: SystemPasswordFillRecord?, origin: URL, now: Date) -> SystemPasswordFillRecord? {
        guard let record, let site = PasswordAutofillPolicy.siteKey(of: origin), site == record.siteKey,
              now.timeIntervalSince(record.date) <= SystemPasswordFillRecord.lifetime
        else { return nil }
        return record
    }

    /// `knownUsernames` is what Passwords lists for the sign-in's host now. Passwords never reveals a stored password without the person
    /// authenticating, so a sign-in with a known username is offered as an update only when it is clearly a new password: the page said
    /// so, or it is not the password Orbit filled for that username moments ago.
    static func saveDecision(
        submission: PasswordSubmission,
        knownUsernames: [String],
        filled: SystemPasswordFillRecord?,
        now: Date
    ) -> SystemPasswordSaveDecision {
        guard !submission.password.isEmpty, PasswordAutofillPolicy.isSecureForFill(origin: submission.origin) else { return .nothing }
        let known = knownUsernames
        var username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty {
            // A change-password page has no username field: it can only mean the one login the site has.
            guard submission.isNewPassword, known.count == 1, let only = known.first else { return .nothing }
            username = only
        }
        guard known.contains(username) else { return .save(username: username) }
        if submission.isNewPassword { return .update(username: username) }
        if let record = liveRecord(filled, origin: submission.origin, now: now), record.username == username,
           record.passwordDigest != digest(submission.password) {
            return .update(username: username)
        }
        return .nothing
    }
}
