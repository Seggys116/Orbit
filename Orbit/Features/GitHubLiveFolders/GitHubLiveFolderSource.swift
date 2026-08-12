import Foundation

// MARK: - The seam

nonisolated public struct GitHubLiveFolderSource: Sendable {

    public let search: @Sendable (String) async -> Result<[GitHubPullRequest], GitHubLiveFolderError>

    public let currentLogin: @Sendable () async -> String?

    public init(
        search: @escaping @Sendable (String) async -> Result<[GitHubPullRequest], GitHubLiveFolderError>,
        currentLogin: @escaping @Sendable () async -> String?
    ) {
        self.search = search
        self.currentLogin = currentLogin
    }

    public static let unconfigured = GitHubLiveFolderSource(
        search: { _ in .failure(.signedOut) },
        currentLogin: { nil }
    )

    // userAgent is a parameter, not a constant: this file also compiles into the host-less
    // OrbitTests bundle, which cannot see the generated ChromiumBuild.userAgent.
    @MainActor
    public static func live(
        session: any EngineSession,
        userAgent: String,
        urlSession: URLSession = .shared
    ) -> GitHubLiveFolderSource {
        let cookieJar: @Sendable @MainActor () async -> [String: String] = { [weak session] in
            guard let session else { return [:] }
            var pairs: [String: String] = [:]
            for cookie in await session.cookies(for: GitHubSearchEndpoint.origin) {
                pairs[cookie.name] = cookie.value
            }
            return pairs
        }
        return GitHubLiveFolderSource(
            search: { query in
                let cookies = await cookieJar()
                return await GitHubSearchEndpoint.search(
                    query: query,
                    cookies: cookies,
                    userAgent: userAgent,
                    urlSession: urlSession
                )
            },
            currentLogin: {
                let cookies = await cookieJar()
                guard let login = cookies[GitHubSearchEndpoint.loginCookieName], !login.isEmpty else { return nil }
                return login
            }
        )
    }
}

// MARK: - Queries

nonisolated public enum GitHubLiveFolderQuery {

    public static func createdByMe(login: String) -> String {
        "is:pr is:open author:\(login) sort:updated"
    }

    public static func reviewRequested(login: String) -> String {
        "is:pr is:open review-requested:\(login) sort:updated"
    }
}

// MARK: - The endpoint

// Auth reuses the user's github.com session cookies (no OAuth). The session cookie is scoped to
// github.com, not api.github.com, so requests go to GitHub's first-party JSON API at that host:
// GET https://github.com/search?q=<encoded>&type=issues, Accept: application/json.
nonisolated public enum GitHubSearchEndpoint {

    public static let origin = URL(string: "https://github.com")!

    // Not HttpOnly; the cheapest truthful signed-out signal.
    public static let loginCookieName = "dotcom_user"

    // RFC 3986 unreserved set, spelled out: urlQueryAllowed leaves &, +, = unescaped.
    public static let unreservedQueryCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters) else {
            return nil
        }
        return URL(string: "https://github.com/search?q=\(encoded)&type=issues")
    }

    public static func cookieHeader(from cookies: [String: String]) -> String {
        cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    public static func request(query: String, cookies: [String: String], userAgent: String) -> URLRequest? {
        guard let url = searchURL(query: query) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // false: the default would read/write HTTPCookieStorage.shared, leaking the engine's
        // per-profile session cookie into a process-wide store nothing else in Orbit manages.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader(from: cookies), forHTTPHeaderField: "Cookie")
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    public static func search(
        query: String,
        cookies: [String: String],
        userAgent: String,
        urlSession: URLSession
    ) async -> Result<[GitHubPullRequest], GitHubLiveFolderError> {
        guard let login = cookies[loginCookieName], !login.isEmpty else { return .failure(.signedOut) }
        guard let request = request(query: query, cookies: cookies, userAgent: userAgent) else {
            return .failure(.malformed("could not build a search URL for \(query)"))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.malformed("the response was not HTTP"))
        }
        if let failure = failure(forStatus: http.statusCode, body: data) {
            return .failure(failure)
        }
        return GitHubSearchPayload.pullRequests(from: data)
    }

    public static func failure(forStatus status: Int, body: Data) -> GitHubLiveFolderError? {
        switch status {
        case 200:
            return nil
        case 401:
            return .signedOut
        case 403:
            // GitHub answers a rate limit with 403 at least as often as 429; the body decides.
            let text = String(decoding: body, as: UTF8.self).lowercased()
            if text.contains("rate limit") || text.contains("abuse detection") || text.contains("too many requests") {
                return .rateLimited
            }
            return .badResponse(403)
        case 429:
            return .rateLimited
        default:
            return .badResponse(status)
        }
    }
}

