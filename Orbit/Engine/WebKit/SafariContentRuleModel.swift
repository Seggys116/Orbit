import Foundation

// MARK: - Rule model

nonisolated struct SafariRule: Sendable, Hashable, Encodable {

    struct Trigger: Sendable, Hashable, Encodable {
        var urlFilter: String
        var caseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var loadContext: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    struct Action: Sendable, Hashable, Encodable {
        var type: String
        var selector: String?
        var redirectURL: String?

        static let block = Action(type: "block")
        static let ignorePreviousRules = Action(type: "ignore-previous-rules")

        enum CodingKeys: String, CodingKey {
            case type, selector, redirect
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(selector, forKey: .selector)
            if let redirectURL { try container.encode(["url": redirectURL], forKey: .redirect) }
        }
    }

    var trigger: Trigger
    var action: Action
}

// MARK: - What this WebKit accepts

nonisolated struct SafariRuleCapabilities: Equatable, Sendable {
    var resourceTypes: Set<String>
    var loadContext: Bool
    var redirect: Bool

    // Types every WebKit that supports content rule lists has accepted.
    static let baseline = SafariRuleCapabilities(
        resourceTypes: ["document", "image", "style-sheet", "script", "font", "media", "raw"],
        loadContext: false,
        redirect: false
    )

    static let full = SafariRuleCapabilities(
        resourceTypes: baseline.resourceTypes.union(["fetch", "ping", "websocket", "other"]),
        loadContext: true,
        redirect: true
    )
}

// MARK: - Translation result

nonisolated struct SafariTranslation: Sendable {
    // Blocks and redirect stubs, in list order.
    var blocks: [SafariRule] = []
    var exceptions: [SafariRule] = []
    // $important blocks go after the exceptions so those cannot cancel them.
    var important: [SafariRule] = []
    var genericCosmetic: [SafariRule] = []
    var specificCosmetic: [SafariRule] = []
    // generichide / specifichide / elemhide exceptions, one set per cosmetic list kind.
    var genericHideIgnores: [SafariRule] = []
    var specificHideIgnores: [SafariRule] = []
    var report = ContentBlockingEngineReport()
}
