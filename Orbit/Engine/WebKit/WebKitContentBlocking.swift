import CryptoKit
import Foundation
import ObjectiveC
import OSLog
import WebKit

// Owns the compiled rule lists and keeps every web view's user content controller in step with the blocker.
@MainActor
final class WebKitContentBlocking {

    static let identifierPrefix = "orbit-cb-"
    private static let probeIdentifier = "orbit-cb-probe"
    private static let legacyIdentifier = "orbit-content-blocking"
    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitContentBlocking")
    private static var associationKey: UInt8 = 0
    private static var cachedCapabilities: SafariRuleCapabilities?

    // WebKit reports blocked loads only through this private navigation delegate callback.
    static let countingSelector = NSSelectorFromString("_webView:contentRuleListWithIdentifier:performedAction:forURL:")

    static var canCountBlockedRequests: Bool {
        guard let actionClass = NSClassFromString("_WKContentRuleListAction") else { return false }
        return class_respondsToSelector(actionClass, NSSelectorFromString("blockedLoad"))
    }

    static var countingCapability: EngineCapabilities {
        canCountBlockedRequests ? .blockedRequestCounts : []
    }

    private let store: WKContentRuleListStore
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var installed: [WKContentRuleList] = []
    private var generation = 0

    private(set) var blocker: ContentBlocker?
    private(set) var lastReport = ContentBlockingEngineReport()

    init(store: WKContentRuleListStore = .default()) {
        self.store = store
    }

    var installedListCount: Int { installed.count }

