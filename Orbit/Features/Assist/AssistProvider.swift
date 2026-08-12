import Foundation

// MARK: - Provider kinds

enum AssistProviderKind: String, CaseIterable, Sendable {

    case anthropic
    case openAICompatible

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    var defaultBaseURLString: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    var baseURLPlaceholder: String { defaultBaseURLString }

    var modelPlaceholder: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openAICompatible: return "gpt-5.6-luna"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openAICompatible: return "sk-…"
        }
    }

    var requestPath: String {
        switch self {
        case .anthropic: return "/v1/messages"
        case .openAICompatible: return "/chat/completions"
        }
    }

    var baseURLDescription: String {
        switch self {
        case .anthropic:
            return "Anthropic's API host, or any host that speaks the same Messages API. Orbit posts to \(requestPath) beneath it."
        case .openAICompatible:
            return "The base URL of any OpenAI-compatible API — OpenAI, OpenRouter, Groq, together.ai, Ollama, LM Studio, or your own. Include the version path; Orbit posts to \(requestPath) beneath it."
        }
    }

    /// Turns a base URL into the URL Orbit posts to. A base that already names the request path is left alone, so pasting a full endpoint works too.
    static func requestURL(kind: AssistProviderKind, baseURLString: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? kind.defaultBaseURLString : trimmed
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }

        if !path.hasSuffix(kind.requestPath) {
            if kind == .anthropic, path.hasSuffix("/v1") { path.removeLast("/v1".count) }
            path += kind.requestPath
        }

        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// MARK: - Provider configuration

struct AssistProviderConfig: Equatable, Sendable {

    var kind: AssistProviderKind
    var baseURLString: String
    var model: String

    /// Held in the Keychain, never in UserDefaults or state.json.
    var apiKey: String

    init(kind: AssistProviderKind = .anthropic, baseURLString: String = "", model: String = "", apiKey: String = "") {
        self.kind = kind
        self.baseURLString = baseURLString
        self.model = model
        self.apiKey = apiKey
    }

    var requestURL: URL? {
        AssistProviderKind.requestURL(kind: kind, baseURLString: baseURLString)
    }

    var isConfigured: Bool {
        guard let requestURL, !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if Self.isLoopback(requestURL) { return true }
        return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }

    var destinationDescription: String {
        guard let host = requestURL?.host else { return "no provider" }
        return host
    }
}

// MARK: - Requests

struct AssistRequest: Equatable, Sendable {
    var system: String
    var user: String
    var maxOutputTokens: Int
    var temperature: Double

    init(system: String, user: String, maxOutputTokens: Int = 512, temperature: Double = 0.2) {
        self.system = system
        self.user = user
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

enum AssistError: LocalizedError, Equatable {
    case notConfigured
    case assistDisabled
    case featureDisabled(String)
    case incognito
    case noPageText
    case transport(String)
    case http(status: Int, body: String)
    case malformedResponse(String)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI provider is configured. Pick a provider and set a model and key in Settings → Assist."
        case .assistDisabled:
            return "Assist is switched off. Turn it on in Settings → Assist."
        case .featureDisabled(let name):
            return "\(name) is switched off in Settings → Assist."
        case .incognito:
            return "Orbit never sends anything from an incognito window to an AI provider."
        case .noPageText:
            return "This page produced no readable text to send."
        case .transport(let message):
            return "Could not reach the provider: \(message)"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : " — \(trimmed.prefix(400))"
            return "The provider returned HTTP \(status)\(detail)"
        case .malformedResponse(let detail):
            return "The provider's reply was not in the expected format: \(detail)"
        case .emptyCompletion:
            return "The provider returned an empty answer."
        }
    }
}

// MARK: - The seam

struct AssistSink: Sendable {

    let generate: @Sendable (AssistRequest) async throws -> String
    let pageText: @Sendable () async -> PageTextExtract?

    init(
        generate: @escaping @Sendable (AssistRequest) async throws -> String,
        pageText: @escaping @Sendable () async -> PageTextExtract?
    ) {
        self.generate = generate
        self.pageText = pageText
    }

    static let unconfigured = AssistSink(
        generate: { _ in throw AssistError.notConfigured },
        pageText: { nil }
    )
}

// MARK: - The real client

struct AssistProviderClient: Sendable {

    let config: AssistProviderConfig
    let session: URLSession

    init(config: AssistProviderConfig, session: URLSession = AssistProviderClient.defaultSession) {
        self.config = config
        self.session = session
    }

    static let anthropicVersion = "2023-06-01"

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    func generate(_ request: AssistRequest) async throws -> String {
        guard config.isConfigured, let endpoint = config.requestURL else { throw AssistError.notConfigured }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in Self.headers(kind: config.kind, apiKey: config.apiKey) {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = try Self.encodeBody(request, kind: config.kind, model: config.model)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AssistError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decodeCompletion(data)
    }

    // MARK: Wire format

    /// Never sends both schemes' auth headers at once — a proxy in front of either provider can reject the stray one.
    static func headers(kind: AssistProviderKind, apiKey: String) -> [String: String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .anthropic:
            var headers = ["anthropic-version": anthropicVersion]
            if !key.isEmpty { headers["x-api-key"] = key }
            return headers
        case .openAICompatible:
            return key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
        }
    }

    static func encodeBody(_ request: AssistRequest, kind: AssistProviderKind, model: String) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": request.maxOutputTokens,
            "stream": false,
        ]

        switch kind {
        case .anthropic:
            // The system prompt is a top-level field, not a message, and current Claude models reject `temperature` outright.
            payload["system"] = request.system
            payload["messages"] = [["role": "user", "content": request.user]]
        case .openAICompatible:
            payload["temperature"] = request.temperature
            payload["messages"] = [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ]
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Accepts both OpenAI's choices[0].message.content and Anthropic's content[0].text.
    static func decodeCompletion(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistError.malformedResponse("body was not a JSON object")
        }

        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
                return try nonEmpty(content)
            }
            if let text = first["text"] as? String {
                return try nonEmpty(text)
            }
        }

        if let content = root["content"] as? [[String: Any]] {
            let joined = content.compactMap { $0["text"] as? String }.joined()
            return try nonEmpty(joined)
        }

        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw AssistError.malformedResponse(message)
        }

        throw AssistError.malformedResponse("no choices[0].message.content and no content[].text")
    }

    private static func nonEmpty(_ string: String) throws -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw AssistError.emptyCompletion }
        return trimmed
    }
}
