import Foundation

// MARK: - One stub resource

nonisolated public struct RedirectResource: Sendable, Equatable {
    public let name: String
    public let mimeType: String
    public let content: [UInt8]

    init(name: String, mimeType: String, base64: String) {
        self.name = name
        self.mimeType = mimeType
        self.content = [UInt8](Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data())
    }

    init(name: String, mimeType: String, content: [UInt8]) {
        self.name = name
        self.mimeType = mimeType
        self.content = content
    }
}

// MARK: - What a redirect token resolves to

nonisolated public enum RedirectSubstitution: Sendable, Equatable {
    case resource(RedirectResource)
    case empty
}

// MARK: - The library

nonisolated public enum RedirectResourceLibrary {

    public static let noRedirectToken = "none"

    public static func substitution(for token: String) -> RedirectSubstitution? {
        let key = normalize(token)
        if key == "empty" { return .empty }
        guard let resource = resource(named: key) else { return nil }
        return .resource(resource)
    }

    public static func isNoRedirectToken(_ token: String) -> Bool {
        normalize(token) == noRedirectToken
    }

    public static func isKnownToken(_ token: String) -> Bool {
        isNoRedirectToken(token) || substitution(for: token) != nil
    }

    public static func resource(named token: String) -> RedirectResource? {
        let key = normalize(token)
        if let direct = byName[key] { return direct }
        if let aliased = resourceAliases[key] { return byName[aliased] }
        return nil
    }

    public static var allResources: [RedirectResource] { bundledResources }

    public static func mimeTypeForEmptyStub(resourceType: ContentBlockingResourceType) -> String {
        switch resourceType {
        case .document, .subdocument: return "text/html"
        case .script: return "text/javascript"
        case .stylesheet: return "text/css"
        case .image: return "image/gif"
        case .media: return "video/mp4"
        case .font: return "font/woff2"
        default: return "text/plain"
        }
    }

    // MARK: - Internals

    private static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static let byName: [String: RedirectResource] = {
        var map: [String: RedirectResource] = [:]
        map.reserveCapacity(bundledResources.count)
        for resource in bundledResources { map[resource.name] = resource }
        return map
    }()
}
