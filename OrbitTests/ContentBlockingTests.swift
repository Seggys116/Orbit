import XCTest

final class ContentBlockingTests: XCTestCase {

    // MARK: - Fixtures

    private enum EasyListExcerpt {
        static let realRules = """
        [Adblock Plus 2.0]
        ! Version: 202606111618
        ! Title: EasyList
        ! Expires: 4 days (update frequency)
        ||adnxs.com^
        ||googlesyndication.com/pagead/
        ||googlesyndication.com^$domain=blogto.com|youtube.com
        ||scorecardresearch.com^$third-party
        -ads-manager/$domain=~wordpress.org
        /adsense/$script
        ||example-cdn.com/banner.gif|
        @@||allowed.example.com/ads/tracker.js
        ##.advertisement
        example.com##.sponsored-post
        example.com#@#.advertisement
        ~excluded.example.com##.generic-ad
        """
    }

    private func makeRuleSet(_ text: String, listID: String = "TestList") -> ContentBlockerRuleSet {
        var set = ContentBlockerRuleSet()
        set.add(listText: text, listID: listID)
        return set
    }

    private func makeBlocker(_ text: String) -> ContentBlocker {
        let blocker = ContentBlocker()
        blocker.setRuleSet(makeRuleSet(text))
        blocker.isEnabled = true
        return blocker
    }

    // MARK: - The headline requirement: a known ad URL is actually blocked

    func testKnownAdServingURLIsBlocked() {
        let blocker = makeBlocker(EasyListExcerpt.realRules)

        let decision = blocker.decision(
            forURL: "https://ib.adnxs.com/ut/v3/prebid",
            documentURL: "https://www.publisher-site.example/article",
            resourceType: .xmlhttprequest
        )
        XCTAssertTrue(decision.isBlocked, "||adnxs.com^ must block a request to ib.adnxs.com")
        guard case .block(let rule, let listID) = decision else {
            return XCTFail("Expected .block, got \(decision)")
        }
        XCTAssertEqual(rule, "||adnxs.com^")
        XCTAssertEqual(listID, "TestList")

        XCTAssertEqual(blocker.blockedRequestCount, 1)
    }

    func testNonAdRequestOnTheSamePageIsNotBlocked() {
        let blocker = makeBlocker(EasyListExcerpt.realRules)
        let decision = blocker.decision(
            forURL: "https://www.publisher-site.example/assets/app.js",
            documentURL: "https://www.publisher-site.example/article",
            resourceType: .script
        )
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(blocker.blockedRequestCount, 0, "Allowing a request must not increment the blocked count")
    }

