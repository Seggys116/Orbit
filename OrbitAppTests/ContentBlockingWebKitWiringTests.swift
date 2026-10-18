//  Content blocking on the WebKit engine: the blocker wiring, the filter-list to
//  content-rule translation, and live page loads against system WebKit.

import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class ContentBlockingWebKitWiringTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    private func makeBlocker(_ listText: String) -> ContentBlocker {
        var ruleSet = ContentBlockerRuleSet()
        ruleSet.add(listText: listText, listID: "TestList")
        let blocker = ContentBlocker()
        blocker.setRuleSet(ruleSet)
        blocker.isEnabled = true
        return blocker
    }

    func testApplyContentBlockerAdvertisesTheCapability() {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        XCTAssertTrue(engine.capabilities.contains(.contentBlocking))
        XCTAssertEqual(
            engine.capabilities.contains(.blockedRequestCounts),
            WebKitContentBlocking.canCountBlockedRequests,
            "counting is advertised only when WebKit's content rule action callback exists"
        )
    }

    func testApplyContentBlockerInstallsAHandlerThatBlocksAMatchingRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertTrue(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
        XCTAssertFalse(webKit.blockerDecision(url: "https://example.com/app.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerNilBlockerAllowsEveryRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        await engine.applyContentBlocker(nil, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerDisabledBlockerAllowsEveryRequest() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.isEnabled = false

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script))
    }

    func testApplyContentBlockerRespectsAllowlist() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com^\n")
        blocker.setAllowlist(["example.com"])

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let webKit = try XCTUnwrap(engine as? WebKitEngine)
        XCTAssertFalse(
            webKit.blockerDecision(url: "https://ads.example.com/tracker.js", documentURL: "https://example.com/", resourceType: .script),
            "the document's own host is allowlisted, so nothing on its page should be blocked"
        )
    }

    func testApplyContentBlockerServesAnEmptyRedirectSubstitutionRatherThanBlocking() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/ga.js",
            documentURL: "https://example.com/",
            resourceType: .script
        ) else {
            return XCTFail("an empty redirect must substitute, not block")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .script)
        XCTAssertEqual(payload.mimeType, "text/javascript")
        XCTAssertTrue(payload.content.isEmpty)
    }

    func testApplyContentBlockerServesANamedRedirectResourceWithItsOwnBytes() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/ga.js$redirect=noopjs\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        let expected = try XCTUnwrap(RedirectResourceLibrary.resource(named: "noopjs"))
        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/ga.js",
            documentURL: "https://example.com/",
            resourceType: .script
        ) else {
            return XCTFail("a named redirect must substitute")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .script)
        XCTAssertEqual(payload.mimeType, expected.mimeType)
        XCTAssertEqual(payload.content, expected.content)
    }

    func testApplyContentBlockerSubstitutionMimeTypeFollowsTheRequestedResourceType() async throws {
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        let blocker = makeBlocker("||ads.example.com/pixel$redirect=empty\n")

        await engine.applyContentBlocker(blocker, session: engine.defaultSession)

        guard case .redirect(_, _, let substitution) = blocker.decision(
            forURL: "https://ads.example.com/pixel",
            documentURL: "https://example.com/",
            resourceType: .image
        ) else {
            return XCTFail("an empty image redirect must substitute")
        }
        let payload = blocker.stubPayload(for: substitution, resourceType: .image)
        XCTAssertEqual(payload.mimeType, "image/gif")
        XCTAssertTrue(payload.content.isEmpty)
    }
}

// MARK: - Filter list to WebKit content rules

final class SafariContentRuleTranslatorTests: XCTestCase {

    private func translate(
        _ text: String,
        capabilities: SafariRuleCapabilities = .full
    ) -> SafariTranslation {
        var set = ContentBlockerRuleSet()
        set.add(listText: text, listID: "T")
        return SafariContentRuleTranslator.translate(set, capabilities: capabilities)
    }

    private func single(_ rules: [SafariRule], file: StaticString = #filePath, line: UInt = #line) throws -> SafariRule {
        XCTAssertEqual(rules.count, 1, file: file, line: line)
        return try XCTUnwrap(rules.first, file: file, line: line)
    }

