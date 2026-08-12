import Foundation

nonisolated public final class ContentBlocker: NSObject, @unchecked Sendable {

    // lock guards this header; accessed from the main actor and the engine's IO thread.
    private let lock = NSLock()
    private var ruleSet = ContentBlockerRuleSet()
    private var enabled = false
    private var allowlist: Set<String> = []
    private var blockedCount: UInt64 = 0
    private var perHostBlockedCount: [String: UInt64] = [:]

    public override init() {
        super.init()
    }

    // MARK: - Configuration

    public func setRuleSet(_ newValue: ContentBlockerRuleSet) {
        lock.lock()
        ruleSet = newValue
        lock.unlock()
    }

    public var currentRuleSet: ContentBlockerRuleSet {
        lock.lock()
        defer { lock.unlock() }
        return ruleSet
    }

    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
        }
    }

    public func setAllowlist(_ hosts: Set<String>) {
        lock.lock()
        allowlist = Set(hosts.map { $0.lowercased() })
        lock.unlock()
    }

    public var allowlistedHosts: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return allowlist
    }

    public func isAllowlisted(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.allowlist(allowlist, covers: host.lowercased())
    }

    private static func allowlist(_ hosts: Set<String>, covers host: String) -> Bool {
        if hosts.contains(host) { return true }
        return hosts.contains { ContentBlockingURL.host(host, matchesDomain: $0) }
    }

    // MARK: - Counters

    public var blockedRequestCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return blockedCount
    }

    public func blockedRequestCount(forDocumentHost host: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return perHostBlockedCount[host.lowercased()] ?? 0
    }

    public func resetCounters() {
        lock.lock()
        blockedCount = 0
        perHostBlockedCount.removeAll()
        lock.unlock()
    }

    // MARK: - Decisions

    public func decision(
        forURL urlString: String,
        documentURL documentURLString: String,
        resourceType: ContentBlockingResourceType
    ) -> ContentBlockingDecision {
        lock.lock()
        let isOn = enabled
        let rules = ruleSet
        let hosts = allowlist
        lock.unlock()

        guard isOn else { return .disabled }

        let documentHost = ContentBlockingURL.host(ofURLString: documentURLString)
        if let documentHost, Self.allowlist(hosts, covers: documentHost) {
            return .allowlistedSite(host: documentHost)
        }

        let decision = rules.decision(
            forURL: urlString,
            documentURL: documentURLString,
            resourceType: resourceType
        )

        if decision.preventedOriginalResponse {
            lock.lock()
            blockedCount &+= 1
            if let documentHost {
                perHostBlockedCount[documentHost, default: 0] &+= 1
            }
            lock.unlock()
        }
        return decision
    }

    @objc(shouldBlockURL:documentURL:resourceType:)
    public func shouldBlock(url: String, documentURL: String, resourceType: Int) -> Bool {
        let type = ContentBlockingResourceType(rawValue: resourceType) ?? .other
        return decision(forURL: url, documentURL: documentURL, resourceType: type).isBlocked
    }

    public func stubPayload(
        for substitution: RedirectSubstitution,
        resourceType: ContentBlockingResourceType
    ) -> (mimeType: String, content: [UInt8]) {
        switch substitution {
        case .resource(let resource):
            return (resource.mimeType, resource.content)
        case .empty:
            return (RedirectResourceLibrary.mimeTypeForEmptyStub(resourceType: resourceType), [])
        }
    }

    public func cosmeticStyleSheet(forHost host: String) -> String {
        cosmeticStyleSheet(forDocumentURL: "https://\(host.lowercased())/")
    }

    public func cosmeticStyleSheet(forDocumentURL documentURLString: String) -> String {
        lock.lock()
        let isOn = enabled
        let rules = ruleSet
        let hosts = allowlist
        lock.unlock()

        guard isOn else { return "" }
        let lowered = (ContentBlockingURL.host(ofURLString: documentURLString) ?? documentURLString).lowercased()
        guard !Self.allowlist(hosts, covers: lowered) else { return "" }

        return rules.cosmeticStyleSheet(forDocumentURL: documentURLString)
    }
}