// MARK: - Title cleanup

nonisolated public enum GitHubLiveFolderTitle {

    // Order is load-bearing: decoding entities first would turn a literal "&lt;em&gt;" into markup and strip it.
    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<em>", with: "")
        text = text.replacingOccurrences(of: "</em>", with: "")
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ string: String) -> String {
        var result = decodeNumericReferences(string)
        // &amp; must decode last, or a double-encoded &amp;lt; becomes < instead of the literal &lt;.
        for (entity, replacement) in namedEntitiesAmpersandLast {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static func decodeNumericReferences(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#x?[0-9A-Fa-f]+;"#, options: [.caseInsensitive]) else {
            return string
        }
        let ns = string as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            if let value = scalarValue(ofNumericReference: token), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                result += token
            }
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    private static func scalarValue(ofNumericReference token: String) -> Int? {
        let inner = token.dropFirst(2).dropLast()
        if inner.hasPrefix("x") || inner.hasPrefix("X") {
            return Int(inner.dropFirst(), radix: 16)
        }
        return Int(inner)
    }

    private static let namedEntitiesAmpersandLast: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&amp;", "&"),
    ]
}

// MARK: - The wire format

// Undocumented first-party endpoint: every field optional, every number tolerant of a JSON string too.
nonisolated public enum GitHubSearchPayload {

    nonisolated private struct Envelope: Decodable {
        var payload: Payload?
    }

    nonisolated private struct Payload: Decodable {
        var logged_in: Bool?
        var results: [SearchResult]?
    }

    nonisolated private struct SearchResult: Decodable {
        var id: LooseValue?
        var number: LooseValue?
        var state: String?
        var merged: Bool?
        var reviewable_state: String?
        var hl_title: String?
        var title: String?
        var author_name: String?
        var created: String?
        var repo: RepoBox?
    }

    nonisolated private struct RepoBox: Decodable {
        var repository: Repository?
    }

    nonisolated private struct Repository: Decodable {
        var owner_login: String?
        var name: String?
    }

    // GitHub sends id as a string and number as a number; nothing promises it keeps doing either.
    nonisolated private enum LooseValue: Decodable {
        case string(String)
        case integer(Int)
        case double(Double)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) { self = .integer(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Double.self) { self = .double(value); return }
            throw DecodingError.typeMismatch(
                LooseValue.self,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "not a string or a number")
            )
        }

        var stringValue: String {
            switch self {
            case .string(let value): return value
            case .integer(let value): return String(value)
            case .double(let value): return String(Int(value))
            }
        }

        var integerValue: Int? {
            switch self {
            case .string(let value): return Int(value)
            case .integer(let value): return value
            case .double(let value): return Int(value)
            }
        }
    }

    // payload.logged_in == false is signedOut, not empty: an unauthenticated search still returns results.
    public static func pullRequests(from data: Data) -> Result<[GitHubPullRequest], GitHubLiveFolderError> {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }
        guard let payload = envelope.payload else {
            return .failure(.malformed("the response carried no `payload` object"))
        }
        if payload.logged_in == false {
            return .failure(.signedOut)
        }
        return .success((payload.results ?? []).compactMap(reduce))
    }

    private static func reduce(_ result: SearchResult) -> GitHubPullRequest? {
        guard let id = result.id?.stringValue, !id.isEmpty else { return nil }
        guard let number = result.number?.integerValue else { return nil }
        guard let owner = result.repo?.repository?.owner_login, !owner.isEmpty else { return nil }
        guard let repository = result.repo?.repository?.name, !repository.isEmpty else { return nil }
        guard let url = URL(string: "https://github.com/\(owner)/\(repository)/pull/\(number)") else { return nil }

        let rawTitle = result.hl_title ?? result.title ?? ""
        return GitHubPullRequest(
            id: id,
            number: number,
            title: GitHubLiveFolderTitle.clean(rawTitle),
            ownerLogin: owner,
            repositoryName: repository,
            authorLogin: result.author_name ?? "",
            // Absent reviewable_state is not a claim the PR is a draft.
            isDraft: result.reviewable_state.map { $0 != "ready" } ?? false,
            isMerged: result.merged ?? false,
            state: result.state ?? "open",
            createdAt: result.created.flatMap(parseTimestamp),
            url: url
        )
    }

    public static func parseTimestamp(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
