import Darwin
import Foundation

/// Import and export of saved logins as CSV, in the shapes the common password managers and browsers use.
nonisolated enum PasswordCSV {

    // MARK: - Types

    /// Which export a file came from, decided by its header row.
    enum Format: String, Sendable, Equatable {
        /// Title,URL,Username,Password,Notes,OTPAuth: the Passwords app and Safari.
        case applePasswords
        /// name,url,username,password,note: Chrome, Edge, Brave and Arc. Also what `export` writes.
        case chrome
        /// url,username,password,httpRealm,formActionOrigin,guid,...
        case firefox
        /// Any other header with a URL column and a password column, such as login_uri,login_username,login_password (Bitwarden) or Title,Url,Username,Password (1Password).
        case generic
    }

    struct ImportedLogin: Equatable, Sendable, CustomStringConvertible {
        /// `scheme://host[:port]`, already reduced from whatever URL the file held.
        var origin: URL
        var username: String
        var password: String

        var description: String { "ImportedLogin(\(origin.absoluteString), <password withheld>)" }
    }

    enum SkipReason: Error, Equatable, Sendable {
        case noUsableURL
        case emptyUsername
        case emptyPassword
        /// The URL has a scheme other than http or https, such as an Android app (`android://...`).
        case nonHTTPOrigin(scheme: String)
        case malformedRow
    }

    struct SkippedRow: Equatable, Sendable {
        /// The 1-based line of the file the row starts on, counting the header as line 1.
        var line: Int
        var reason: SkipReason
        /// The row's URL text, or its title when it has no URL. Never the password.
        var label: String
    }

    struct ParseResult: Equatable, Sendable {
        var format: Format
        var logins: [ImportedLogin]
        var skipped: [SkippedRow]
    }

    enum ImportError: Error, Equatable, Sendable {
        case empty
        case notText
        /// The header row has no URL column or no password column.
        case unrecognizedFormat
    }

    struct MergeSummary: Equatable, Sendable {
        var added = 0
        var updated = 0
        var unchanged = 0
        var skipped = 0
    }

    // MARK: - Import

    static func parse(data: Data) throws -> ParseResult {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw ImportError.notText }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> ParseResult {
        let rows = records(in: text)
        guard let header = rows.first else { throw ImportError.empty }
        guard !header.isMalformed, let columns = Columns(header: header.fields) else {
            throw ImportError.unrecognizedFormat
        }

        var logins: [ImportedLogin] = []
        var skipped: [SkippedRow] = []
        for record in rows.dropFirst() {
            switch importedLogin(from: record, columns: columns) {
            case .login(let login): logins.append(login)
            case .skipped(let row): skipped.append(row)
            }
        }
        return ParseResult(format: columns.format, logins: logins, skipped: skipped)
    }

    /// Saves each imported login through the vault's own rules, so a login already stored counts as unchanged or updated rather than being duplicated. Rows skipped while parsing, and logins the vault refuses, count as skipped.
    static func merge(_ result: ParseResult, into vault: any PasswordVault) -> MergeSummary {
        var summary = MergeSummary(skipped: result.skipped.count)
        for login in result.logins {
            switch vault.save(origin: login.origin, username: login.username, password: login.password) {
            case .added: summary.added += 1
            case .updated: summary.updated += 1
            case .unchanged: summary.unchanged += 1
            case nil: summary.skipped += 1
            }
        }
        return summary
    }

    // MARK: - Export

    static let exportHeader = ["name", "url", "username", "password", "note"]

    /// The Chrome header and quoting, with CRLF line ends, ordered by site then username so the file is stable. Every field a spreadsheet would run as a formula is neutralised (see `neutralized`), and `parse` undoes that. The result holds every password in clear text.
    static func export(_ logins: [SavedLogin]) -> String {
        let ordered = logins.sorted {
            if $0.origin != $1.origin { return $0.origin < $1.origin }
            if $0.username != $1.username { return $0.username < $1.username }
            return $0.id.uuidString < $1.id.uuidString
        }
        var lines = [exportHeader.map(escape).joined(separator: ",")]
        for login in ordered {
            let name = URL(string: login.origin)?.host() ?? login.origin
            let fields = [name, login.origin, login.username, login.password, ""]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A spreadsheet reads a cell that starts with one of these as a formula (or, for tab and CR, trims it to one), which can run code or leak data when the exported file is opened.
    private static let formulaTriggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// True when the field starts with a formula trigger, possibly behind quotes that an earlier `neutralized` added.
    private static func startsLikeFormula(_ field: String) -> Bool {
        guard let first = field.unicodeScalars.first(where: { $0 != "'" }) else { return false }
        return formulaTriggers.contains(first)
    }

    /// A field a spreadsheet would run as a formula gets a single quote in front, which it shows as nothing and treats as plain text.
    /// A field that already starts with quotes before a trigger gets one more, so `restored` can take exactly one off again.
    static func neutralized(_ field: String) -> String {
        startsLikeFormula(field) ? "'" + field : field
    }

    /// Undoes `neutralized`: removes one leading single quote, and only when what follows (after any further quotes) is a formula trigger,
    /// so a value that really starts with a quote and a letter is left alone.
    static func restored(_ field: String) -> String {
        guard field.unicodeScalars.first == "'", startsLikeFormula(field) else { return field }
        var scalars = field.unicodeScalars
        scalars.removeFirst()
        return String(scalars)
    }

    static func escape(_ field: String) -> String {
        let field = neutralized(field)
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Rows

    private struct Columns {
        let format: Format
        let url: Int
        let username: Int?
        let password: Int

        private static let urlNames = ["url", "login_uri", "login uri", "uri", "website", "web site", "origin", "hostname", "site"]
        private static let usernameNames = ["username", "login_username", "login username", "user name", "user", "login", "login name"]
        private static let passwordNames = ["password", "login_password", "login password", "pass"]

        init?(header: [String]) {
            let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            func index(of aliases: [String]) -> Int? {
                for alias in aliases {
                    if let found = names.firstIndex(of: alias) { return found }
                }
                return nil
            }
            guard let url = index(of: Self.urlNames), let password = index(of: Self.passwordNames) else { return nil }
            self.url = url
            self.password = password
            self.username = index(of: Self.usernameNames)

            let present = Set(names)
            if present.contains("httprealm") || present.contains("formactionorigin") {
                format = .firefox
            } else if present.contains("otpauth") && present.contains("title") {
                format = .applePasswords
            } else if ["name", "url", "username", "password"].allSatisfy(present.contains) {
                format = .chrome
            } else {
                format = .generic
            }
        }

        var highestIndex: Int { max(url, password, username ?? 0) }
    }

    private enum RowOutcome {
        case login(ImportedLogin)
        case skipped(SkippedRow)
    }

    private static func importedLogin(from record: Record, columns: Columns) -> RowOutcome {
        func skip(_ reason: SkipReason, label: String = "") -> RowOutcome {
            .skipped(SkippedRow(line: record.line, reason: reason, label: label))
        }
        guard !record.isMalformed, record.fields.count > columns.highestIndex else { return skip(.malformedRow) }

        // Bitwarden lists several URIs in one field, one per line; the first is the login's own.
        let rawURL = record.fields[columns.url]
            .split(whereSeparator: \.isNewline)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let origin: URL
        switch importedOrigin(from: rawURL) {
        case .success(let url): origin = url
        case .failure(let reason): return skip(reason, label: rawURL)
        }
        let password = restored(record.fields[columns.password])
        guard !password.isEmpty else { return skip(.emptyPassword, label: rawURL) }
        let username = columns.username.map { restored(record.fields[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !username.isEmpty else { return skip(.emptyUsername, label: rawURL) }
        return .login(ImportedLogin(origin: origin, username: username, password: password))
    }

    /// A URL with no scheme, as some exports hold ("example.com/login"), is taken as https.
    private static func importedOrigin(from raw: String) -> Result<URL, SkipReason> {
        guard !raw.isEmpty else { return .failure(.noUsableURL) }
        var candidate = raw
        if let separator = raw.range(of: "://"), isScheme(raw[..<separator.lowerBound]) {
            let scheme = raw[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return .failure(.nonHTTPOrigin(scheme: scheme)) }
        } else {
            candidate = "https://" + raw
        }
        guard let url = URL(string: candidate),
              let origin = PasswordOrigin(url: url),
              let originURL = URL(string: origin.origin)
        else { return .failure(.noUsableURL) }
        return .success(originURL)
    }

    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    // MARK: - RFC 4180 parser

    struct Record: Equatable, Sendable {
        var fields: [String]
        /// The 1-based line the record starts on.
        var line: Int
        /// A quoted field that never closed.
        var isMalformed: Bool
    }

    /// Fields may be quoted, hold doubled quotes and line breaks, and records end with CRLF, LF or a lone CR. A leading byte order mark is dropped and blank lines are skipped. Works on unicode scalars because Swift treats CRLF as one Character.
    static func records(in text: String) -> [Record] {
        let scalars = Array(text.unicodeScalars)
        let count = scalars.count
        var records: [Record] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var fieldWasQuoted = false
        var recordHasQuotedField = false
        var inQuotes = false
        var line = 1
        var recordLine = 1
        var index = scalars.first == "\u{FEFF}" ? 1 : 0

        func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
        }
        func endRecord(malformed: Bool) {
            endField()
            let isBlankLine = fields.count == 1 && fields[0].isEmpty && !recordHasQuotedField
            if malformed || !isBlankLine {
                records.append(Record(fields: fields, line: recordLine, isMalformed: malformed))
            }
            fields = []
            recordHasQuotedField = false
        }

        while index < count {
            let scalar = scalars[index]
            let followedByLineFeed = index + 1 < count && scalars[index + 1] == "\n"

            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    if scalar == "\n" || (scalar == "\r" && !followedByLineFeed) { line += 1 }
                    field.append(scalar)
                }
                index += 1
                continue
            }

            switch scalar {
            case "\"" where field.isEmpty && !fieldWasQuoted:
                inQuotes = true
                fieldWasQuoted = true
                recordHasQuotedField = true
            case ",":
                endField()
            case "\r", "\n":
                if scalar == "\r" && followedByLineFeed { index += 1 }
                endRecord(malformed: false)
                line += 1
                recordLine = line
            default:
                field.append(scalar)
            }
            index += 1
        }

        if inQuotes {
            endRecord(malformed: true)
        } else if !fields.isEmpty || !field.isEmpty || fieldWasQuoted {
            endRecord(malformed: false)
        }
        return records
    }
}

/// Writes a file that holds plaintext passwords. It is created with mode 0600 from the first byte, so it is never readable by anyone else
/// even for a moment: the data goes to a new file beside the destination (created exclusively, owner read/write only) and is renamed
/// into place, so a failure at any step leaves neither a partial file nor a world-readable one.
nonisolated enum PasswordExportFile {

    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent().path
        let temporary = directory + "/.orbit-passwords-\(UUID().uuidString).tmp"
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError(errno) }

        var isOpen = true
        var isInPlace = false
        defer {
            if isOpen { Darwin.close(descriptor) }
            if !isInPlace { Darwin.unlink(temporary) }
        }

        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError(errno) }
        isOpen = false
        guard Darwin.close(descriptor) == 0 else { throw posixError(errno) }
        guard Darwin.rename(temporary, destination.path) == 0 else { throw posixError(errno) }
        isInPlace = true
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                offset += written
            }
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