    private func jsonObjects(_ rules: [SafariRule]) throws -> [[String: Any]] {
        let data = Data(SafariContentRuleTranslator.json(rules).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Network options survive

    func testHostAnchorSeparatorAndThirdPartyAreKept() throws {
        let rule = try single(translate("||tracker.example^$third-party\n").blocks)
        XCTAssertEqual(rule.trigger.urlFilter, "^[^:]+://+([^/]+\\.)?tracker\\.example[/:?&=#]")
        XCTAssertEqual(rule.trigger.loadType, ["third-party"])
        XCTAssertNil(rule.trigger.resourceType)
        XCTAssertEqual(rule.action.type, "block")
    }

    func testFirstPartyOnlyRuleIsNotWidenedToThirdParty() throws {
        let negated = try single(translate("||cdn.example^$~third-party\n").blocks)
        XCTAssertEqual(negated.trigger.loadType, ["first-party"])
        let explicit = try single(translate("||cdn.example^$first-party\n").blocks)
        XCTAssertEqual(explicit.trigger.loadType, ["first-party"])
    }

    func testResourceTypesMapToWebKitTypes() throws {
        let rule = try single(translate("||cdn.example^$script,image,stylesheet,xmlhttprequest,font,media\n").blocks)
        XCTAssertEqual(
            Set(try XCTUnwrap(rule.trigger.resourceType)),
            ["script", "image", "style-sheet", "raw", "fetch", "font", "media"]
        )
    }

    func testWebSocketPingAndOtherMapWhenSupported() throws {
        let rule = try single(translate("||cdn.example^$websocket,ping,other\n").blocks)
        XCTAssertEqual(Set(try XCTUnwrap(rule.trigger.resourceType)), ["websocket", "ping", "other"])
    }

    func testTypesThisWebKitRejectsFallBackToRawOrAreDropped() throws {
        let rule = try single(translate("||cdn.example^$other,script\n", capabilities: .baseline).blocks)
        XCTAssertEqual(Set(try XCTUnwrap(rule.trigger.resourceType)), ["script", "raw"])
        let dropped = translate("||cdn.example^$websocket\n", capabilities: .baseline)
        XCTAssertTrue(dropped.blocks.isEmpty)
        XCTAssertEqual(dropped.report.skippedUnsupportedRules, 1)
    }

    func testSubdocumentIsAChildFrameDocumentAndDocumentIsTopFrame() throws {
        let child = try single(translate("||frames.example^$subdocument\n").blocks)
        XCTAssertEqual(child.trigger.resourceType, ["document"])
        XCTAssertEqual(child.trigger.loadContext, ["child-frame"])
        let top = try single(translate("||frames.example^$document\n").blocks)
        XCTAssertEqual(top.trigger.resourceType, ["document"])
        XCTAssertEqual(top.trigger.loadContext, ["top-frame"])
        let both = try single(translate("||frames.example^$document,subdocument\n").blocks)
        XCTAssertEqual(both.trigger.resourceType, ["document"])
        XCTAssertNil(both.trigger.loadContext)
    }

    func testMixedDocumentAndSubresourceTypesEmitOneTriggerPerKind() {
        let rules = translate("||x.example^$script,subdocument\n").blocks
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.contains { $0.trigger.resourceType == ["script"] && $0.trigger.loadContext == nil })
        XCTAssertTrue(rules.contains { $0.trigger.resourceType == ["document"] && $0.trigger.loadContext == ["child-frame"] })
    }

    func testPopupBecomesADocumentRule() throws {
        let rule = try single(translate("||ads.example^$popup\n").blocks)
        XCTAssertEqual(rule.trigger.resourceType, ["document"])
        XCTAssertEqual(rule.trigger.loadContext, ["top-frame"])
    }

    func testNegatedTypesExcludeOnlyThoseTypes() throws {
        let rules = translate("||cdn.example^$~script\n").blocks
        let names = Set(rules.flatMap { $0.trigger.resourceType ?? [] })
        XCTAssertFalse(names.contains("script"))
        XCTAssertTrue(names.contains("image"))
        XCTAssertTrue(names.contains("document"))
    }

    func testDomainOptionBecomesIfDomainAndUnlessDomain() throws {
        let included = try single(translate("||x.example^$domain=a.example|b.example\n").blocks)
        XCTAssertEqual(included.trigger.ifDomain, ["*a.example", "*b.example"])
        XCTAssertNil(included.trigger.unlessDomain)
        let excluded = try single(translate("||x.example^$domain=~a.example\n").blocks)
        XCTAssertEqual(excluded.trigger.unlessDomain, ["*a.example"])
        XCTAssertNil(excluded.trigger.ifDomain)
    }

    func testIncludedDomainWithUnrelatedExclusionKeepsOnlyTheInclusion() throws {
        let rule = try single(translate("||x.example^$domain=a.example|~other.example\n").blocks)
        XCTAssertEqual(rule.trigger.ifDomain, ["*a.example"])
        XCTAssertNil(rule.trigger.unlessDomain)
    }

    func testExclusionInsideAnIncludedDomainIsSkippedNotWidened() {
        let result = translate("||x.example^$domain=a.example|~sub.a.example\n")
        XCTAssertTrue(result.blocks.isEmpty, "WebKit cannot hold both lists; emitting the wider rule would block excluded pages")
        XCTAssertEqual(result.report.skippedUnsupportedRules, 1)
    }

    func testMatchCaseSetsCaseSensitivity() throws {
        let sensitive = try single(translate("||x.example/Ads$match-case\n").blocks)
        XCTAssertEqual(sensitive.trigger.caseSensitive, true)
        XCTAssertTrue(sensitive.trigger.urlFilter.contains("Ads"), "case must survive into a case-sensitive filter")
        let insensitive = try single(translate("||x.example/Ads\n").blocks)
        XCTAssertNil(insensitive.trigger.caseSensitive)
    }

    // MARK: URL filter syntax

    func testAnchorsWildcardsAndEscaping() throws {
        let rule = try single(translate("|https://x.example/ads/*/banner.gif|\n").blocks)
        XCTAssertEqual(rule.trigger.urlFilter, "^https://x\\.example/ads/.*/banner\\.gif$")
    }

    func testSeparatorInTheMiddleIsAClassAndTrailingOneAlsoMatchesTheEnd() throws {
        let middle = try single(translate("||x.example^banner\n").blocks)
        XCTAssertEqual(middle.trigger.urlFilter, "^[^:]+://+([^/]+\\.)?x\\.example[/:?&=#]banner")
        let trailing = translate("/ads^\n").blocks
        XCTAssertEqual(trailing.map(\.trigger.urlFilter), ["/ads[/:?&=#]", "/ads$"])
    }

    func testPlainSubstringPatternHasNoAnchorAndNoDanglingWildcards() throws {
        let rule = try single(translate("*/banner/*\n").blocks)
        XCTAssertEqual(rule.trigger.urlFilter, "/banner/")
    }

    func testRegexFiltersConvertOnlyInsideWebKitsSubset() {
        let convert = { SafariContentRuleTranslator.webKitRegex(from: $0, caseSensitive: false) }
        XCTAssertEqual(convert(#"ads\d+\.js"#), "ads[0-9]+\\.js")
        XCTAssertEqual(convert(#"^https?://[a-z0-9]+\.example\.com/ad"#), "^https?://[a-z0-9]+\\.example\\.com/ad")
        XCTAssertEqual(convert(#"/ads/[^/]+\.gif$"#), "/ads/[^/]+\\.gif$")
        XCTAssertEqual(convert(#"(ab)+c"#), "(ab)+c")
        XCTAssertEqual(convert(#"\/ads\/"#), "/ads/")
        for unsupported in [#"a|b"#, #"a{2,3}"#, #"(?:a)"#, #"\bfoo"#, #"a+?"#, #"(a(b))"#, #"a$b"#, #"x^y"#, #"[[:alpha:]]"#, #"\1"#, "caf\u{e9}", #"()"#] {
            XCTAssertNil(convert(unsupported), "\(unsupported) is outside WebKit's regex subset")
        }
    }

    func testUnsupportedRegexFilterIsCountedAndTheListStillTranslates() {
        let result = translate("""
        ||fine.example^
        /tracker(a|b)\\.js/
        """)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.report.skippedRegexRules + result.report.parserInvalidRegexRules, 1)
    }

    func testSupportedRegexFilterBecomesARule() throws {
        let rule = try single(translate("/\\/ads\\/[a-z]+\\.js$/\n").blocks)
        XCTAssertEqual(rule.trigger.urlFilter, "/ads/[a-z]+\\.js$")
    }

    func testNonASCIIPatternIsSkippedWithAReason() {
        let result = translate("||b\u{fc}cher.example^\n")
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertEqual(result.report.skippedUnsupportedRules, 1)
    }

    // MARK: Exceptions and ordering

    func testExceptionsFollowBlocksAndImportantBlocksFollowExceptions() throws {
        let result = translate("""
        ||a.example^
        @@||a.example/ok
        ||b.example^$important
        ||c.example^
        """)
        let plan = SafariContentRuleTranslator.plan(result, allowlist: [])
        let list = try XCTUnwrap(plan.lists.first)
        XCTAssertEqual(plan.lists.count, 1)
        XCTAssertEqual(list.rules.map(\.action.type), ["block", "block", "ignore-previous-rules", "block"])
        XCTAssertTrue(list.rules[0].trigger.urlFilter.contains("a\\.example"))
        XCTAssertTrue(list.rules[1].trigger.urlFilter.contains("c\\.example"))
        XCTAssertTrue(list.rules[3].trigger.urlFilter.contains("b\\.example"), "$important must come after the exceptions")
    }

    func testExceptionKeepsItsOwnOptions() throws {
        let rule = try single(translate("@@||cdn.example/lib.js$script,domain=site.example\n").exceptions)
        XCTAssertEqual(rule.action.type, "ignore-previous-rules")
        XCTAssertEqual(rule.trigger.resourceType, ["script"])
        XCTAssertEqual(rule.trigger.ifDomain, ["*site.example"])
    }

    func testIdenticalRulesFromDifferentListsAppearOnce() {
        var set = ContentBlockerRuleSet()
        set.add(listText: "||dup.example^\n", listID: "A")
        set.add(listText: "||dup.example^\n", listID: "B")
        XCTAssertEqual(SafariContentRuleTranslator.translate(set, capabilities: .full).blocks.count, 1)
    }

    // MARK: Redirect stubs

    func testRedirectStubBecomesARedirectActionWhenWebKitAccepts() throws {
        let result = translate("||ads.example/ga.js$redirect=noopjs\n")
        let rule = try single(result.blocks)
        XCTAssertEqual(rule.action.type, "redirect")
        XCTAssertTrue(try XCTUnwrap(rule.action.redirectURL).hasPrefix("data:"))
        XCTAssertEqual(result.report.redirectStubs, 1)
        let objects = try jsonObjects([rule])
        let redirect = try XCTUnwrap(objects.first?["action"] as? [String: Any])["redirect"] as? [String: String]
        XCTAssertNotNil(redirect?["url"])
    }

    func testEmptyRedirectUsesTheMimeTypeOfTheRequestedType() throws {
        let rule = try single(translate("||ads.example/ga.js$script,redirect=empty\n").blocks)
        XCTAssertEqual(rule.action.redirectURL, "data:text/javascript,")
    }

    func testRedirectFallsBackToABlockWhenWebKitCannotRedirect() throws {
        let result = translate("||ads.example/ga.js$redirect=noopjs\n", capabilities: .baseline)
        let rule = try single(result.blocks)
        XCTAssertEqual(rule.action.type, "block")
        XCTAssertEqual(result.report.redirectsBlockedInstead, 1)
    }

    func testRuleOnlyRedirectsAndRedirectExceptionsAreSkippedWithAReason() {
        let result = translate("""
        ||only.example/b.js$redirect-rule=noopjs
        @@||ok.example/b.js$redirect=none
        """)
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertTrue(result.exceptions.isEmpty)
        XCTAssertEqual(result.report.skippedUnsupportedRules, 2)
        XCTAssertFalse(result.report.messages.isEmpty)
    }

    // MARK: Cosmetic rules

    func testGenericAndDomainSpecificHidesAreSeparatedAndScoped() throws {
        let result = translate("""
        ##.ad
        site.example##.promo
        ~site.example##.banner
        """)
        XCTAssertEqual(result.genericCosmetic.count, 2)
        XCTAssertEqual(result.specificCosmetic.count, 1)
        let specific = try XCTUnwrap(result.specificCosmetic.first)
        XCTAssertEqual(specific.action.type, "css-display-none")
        XCTAssertEqual(specific.action.selector, ".promo")
        XCTAssertEqual(specific.trigger.ifDomain, ["*site.example"])
        let excluded = try XCTUnwrap(result.genericCosmetic.first { $0.action.selector == ".banner" })
        XCTAssertEqual(excluded.trigger.unlessDomain, ["*site.example"])
        XCTAssertEqual(excluded.trigger.urlFilter, ".*")
    }

    func testSelectorsContainingADollarAreNotTruncated() throws {
        let rule = try single(translate("site.example##a[href$=\"/track\"]\n").specificCosmetic)
        XCTAssertEqual(rule.action.selector, "a[href$=\"/track\"]")
    }

    func testCosmeticExceptionBecomesUnlessDomainOnAGenericHide() throws {
        let result = translate("""
        ##.ad
        site.example#@#.ad
        """)
        let rule = try single(result.genericCosmetic)
        XCTAssertEqual(rule.trigger.unlessDomain, ["*site.example"])
    }

    func testCosmeticExceptionRemovesTheDomainFromASpecificHide() throws {
        let result = translate("""
        a.example,b.example##.ad
        a.example#@#.ad
        """)
        let rule = try single(result.specificCosmetic)
        XCTAssertEqual(rule.trigger.ifDomain, ["*b.example"])
    }

    func testGenericCosmeticExceptionDropsTheSelectorEverywhere() {
        let result = translate("""
        ##.ad
        site.example##.ad
        #@#.ad
        """)
        XCTAssertTrue(result.genericCosmetic.isEmpty)
        XCTAssertTrue(result.specificCosmetic.isEmpty)
    }

    func testScriptletsAreLeftOutAndCountedNotEmittedAsSelectors() {
        let result = translate("""
        site.example##+js(abort-on-property-read, adsGlobal)
        site.example##div:has-text(Sponsored)
        ##.keep
        """)
        XCTAssertEqual(result.genericCosmetic.count, 1)
        XCTAssertTrue(result.specificCosmetic.isEmpty)
        XCTAssertEqual(result.report.parserUnsupportedRules, 2)
        XCTAssertTrue(result.report.messages.contains { $0.contains("scriptlets") })
    }

    func testGenerichideExceptionCancelsGenericHidesOnlyAndElemhideBoth() throws {
        let result = translate("""
        ##.ad
        site.example##.promo
        @@||quiet.example^$generichide
        @@||bare.example^$elemhide
        """)
        let plan = SafariContentRuleTranslator.plan(result, allowlist: [])
        let generic = try XCTUnwrap(plan.lists.first { $0.kind == .genericCosmetic })
        let specific = try XCTUnwrap(plan.lists.first { $0.kind == .specificCosmetic })
        XCTAssertEqual(generic.rules.filter { $0.action.type == "ignore-previous-rules" }.count, 2)
        XCTAssertEqual(specific.rules.filter { $0.action.type == "ignore-previous-rules" }.count, 1)
        XCTAssertEqual(generic.rules.first?.action.type, "css-display-none", "the exceptions must follow the hides they cancel")
        XCTAssertTrue(specific.rules.last?.trigger.urlFilter.contains("bare\\.example") == true)
    }

    func testGenericblockHasNoWebKitEquivalentAndSaysSo() {
        let result = translate("@@||quiet.example^$genericblock\n")
        XCTAssertTrue(result.exceptions.isEmpty)
        XCTAssertEqual(result.report.skippedUnsupportedRules, 1)
    }

    // MARK: Lists, limits and the allowlist

    func testEveryListCarriesAllExceptionsAndTheAllowlistTrailer() throws {
        var lines = (0..<7).map { "||ad\($0).example^" }
        lines.append("@@||ad1.example/ok")
        lines.append("@@||ad2.example/ok")
        let result = translate(lines.joined(separator: "\n"))
        let plan = SafariContentRuleTranslator.plan(result, allowlist: ["site.example"], maxRulesPerList: 6)

        XCTAssertEqual(plan.lists.count, 3)
        XCTAssertEqual(plan.exceptionsDropped, 0)
        var blocks = 0
        for list in plan.lists {
            XCTAssertLessThanOrEqual(list.rules.count, 6)
            XCTAssertEqual(list.rules.filter { $0.action.type == "ignore-previous-rules" }.count, 3,
                           "two exceptions plus the allowlist rule in every list")
            let last = try XCTUnwrap(list.rules.last)
            XCTAssertEqual(last.action.type, "ignore-previous-rules")
            XCTAssertEqual(last.trigger.ifDomain, ["*site.example"])
            blocks += list.rules.filter { $0.action.type == "block" }.count
        }
        XCTAssertEqual(blocks, 7, "splitting must not lose or truncate rules")
    }

    func testLargeListsAreSplitInsteadOfTruncatedAtFiftyThousand() {
        let lines = (0..<100_000).map { "||ad\($0).example^" }.joined(separator: "\n")
        let plan = SafariContentRuleTranslator.plan(translate(lines), allowlist: [])
        XCTAssertGreaterThanOrEqual(plan.lists.count, 3)
        XCTAssertTrue(plan.lists.allSatisfy { $0.rules.count <= SafariContentRuleTranslator.maximumRulesPerList })
        XCTAssertEqual(plan.lists.reduce(0) { $0 + $1.rules.count }, 100_000)
    }

    func testAllowlistRuleCancelsEarlierRulesOnThoseSitesOnly() throws {
        let rule = try XCTUnwrap(SafariContentRuleTranslator.allowlistRule(for: ["b.example", "a.example", "bad host"]))
        XCTAssertEqual(rule.trigger.ifDomain, ["*a.example", "*b.example"])
        XCTAssertEqual(rule.action.type, "ignore-previous-rules")
        XCTAssertNil(SafariContentRuleTranslator.allowlistRule(for: []))
    }

    func testNothingToBlockProducesNoLists() {
        let plan = SafariContentRuleTranslator.plan(translate("! only a comment\n"), allowlist: ["site.example"])
        XCTAssertTrue(plan.lists.isEmpty)
    }

    func testEncodedRulesCarryWebKitsKeyNames() throws {
        let rule = try single(translate("||x.example^$third-party,script,domain=a.example,match-case\n").blocks)
        let object = try XCTUnwrap(jsonObjects([rule]).first)
        let trigger = try XCTUnwrap(object["trigger"] as? [String: Any])
        XCTAssertNotNil(trigger["url-filter"])
        XCTAssertEqual(trigger["url-filter-is-case-sensitive"] as? Bool, true)
        XCTAssertEqual(trigger["resource-type"] as? [String], ["script"])
        XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*a.example"])
        XCTAssertNil(trigger["unless-domain"])
        XCTAssertEqual((object["action"] as? [String: Any])?["type"] as? String, "block")
    }

    func testDomainNamesWebKitCannotHoldAreRejected() {
        XCTAssertEqual(SafariContentRuleTranslator.webKitDomain("Example.COM"), "*example.com")
        XCTAssertNil(SafariContentRuleTranslator.webKitDomain("google.*"))
        XCTAssertNil(SafariContentRuleTranslator.webKitDomain("b\u{fc}cher.example"))
        XCTAssertNil(SafariContentRuleTranslator.webKitDomain(".example.com"))
        XCTAssertNil(SafariContentRuleTranslator.webKitDomain("/regex/"))
    }
}

// MARK: - Real WebKit

@MainActor
final class ContentBlockingWebKitLiveTests: XCTestCase {

    private struct Outcome {
        var loaded: Set<String>
        var failed: Set<String>
    }

    // The page is served from 127.0.0.1; "localhost" is a different host, so its scripts are third-party.
    private static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>cb</title>
    <script>
    window.__loaded = []; window.__failed = [];
    function add(name, host, path) {
      var s = document.createElement('script');
      s.src = 'http://' + host + ':' + location.port + path;
      s.onload = function () { window.__loaded.push(name); };
      s.onerror = function () { window.__failed.push(name); };
      document.head.appendChild(s);
    }
    add('tp', 'localhost', '/tp.js');
    add('fp', '127.0.0.1', '/fp.js');
    add('allowed', 'localhost', '/allowed.js');
    add('scoped-out', 'localhost', '/scoped-out.js');
    add('scoped-in', 'localhost', '/scoped-in.js');
    </script></head><body></body></html>
    """

    private func makeServer() throws -> LiveHTTPTestServer {
        let headers = ["Cache-Control": "no-store"]
        var routes: [String: LiveHTTPTestServer.Route] = [
            "/page": .init(contentType: "text/html; charset=utf-8", body: Self.pageHTML, extraHeaders: headers),
        ]
        for name in ["tp", "fp", "allowed", "scoped-out", "scoped-in"] {
            routes["/\(name).js"] = .init(contentType: "text/javascript", body: "/* \(name) */", extraHeaders: headers)
        }
        return try LiveHTTPTestServer(routes: routes)
    }

    private func makeBlocker(_ rules: String, allowlist: Set<String> = []) -> ContentBlocker {
        var set = ContentBlockerRuleSet()
        set.add(listText: rules, listID: "Live")
        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.setAllowlist(allowlist)
        blocker.isEnabled = true
        return blocker
    }

    private func visit(_ contents: WebKitWebContents, _ server: LiveHTTPTestServer) async throws -> Outcome {
        contents.load(server.baseURL.appendingPathComponent("page"))
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        let json = try await contents.evaluateJavaScript(
            "JSON.stringify({loaded: window.__loaded || [], failed: window.__failed || []})"
        ) as? String
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        return Outcome(loaded: Set(object["loaded"] ?? []), failed: Set(object["failed"] ?? []))
    }

    // Runs `body` against the shared engine, then removes this test's rule lists from it.
    private func live(
        _ rules: String,
        allowlist: Set<String> = [],
        _ body: @escaping (WebKitEngine, ContentBlocker, LiveHTTPTestServer) async throws -> Void
    ) throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let server = try self.makeServer()
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let blocker = self.makeBlocker(rules, allowlist: allowlist)
            await engine.applyContentBlocker(blocker, session: engine.defaultSession)
            var failure: Error?
            do {
                try await body(engine, blocker, server)
            } catch {
                failure = error
            }
            server.stop()
            await engine.applyContentBlocker(nil, session: engine.defaultSession)
            if let failure { throw failure }
        }
    }

    private func withTab(_ engine: WebKitEngine, _ body: (WebKitWebContents) async throws -> Void) async throws {
        let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        try await body(contents)
    }

    func testCapabilityIsAdvertisedOnlyWhenTheCountingCallbackExists() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            XCTAssertEqual(
                engine.capabilities.contains(.blockedRequestCounts),
                WebKitContentBlocking.canCountBlockedRequests
            )
            XCTAssertTrue(engine.capabilities.contains(.contentBlocking))
        }
    }

    func testThirdPartyScriptIsBlockedAndFirstPartyIsNot() throws {
        try live("||localhost^$third-party\n||127.0.0.1^$third-party\n") { engine, _, server in
            try await self.withTab(engine) { contents in
                let outcome = try await self.visit(contents, server)
                XCTAssertTrue(outcome.failed.contains("tp"), "the third-party script must be blocked")
                XCTAssertTrue(outcome.loaded.contains("fp"), "the first-party script must load")
                XCTAssertNil(server.requestLog.first(path: "/tp.js"), "a blocked request must never reach the network")
                XCTAssertNotNil(server.requestLog.first(path: "/fp.js"))
            }
        }
    }

    func testDomainOptionScopesTheBlock() throws {
        let rules = """
        ||localhost/scoped-out.js$script,domain=example.org
        ||localhost/scoped-in.js$script,domain=127.0.0.1
        ||localhost/tp.js$script,domain=~127.0.0.1
        """
        try live(rules) { engine, _, server in
            try await self.withTab(engine) { contents in
                let outcome = try await self.visit(contents, server)
                XCTAssertTrue(outcome.failed.contains("scoped-in"), "domain= naming this page must block")
                XCTAssertTrue(outcome.loaded.contains("scoped-out"), "domain= naming another site must not block")
                XCTAssertTrue(outcome.loaded.contains("tp"), "a ~domain exclusion for this page must not block")
            }
        }
    }

    func testExceptionRuleLetsOneResourceThrough() throws {
        try live("||localhost^$script\n@@||localhost/allowed.js\n") { engine, _, server in
            try await self.withTab(engine) { contents in
                let outcome = try await self.visit(contents, server)
                XCTAssertTrue(outcome.loaded.contains("allowed"))
                XCTAssertTrue(outcome.failed.contains("tp"))
            }
        }
    }

    func testAllowlistedSiteLoadsTheResourceAndRemovingItBlocksAgainWithoutRelaunch() throws {
        try live("||localhost^$script\n", allowlist: ["127.0.0.1"]) { engine, blocker, server in
            try await self.withTab(engine) { contents in
                let allowed = try await self.visit(contents, server)
                XCTAssertTrue(allowed.loaded.contains("tp"), "the allowlisted site must not be blocked")

                blocker.setAllowlist([])
                await engine.applyContentBlocker(blocker, session: engine.defaultSession)
                let blocked = try await self.visit(contents, server)
                XCTAssertTrue(blocked.failed.contains("tp"), "leaving the allowlist must re-enable blocking in the open tab")

                blocker.setAllowlist(["127.0.0.1"])
                await engine.applyContentBlocker(blocker, session: engine.defaultSession)
                let again = try await self.visit(contents, server)
                XCTAssertTrue(again.loaded.contains("tp"))
            }
        }
    }

    func testTurningBlockingOffAndOnAppliesToAnOpenTab() throws {
        try live("||localhost^$script\n") { engine, blocker, server in
            try await self.withTab(engine) { contents in
                let first = try await self.visit(contents, server)
                XCTAssertTrue(first.failed.contains("tp"))

                blocker.isEnabled = false
                await engine.applyContentBlocker(blocker, session: engine.defaultSession)
                XCTAssertEqual(engine.contentBlocking.installedListCount, 0)
                let off = try await self.visit(contents, server)
                XCTAssertTrue(off.loaded.contains("tp"), "disabled blocking must load everything")

                blocker.isEnabled = true
                await engine.applyContentBlocker(blocker, session: engine.defaultSession)
                let on = try await self.visit(contents, server)
                XCTAssertTrue(on.failed.contains("tp"))

                await engine.applyContentBlocker(nil, session: engine.defaultSession)
                let removed = try await self.visit(contents, server)
                XCTAssertTrue(removed.loaded.contains("tp"), "a nil blocker removes the lists")
            }
        }
    }

    func testTabOpenedAfterTheListsCompiledIsBlocked() throws {
        try live("||localhost^$script\n") { engine, _, server in
            XCTAssertGreaterThan(engine.contentBlocking.installedListCount, 0)
            try await self.withTab(engine) { contents in
                let outcome = try await self.visit(contents, server)
                XCTAssertTrue(outcome.failed.contains("tp"))
            }
        }
    }

    func testOneInvalidRuleDoesNotDisableTheRestOfTheList() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("orbit-cb-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
            let coordinator = WebKitContentBlocking(store: store)

            func rule(_ filter: String) -> SafariRule {
                SafariRule(trigger: SafariRule.Trigger(urlFilter: filter), action: .block)
            }
            let rules = [rule("good-one\\.example"), rule("bad|alternation"), rule("good-two\\.example")]
            let plan = SafariRuleListPlan(kind: .network, index: 0, rules: rules)
            var report = ContentBlockingEngineReport()
            let list = await coordinator.compileResilient(
                batch: plan,
                json: SafariContentRuleTranslator.json(rules),
                identifier: "orbit-cb-test-\(UUID().uuidString)",
                report: &report
            )
            XCTAssertNotNil(list, "the valid rules must still compile")
            XCTAssertEqual(report.rulesDroppedAtCompile, 1)
            XCTAssertTrue(report.messages.contains { $0.contains("bad|alternation") }, "the dropped rule must be reported")
        }
    }

    func testBlockedSubresourcesAreCounted() throws {
        let canCount = WebKitContentBlocking.canCountBlockedRequests
        try live("||localhost^$script\n") { engine, blocker, server in
            blocker.resetCounters()
            try await self.withTab(engine) { contents in
                _ = try await self.visit(contents, server)
                guard canCount else {
                    XCTAssertTrue(WebKitContentBlocking.countingCapability.isEmpty, "an engine that cannot count must not advertise counting")
                    XCTAssertEqual(blocker.blockedRequestCount, 0, "counts appeared although this WebKit has no content rule action callback")
                    return
                }
                let deadline = ContinuousClock.now + .seconds(10)
                while blocker.blockedRequestCount == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertGreaterThan(blocker.blockedRequestCount, 0, "WebKit must report blocked subresources, not only the main document")
                XCTAssertGreaterThan(blocker.blockedRequestCount(forDocumentHost: "127.0.0.1"), 0)
            }
        }
    }

    func testRedirectStubLoadsWhenWebKitAcceptsItOtherwiseTheRequestIsBlocked() throws {
        try live("||localhost/tp.js$script,redirect=noopjs\n") { engine, _, server in
            let report = engine.contentBlocking.lastReport
            try await self.withTab(engine) { contents in
                let outcome = try await self.visit(contents, server)
                if report.redirectStubs > 0 {
                    XCTAssertTrue(outcome.loaded.contains("tp"), "the stub must stand in for the blocked script")
                } else {
                    XCTAssertEqual(report.redirectsBlockedInstead, 1)
                    XCTAssertTrue(outcome.failed.contains("tp"))
                }
            }
        }
    }

    func testEngineReportIsPublishedToTheBlocker() throws {
        try live("||localhost^$script\n##.ad\nsite.example##+js(abort-on-property-read, x)\n") { engine, blocker, _ in
            let report = blocker.engineReport
            XCTAssertEqual(report, engine.contentBlocking.lastReport)
            XCTAssertGreaterThan(report.networkRules, 0)
            XCTAssertGreaterThan(report.cosmeticRules, 0)
            XCTAssertEqual(report.failedRuleLists, 0)
            XCTAssertGreaterThan(report.ruleLists, 0)
            XCTAssertEqual(report.parserUnsupportedRules, 1)
        }
    }
}
