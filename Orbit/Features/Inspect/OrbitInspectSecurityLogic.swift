// Foundation-only (no AppKit, SwiftUI, WebKit or Security.framework): compiled into the unit test bundle with OrbitInspectApplicationLogic.swift and OrbitInspectDecode.swift.

import Foundation

enum OrbitSecurityState: String, Codable, Sendable {
    case pass, warn, fail, info

    /// Higher is worse. `info` ranks below `pass` for roll-ups because it carries no verdict.
    var severity: Int {
        switch self {
        case .info: return 0
        case .pass: return 1
        case .warn: return 2
        case .fail: return 3
        }
    }

    static func worst(_ states: [OrbitSecurityState]) -> OrbitSecurityState {
        states.max { $0.severity < $1.severity } ?? .info
    }
}

enum OrbitSecuritySection: String, CaseIterable, Identifiable, Sendable {
    case connection, content, headers, cookies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "Connection"
        case .content: return "Content"
        case .headers: return "Headers and policy"
        case .cookies: return "Cookies"
        }
    }

    var symbol: String {
        switch self {
        case .connection: return "lock"
        case .content: return "doc.richtext"
        case .headers: return "shield.lefthalf.filled"
        case .cookies: return "circle.grid.2x2"
        }
    }
}

enum OrbitSecurityOverall: String, Sendable {
    case secure, issues, notSecure

    var title: String {
        switch self {
        case .secure: return "Secure"
        case .issues: return "Issues found"
        case .notSecure: return "Not secure"
        }
    }

    var symbol: String {
        switch self {
        case .secure: return "lock.shield.fill"
        case .issues: return "exclamationmark.shield.fill"
        case .notSecure: return "xmark.shield.fill"
        }
    }
}

struct OrbitSecurityFinding: Equatable, Sendable {
    var text: String
    var state: OrbitSecurityState = .info
    var nodeID: Int? = nil
    var selector: String? = nil
    var url: String? = nil
}

struct OrbitSecurityCheck: Identifiable, Equatable, Sendable {
    var id: String
    var section: OrbitSecuritySection
    var title: String
    var state: OrbitSecurityState
    var value: String?
    var summary: String
    var advice: String
    var findings: [OrbitSecurityFinding] = []
    /// Lighthouse weight. Checks that carry no verdict (state `info`) never count towards a score.
    var weight: Double
    /// A failure here makes the page "Not secure" as a whole.
    var isCritical: Bool = false
}

struct OrbitSecurityRow: Equatable, Sendable {
    var label: String
    var value: String
}

nonisolated struct OrbitSecurityCertificate: Equatable, Sendable {
    var subject: String
    var issuer: String
    var notBefore: Date?
    var notAfter: Date?
    var serialNumber: String?
    var subjectAlternativeNames: [String] = []
    var keyType: String?
    var keySizeBits: Int?
    var signatureAlgorithm: String?
}

nonisolated enum OrbitSecurityTrust: Equatable, Sendable {
    case trusted
    case untrusted(String)
    /// No server trust was available: a non-TLS page, or the document has not committed yet.
    case unavailable
}

struct OrbitSecurityRequest: Equatable, Sendable {
    var url: String
    var type: String
    var nodeID: Int? = nil
    var selector: String? = nil
}

struct OrbitSecurityForm: Equatable, Sendable {
    var action: String
    var method: String
    var hasPassword: Bool
    var nodeID: Int
    var selector: String
}

struct OrbitSecurityFrame: Equatable, Sendable {
    var src: String
    var isSandboxed: Bool
    var isCrossOrigin: Bool
    var nodeID: Int
    var selector: String
}

struct OrbitSecurityScript: Equatable, Sendable {
    var url: String
    /// "script" or "link" (a stylesheet).
    var tag: String
    var hasIntegrity: Bool
    var nodeID: Int
    var selector: String
}

struct OrbitSecurityLink: Equatable, Sendable {
    var href: String
    var rel: String
    var nodeID: Int
    var selector: String
}

struct OrbitSecurityInput: Sendable {
    var pageURL: String = ""
    var certificates: [OrbitSecurityCertificate] = []
    var trust: OrbitSecurityTrust = .unavailable
    var hasOnlySecureContent: Bool? = nil
    /// Header names lowercased. Nil means the document response was not captured (reload to capture it).
    var documentHeaders: [String: String]? = nil
    var metaCSP: [String] = []
    var metaReferrer: String? = nil
    var requests: [OrbitSecurityRequest] = []
    var domReferences: [OrbitSecurityRequest] = []
    var forms: [OrbitSecurityForm] = []
    var frames: [OrbitSecurityFrame] = []
    /// Scripts and stylesheets from another origin than the page.
    var scripts: [OrbitSecurityScript] = []
    /// Links to other origins that open in a new tab.
    var links: [OrbitSecurityLink] = []
    var libraries: [LHLibrary] = []
    var cookies: [OrbitApplicationLogic.CookieRecord] = []
    var now: Date = Date()
}

struct OrbitSecurityCookieRow: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var domain: String
    var secure: OrbitSecurityState
    var httpOnly: OrbitSecurityState
    var sameSite: OrbitSecurityState
    var sameSiteValue: String
    var issues: [String]
}

struct OrbitSecurityReport: Equatable, Sendable {
    var pageURL: String
    var checks: [OrbitSecurityCheck]
    var certificates: [OrbitSecurityCertificate]
    var cookieRows: [OrbitSecurityCookieRow]
    var overall: OrbitSecurityOverall
    var headline: String
    var passCount: Int
    var warnCount: Int
    var failCount: Int
    var infoCount: Int

    func checks(in section: OrbitSecuritySection) -> [OrbitSecurityCheck] {
        checks.filter { $0.section == section }
    }
}

struct OrbitSecurityCSPDirective: Equatable, Sendable {
    var name: String
    var values: [String]
}

struct OrbitSecurityCSPPolicy: Equatable, Sendable {
    var directives: [OrbitSecurityCSPDirective]
    var reportOnly: Bool
    var fromMeta: Bool

    func values(for name: String) -> [String]? {
        directives.first { $0.name == name }?.values
    }

    func effectiveValues(for name: String) -> [String]? {
        values(for: name) ?? values(for: "default-src")
    }
}

struct OrbitSecurityCSPFinding: Equatable, Sendable {
    var state: OrbitSecurityState
    var directive: String
    var message: String

    var key: String { "\(directive)|\(message)" }
}

struct OrbitSecurityHSTS: Equatable, Sendable {
    var maxAge: Int?
    var includeSubDomains: Bool
    var preload: Bool
}