    func testHostAnchorDoesNotMatchLookalikeDomains() {
        let blocker = makeBlocker("||adnxs.com^\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "bare domain must match")

        XCTAssertTrue(blocker.decision(
            forURL: "https://sub.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "subdomain must match")

        XCTAssertFalse(blocker.decision(
            forURL: "https://notadnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "notadnxs.com is a different domain and must NOT be blocked")

        XCTAssertFalse(blocker.decision(
            forURL: "https://adnxs.com.evil.example/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "adnxs.com.evil.example is a different domain and must NOT be blocked")
    }

    func testHostAnchorRequiresAHostBoundaryNotJustASubstringAnywhereInTheURL() {
        let blocker = makeBlocker("||ads.example^\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://ads.example/unit", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "control: the rule does fire at a real host boundary")

        XCTAssertFalse(blocker.decision(
            forURL: "https://tracker.example/redirect?to=ads.example/unit",
            documentURL: "https://a.example/",
            resourceType: .script
        ).isBlocked, "|| must anchor to the host, not match the domain inside a query string")

        XCTAssertFalse(blocker.decision(
            forURL: "https://tracker.example/ads.example/unit",
            documentURL: "https://a.example/",
            resourceType: .script
        ).isBlocked, "|| must anchor to the host, not match the domain inside a path")
    }

    // MARK: - Exceptions

    func testExceptionRuleExemptsAnOtherwiseBlockedRequest() {
        let text = """
        ||tracker.example^
        @@||tracker.example/allowed.js
        """
        let blocker = makeBlocker(text)

        XCTAssertTrue(blocker.decision(
            forURL: "https://tracker.example/beacon.js", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)

        let exempted = blocker.decision(
            forURL: "https://tracker.example/allowed.js", documentURL: "https://a.example/", resourceType: .script
        )
        XCTAssertFalse(exempted.isBlocked)
        guard case .exempted(let rule, _) = exempted else {
            return XCTFail("Expected .exempted, got \(exempted)")
        }
        XCTAssertEqual(rule, "@@||tracker.example/allowed.js")
    }

    func testImportantRuleBeatsAnException() {
        let text = """
        ||tracker.example^$important
        @@||tracker.example^
        """
        let blocker = makeBlocker(text)
        XCTAssertTrue(blocker.decision(
            forURL: "https://tracker.example/x.js", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "$important must survive an @@ exception")
    }

    // MARK: - Options

    func testThirdPartyOptionIsHonoured() {
        let blocker = makeBlocker("||scorecardresearch.com^$third-party\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://sb.scorecardresearch.com/beacon.js",
            documentURL: "https://news.example/story",
            resourceType: .script
        ).isBlocked, "third-party request must be blocked")

        XCTAssertFalse(blocker.decision(
            forURL: "https://sb.scorecardresearch.com/beacon.js",
            documentURL: "https://www.scorecardresearch.com/own-page",
            resourceType: .script
        ).isBlocked, "$third-party must not fire on a first-party request")
    }

    func testDomainOptionRestrictsWhereARuleApplies() {
        let blocker = makeBlocker("||googlesyndication.com^$domain=blogto.com|youtube.com\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://pagead2.googlesyndication.com/x",
            documentURL: "https://www.youtube.com/watch",
            resourceType: .script
        ).isBlocked, "$domain= lists youtube.com, and www.youtube.com is a subdomain of it")

        XCTAssertFalse(blocker.decision(
            forURL: "https://pagead2.googlesyndication.com/x",
            documentURL: "https://other.example/page",
            resourceType: .script
        ).isBlocked, "$domain= must confine the rule to the named documents")
    }

    func testNegatedDomainOptionIsHonoured() {
        let blocker = makeBlocker("-ads-manager/$domain=~wordpress.org\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://a.example/-ads-manager/x.js",
            documentURL: "https://a.example/page",
            resourceType: .script
        ).isBlocked)

        XCTAssertFalse(blocker.decision(
            forURL: "https://a.example/-ads-manager/x.js",
            documentURL: "https://wordpress.org/page",
            resourceType: .script
        ).isBlocked, "~wordpress.org must exclude wordpress.org documents")
    }

    func testResourceTypeOptionIsHonoured() {
        let blocker = makeBlocker("/adsense/$script\n")
        let url = "https://a.example/adsense/unit"

        XCTAssertTrue(blocker.decision(
            forURL: url, documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)

        XCTAssertFalse(blocker.decision(
            forURL: url, documentURL: "https://a.example/", resourceType: .image
        ).isBlocked, "$script must not block an image request")
    }

    // EasyList's /pagead/conversion.js$script (id 2810) has no domain option, so Orbit's
    // own blocker can answer CorpusUBlockOriginLiteLiveTests's negative control first.
    func testEasyListsGenericAdScriptRuleMatchesALoopbackOriginToo() {
        let blocker = makeBlocker("/pagead/conversion.js$script\n")
        let origin = "http://127.0.0.1:52341"

        XCTAssertTrue(blocker.decision(
            forURL: origin + "/pagead/conversion.js",
            documentURL: origin + "/",
            resourceType: .script
        ).isBlocked, "a generic EasyList rule has no domain condition, so a loopback origin is not exempt from it")

        XCTAssertFalse(blocker.decision(
            forURL: origin + "/orbit-control.js",
            documentURL: origin + "/",
            resourceType: .script
        ).isBlocked, "the corpus suite's control script must match nothing, or neither blocker's behaviour is measurable")
    }

    func testRightAnchorRequiresAnEndOfURLMatch() {
        let blocker = makeBlocker("||example-cdn.com/banner.gif|\n")

        XCTAssertTrue(blocker.decision(
            forURL: "https://example-cdn.com/banner.gif", documentURL: "https://a.example/", resourceType: .image
        ).isBlocked)

        XCTAssertFalse(blocker.decision(
            forURL: "https://example-cdn.com/banner.gif?v=2", documentURL: "https://a.example/", resourceType: .image
        ).isBlocked, "a trailing | anchors to the end of the address")
    }

    func testSeparatorMatchesEndOfAddress() {
        let blocker = makeBlocker("||ads.example^\n")
        XCTAssertTrue(blocker.decision(
            forURL: "https://ads.example", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "^ must also match the end of the address")
    }

    // MARK: - Unsupported syntax is dropped, not widened

    func testUnsupportedOptionsAreDroppedAndCounted() {
        let text = """
        ||cdn.example/script.js$redirect=noopjs
        ||other.example/x.js$csp=script-src 'none'
        ||fine.example/y.js$script
        """
        let set = makeRuleSet(text)
        XCTAssertEqual(set.stats.blockingRules, 1, "only the $script rule is a plain block")
        XCTAssertEqual(set.stats.redirectRules, 1)
        XCTAssertEqual(set.stats.unsupportedRules, 1, "only the $csp= rule is unrepresentable")

        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true
        XCTAssertFalse(blocker.decision(
            forURL: "https://cdn.example/script.js", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "a $redirect= rule must serve a stub, never cancel the request")
        XCTAssertEqual(blocker.decision(
            forURL: "https://other.example/x.js", documentURL: "https://a.example/", resourceType: .script
        ), .allow, "a dropped $csp= rule must block nothing")
        XCTAssertTrue(blocker.decision(
            forURL: "https://fine.example/y.js", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)
    }

    func testStatsCountWhatWasActuallyCompiled() {
        let set = makeRuleSet(EasyListExcerpt.realRules)
        XCTAssertEqual(set.stats.totalNetworkRules, set.networkRuleCount,
                       "the published rule count must equal what the parser reported compiling")
        XCTAssertEqual(set.stats.exceptionRules, 1)
        XCTAssertGreaterThan(set.stats.cosmeticRules, 0)
        XCTAssertEqual(set.stats.cosmeticExceptionRules, 1)
    }

    // MARK: - The token index must not lose rules

    func testTokenIndexAgreesWithExhaustiveMatching() {
        let rules = [
            "||adnxs.com^",
            "||googlesyndication.com/pagead/",
            "/adsense/$script",
            "-ads-manager/",
            "||example-cdn.com/banner.gif|",
            "banner_ad.",
            "||a.example^*/track?",
            "||b.example/px",
            "/pagead/js/adsbygoogle.js",
            "||metrics.example^",
        ]
        let urls = [
            "https://ib.adnxs.com/ut/v3/prebid",
            "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
            "https://site.example/adsense/unit.js",
            "https://site.example/-ads-manager/loader.js",
            "https://example-cdn.com/banner.gif",
            "https://site.example/img/banner_ad.png",
            "https://a.example/x/track?id=1",
            "https://b.example/px?u=2",
            "https://metrics.example/collect",
            "https://harmless.example/app.js",
            "https://notadnxs.com/x",
        ]

        var combined = ContentBlockerRuleSet()
        combined.add(listText: rules.joined(separator: "\n"), listID: "L")

        for url in urls {
            var expectedAny = false
            var expectedRule: String?
            for rule in rules {
                var single = ContentBlockerRuleSet()
                single.add(listText: rule, listID: "L")
                if single.decision(forURL: url, documentURL: "https://doc.example/", resourceType: .script).isBlocked {
                    expectedAny = true
                    if expectedRule == nil { expectedRule = rule }
                }
            }
            let actual = combined.decision(forURL: url, documentURL: "https://doc.example/", resourceType: .script)
            XCTAssertEqual(actual.isBlocked, expectedAny,
                           "combined rule set disagreed with per-rule matching for \(url) (expected rule: \(expectedRule ?? "none"))")
        }
    }

    func testTokenIsNeverChosenFromAnUndelimitedRun() {
        XCTAssertNil(
            FilterTokenizer.bestToken(forPattern: "ads*x", leftAnchored: false, rightAnchored: false).flatMap { token -> UInt64? in
                FilterTokenizer.tokens(forURLBytes: Array("https://a.example/ads".utf8)).contains(token) ? nil : token
            },
            "any token chosen must be one a matching URL can produce"
        )
        XCTAssertNotNil(FilterTokenizer.bestToken(forPattern: "/adsense/", leftAnchored: false, rightAnchored: false))
    }

    // MARK: - Per-site allowlist is real, not cosmetic

    func testAllowlistedSiteStopsBlockingAndUnAllowlistingRestoresIt() {
        let blocker = makeBlocker("||adnxs.com^\n")
        let adURL = "https://ib.adnxs.com/ut/v3/prebid"

        XCTAssertTrue(blocker.decision(
            forURL: adURL, documentURL: "https://news.example/story", resourceType: .script
        ).isBlocked)

        blocker.setAllowlist(["news.example"])
        let allowed = blocker.decision(
            forURL: adURL, documentURL: "https://news.example/story", resourceType: .script
        )
        XCTAssertFalse(allowed.isBlocked, "allowlisting the document host must stop blocking on it")
        XCTAssertEqual(allowed, .allowlistedSite(host: "news.example"))

        XCTAssertTrue(blocker.decision(
            forURL: adURL, documentURL: "https://other.example/story", resourceType: .script
        ).isBlocked, "allowlisting one site must not disable blocking everywhere")

        blocker.setAllowlist([])
        XCTAssertTrue(blocker.decision(
            forURL: adURL, documentURL: "https://news.example/story", resourceType: .script
        ).isBlocked, "removing the allowlist entry must restore blocking")
    }

    func testAllowlistCoversSubdomainsOfTheStoredHost() {
        let blocker = makeBlocker("||adnxs.com^\n")
        blocker.setAllowlist(["news.example"])
        XCTAssertFalse(blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://www.news.example/story", resourceType: .script
        ).isBlocked, "allowlisting news.example must cover www.news.example")
    }

    func testDisabledBlockerBlocksNothingAndSaysSo() {
        let blocker = makeBlocker("||adnxs.com^\n")
        blocker.isEnabled = false
        let decision = blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        )
        XCTAssertEqual(decision, .disabled, "'off' must be distinguishable from 'nothing matched'")
        XCTAssertEqual(blocker.blockedRequestCount, 0)
    }

    // MARK: - Cosmetic filtering

    func testCosmeticSelectorsAreScopedAndExcepted() {
        let blocker = makeBlocker(EasyListExcerpt.realRules)

        let onExample = blocker.cosmeticStyleSheet(forHost: "example.com")
        XCTAssertTrue(onExample.contains(".sponsored-post"), "domain-scoped rule must apply on its domain")
        XCTAssertFalse(onExample.contains(".advertisement"),
                       "example.com#@#.advertisement must remove the generic rule on this host")

        let onOther = blocker.cosmeticStyleSheet(forHost: "other.example")
        XCTAssertTrue(onOther.contains(".advertisement"), "generic rule applies elsewhere")
        XCTAssertFalse(onOther.contains(".sponsored-post"), "example.com rule must not leak to other hosts")

        let onExcluded = blocker.cosmeticStyleSheet(forHost: "excluded.example.com")
        XCTAssertFalse(onExcluded.contains(".generic-ad"), "~excluded.example.com must exclude that host")
        XCTAssertTrue(blocker.cosmeticStyleSheet(forHost: "elsewhere.example").contains(".generic-ad"))
    }

    func testCosmeticStyleSheetIsEmptyWhenBlockingIsOffOrSiteAllowlisted() {
        let blocker = makeBlocker(EasyListExcerpt.realRules)
        XCTAssertFalse(blocker.cosmeticStyleSheet(forHost: "other.example").isEmpty)

        blocker.setAllowlist(["other.example"])
        XCTAssertTrue(blocker.cosmeticStyleSheet(forHost: "other.example").isEmpty,
                      "element hiding must stop on an allowlisted site too")

        blocker.setAllowlist([])
        blocker.isEnabled = false
        XCTAssertTrue(blocker.cosmeticStyleSheet(forHost: "other.example").isEmpty)
    }

    func testProceduralAndScriptletCosmeticsAreRejected() {
        let set = makeRuleSet("""
        example.com##+js(set, x, true)
        example.com#?#div:has-text(Ad)
        example.com##.plain-selector
        """)
        XCTAssertEqual(set.stats.cosmeticRules, 1)
        XCTAssertEqual(set.stats.unsupportedRules, 2, "scriptlet and procedural rules must be dropped, not injected")
    }

    // MARK: - Filter list header parsing

    func testListHeaderVersionAndExpiryAreReadFromTheBytes() {
        let header = FilterListStore.parseHeader("""
        [Adblock Plus 2.0]
        ! Version: 202606111618
        ! Title: EasyList
        ! Expires: 4 days (update frequency)
        ||ads.example^
        """)
        XCTAssertEqual(header.version, "202606111618")
        XCTAssertEqual(header.title, "EasyList")
        XCTAssertEqual(header.expires, 4 * 86_400)
    }

    func testExpiresSupportsHours() {
        XCTAssertEqual(FilterListStore.parseExpires("12 hours"), 12 * 3600)
        XCTAssertEqual(FilterListStore.parseExpires("1 day"), 86_400)
        XCTAssertNil(FilterListStore.parseExpires("whenever"))
    }

    func testCacheEntryStalenessUsesTheListsOwnDeclaredExpiry() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        let entry = FilterListCacheEntry(
            listID: "EasyList",
            sourceURLs: [URL(string: "https://easylist.to/easylist/easylist.txt")!],
            declaredVersion: "1",
            declaredTitle: "EasyList",
            expiresAfter: 3600,
            fetchedAt: fetched,
            lastCheckedAt: fetched,
            etag: nil,
            lastModified: nil,
            byteCount: 10,
            contentHash: "abc"
        )
        XCTAssertFalse(entry.isStale(now: fetched.addingTimeInterval(3599)))
        XCTAssertTrue(entry.isStale(now: fetched.addingTimeInterval(3601)))
    }

    // MARK: - Catalogue

    func testCatalogueMatchesArcsGroupingAndCarriesLicences() {
        for category in FilterListCategory.allCases {
            XCTAssertFalse(FilterListCatalog.lists(in: category).isEmpty,
                           "no lists in \(category.rawValue)")
        }
        for descriptor in FilterListCatalog.all {
            XCTAssertFalse(descriptor.licence.isEmpty, "\(descriptor.id) has no licence recorded")
            XCTAssertTrue(!descriptor.urls.isEmpty || descriptor.isBundled,
                          "\(descriptor.id) has neither a source URL nor a bundled resource")
            for url in descriptor.urls {
                XCTAssertEqual(url.scheme, "https", "\(descriptor.id) must fetch over https")
            }
        }
        XCTAssertEqual(FilterListCatalog.defaultEnabledIDs,
                       ["EasyList", "EasyPrivacy", "uBlock", FilterListCatalog.orbitUnbreakID])
    }

    func testCategoryLabelsMatchArcsOwnWording() {
        XCTAssertEqual(FilterListCategory.generic.displayName, "Ad Blockers")
        XCTAssertEqual(FilterListCategory.privacy.displayName, "Trackers")
        XCTAssertEqual(FilterListCategory.cookies.displayName, "Cookie Banners")
        XCTAssertEqual(FilterListCategory.regional.displayName, "Regional Ad Blockers")

        XCTAssertEqual(FilterListCategory.generic.settingsRowTitle, "Block Ads")
        XCTAssertEqual(FilterListCategory.privacy.settingsRowTitle, "Block Trackers")
        XCTAssertEqual(FilterListCategory.cookies.settingsRowTitle, "Block Cookie Banners")
        XCTAssertNil(FilterListCategory.regional.settingsRowTitle,
                     "Arc's General pane has exactly three rows; regional lists live only in the dialog")

        XCTAssertEqual(FilterListCategory.cookies.settingsRowFootnote,
                       "Blocking cookie banners may cause pages to load incorrectly.")
        XCTAssertNil(FilterListCategory.generic.settingsRowFootnote)
        XCTAssertNil(FilterListCategory.privacy.settingsRowFootnote)
    }

    func testCatalogueListNamesAndOrderMatchArcsAdvancedDialog() {
        XCTAssertEqual(
            FilterListCatalog.lists(in: .generic).map(\.displayName),
            ["EasyList", "AdGuard - Ads", "uBlock Origin filters"]
        )
        XCTAssertEqual(
            FilterListCatalog.lists(in: .privacy).map(\.displayName),
            [
                "EasyPrivacy",
                "AdGuard Tracking Protection",
                "EasyList - Social Widgets",
                "AdGuard – Social Widgets",
                "Fanboy – Anti-Facebook",
            ]
        )
        XCTAssertEqual(
            FilterListCatalog.lists(in: .cookies).map(\.displayName),
            ["CookieMonster by Fanboy", "AdGuard – Cookie Notices"]
        )
    }

    func testCatalogueDoesNotUseArcsPrivateMirror() {
        for descriptor in FilterListCatalog.all {
            for url in descriptor.urls {
                XCTAssertFalse(url.absoluteString.contains("diabrowser.engineering"),
                               "\(descriptor.id) points at Arc's own CDN")
            }
        }
    }

    // MARK: - Engine capability honesty

    func testBlockingAndCountingAreSeparableCapabilities() {
        XCTAssertFalse(EngineCapabilities.contentBlocking.isEmpty)
        XCTAssertNotEqual(EngineCapabilities.contentBlocking.rawValue,
                          EngineCapabilities.blockedRequestCounts.rawValue,
                          "counting must be a separate capability from blocking")
        let both: EngineCapabilities = [.contentBlocking, .blockedRequestCounts]
        XCTAssertTrue(both.contains(.contentBlocking))
        XCTAssertTrue(both.contains(.blockedRequestCounts))
        let blockOnly: EngineCapabilities = [.contentBlocking]
        XCTAssertFalse(blockOnly.contains(.blockedRequestCounts),
                       "a backend that only blocks must not read as one that also counts")
    }

    // MARK: - Resource type mapping

    func testResourceTypeRawValuesAreStable() {
        XCTAssertEqual(ContentBlockingResourceType.document.rawValue, 0)
        XCTAssertEqual(ContentBlockingResourceType.subdocument.rawValue, 1)
        XCTAssertEqual(ContentBlockingResourceType.stylesheet.rawValue, 2)
        XCTAssertEqual(ContentBlockingResourceType.script.rawValue, 3)
        XCTAssertEqual(ContentBlockingResourceType.image.rawValue, 4)
        XCTAssertEqual(ContentBlockingResourceType.font.rawValue, 5)
        XCTAssertEqual(ContentBlockingResourceType.object.rawValue, 6)
        XCTAssertEqual(ContentBlockingResourceType.media.rawValue, 7)
        XCTAssertEqual(ContentBlockingResourceType.xmlhttprequest.rawValue, 8)
        XCTAssertEqual(ContentBlockingResourceType.ping.rawValue, 9)
        XCTAssertEqual(ContentBlockingResourceType.websocket.rawValue, 10)
        XCTAssertEqual(ContentBlockingResourceType.csp_report.rawValue, 11)
        XCTAssertEqual(ContentBlockingResourceType.other.rawValue, 12)
    }

    func testObjCEntryPointAgreesWithTheSwiftDecision() {
        let blocker = makeBlocker("||adnxs.com^\n")
        XCTAssertTrue(blocker.shouldBlock(
            url: "https://ib.adnxs.com/x",
            documentURL: "https://a.example/",
            resourceType: ContentBlockingResourceType.script.rawValue
        ))
        XCTAssertFalse(blocker.shouldBlock(
            url: "https://harmless.example/x",
            documentURL: "https://a.example/",
            resourceType: ContentBlockingResourceType.script.rawValue
        ))
        XCTAssertFalse(blocker.shouldBlock(
            url: "https://harmless.example/x", documentURL: "https://a.example/", resourceType: 999
        ))
    }

    // MARK: - Real-scale sanity

    func testMostRulesAreIndexedRatherThanScannedOnEveryRequest() {
        var lines: [String] = []
        for i in 0..<2000 {
            lines.append("||adserver\(i).example^")
            lines.append("/tracking\(i)/pixel.gif")
        }
        var set = ContentBlockerRuleSet()
        set.add(listText: lines.joined(separator: "\n"), listID: "L")

        XCTAssertEqual(set.networkRuleCount, 4000)
        XCTAssertLessThan(set.untokenizedRuleCount, set.networkRuleCount / 10,
                          "the token index must file the overwhelming majority of rules")

        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true
        XCTAssertTrue(blocker.decision(
            forURL: "https://adserver1999.example/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)
        XCTAssertTrue(blocker.decision(
            forURL: "https://a.example/tracking42/pixel.gif", documentURL: "https://a.example/", resourceType: .image
        ).isBlocked)
    }
}