    func install(on controller: WKUserContentController) {
        controllers.add(controller)
        objc_setAssociatedObject(controller, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        for list in installed { controller.add(list) }
    }

    static func coordinator(for controller: WKUserContentController) -> WebKitContentBlocking? {
        objc_getAssociatedObject(controller, &associationKey) as? WebKitContentBlocking
    }

    // A disabled or absent blocker removes the lists from every web view at once.
    func apply(_ newBlocker: ContentBlocker?) async {
        blocker = newBlocker
        generation += 1
        let mine = generation

        guard let newBlocker, newBlocker.isEnabled else {
            replaceInstalled(with: [])
            lastReport = ContentBlockingEngineReport()
            newBlocker?.setEngineReport(lastReport)
            return
        }

        let capabilities = await resolveCapabilities()
        guard mine == generation else { return }

        let ruleSet = newBlocker.currentRuleSet
        var translation = await Self.translate(ruleSet, capabilities: capabilities)
        guard mine == generation else { return }

        var compiled = await Self.plan(translation, allowlist: newBlocker.allowlistedHosts)
        var report = translation.report
        // WebKit compiles from the planned lists. Keeping this translation cached
        // left every url-filter string resident after the WKContentRuleLists existed.
        translation = SafariTranslation()
        if compiled.exceptionsDropped > 0 {
            report.note("Dropped \(compiled.exceptionsDropped) exception rule(s) beyond the per-list limit")
        }

        var lists: [WKContentRuleList] = []
        var currentIdentifiers: Set<String> = []
        var planned = compiled.lists
        compiled.lists = []
        for index in planned.indices {
            guard mine == generation else { return }
            let kind = planned[index].kind
            let listIndex = planned[index].index
            let rules = DroppableRules(planned[index].rules)
            planned[index] = SafariRuleListPlan(kind: kind, index: listIndex, rules: [])
            let encoded = DroppableString(await Self.encode(rules.value))
            let identifier = Self.identifier(kind: kind, index: listIndex, json: encoded.value)
            currentIdentifiers.insert(identifier)
            let list = await compilePrepared(
                kind: kind,
                index: listIndex,
                rules: rules,
                json: encoded,
                identifier: identifier,
                report: &report
            )
            rules.drop()
            encoded.value = ""
            if let list {
                lists.append(list)
            } else {
                report.failedRuleLists += 1
            }
        }
        planned = []
        guard mine == generation else { return }

        report.ruleLists = lists.count
        replaceInstalled(with: lists)
        lastReport = report
        newBlocker.setEngineReport(report)
        Self.logger.info(
            """
            Content rules: \(report.networkRules, privacy: .public) network, \
            \(report.cosmeticRules, privacy: .public) cosmetic in \(lists.count, privacy: .public) list(s); \
            \(report.rulesDroppedAtCompile, privacy: .public) dropped at compile, \
            \(report.failedRuleLists, privacy: .public) list(s) failed, \
            \(report.skippedRegexRules, privacy: .public) regex and \
            \(report.skippedUnsupportedRules, privacy: .public) other rules skipped
            """
        )
        await removeStaleLists(keeping: currentIdentifiers)
    }

    private func replaceInstalled(with lists: [WKContentRuleList]) {
        for controller in controllers.allObjects {
            for old in installed { controller.remove(old) }
            for list in lists { controller.add(list) }
        }
        installed = lists
    }

    // MARK: Compile

    private static func identifier(kind: SafariRuleListPlan.Kind, index: Int, json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8))
        let hash = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(identifierPrefix)\(kind.rawValue)-\(index)-\(hash)"
    }

    func compileResilient(
        batch: SafariRuleListPlan,
        json: String,
        identifier: String,
        report: inout ContentBlockingEngineReport
    ) async -> WKContentRuleList? {
        await compilePrepared(
            kind: batch.kind,
            index: batch.index,
            rules: DroppableRules(batch.rules),
            json: DroppableString(json),
            identifier: identifier,
            report: &report
        )
    }

    // `rules` and `json` are the only owners of this batch. The JSON string is
    // released once WebKit has copied it, and the rules are released once the
    // list exists, so a successful compile does not keep both.
    private func compilePrepared(
        kind: SafariRuleListPlan.Kind,
        index: Int,
        rules: DroppableRules,
        json: DroppableString,
        identifier: String,
        report: inout ContentBlockingEngineReport
    ) async -> WKContentRuleList? {
        if let existing = await lookUp(identifier) {
            rules.drop()
            json.value = ""
            return existing
        }

        let first = await compileOwning(identifier: identifier, box: json)
        if let list = first.list {
            rules.drop()
            return list
        }

        let reason = first.error.map { Self.describe($0) } ?? "no list returned"
        Self.logger.error("Rule list \(identifier, privacy: .public) failed to compile: \(reason, privacy: .public)")
        guard Self.isCompileFailure(first.error) else {
            report.note("Rule list \(kind.rawValue) \(index) could not be stored: \(reason)")
            rules.drop()
            return nil
        }

        var attempts = 0
        var indexed = Array(rules.value.enumerated())
        rules.drop()
        let invalid = await invalidIndices(in: indexed, attempts: &attempts)
        await removeList(Self.probeIdentifier)
        guard let invalid else {
            report.note("Rule list \(kind.rawValue) \(index) failed to compile and could not be repaired: \(reason)")
            return nil
        }

        for position in invalid.sorted().prefix(3) {
            let sample = Self.sample(indexed[position].element)
            Self.logger.error("Dropping invalid rule \(position, privacy: .public): \(sample, privacy: .public)")
            report.note("Dropped invalid rule: \(sample)")
        }
        report.rulesDroppedAtCompile += invalid.count

        var kept = indexed.filter { !invalid.contains($0.offset) }.map(\.element)
        indexed = []
        guard !kept.isEmpty else { return nil }
        let repairedJSON = DroppableString(await Self.encode(kept))
        kept = []
        let repaired = await compileOwning(identifier: identifier, box: repairedJSON)
        if repaired.list == nil {
            let message = repaired.error.map { Self.describe($0) } ?? "no list returned"
            Self.logger.error("Repaired rule list \(identifier, privacy: .public) still failed: \(message, privacy: .public)")
            report.note("Rule list \(kind.rawValue) \(index) failed after repair: \(message)")
        }
        return repaired.list
    }

    // Splits the failing set until single rules remain; WebKit reports no rule index.
    private func invalidIndices(in rules: [(offset: Int, element: SafariRule)], attempts: inout Int) async -> Set<Int>? {
        if rules.isEmpty { return [] }
        attempts += 1
        if attempts > 400 { return nil }
        let encoded = DroppableString(await Self.encode(rules.map(\.element)))
        let outcome = await compileOwning(identifier: Self.probeIdentifier, box: encoded)
        if outcome.list != nil { return [] }
        guard Self.isCompileFailure(outcome.error) else { return nil }
        if rules.count == 1 { return [rules[0].offset] }
        let middle = rules.count / 2
        guard let left = await invalidIndices(in: Array(rules[..<middle]), attempts: &attempts),
              let right = await invalidIndices(in: Array(rules[middle...]), attempts: &attempts)
        else { return nil }
        return left.union(right)
    }

    private func compile(identifier: String, json: String) async -> (list: WKContentRuleList?, error: Error?) {
        await compileOwning(identifier: identifier, box: DroppableString(json))
    }

    // The string is cleared before this function suspends, so the async frame
    // does not keep a second copy for the whole compile.
    private func compileOwning(identifier: String, box: DroppableString) async -> (list: WKContentRuleList?, error: Error?) {
        await withCheckedContinuation { continuation in
            let payload = box.value
            box.value = ""
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: payload) { list, error in
                continuation.resume(returning: (list, error))
            }
        }
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func removeList(_ identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    private func availableIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: identifiers ?? [])
            }
        }
    }

    private func removeStaleLists(keeping keep: Set<String>) async {
        for identifier in await availableIdentifiers() where identifier == Self.legacyIdentifier
            || (identifier.hasPrefix(Self.identifierPrefix) && !keep.contains(identifier)) {
            await removeList(identifier)
        }
    }

    private static func isCompileFailure(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == WKErrorDomain && error.code == WKError.Code.contentRuleListStoreCompileFailed.rawValue
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String { parts.append(reason) }
        if let help = nsError.userInfo[NSHelpAnchorErrorKey] as? String { parts.append(help) }
        return parts.joined(separator: ": ")
    }

    private static func sample(_ rule: SafariRule) -> String {
        let text = SafariContentRuleTranslator.json([rule])
        return text.count > 240 ? String(text.prefix(240)) + "..." : text
    }

    @concurrent
    private nonisolated static func translate(
        _ ruleSet: ContentBlockerRuleSet,
        capabilities: SafariRuleCapabilities
    ) async -> SafariTranslation {
        SafariContentRuleTranslator.translate(ruleSet, capabilities: capabilities)
    }

    @concurrent
    private nonisolated static func plan(_ translation: SafariTranslation, allowlist: Set<String>) async -> SafariRulePlanSet {
        SafariContentRuleTranslator.plan(translation, allowlist: allowlist)
    }

    @concurrent
    private nonisolated static func encode(_ rules: [SafariRule]) async -> String {
        SafariContentRuleTranslator.json(rules)
    }

    // MARK: Capability probe

    // Compiles tiny lists to learn which optional rule features this WebKit accepts.
    private func resolveCapabilities() async -> SafariRuleCapabilities {
        if let cached = Self.cachedCapabilities { return cached }

        var features: [(label: String, rule: String)] = []
        for type in ["fetch", "ping", "websocket", "other"] {
            features.append((type, #"{"trigger":{"url-filter":"orbit-probe","resource-type":["\#(type)"]},"action":{"type":"block"}}"#))
        }
        features.append(("load-context", #"{"trigger":{"url-filter":"orbit-probe","resource-type":["document"],"load-context":["top-frame"]},"action":{"type":"block"}}"#))
        features.append(("redirect", #"{"trigger":{"url-filter":"orbit-probe"},"action":{"type":"redirect","redirect":{"url":"data:text/plain,"}}}"#))

        var supported = Set<String>()
        let combined = "[" + features.map(\.rule).joined(separator: ",") + "]"
        if await compile(identifier: Self.probeIdentifier, json: combined).list != nil {
            supported = Set(features.map(\.label))
        } else {
            for feature in features {
                let outcome = await compile(identifier: Self.probeIdentifier, json: "[\(feature.rule)]")
                if outcome.list != nil { supported.insert(feature.label) }
            }
        }
        await removeList(Self.probeIdentifier)

        var resolved = SafariRuleCapabilities.baseline
        resolved.resourceTypes.formUnion(supported.intersection(["fetch", "ping", "websocket", "other"]))
        resolved.loadContext = supported.contains("load-context")
        resolved.redirect = supported.contains("redirect")
        let unsupported = features.map(\.label).filter { !supported.contains($0) }
        if !unsupported.isEmpty {
            Self.logger.error("WebKit rejected content rule feature(s): \(unsupported.joined(separator: ", "), privacy: .public)")
        }
        Self.cachedCapabilities = resolved
        return resolved
    }
}

// Class storage so a batch's rules or JSON can be released while an async
// frame is still suspended. Assigning "" or [] drops the buffer immediately.
private final class DroppableString {
    var value: String
    init(_ value: String) { self.value = value }
}

private final class DroppableRules {
    var value: [SafariRule]
    init(_ value: [SafariRule]) { self.value = value }
    func drop() { value = [] }
}