enum OrbitSecurityLogic {

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasPrefix("127.")
    }

    static func isInsecureURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("ws://")
    }

    private static func isInsecureRemote(_ reference: String, relativeTo page: URL?) -> Bool {
        guard let url = URL(string: reference, relativeTo: page)?.absoluteURL else { return false }
        return isInsecureURL(url.absoluteString) && !isLocalHost(url.host)
    }

    /// RFC 6125 style host match: a wildcard covers exactly one leading label.
    static func hostMatches(host: String, pattern: String) -> Bool {
        let host = host.lowercased()
        let pattern = pattern.lowercased()
        if host == pattern { return true }
        guard pattern.hasPrefix("*.") else { return false }
        let suffix = String(pattern.dropFirst(1))
        guard host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    static func daysUntil(_ date: Date, now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    static func expiryDescription(notAfter: Date?, now: Date) -> String {
        guard let notAfter else { return "Expiry date unknown" }
        if notAfter < now {
            let daysAgo = Int((now.timeIntervalSince(notAfter) / 86_400).rounded(.down))
            switch daysAgo {
            case 0: return "Expired today"
            case 1: return "Expired yesterday"
            default: return "Expired \(daysAgo) days ago"
            }
        }
        let days = daysUntil(notAfter, now: now)
        switch days {
        case 0: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return "Expires in \(days) days"
        }
    }

    static func validityDescription(notBefore: Date?, notAfter: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let from = notBefore.map { formatter.string(from: $0) } ?? "unknown"
        let to = notAfter.map { formatter.string(from: $0) } ?? "unknown"
        return "\(from) to \(to) (UTC)"
    }

    /// `kSecAttrKeyType` is a CFString holding a number: "42" is RSA, "73" is elliptic curve.
    nonisolated static func keyTypeName(fromAttribute attribute: String) -> String? {
        switch attribute {
        case "42": return "RSA"
        case "73": return "EC"
        default: return nil
        }
    }

    static func keyDescription(type: String?, bits: Int?) -> String {
        switch (type, bits) {
        case let (type?, bits?): return "\(type) \(bits)-bit"
        case let (type?, nil): return type
        case let (nil, bits?): return "\(bits)-bit key"
        case (nil, nil): return "Unknown"
        }
    }

    private nonisolated static let signatureOIDs: [String: String] = [
        "1.2.840.113549.1.1.4": "MD5 with RSA",
        "1.2.840.113549.1.1.5": "SHA-1 with RSA",
        "1.2.840.113549.1.1.11": "SHA-256 with RSA",
        "1.2.840.113549.1.1.12": "SHA-384 with RSA",
        "1.2.840.113549.1.1.13": "SHA-512 with RSA",
        "1.2.840.113549.1.1.10": "RSA-PSS",
        "1.2.840.10045.4.1": "SHA-1 with ECDSA",
        "1.2.840.10045.4.3.2": "SHA-256 with ECDSA",
        "1.2.840.10045.4.3.3": "SHA-384 with ECDSA",
        "1.2.840.10045.4.3.4": "SHA-512 with ECDSA",
        "1.3.101.112": "Ed25519",
    ]

    /// Security.framework reports either a dotted OID or a readable name. Both come out readable.
    nonisolated static func signatureAlgorithmName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = signatureOIDs[trimmed] { return known }
        return trimmed.replacingOccurrences(of: " Encryption", with: "")
    }

    static func isWeakSignature(_ name: String?) -> Bool {
        guard let lower = name?.lowercased() else { return false }
        let compact = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        return compact.contains("sha1") || compact.contains("md5") || compact.contains("md2")
    }

    static func certificateRows(_ certificate: OrbitSecurityCertificate, now: Date) -> [OrbitSecurityRow] {
        var rows = [
            OrbitSecurityRow(label: "Subject", value: certificate.subject),
            OrbitSecurityRow(label: "Issuer", value: certificate.issuer),
            OrbitSecurityRow(label: "Valid", value: validityDescription(notBefore: certificate.notBefore, notAfter: certificate.notAfter)),
            OrbitSecurityRow(label: "Expiry", value: expiryDescription(notAfter: certificate.notAfter, now: now)),
            OrbitSecurityRow(label: "Public key", value: keyDescription(type: certificate.keyType, bits: certificate.keySizeBits)),
            OrbitSecurityRow(label: "Signature", value: certificate.signatureAlgorithm ?? "Unknown"),
        ]
        if !certificate.subjectAlternativeNames.isEmpty {
            rows.append(OrbitSecurityRow(label: "Alternative names", value: certificate.subjectAlternativeNames.joined(separator: ", ")))
        }
        if let serial = certificate.serialNumber, !serial.isEmpty {
            rows.append(OrbitSecurityRow(label: "Serial", value: serial))
        }
        return rows
    }

    static func parseHSTS(_ value: String) -> OrbitSecurityHSTS {
        var maxAge: Int?
        var include = false
        var preload = false
        for part in value.split(separator: ";") {
            let token = part.trimmingCharacters(in: .whitespaces)
            let lower = token.lowercased()
            if lower.hasPrefix("max-age") {
                let number = token.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                maxAge = Int(number)
            } else if lower == "includesubdomains" {
                include = true
            } else if lower == "preload" {
                preload = true
            }
        }
        return OrbitSecurityHSTS(maxAge: maxAge, includeSubDomains: include, preload: preload)
    }

    /// The first occurrence of a directive wins, as in the specification.
    static func parseCSP(_ text: String, reportOnly: Bool, fromMeta: Bool = false) -> [OrbitSecurityCSPPolicy] {
        text.split(separator: ",").compactMap { rawPolicy in
            var directives: [OrbitSecurityCSPDirective] = []
            var seen = Set<String>()
            for rawDirective in rawPolicy.split(separator: ";") {
                let tokens = rawDirective.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
                guard let first = tokens.first else { continue }
                let name = first.lowercased()
                guard seen.insert(name).inserted else { continue }
                directives.append(OrbitSecurityCSPDirective(name: name, values: Array(tokens.dropFirst())))
            }
            guard !directives.isEmpty else { return nil }
            return OrbitSecurityCSPPolicy(directives: directives, reportOnly: reportOnly, fromMeta: fromMeta)
        }
    }

    private static func isNonceOrHash(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasPrefix("'nonce-") || lower.hasPrefix("'sha256-") || lower.hasPrefix("'sha384-") || lower.hasPrefix("'sha512-")
    }

    private static func findings(for policy: OrbitSecurityCSPPolicy) -> [OrbitSecurityCSPFinding] {
        var out: [OrbitSecurityCSPFinding] = []

        if let scripts = policy.effectiveValues(for: "script-src") {
            let lower = scripts.map { $0.lowercased() }
            let hasNonceOrHash = scripts.contains(where: isNonceOrHash)
            let strictDynamic = lower.contains("'strict-dynamic'") && hasNonceOrHash
            if lower.contains("'unsafe-inline'") && !hasNonceOrHash {
                out.append(.init(state: .fail, directive: "script-src",
                                 message: "'unsafe-inline' lets any injected inline script run, which defeats XSS protection."))
            }
            if lower.contains("'unsafe-eval'") {
                out.append(.init(state: .warn, directive: "script-src",
                                 message: "'unsafe-eval' allows eval() and similar string-to-code calls."))
            }
            if !strictDynamic {
                if lower.contains("*") {
                    out.append(.init(state: .fail, directive: "script-src",
                                     message: "The wildcard * allows scripts from any origin."))
                }
                for scheme in ["https:", "http:", "data:"] where lower.contains(scheme) {
                    out.append(.init(state: .fail, directive: "script-src",
                                     message: "The scheme source \(scheme) allows scripts from any \(scheme.dropLast()) origin."))
                }
                for token in scripts where token.hasPrefix("*.") || (token.contains("*") && token != "*") {
                    out.append(.init(state: .warn, directive: "script-src",
                                     message: "The wildcard host \(token) trusts every subdomain."))
                }
                for token in scripts where token.lowercased().hasPrefix("http://") {
                    out.append(.init(state: .warn, directive: "script-src",
                                     message: "\(token) allows scripts over plain HTTP."))
                }
            }
        } else {
            out.append(.init(state: .fail, directive: "script-src",
                             message: "Neither script-src nor default-src is set, so scripts from any origin can run."))
        }

        if let styles = policy.effectiveValues(for: "style-src") {
            let lower = styles.map { $0.lowercased() }
            if lower.contains("'unsafe-inline'") && !styles.contains(where: isNonceOrHash) {
                out.append(.init(state: .warn, directive: "style-src",
                                 message: "'unsafe-inline' allows injected inline styles, which can leak data or restyle the page."))
            }
            if lower.contains("*") {
                out.append(.init(state: .warn, directive: "style-src", message: "The wildcard * allows styles from any origin."))
            }
        }

        if let objects = policy.effectiveValues(for: "object-src") {
            let lower = objects.map { $0.lowercased() }
            if lower != ["'none'"], lower.contains("*") || lower.contains("https:") || lower.contains("http:") || lower.contains("data:") {
                out.append(.init(state: .warn, directive: "object-src",
                                 message: "object-src is broad. Set object-src 'none' unless you embed plugins."))
            }
        } else {
            out.append(.init(state: .warn, directive: "object-src",
                             message: "object-src is missing. Set object-src 'none' to block plugin content."))
        }

        // base-uri has no default-src fallback.
        if let base = policy.values(for: "base-uri") {
            if base.map({ $0.lowercased() }).contains("*") {
                out.append(.init(state: .warn, directive: "base-uri", message: "base-uri * lets injected <base> tags redirect relative URLs."))
            }
        } else {
            out.append(.init(state: .warn, directive: "base-uri",
                             message: "base-uri is missing. Set base-uri 'self' or 'none' so injected <base> tags cannot redirect relative URLs."))
        }

        // frame-ancestors only works in a header.
        if let ancestors = policy.values(for: "frame-ancestors") {
            if ancestors.contains("*") {
                out.append(.init(state: .warn, directive: "frame-ancestors", message: "frame-ancestors * lets any site frame this page."))
            }
        } else {
            let hint = policy.fromMeta ? " Meta policies cannot set it; send it in the header." : ""
            out.append(.init(state: .warn, directive: "frame-ancestors",
                             message: "frame-ancestors is missing, so the CSP does not stop other sites framing this page.\(hint)"))
        }

        return out
    }

    /// With several enforced policies a finding only counts when no policy resolves it: every policy must allow a load, so a second can only tighten the first.
    static func gradeCSP(_ policies: [OrbitSecurityCSPPolicy]) -> [OrbitSecurityCSPFinding] {
        let enforced = policies.filter { !$0.reportOnly }
        if !enforced.isEmpty {
            let perPolicy = enforced.map { findings(for: $0) }
            guard var shared = perPolicy.first else { return [] }
            for other in perPolicy.dropFirst() {
                let keys = Set(other.map(\.key))
                shared = shared.filter { keys.contains($0.key) }
            }
            return shared
        }
        let reportOnly = policies.filter(\.reportOnly)
        guard !reportOnly.isEmpty else {
            return [.init(state: .fail, directive: "content-security-policy", message: "No Content-Security-Policy is set.")]
        }
        var out: [OrbitSecurityCSPFinding] = [
            .init(state: .warn, directive: "content-security-policy-report-only",
                  message: "The policy is report-only: violations are reported but nothing is blocked."),
        ]
        out += findings(for: reportOnly[0])
        return out
    }

    private struct HeaderVerdict {
        var state: OrbitSecurityState
        var summary: String
    }

    private static func gradeReferrerPolicy(_ value: String?) -> HeaderVerdict {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return HeaderVerdict(state: .warn, summary: "Not set. The browser default applies; set it explicitly.")
        }
        // The last token the browser recognises wins.
        let known: Set<String> = [
            "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin",
            "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url",
        ]
        let tokens = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let effective = tokens.last(where: { known.contains($0) }) else {
            return HeaderVerdict(state: .warn, summary: "\"\(value)\" is not a valid policy, so it is ignored.")
        }
        switch effective {
        case "unsafe-url":
            return HeaderVerdict(state: .fail, summary: "unsafe-url sends the full URL, including path and query, to every site.")
        case "no-referrer-when-downgrade":
            return HeaderVerdict(state: .warn, summary: "Sends the full URL to every HTTPS site, including other origins.")
        case "origin-when-cross-origin":
            return HeaderVerdict(state: .warn, summary: "Sends the origin even when a request is downgraded to HTTP.")
        default:
            return HeaderVerdict(state: .pass, summary: "\(effective) limits what the Referer header reveals.")
        }
    }

    private static func gradeClickjacking(xfo: String?, ancestors: [String]?) -> HeaderVerdict {
        if let ancestors {
            if ancestors.contains("*") {
                return HeaderVerdict(state: .fail, summary: "frame-ancestors * lets any site frame this page.")
            }
            return HeaderVerdict(state: .pass, summary: "frame-ancestors restricts which sites can frame this page.")
        }
        if let xfo {
            let normalized = xfo.trimmingCharacters(in: .whitespaces).lowercased()
            if normalized == "deny" || normalized == "sameorigin" {
                return HeaderVerdict(state: .pass, summary: "X-Frame-Options \(normalized.uppercased()) blocks framing by other sites.")
            }
            if normalized.hasPrefix("allow-from") {
                return HeaderVerdict(state: .warn, summary: "ALLOW-FROM is obsolete and ignored by current browsers. Use frame-ancestors.")
            }
            return HeaderVerdict(state: .fail, summary: "\"\(xfo)\" is not a valid X-Frame-Options value.")
        }
        return HeaderVerdict(state: .fail, summary: "No X-Frame-Options or frame-ancestors: other sites can frame this page.")
    }


    private static let sensitiveNameFragments = ["sess", "sid", "token", "auth", "jwt", "login", "account"]

    static func looksSensitive(cookieName: String) -> Bool {
        let lower = cookieName.lowercased()
        if lower.contains("csrf") || lower.contains("xsrf") { return false }
        return sensitiveNameFragments.contains { lower.contains($0) }
    }

    static func cookieRows(
        cookies: [OrbitApplicationLogic.CookieRecord], pageURL: String
    ) -> [OrbitSecurityCookieRow] {
        guard let url = URL(string: pageURL) else { return [] }
        let https = url.scheme?.lowercased() == "https"
        let local = isLocalHost(url.host)
        return cookies
            .filter { OrbitApplicationLogic.cookie($0, matchesURL: url) }
            .map { cookie in
                var issues: [String] = []

                let secure: OrbitSecurityState
                if cookie.isSecure {
                    secure = .pass
                } else if https {
                    secure = .fail
                    issues.append("Missing Secure: it is also sent over plain HTTP.")
                } else {
                    secure = local ? .info : .warn
                    if !local { issues.append("Sent over plain HTTP. This page is not served over HTTPS.") }
                }

                let httpOnly: OrbitSecurityState
                if cookie.isHTTPOnly {
                    httpOnly = .pass
                } else if looksSensitive(cookieName: cookie.name) {
                    httpOnly = .fail
                    issues.append("Missing HttpOnly on what looks like a session cookie: scripts can read it.")
                } else {
                    httpOnly = .warn
                    issues.append("Missing HttpOnly: scripts can read it.")
                }

                let sameSite: OrbitSecurityState
                switch cookie.sameSite.lowercased() {
                case "lax", "strict":
                    sameSite = .pass
                case "none":
                    if cookie.isSecure {
                        sameSite = .info
                    } else {
                        sameSite = .fail
                        issues.append("SameSite=None without Secure is rejected by browsers.")
                    }
                default:
                    sameSite = .warn
                    issues.append("SameSite is not set. Browsers treat it as Lax; state it explicitly.")
                }

                if cookie.name.hasPrefix("__Secure-"), !cookie.isSecure {
                    issues.append("The __Secure- prefix requires the Secure attribute.")
                }
                if cookie.name.hasPrefix("__Host-") {
                    if !cookie.isSecure { issues.append("The __Host- prefix requires the Secure attribute.") }
                    if cookie.domain.hasPrefix(".") { issues.append("The __Host- prefix forbids a Domain attribute.") }
                    if cookie.path != "/" { issues.append("The __Host- prefix requires Path=/.") }
                }

                return OrbitSecurityCookieRow(
                    id: cookie.id, name: cookie.name, domain: cookie.domain,
                    secure: secure, httpOnly: httpOnly, sameSite: sameSite,
                    sameSiteValue: cookie.sameSite.isEmpty ? "Not set" : cookie.sameSite,
                    issues: issues
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }


    static func summaryText(_ report: OrbitSecurityReport) -> String {
        var lines = [
            "Security: \(report.pageURL)",
            "\(report.overall.title). \(report.headline)",
            "\(report.passCount) passed, \(report.warnCount) warnings, \(report.failCount) failed",
        ]
        for section in OrbitSecuritySection.allCases {
            lines.append("")
            lines.append(section.title)
            for check in report.checks(in: section) {
                lines.append("  [\(check.state.rawValue)] \(check.title): \(check.summary)")
                if let value = check.value, !value.isEmpty {
                    lines.append("      \(value.replacingOccurrences(of: "\n", with: " | "))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }


    static func evaluate(_ input: OrbitSecurityInput) -> OrbitSecurityReport {
        let page = URL(string: input.pageURL)
        let scheme = page?.scheme?.lowercased() ?? ""
        let host = page?.host ?? ""
        let isHTTPS = scheme == "https"
        let isHTTP = scheme == "http"
        let isWeb = isHTTPS || isHTTP
        let local = isLocalHost(host)
        let cookieRows = Self.cookieRows(cookies: input.cookies, pageURL: input.pageURL)

        var checks: [OrbitSecurityCheck] = []
        checks += connectionChecks(input: input, scheme: scheme, host: host, local: local)
        checks += contentChecks(input: input, page: page, isHTTPS: isHTTPS, isWeb: isWeb)
        checks += headerChecks(input: input, isHTTPS: isHTTPS, isWeb: isWeb)
        checks += cookieChecks(rows: cookieRows, isWeb: isWeb)

        let fails = checks.filter { $0.state == .fail }
        let warns = checks.filter { $0.state == .warn }
        let overall: OrbitSecurityOverall
        if fails.contains(where: \.isCritical) {
            overall = .notSecure
        } else if !fails.isEmpty || !warns.isEmpty {
            overall = .issues
        } else {
            overall = .secure
        }

        let headline: String
        switch overall {
        case .notSecure:
            headline = fails.first(where: \.isCritical)?.summary ?? "This page is not secure."
        case .issues:
            headline = "\(fails.count + warns.count) \(fails.count + warns.count == 1 ? "thing" : "things") to improve."
        case .secure:
            headline = isWeb && !isHTTPS ? "Local page, not encrypted. No issues found." : "No issues found."
        }

        return OrbitSecurityReport(
            pageURL: input.pageURL, checks: checks, certificates: input.certificates, cookieRows: cookieRows,
            overall: overall, headline: headline,
            passCount: checks.filter { $0.state == .pass }.count,
            warnCount: warns.count, failCount: fails.count,
            infoCount: checks.filter { $0.state == .info }.count
        )
    }


    private static func connectionChecks(
        input: OrbitSecurityInput, scheme: String, host: String, local: Bool
    ) -> [OrbitSecurityCheck] {
        var out: [OrbitSecurityCheck] = []
        let isHTTPS = scheme == "https"

        let https: (OrbitSecurityState, String)
        switch scheme {
        case "https": https = (.pass, "The page was loaded over HTTPS.")
        case "http" where local: https = (.info, "Local development server over HTTP. Nothing is encrypted.")
        case "http": https = (.fail, "The page was loaded over HTTP, so everything on it can be read or changed in transit.")
        case "file": https = (.info, "A local file. There is no network connection to secure.")
        case "": https = (.info, "No page is loaded.")
        default: https = (.info, "A \(scheme): page. There is no network connection to inspect.")
        }
        out.append(OrbitSecurityCheck(
            id: "https", section: .connection, title: "Protocol", state: https.0,
            value: scheme.isEmpty ? nil : scheme,
            summary: https.1,
            advice: "HTTPS encrypts traffic and proves the server's identity. Serve every page over HTTPS and redirect HTTP to it.",
            weight: 10, isCritical: true
        ))

        guard isHTTPS else { return out }

        switch input.trust {
        case .trusted:
            out.append(OrbitSecurityCheck(
                id: "trust", section: .connection, title: "Certificate trust", state: .pass,
                value: "Trusted", summary: "The certificate chain is trusted by this Mac for \(host).",
                advice: "Browsers refuse chains that do not end in a trusted root. Renew or reinstall the full chain if this fails.",
                weight: 10, isCritical: true
            ))
        case .untrusted(let reason):
            out.append(OrbitSecurityCheck(
                id: "trust", section: .connection, title: "Certificate trust", state: .fail,
                value: reason, summary: "The certificate chain is not trusted by this Mac: \(reason)",
                advice: "Serve a certificate from a trusted authority with the full intermediate chain. A self-signed or expired certificate trains visitors to click through warnings.",
                weight: 10, isCritical: true
            ))
        case .unavailable:
            out.append(OrbitSecurityCheck(
                id: "trust", section: .connection, title: "Certificate trust", state: .info,
                value: nil, summary: "No certificate was captured for this load. Refresh to read it.",
                advice: "Orbit reads the certificate when the document commits.",
                weight: 10
            ))
        }

        guard let leaf = input.certificates.first else { return out + tlsInfoChecks() }

        var names = leaf.subjectAlternativeNames
        if names.isEmpty { names = [leaf.subject] }
        let covered = names.contains { hostMatches(host: host, pattern: $0) }
        out.append(OrbitSecurityCheck(
            id: "hostname", section: .connection, title: "Certificate covers this host",
            state: covered ? .pass : .fail,
            value: names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", and \(names.count - 6) more" : ""),
            summary: covered ? "\(host) is listed in the certificate." : "\(host) is not listed in the certificate's names.",
            advice: "The certificate must list every hostname it serves in its Subject Alternative Names. Reissue it with the missing name.",
            weight: 5, isCritical: true
        ))

        let expiryState: OrbitSecurityState
        var expired = false
        if let notAfter = leaf.notAfter {
            expired = notAfter < input.now
            let days = daysUntil(notAfter, now: input.now)
            expiryState = expired || days <= 14 ? .fail : days <= 30 ? .warn : .pass
        } else {
            expiryState = .info
        }
        out.append(OrbitSecurityCheck(
            id: "expiry", section: .connection, title: "Certificate expiry", state: expiryState,
            value: validityDescription(notBefore: leaf.notBefore, notAfter: leaf.notAfter),
            summary: expiryDescription(notAfter: leaf.notAfter, now: input.now),
            advice: "An expired certificate stops the site working. Automate renewal (ACME) and alert at least 30 days ahead.",
            weight: 5, isCritical: expired
        ))

        var keyState: OrbitSecurityState = .info
        if let bits = leaf.keySizeBits {
            switch leaf.keyType {
            case "RSA": keyState = bits >= 2048 ? .pass : .fail
            case "EC": keyState = bits >= 256 ? .pass : .warn
            default: keyState = .info
            }
        }
        out.append(OrbitSecurityCheck(
            id: "key", section: .connection, title: "Public key strength", state: keyState,
            value: keyDescription(type: leaf.keyType, bits: leaf.keySizeBits),
            summary: keyState == .pass ? "The key size is strong enough." : keyState == .info ? "Key details were not available." : "The key is weaker than current guidance.",
            advice: "Use RSA 2048-bit or larger, or an elliptic curve key of at least 256 bits.",
            weight: 3
        ))

        let weak = isWeakSignature(leaf.signatureAlgorithm)
        out.append(OrbitSecurityCheck(
            id: "signature", section: .connection, title: "Signature algorithm",
            state: leaf.signatureAlgorithm == nil ? .info : weak ? .fail : .pass,
            value: leaf.signatureAlgorithm,
            summary: leaf.signatureAlgorithm == nil ? "The signature algorithm was not available." : weak ? "The certificate is signed with a broken hash." : "The signature uses a current hash.",
            advice: "SHA-1 and MD5 signatures can be forged. Reissue the certificate with SHA-256 or stronger.",
            weight: 3
        ))

        return out + tlsInfoChecks()
    }

    private static func tlsInfoChecks() -> [OrbitSecurityCheck] {
        [
            OrbitSecurityCheck(
                id: "tls-version", section: .connection, title: "TLS version", state: .info,
                value: "Not exposed by WebKit", summary: "WebKit does not tell the app which TLS version was negotiated.",
                advice: "Check the server with an external scanner such as SSL Labs to confirm TLS 1.2 or newer.", weight: 0
            ),
            OrbitSecurityCheck(
                id: "tls-cipher", section: .connection, title: "Cipher suite", state: .info,
                value: "Not exposed by WebKit", summary: "WebKit does not tell the app which cipher suite was negotiated.",
                advice: "Check the server with an external scanner such as SSL Labs to confirm only modern suites are offered.", weight: 0
            ),
        ]
    }


    private static func contentChecks(
        input: OrbitSecurityInput, page: URL?, isHTTPS: Bool, isWeb: Bool
    ) -> [OrbitSecurityCheck] {
        var out: [OrbitSecurityCheck] = []

        // WebKit's own verdict.
        let secureState: OrbitSecurityState
        let secureSummary: String
        if !isHTTPS {
            secureState = .info
            secureSummary = "Only meaningful for HTTPS pages."
        } else if let only = input.hasOnlySecureContent {
            secureState = only ? .pass : .fail
            secureSummary = only ? "Every resource on the page loaded securely." : "WebKit loaded at least one resource insecurely."
        } else {
            secureState = .info
            secureSummary = "WebKit has not reported a verdict yet."
        }
        out.append(OrbitSecurityCheck(
            id: "secure-content", section: .content, title: "Only secure content",
            state: secureState, value: input.hasOnlySecureContent.map { $0 ? "true" : "false" },
            summary: secureSummary,
            advice: "WebKit reports hasOnlySecureContent as false when an HTTPS page loads anything over HTTP. Change those URLs to HTTPS.",
            weight: 8, isCritical: secureState == .fail
        ))

        // Mixed content from the network log and the DOM.
        var seen = Set<String>()
        var mixed: [OrbitSecurityFinding] = []
        if isHTTPS {
            for request in input.requests + input.domReferences where isInsecureURL(request.url) {
                guard !isLocalHost(URL(string: request.url)?.host), seen.insert(request.url).inserted else { continue }
                mixed.append(OrbitSecurityFinding(
                    text: "\(request.type.isEmpty ? "request" : request.type): \(request.url)", state: .fail,
                    nodeID: request.nodeID, selector: request.selector, url: request.url
                ))
            }
        }
        out.append(OrbitSecurityCheck(
            id: "mixed-content", section: .content, title: "Mixed content requests",
            state: !isHTTPS ? .info : mixed.isEmpty ? .pass : .fail,
            value: isHTTPS ? "\(mixed.count)" : nil,
            summary: !isHTTPS ? "Only meaningful for HTTPS pages." : mixed.isEmpty ? "No HTTP requests were made from this HTTPS page." : "\(mixed.count) HTTP \(mixed.count == 1 ? "request" : "requests") on an HTTPS page.",
            advice: "Browsers block or downgrade HTTP subresources on HTTPS pages. Load them over HTTPS, or add upgrade-insecure-requests to your CSP.",
            findings: Array(mixed.prefix(50)), weight: 5, isCritical: !mixed.isEmpty
        ))

        var formFindings: [OrbitSecurityFinding] = []
        for form in input.forms {
            let insecureAction = isInsecureRemote(form.action, relativeTo: page)
            if isHTTPS && insecureAction {
                formFindings.append(OrbitSecurityFinding(
                    text: "Submits to \(form.action) over HTTP", state: .fail,
                    nodeID: form.nodeID, selector: form.selector, url: form.action
                ))
            } else if form.hasPassword && isWeb && !isHTTPS && !isLocalHost(page?.host) {
                formFindings.append(OrbitSecurityFinding(
                    text: "Password field on a page served over HTTP", state: .fail,
                    nodeID: form.nodeID, selector: form.selector, url: form.action
                ))
            } else if form.hasPassword && insecureAction {
                formFindings.append(OrbitSecurityFinding(
                    text: "Password form submits to \(form.action) over HTTP", state: .fail,
                    nodeID: form.nodeID, selector: form.selector, url: form.action
                ))
            }
        }
        out.append(OrbitSecurityCheck(
            id: "forms", section: .content, title: "Form submission",
            state: formFindings.isEmpty ? (input.forms.isEmpty ? .info : .pass) : .fail,
            value: "\(input.forms.count) \(input.forms.count == 1 ? "form" : "forms")",
            summary: formFindings.isEmpty ? (input.forms.isEmpty ? "The page has no forms." : "No form submits over plain HTTP.") : "\(formFindings.count) insecure \(formFindings.count == 1 ? "form" : "forms").",
            advice: "Form data sent over HTTP can be read in transit, and passwords must never be. Point action at an HTTPS URL.",
            findings: formFindings, weight: 5
        ))

        var frameFindings: [OrbitSecurityFinding] = []
        var unsandboxed = 0
        for frame in input.frames {
            if isInsecureRemote(frame.src, relativeTo: page) && isHTTPS {
                frameFindings.append(OrbitSecurityFinding(
                    text: "Frame loads \(frame.src) over HTTP", state: .fail,
                    nodeID: frame.nodeID, selector: frame.selector, url: frame.src
                ))
            } else if frame.isCrossOrigin && !frame.isSandboxed {
                unsandboxed += 1
            }
        }
        out.append(OrbitSecurityCheck(
            id: "frames", section: .content, title: "Embedded frames",
            state: frameFindings.isEmpty ? (input.frames.isEmpty ? .info : .pass) : .fail,
            value: "\(input.frames.count) \(input.frames.count == 1 ? "frame" : "frames")",
            summary: frameFindings.isEmpty
                ? (input.frames.isEmpty ? "The page has no iframes." : unsandboxed == 0 ? "No frame loads from an insecure origin." : "No frame loads from an insecure origin. \(unsandboxed) cross-origin \(unsandboxed == 1 ? "frame has" : "frames have") no sandbox attribute.")
                : "\(frameFindings.count) \(frameFindings.count == 1 ? "frame loads" : "frames load") from an insecure origin.",
            advice: "A frame from an HTTP origin can be replaced by an attacker on the network. Use HTTPS, and add sandbox to untrusted embeds.",
            findings: frameFindings, weight: 3
        ))

        out.append(integrityCheck(input: input, isWeb: isWeb))
        out.append(externalLinkCheck(input: input, isWeb: isWeb))
        out.append(libraryCheck(input: input, isWeb: isWeb))

        return out
    }

    private static func integrityCheck(input: OrbitSecurityInput, isWeb: Bool) -> OrbitSecurityCheck {
        let advice = "A script or stylesheet from another origin runs with the full power of your page, and if that server is compromised so is the page. Add integrity=\"sha384-...\" and crossorigin=\"anonymous\" so the browser refuses a changed file."
        guard isWeb else {
            return OrbitSecurityCheck(
                id: "sri", section: .content, title: "Subresource integrity", state: .info, value: nil,
                summary: "Only meaningful for pages loaded over HTTP or HTTPS.", advice: advice, weight: 3
            )
        }
        let missing = input.scripts.filter { !$0.hasIntegrity }
        let scriptCount = missing.filter { $0.tag != "link" }.count
        let findings = missing.prefix(50).map { resource in
            OrbitSecurityFinding(
                text: "\(resource.tag == "link" ? "stylesheet" : "script"): \(resource.url)", state: .warn,
                nodeID: resource.nodeID, selector: resource.selector, url: resource.url
            )
        }
        let summary: String
        if input.scripts.isEmpty {
            summary = "The page loads no scripts or stylesheets from other origins."
        } else if missing.isEmpty {
            summary = "All \(input.scripts.count) cross-origin scripts and stylesheets carry an integrity hash."
        } else {
            summary = "\(missing.count) of \(input.scripts.count) cross-origin scripts and stylesheets have no integrity hash (\(scriptCount) \(scriptCount == 1 ? "script" : "scripts"))."
        }
        return OrbitSecurityCheck(
            id: "sri", section: .content, title: "Subresource integrity",
            state: missing.isEmpty ? .pass : .warn, value: "\(missing.count) of \(input.scripts.count) unprotected",
            summary: summary, advice: advice, findings: findings, weight: 3
        )
    }

    private static func externalLinkCheck(input: OrbitSecurityInput, isWeb: Bool) -> OrbitSecurityCheck {
        let advice = "A page opened with target=\"_blank\" can reach back through window.opener in browsers that predate the implied noopener. Add rel=\"noopener noreferrer\" to links that open other sites in a new tab."
        guard isWeb else {
            return OrbitSecurityCheck(
                id: "noopener", section: .content, title: "External links in new tabs", state: .info, value: nil,
                summary: "Only meaningful for pages loaded over HTTP or HTTPS.", advice: advice, weight: 2
            )
        }
        let unsafe = input.links.filter { link in
            let tokens = Set(link.rel.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init))
            return !tokens.contains("noopener") && !tokens.contains("noreferrer")
        }
        let findings = unsafe.prefix(50).map { link in
            OrbitSecurityFinding(
                text: "Opens \(link.href) without rel=noopener", state: .warn,
                nodeID: link.nodeID, selector: link.selector, url: link.href
            )
        }
        let summary: String
        if input.links.isEmpty {
            summary = "No link opens another site in a new tab."
        } else if unsafe.isEmpty {
            summary = "All \(input.links.count) links that open other sites in a new tab set rel=noopener or noreferrer."
        } else {
            summary = "\(unsafe.count) of \(input.links.count) links that open other sites in a new tab lack rel=noopener. Current browsers imply it, older ones do not."
        }
        return OrbitSecurityCheck(
            id: "noopener", section: .content, title: "External links in new tabs",
            state: unsafe.isEmpty ? .pass : .warn, value: "\(unsafe.count) of \(input.links.count) unprotected",
            summary: summary, advice: advice, findings: findings, weight: 2
        )
    }

    private static func libraryCheck(input: OrbitSecurityInput, isWeb: Bool) -> OrbitSecurityCheck {
        let advice = "Upgrade each listed library to at least its fixed version, or replace it. Matching is by reported version, so a patched build that keeps the old version number can be a false positive."
        guard isWeb else {
            return OrbitSecurityCheck(
                id: "libraries", section: .content, title: "Vulnerable libraries", state: .info, value: nil,
                summary: "Only meaningful for pages loaded over HTTP or HTTPS.", advice: advice, weight: 5
            )
        }
        let (matches, unversioned) = OrbitLighthouseLogic.vulnerabilities(in: input.libraries)
        let endOfLife = input.libraries.filter { OrbitLighthouseLogic.endOfLife[$0.name] != nil }
        var findings = matches.map { match in
            OrbitSecurityFinding(
                text: "\(match.library) \(match.version): \(match.advisoryID) (\(match.severity.title)). \(match.summary) "
                    + (match.fixedIn.map { "Fixed in \($0)." } ?? "No fixed release."),
                state: match.severity >= .high ? .fail : .warn
            )
        }
        findings += endOfLife.map { library in
            OrbitSecurityFinding(
                text: "\(library.name) \(library.version ?? "(version not detected)"): \(OrbitLighthouseLogic.endOfLife[library.name] ?? "")",
                state: .warn
            )
        }
        let state: OrbitSecurityState = findings.isEmpty ? .pass : OrbitSecurityState.worst(findings.map(\.state))
        let summary: String
        if input.libraries.isEmpty {
            summary = "No jQuery, Bootstrap, Lodash, Moment.js or AngularJS was detected on the page."
        } else if findings.isEmpty {
            let names = input.libraries.map { "\($0.name) \($0.version ?? "")".trimmingCharacters(in: .whitespaces) }
            summary = "No known advisory matches \(names.joined(separator: ", "))."
                + (unversioned.isEmpty ? "" : " \(unversioned.count) detected without a readable version was not checked.")
        } else {
            summary = "\(matches.count) known \(matches.count == 1 ? "advisory affects" : "advisories affect") the libraries on this page."
        }
        return OrbitSecurityCheck(
            id: "libraries", section: .content, title: "Vulnerable libraries",
            state: state, value: input.libraries.isEmpty ? nil : "\(matches.count) \(matches.count == 1 ? "advisory" : "advisories")",
            summary: summary, advice: advice, findings: findings, weight: 5
        )
    }


    private static func headerChecks(input: OrbitSecurityInput, isHTTPS: Bool, isWeb: Bool) -> [OrbitSecurityCheck] {
        func notApplicable(_ id: String, _ title: String, _ weight: Double, _ advice: String, _ reason: String) -> OrbitSecurityCheck {
            OrbitSecurityCheck(id: id, section: .headers, title: title, state: .info, value: nil, summary: reason, advice: advice, weight: weight)
        }

        let hstsAdvice = "Strict-Transport-Security makes browsers use HTTPS for your site. Send max-age=31536000; includeSubDomains; preload."
        let cspAdvice = "A strict Content-Security-Policy limits where scripts and other content can load from, which contains XSS. Use nonces or hashes instead of 'unsafe-inline'."
        let xctoAdvice = "Without nosniff, browsers may guess a response is a script. Send X-Content-Type-Options: nosniff."
        let clickAdvice = "Without framing limits, another site can overlay your page invisibly and trick clicks. Send frame-ancestors 'self' in the CSP, or X-Frame-Options: DENY."
        let referrerAdvice = "The Referer header can leak private URLs. Send Referrer-Policy: strict-origin-when-cross-origin or stricter."
        let coopAdvice = "Cross-Origin-Opener-Policy isolates your window from pop-ups other sites open. Send Cross-Origin-Opener-Policy: same-origin."
        let coepAdvice = "Cross-Origin-Embedder-Policy requires embedded resources to opt in, and with COOP enables cross-origin isolation. Send require-corp or credentialless if you need that."
        let corpAdvice = "Cross-Origin-Resource-Policy stops other sites loading this document or its assets. Send same-origin or same-site unless the content is public."
        let permissionsAdvice = "Permissions-Policy turns off browser features (camera, microphone, geolocation) for this page and its frames. Send a policy that disables what you do not use."

        guard isWeb else {
            let reason = "Not applicable: this page has no HTTP response."
            return [
                notApplicable("hsts", "Strict-Transport-Security", 8, hstsAdvice, reason),
                notApplicable("csp", "Content-Security-Policy", 12, cspAdvice, reason),
                notApplicable("xcto", "X-Content-Type-Options", 5, xctoAdvice, reason),
                notApplicable("clickjacking", "Framing protection", 7, clickAdvice, reason),
                notApplicable("referrer", "Referrer-Policy", 3, referrerAdvice, reason),
                notApplicable("coop", "Cross-Origin-Opener-Policy", 3, coopAdvice, reason),
                notApplicable("coep", "Cross-Origin-Embedder-Policy", 2, coepAdvice, reason),
                notApplicable("corp", "Cross-Origin-Resource-Policy", 2, corpAdvice, reason),
                notApplicable("permissions", "Permissions-Policy", 2, permissionsAdvice, reason),
            ]
        }

        // The meta policy and referrer still exist without a captured response.
        let headers = input.documentHeaders
        let missingHeaders = "Response headers were not captured for this load. Reload the page with the panel open."
        func header(_ name: String) -> String? { headers?[name] }

        var out: [OrbitSecurityCheck] = []

        if !isHTTPS {
            out.append(notApplicable("hsts", "Strict-Transport-Security", 8, hstsAdvice, "Not applicable: browsers ignore HSTS on HTTP pages."))
        } else if headers == nil {
            out.append(notApplicable("hsts", "Strict-Transport-Security", 8, hstsAdvice, missingHeaders))
        } else if let raw = header("strict-transport-security") {
            let hsts = parseHSTS(raw)
            var state: OrbitSecurityState = .pass
            var notes: [OrbitSecurityFinding] = []
            let sixMonths = 15_552_000
            let oneYear = 31_536_000
            if let maxAge = hsts.maxAge {
                if maxAge == 0 {
                    state = .fail
                    notes.append(.init(text: "max-age=0 switches HSTS off.", state: .fail))
                } else if maxAge < sixMonths {
                    state = .warn
                    notes.append(.init(text: "max-age is \(maxAge / 86_400) days. Use at least 180 days, ideally one year.", state: .warn))
                } else if maxAge < oneYear {
                    notes.append(.init(text: "max-age is \(maxAge / 86_400) days. One year is needed for the preload list.", state: .info))
                } else {
                    notes.append(.init(text: "max-age is \(maxAge / 86_400) days.", state: .pass))
                }
            } else {
                state = .fail
                notes.append(.init(text: "max-age is missing, so the header has no effect.", state: .fail))
            }
            if hsts.includeSubDomains {
                notes.append(.init(text: "includeSubDomains is set.", state: .pass))
            } else {
                if state == .pass { state = .warn }
                notes.append(.init(text: "includeSubDomains is not set, so subdomains can still be downgraded.", state: .warn))
            }
            notes.append(.init(text: hsts.preload ? "preload is set." : "preload is not set. It is optional, and required for the browser preload list.", state: hsts.preload ? .pass : .info))
            out.append(OrbitSecurityCheck(
                id: "hsts", section: .headers, title: "Strict-Transport-Security", state: state, value: raw,
                summary: state == .pass ? "HSTS is enforced for a year or more, including subdomains." : state == .warn ? "HSTS is set but could be stronger." : "HSTS is set but ineffective.",
                advice: hstsAdvice, findings: notes, weight: 8
            ))
        } else {
            out.append(OrbitSecurityCheck(
                id: "hsts", section: .headers, title: "Strict-Transport-Security", state: .fail, value: nil,
                summary: "Not set. Browsers can be tricked into using HTTP on first contact.", advice: hstsAdvice, weight: 8
            ))
        }

        do {
            var policies: [OrbitSecurityCSPPolicy] = []
            if let raw = header("content-security-policy") { policies += parseCSP(raw, reportOnly: false) }
            if let raw = header("content-security-policy-report-only") { policies += parseCSP(raw, reportOnly: true) }
            for meta in input.metaCSP { policies += parseCSP(meta, reportOnly: false, fromMeta: true) }
            let rawValue = [header("content-security-policy"),
                            header("content-security-policy-report-only").map { "(report-only) \($0)" }]
                .compactMap { $0 }
                + input.metaCSP.map { "(meta) \($0)" }
            if headers == nil && policies.isEmpty {
                out.append(notApplicable("csp", "Content-Security-Policy", 12, cspAdvice, missingHeaders))
            } else {
                let found = gradeCSP(policies)
                let state: OrbitSecurityState
                if found.isEmpty {
                    state = .pass
                } else {
                    let worst = OrbitSecurityState.worst(found.map(\.state))
                    state = worst == .info ? .pass : worst
                }
                out.append(OrbitSecurityCheck(
                    id: "csp", section: .headers, title: "Content-Security-Policy", state: state,
                    value: rawValue.isEmpty ? nil : rawValue.joined(separator: "\n"),
                    summary: found.isEmpty ? "The policy is enforced and has no weak directives." : found.count == 1 ? found[0].message : "\(found.count) problems in the policy.",
                    advice: cspAdvice,
                    findings: found.map { OrbitSecurityFinding(text: "\($0.directive): \($0.message)", state: $0.state) },
                    weight: 12
                ))
            }
        }

        if headers == nil {
            out.append(notApplicable("xcto", "X-Content-Type-Options", 5, xctoAdvice, missingHeaders))
        } else if let raw = header("x-content-type-options") {
            let ok = raw.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "nosniff" }
            out.append(OrbitSecurityCheck(
                id: "xcto", section: .headers, title: "X-Content-Type-Options", state: ok ? .pass : .fail, value: raw,
                summary: ok ? "nosniff stops MIME type guessing." : "\"\(raw)\" is not nosniff, the only valid value.", advice: xctoAdvice, weight: 5
            ))
        } else {
            out.append(OrbitSecurityCheck(
                id: "xcto", section: .headers, title: "X-Content-Type-Options", state: .fail, value: nil,
                summary: "Not set. Browsers may treat a response as a different type than declared.", advice: xctoAdvice, weight: 5
            ))
        }

        if headers == nil {
            out.append(notApplicable("clickjacking", "Framing protection", 7, clickAdvice, missingHeaders))
        } else {
            // frame-ancestors is ignored in meta policies, so only header policies count.
            var headerPolicies: [OrbitSecurityCSPPolicy] = []
            if let raw = header("content-security-policy") { headerPolicies += parseCSP(raw, reportOnly: false) }
            let ancestors = headerPolicies.compactMap { $0.values(for: "frame-ancestors") }.first
            let xfo = header("x-frame-options")
            let verdict = gradeClickjacking(xfo: xfo, ancestors: ancestors)
            var raw: [String] = []
            if let xfo { raw.append("X-Frame-Options: \(xfo)") }
            if let ancestors { raw.append("frame-ancestors \(ancestors.joined(separator: " "))") }
            out.append(OrbitSecurityCheck(
                id: "clickjacking", section: .headers, title: "Framing protection", state: verdict.state,
                value: raw.isEmpty ? nil : raw.joined(separator: "\n"), summary: verdict.summary, advice: clickAdvice, weight: 7
            ))
        }

        // Referrer-Policy (a meta tag is honoured too).
        if headers == nil && input.metaReferrer == nil {
            out.append(notApplicable("referrer", "Referrer-Policy", 3, referrerAdvice, missingHeaders))
        } else {
            let value = header("referrer-policy") ?? input.metaReferrer
            let verdict = gradeReferrerPolicy(value)
            out.append(OrbitSecurityCheck(
                id: "referrer", section: .headers, title: "Referrer-Policy", state: verdict.state, value: value,
                summary: verdict.summary, advice: referrerAdvice, weight: 3
            ))
        }

        if headers == nil {
            out.append(notApplicable("coop", "Cross-Origin-Opener-Policy", 3, coopAdvice, missingHeaders))
        } else if let raw = header("cross-origin-opener-policy") {
            let value = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let state: OrbitSecurityState = (value == "same-origin" || value == "same-origin-allow-popups") ? .pass : .warn
            out.append(OrbitSecurityCheck(
                id: "coop", section: .headers, title: "Cross-Origin-Opener-Policy", state: state, value: raw,
                summary: state == .pass ? "The window is isolated from cross-origin openers." : "\"\(raw)\" does not isolate the window.",
                advice: coopAdvice, weight: 3
            ))
        } else {
            out.append(OrbitSecurityCheck(
                id: "coop", section: .headers, title: "Cross-Origin-Opener-Policy", state: .warn, value: nil,
                summary: "Not set. Cross-origin pop-ups can keep a reference to this window.", advice: coopAdvice, weight: 3
            ))
        }

        if headers == nil {
            out.append(notApplicable("coep", "Cross-Origin-Embedder-Policy", 2, coepAdvice, missingHeaders))
        } else if let raw = header("cross-origin-embedder-policy") {
            let value = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let state: OrbitSecurityState = (value == "require-corp" || value == "credentialless") ? .pass : .warn
            out.append(OrbitSecurityCheck(
                id: "coep", section: .headers, title: "Cross-Origin-Embedder-Policy", state: state, value: raw,
                summary: state == .pass ? "Embedded resources must opt in." : "\"\(raw)\" does not restrict embedded resources.",
                advice: coepAdvice, weight: 2
            ))
        } else {
            out.append(OrbitSecurityCheck(
                id: "coep", section: .headers, title: "Cross-Origin-Embedder-Policy", state: .warn, value: nil,
                summary: "Not set. The page cannot become cross-origin isolated.", advice: coepAdvice, weight: 2
            ))
        }

        if headers == nil {
            out.append(notApplicable("corp", "Cross-Origin-Resource-Policy", 2, corpAdvice, missingHeaders))
        } else if let raw = header("cross-origin-resource-policy") {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let state: OrbitSecurityState = (value == "same-origin" || value == "same-site") ? .pass : value == "cross-origin" ? .info : .warn
            out.append(OrbitSecurityCheck(
                id: "corp", section: .headers, title: "Cross-Origin-Resource-Policy", state: state, value: raw,
                summary: state == .pass ? "Other origins cannot load this response." : value == "cross-origin" ? "Any origin can load this response. Fine for public content." : "\"\(raw)\" is not a valid value.",
                advice: corpAdvice, weight: 2
            ))
        } else {
            out.append(OrbitSecurityCheck(
                id: "corp", section: .headers, title: "Cross-Origin-Resource-Policy", state: .warn, value: nil,
                summary: "Not set. Other origins can embed this response.", advice: corpAdvice, weight: 2
            ))
        }

        if headers == nil {
            out.append(notApplicable("permissions", "Permissions-Policy", 2, permissionsAdvice, missingHeaders))
        } else if let raw = header("permissions-policy") {
            var broad: [OrbitSecurityFinding] = []
            for feature in ["camera", "microphone", "geolocation"] {
                let pattern = "\(feature)=*"
                if raw.lowercased().replacingOccurrences(of: " ", with: "").contains(pattern) {
                    broad.append(.init(text: "\(feature) is allowed for every origin.", state: .warn))
                }
            }
            out.append(OrbitSecurityCheck(
                id: "permissions", section: .headers, title: "Permissions-Policy", state: broad.isEmpty ? .pass : .warn, value: raw,
                summary: broad.isEmpty ? "Browser features are restricted by policy." : "Sensitive features are open to every origin.",
                advice: permissionsAdvice, findings: broad, weight: 2
            ))
        } else {
            let legacy = header("feature-policy") != nil
            out.append(OrbitSecurityCheck(
                id: "permissions", section: .headers, title: "Permissions-Policy", state: .warn, value: header("feature-policy"),
                summary: legacy ? "Only the deprecated Feature-Policy is set. Move it to Permissions-Policy." : "Not set. Frames and scripts can request any browser feature.",
                advice: permissionsAdvice, weight: 2
            ))
        }

        return out
    }


    private static func cookieChecks(rows: [OrbitSecurityCookieRow], isWeb: Bool) -> [OrbitSecurityCheck] {
        let secureAdvice = "Cookies without Secure are also sent over plain HTTP, where they can be read. Add the Secure attribute."
        let httpOnlyAdvice = "Cookies without HttpOnly can be read by any script on the page, so an XSS bug steals sessions. Add HttpOnly to cookies scripts do not need."
        let sameSiteAdvice = "SameSite limits which cross-site requests carry the cookie, which blocks most CSRF. Set SameSite=Lax or Strict, and None only with Secure."
        let prefixAdvice = "Cookie prefixes make the browser enforce Secure, Domain and Path rules. Fix the attributes or drop the prefix."

        guard isWeb else {
            return [
                OrbitSecurityCheck(id: "cookie-secure", section: .cookies, title: "Secure flag", state: .info, value: nil,
                                   summary: "Not applicable: cookies belong to web pages.", advice: secureAdvice, weight: 6),
                OrbitSecurityCheck(id: "cookie-httponly", section: .cookies, title: "HttpOnly flag", state: .info, value: nil,
                                   summary: "Not applicable: cookies belong to web pages.", advice: httpOnlyAdvice, weight: 4),
                OrbitSecurityCheck(id: "cookie-samesite", section: .cookies, title: "SameSite attribute", state: .info, value: nil,
                                   summary: "Not applicable: cookies belong to web pages.", advice: sameSiteAdvice, weight: 4),
            ]
        }

        func aggregate(
            id: String, title: String, weight: Double, advice: String,
            state: (OrbitSecurityCookieRow) -> OrbitSecurityState, label: (OrbitSecurityCookieRow) -> String
        ) -> OrbitSecurityCheck {
            guard !rows.isEmpty else {
                return OrbitSecurityCheck(id: id, section: .cookies, title: title, state: .info, value: "0 cookies",
                                          summary: "No cookies are set for this page.", advice: advice, weight: weight)
            }
            let states = rows.map(state)
            let worst = OrbitSecurityState.worst(states)
            let bad = zip(rows, states).filter { $0.1 == .warn || $0.1 == .fail }
            return OrbitSecurityCheck(
                id: id, section: .cookies, title: title, state: worst,
                value: "\(rows.count - bad.count) of \(rows.count) cookies pass",
                summary: bad.isEmpty ? "All \(rows.count) \(rows.count == 1 ? "cookie passes" : "cookies pass")." : "\(bad.count) of \(rows.count) \(rows.count == 1 ? "cookie fails" : "cookies fail") this check.",
                advice: advice,
                findings: bad.map { OrbitSecurityFinding(text: "\($0.0.name): \(label($0.0))", state: $0.1) },
                weight: weight
            )
        }

        var out = [
            aggregate(id: "cookie-secure", title: "Secure flag", weight: 6, advice: secureAdvice,
                      state: \.secure, label: { _ in "not Secure" }),
            aggregate(id: "cookie-httponly", title: "HttpOnly flag", weight: 4, advice: httpOnlyAdvice,
                      state: \.httpOnly, label: { _ in "readable by scripts" }),
            aggregate(id: "cookie-samesite", title: "SameSite attribute", weight: 4, advice: sameSiteAdvice,
                      state: \.sameSite, label: { $0.sameSiteValue == "Not set" ? "SameSite not set" : "SameSite=\($0.sameSiteValue) without Secure" }),
        ]

        let prefixed = rows.filter { row in
            row.issues.contains { $0.contains("prefix") }
        }
        if !prefixed.isEmpty {
            out.append(OrbitSecurityCheck(
                id: "cookie-prefix", section: .cookies, title: "Cookie prefixes", state: .fail,
                value: "\(prefixed.count) \(prefixed.count == 1 ? "cookie" : "cookies")",
                summary: "\(prefixed.count) \(prefixed.count == 1 ? "cookie breaks" : "cookies break") the rules of its prefix.",
                advice: prefixAdvice,
                findings: prefixed.flatMap { row in
                    row.issues.filter { $0.contains("prefix") }.map { OrbitSecurityFinding(text: "\(row.name): \($0)", state: .fail) }
                },
                weight: 2
            ))
        }
        return out
    }
}
