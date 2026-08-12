import XCTest

final class ContentBlockingRedirectTests: XCTestCase {

    // MARK: - Helpers

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

    private func redirectedResourceName(_ decision: ContentBlockingDecision) -> String? {
        guard case .redirect(_, _, let substitution) = decision else { return nil }
        switch substitution {
        case .resource(let resource): return resource.name
        case .empty: return "empty"
        }
    }

    // MARK: - 1. Parsing

    func testRedirectCompilesIntoARuleThatSubstitutesRatherThanBlocks() {
        let set = makeRuleSet("||cdn.example/ads.js$script,redirect=noopjs\n")
        XCTAssertEqual(set.stats.redirectRules, 1)
        XCTAssertEqual(set.stats.unsupportedRules, 0, "$redirect= is supported syntax and must not be counted as dropped")
        XCTAssertEqual(set.networkRuleCount, 1)

        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true
        let decision = blocker.decision(
            forURL: "https://cdn.example/ads.js",
            documentURL: "https://news.example/story",
            resourceType: .script
        )
        XCTAssertEqual(redirectedResourceName(decision), "noop.js",
                       "$redirect=noopjs must resolve through uBO's alias table to noop.js, got \(decision)")
        XCTAssertFalse(decision.isBlocked,
                       "a substituted request must NOT be reported as cancelled — cancelling it is the detectable outcome this exists to avoid")
        XCTAssertTrue(decision.preventedOriginalResponse,
                      "the site's own bytes never arrived, so this still counts as a refused request")
        XCTAssertEqual(blocker.blockedRequestCount, 1)
    }

    func testRedirectRuleDoesNotBlockOnItsOwn() {
        let blocker = makeBlocker("*$script,domain=aranzulla.it,redirect-rule=noopjs\n")
        let decision = blocker.decision(
            forURL: "https://cdn.example/tracker.js",
            documentURL: "https://aranzulla.it/page",
            resourceType: .script
        )
        XCTAssertEqual(decision, .allow,
                       "$redirect-rule= must never block by itself; nothing else here blocks this request")
        XCTAssertEqual(blocker.blockedRequestCount, 0)
    }

    func testRedirectRuleAppliesOnlyOnceSomethingElseBlocks() {
        let blocker = makeBlocker("""
        ||cdn.example/tracker.js
        *$script,domain=aranzulla.it,redirect-rule=noopjs
        """)

        let onAranzulla = blocker.decision(
            forURL: "https://cdn.example/tracker.js",
            documentURL: "https://aranzulla.it/page",
            resourceType: .script
        )
        XCTAssertEqual(redirectedResourceName(onAranzulla), "noop.js", "got \(onAranzulla)")

        let elsewhere = blocker.decision(
            forURL: "https://cdn.example/tracker.js",
            documentURL: "https://other.example/page",
            resourceType: .script
        )
        XCTAssertTrue(elsewhere.isBlocked, "got \(elsewhere)")
        XCTAssertNil(redirectedResourceName(elsewhere))
    }

    func testRedirectHonoursTheOtherOptionsOnTheSameRule() {
        let blocker = makeBlocker(
            "||doubleclick.net/instream/ad_status.js^$script,xhr,redirect=doubleclick_instream_ad_status.js:5\n"
        )
        let url = "https://static.doubleclick.net/instream/ad_status.js"

        for type in [ContentBlockingResourceType.script, .xmlhttprequest] {
            let decision = blocker.decision(forURL: url, documentURL: "https://www.youtube.com/watch?v=x", resourceType: type)
            XCTAssertEqual(redirectedResourceName(decision), "doubleclick_instream_ad_status.js",
                           "\(type) must be substituted, got \(decision)")
        }
        XCTAssertEqual(
            blocker.decision(forURL: url, documentURL: "https://www.youtube.com/watch?v=x", resourceType: .image),
            .allow,
            "the type constraint on a $redirect= rule must be honoured like any other"
        )

        let scoped = makeBlocker("||cdn.example/ads.js$script,redirect=noopjs,domain=news.example\n")
        XCTAssertEqual(
            redirectedResourceName(scoped.decision(
                forURL: "https://cdn.example/ads.js",
                documentURL: "https://news.example/story",
                resourceType: .script
            )),
            "noop.js"
        )
        XCTAssertEqual(
            scoped.decision(
                forURL: "https://cdn.example/ads.js",
                documentURL: "https://other.example/story",
                resourceType: .script
            ),
            .allow,
            "$domain= must confine a $redirect= rule to the documents it names"
        )
    }

    func testUnknownRedirectTokenDropsTheWholeRuleRatherThanBlocking() {
        let set = makeRuleSet("""
        ||cdn.example/ads.js$script,redirect=not-a-real-resource.js
        ||cdn.example/other.js$script,redirect=click2load.html
        ||fine.example/y.js$script
        """)
        XCTAssertEqual(set.stats.unsupportedRules, 2,
                       "both an invented token and a resource Orbit deliberately does not carry must be dropped and counted")
        XCTAssertEqual(set.stats.redirectRules, 0)
        XCTAssertEqual(set.stats.blockingRules, 1)

        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true
        XCTAssertEqual(
            blocker.decision(forURL: "https://cdn.example/ads.js", documentURL: "https://a.example/", resourceType: .script),
            .allow,
            "a $redirect= rule Orbit cannot serve must block NOTHING"
        )
        XCTAssertEqual(
            blocker.decision(forURL: "https://cdn.example/other.js", documentURL: "https://a.example/", resourceType: .script),
            .allow
        )
        XCTAssertTrue(blocker.decision(
            forURL: "https://fine.example/y.js", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "the ordinary rule beside them is unaffected")
    }

    func testHighestPriorityRedirectWinsAndNoneCancelsSubstitution() {
        let blocker = makeBlocker("""
        ||cdn.example/ads.js$script,redirect=noopjs
        ||cdn.example/ads.js$script,redirect=1x1.gif:10
        """)
        XCTAssertEqual(
            redirectedResourceName(blocker.decision(
                forURL: "https://cdn.example/ads.js", documentURL: "https://a.example/", resourceType: .script
            )),
            "1x1.gif",
            "uBO's `:N` suffix is a priority and the highest must win"
        )

        let cancelled = makeBlocker("""
        ||cdn.example/ads.js$script,redirect=noopjs
        .js|$script,redirect-rule=none:10,domain=a.example
        """)
        let decision = cancelled.decision(
            forURL: "https://cdn.example/ads.js", documentURL: "https://a.example/", resourceType: .script
        )
        XCTAssertTrue(decision.isBlocked, "a winning `none` leaves the block standing, got \(decision)")
        XCTAssertNil(redirectedResourceName(decision))
    }

    func testRedirectExceptionSuppressesSubstitutionWithoutExemptingTheBlock() {
        let blocker = makeBlocker("""
        ||g.doubleclick.net/tag/js/gpt.js$script,redirect=noopjs
        @@||g.doubleclick.net/tag/js/gpt.js$script,redirect-rule,domain=pomponik.pl
        """)
        let url = "https://g.doubleclick.net/tag/js/gpt.js"

        let onPomponik = blocker.decision(forURL: url, documentURL: "https://pomponik.pl/x", resourceType: .script)
        XCTAssertTrue(onPomponik.isBlocked, "the exception cancels the stub, not the block; got \(onPomponik)")
        XCTAssertNil(redirectedResourceName(onPomponik))

        let elsewhere = blocker.decision(forURL: url, documentURL: "https://other.example/x", resourceType: .script)
        XCTAssertEqual(redirectedResourceName(elsewhere), "noop.js", "got \(elsewhere)")
    }

    func testEmptyResourceIsAZeroLengthBodyTypedFromTheRequest() {
        let blocker = makeBlocker("||cdn.example/beacon$redirect=empty\n")
        let decision = blocker.decision(
            forURL: "https://cdn.example/beacon", documentURL: "https://a.example/", resourceType: .script
        )
        guard case .redirect(_, _, let substitution) = decision else {
            return XCTFail("Expected .redirect, got \(decision)")
        }
        XCTAssertEqual(substitution, .empty)

        let asScript = blocker.stubPayload(for: substitution, resourceType: .script)
        XCTAssertEqual(asScript.mimeType, "text/javascript")
        XCTAssertTrue(asScript.content.isEmpty)
        XCTAssertEqual(blocker.stubPayload(for: substitution, resourceType: .subdocument).mimeType, "text/html")
        XCTAssertEqual(blocker.stubPayload(for: substitution, resourceType: .xmlhttprequest).mimeType, "text/plain")
    }

    // MARK: - 1b. The un-block modifiers, parsed from real EasyList lines

    func testUnblockModifiersParseAndAreFiledApartFromOrdinaryExceptions() {
        let set = makeRuleSet("""
        @@||www.youtube.com^$generichide
        @@||music.youtube.com^$generichide
        @@||example.com^$elemhide
        @@||example.org^$specifichide
        @@||example.net^$genericblock
        """)
        XCTAssertEqual(set.stats.unblockRules, 5)
        XCTAssertEqual(set.stats.exceptionRules, 0,
                       "an un-block directive is NOT a request exception; filing it as one would exempt every request to the host from blocking")
        XCTAssertEqual(set.stats.unsupportedRules, 0)
        XCTAssertEqual(set.networkRuleCount, 5)

        var withBlock = ContentBlockerRuleSet()
        withBlock.add(listText: """
        ||static.doubleclick.net^
        @@||www.youtube.com^$generichide
        """, listID: "L")
        let blocker = ContentBlocker()
        blocker.setRuleSet(withBlock)
        blocker.isEnabled = true
        XCTAssertTrue(blocker.decision(
            forURL: "https://static.doubleclick.net/instream/ad_status.js",
            documentURL: "https://www.youtube.com/watch?v=x",
            resourceType: .script
        ).isBlocked, "$generichide must not have become a blanket allow for the host")
    }

    func testUnblockModifiersOnABlockingRuleAreRejected() {
        let set = makeRuleSet("||example.com^$generichide\n")
        XCTAssertEqual(set.stats.unsupportedRules, 1)
        XCTAssertEqual(set.stats.blockingRules, 0)
    }

    // MARK: - 2. Cosmetic filtering honours $generichide

    func testGenerichideRemovesEveryGenericSelectorAndKeepsHostSpecificOnes() {
        let set = makeRuleSet("""
        ###AC_ad
        ###AD_160
        ###AD_300
        youtube.com###shopping-timely-shelf
        @@||www.youtube.com^$generichide
        """)

        let onYouTube = set.cosmeticSelectors(forHost: "www.youtube.com")
        XCTAssertEqual(onYouTube, ["#shopping-timely-shelf"],
                       "generichide must remove the generic selectors and keep the host-scoped one")

        let onOther = set.cosmeticSelectors(forHost: "other.example")
        XCTAssertEqual(onOther.count, 3)
        XCTAssertEqual(Set(onOther), ["#AC_ad", "#AD_160", "#AD_300"])

        XCTAssertEqual(onOther.count - (onYouTube.count - 1), 3,
                       "every generic selector must be withheld from the excepted host")
    }

    func testElemhideRemovesEverythingAndSpecifichideRemovesOnlyHostRules() {
        let set = makeRuleSet("""
        ###AC_ad
        example.com###local-ad
        example.org###local-ad
        @@||example.com^$elemhide
        @@||example.org^$specifichide
        """)
        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.com"), [],
                       "$elemhide is the union of generichide and specifichide")
        XCTAssertEqual(set.cosmeticSelectors(forHost: "example.org"), ["#AC_ad"],
                       "$specifichide withholds the host-scoped rule and keeps the generic one")
        XCTAssertEqual(Set(set.cosmeticSelectors(forHost: "elsewhere.example")), ["#AC_ad"])
    }

    func testGenerichideIsScopedToTheHostItNames() {
        let set = makeRuleSet("""
        ###AC_ad
        @@||www.youtube.com^$generichide
        """)
        XCTAssertEqual(set.cosmeticSelectors(forHost: "www.youtube.com"), [])
        XCTAssertEqual(set.cosmeticSelectors(forHost: "music.youtube.com"), ["#AC_ad"],
                       "EasyList carries a SEPARATE @@||music.youtube.com^$generichide; one must not stand in for the other")
    }

    func testGenericblockSuppressesUnscopedBlockingRulesOnly() {
        let blocker = makeBlocker("""
        ||ads.example^
        ||tracker.example^$domain=protected.example
        @@||protected.example^$genericblock
        """)

        XCTAssertEqual(
            blocker.decision(forURL: "https://ads.example/x.js", documentURL: "https://protected.example/", resourceType: .script),
            .allow,
            "$genericblock must suppress a rule with no $domain= scope"
        )
        XCTAssertTrue(blocker.decision(
            forURL: "https://tracker.example/x.js", documentURL: "https://protected.example/", resourceType: .script
        ).isBlocked, "a $domain=-scoped rule is not generic and must still fire")
        XCTAssertTrue(blocker.decision(
            forURL: "https://ads.example/x.js", documentURL: "https://other.example/", resourceType: .script
        ).isBlocked, "$genericblock is scoped to the document it names")
    }

    // MARK: - 3. The real YouTube endpoints

    private static let youTubeRules = """
    ||static.doubleclick.net^
    ||youtube.com/pagead/
    ||youtube.com/youtubei/v1/player/ad_break
    ||www.youtube.com/get_midroll_$domain=youtube.com
    ||youtube.com/api/stats/ads?
    ||youtube.com/ptracking?html5=1&video_id=*&cpn=*&ei=*&ptk=youtube_*&pltype=content
    @@||static.doubleclick.net/instream/ad_status.js$script,domain=ignboards.com
    @@||www.youtube.com^$generichide
    ||doubleclick.net/instream/ad_status.js^$script,xhr,redirect=doubleclick_instream_ad_status.js:5
    """

    func testDoubleclickAdStatusProbeIsSubstitutedRatherThanCancelled() {
        let blocker = makeBlocker(Self.youTubeRules)
        let page = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let probe = "https://static.doubleclick.net/instream/ad_status.js"

        for type in [ContentBlockingResourceType.script, .xmlhttprequest] {
            let decision = blocker.decision(forURL: probe, documentURL: page, resourceType: type)
            XCTAssertEqual(
                redirectedResourceName(decision),
                "doubleclick_instream_ad_status.js",
                """
                The probe YouTube uses to detect a blocker must be ANSWERED, not cancelled (\(type)). \
                Got \(decision). A cancelled probe is what makes the player show \
                "Something went wrong. Refresh or try again later."
                """
            )
            XCTAssertFalse(decision.isBlocked)
        }

        guard case .redirect(_, _, let substitution) = blocker.decision(forURL: probe, documentURL: page, resourceType: .script),
              case .resource(let resource) = substitution else {
            return XCTFail("Expected a resource substitution")
        }
        XCTAssertEqual(String(decoding: resource.content, as: UTF8.self), "window.google_ad_status = 1;\n")
        XCTAssertEqual(resource.mimeType, "text/javascript")
    }

    func testEveryPlaybackEndpointStillLoads() {
        let blocker = makeBlocker(Self.youTubeRules)
        let page = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        let playback: [(String, ContentBlockingResourceType)] = [
            ("https://www.youtube.com/youtubei/v1/player?key=abc", .xmlhttprequest),
            ("https://www.youtube.com/youtubei/v1/next?key=abc", .xmlhttprequest),
            ("https://rr3---sn-4g5e6nsz.googlevideo.com/videoplayback?expire=1&itag=137", .media),
            ("https://www.youtube.com/s/player/abcd1234/player_ias.vflset/en_US/base.js", .script),
            ("https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg", .image),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .document),
        ]
        for (url, type) in playback {
            let decision = blocker.decision(forURL: url, documentURL: page, resourceType: type)
            XCTAssertEqual(decision, .allow,
                           "playback endpoint \(url) must load untouched; got \(decision)")
        }
    }

    func testTheAdAndTelemetryEndpointsBesideThemAreStillBlocked() {
        let blocker = makeBlocker(Self.youTubeRules)
        let page = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        let blocked: [(String, ContentBlockingResourceType)] = [
            ("https://www.youtube.com/pagead/interaction/?ai=x", .xmlhttprequest),
            ("https://www.youtube.com/youtubei/v1/player/ad_break?key=abc", .xmlhttprequest),
            ("https://www.youtube.com/api/stats/ads?ns=yt&ver=2", .ping),
        ]
        for (url, type) in blocked {
            XCTAssertTrue(
                blocker.decision(forURL: url, documentURL: page, resourceType: type).isBlocked,
                "\(url) must still be blocked"
            )
        }
    }

    func testYouTubeGetsNoGenericCosmeticSelectors() {
        var set = ContentBlockerRuleSet()
        set.add(listText: Self.youTubeRules + "\n###AC_ad\n###AD_160\nyoutube.com###shopping-timely-shelf\n", listID: "L")
        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true

        let css = blocker.cosmeticStyleSheet(forDocumentURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertFalse(css.contains("#AC_ad"), "EasyList's own @@||www.youtube.com^$generichide says not to")
        XCTAssertFalse(css.contains("#AD_160"))
        XCTAssertTrue(css.contains("#shopping-timely-shelf"), "host-scoped selectors still apply")
    }

    // MARK: - 4. The bundled resources are present and non-empty

    func testEveryBundledStubResourceIsPresentAndNonEmpty() {
        let resources = RedirectResourceLibrary.allResources
        XCTAssertEqual(resources.count, 44,
                       "the bundled set is uBO's web-accessible resources minus click2load.html and empty; see RedirectResourceData.swift")

        var names = Set<String>()
        for resource in resources {
            XCTAssertFalse(resource.content.isEmpty,
                           "\(resource.name) decoded to zero bytes — its base64 literal is corrupt or missing")
            XCTAssertFalse(resource.mimeType.isEmpty, "\(resource.name) has no MIME type")
            XCTAssertTrue(names.insert(resource.name).inserted, "\(resource.name) is bundled twice")
        }
    }

    func testTheResourcesTheShippingListsNameResolveToUBOsRealContent() {
        let expected: [(token: String, name: String, mime: String, body: String)] = [
            ("noopjs", "noop.js", "text/javascript", "(function() {\n    'use strict';\n})();\n"),
            ("nooptext", "noop.txt", "text/plain", "\n"),
            ("doubleclick_instream_ad_status.js", "doubleclick_instream_ad_status.js", "text/javascript",
             "window.google_ad_status = 1;\n"),
            ("noopvmap-1.0", "noop-vmap1.xml", "text/xml",
             "<vmap:VMAP xmlns:vmap=\"http://www.iab.net/videosuite/vmap\" version=\"1.0\"></vmap:VMAP>\n"),
            ("noopframe", "noop.html", "text/html",
             "<!DOCTYPE html>\n<html>\n    <head><title></title></head>\n    <body></body>\n</html>\n"),
        ]
        for entry in expected {
            guard let resource = RedirectResourceLibrary.resource(named: entry.token) else {
                XCTFail("\(entry.token) does not resolve to any bundled resource")
                continue
            }
            XCTAssertEqual(resource.name, entry.name)
            XCTAssertEqual(resource.mimeType, entry.mime)
            XCTAssertEqual(String(decoding: resource.content, as: UTF8.self), entry.body,
                           "\(entry.token) is not uBO's content")
        }

        let gif = RedirectResourceLibrary.resource(named: "1x1.gif")
        XCTAssertEqual(gif?.content.count, 43)
        XCTAssertEqual(gif.map { Array($0.content.prefix(6)) }, Array("GIF89a".utf8))

        let png = RedirectResourceLibrary.resource(named: "32x32.png")
        XCTAssertEqual(png?.content.count, 83)
        XCTAssertEqual(png.map { Array($0.content.prefix(4)) }, [0x89, 0x50, 0x4E, 0x47])

        let mp4 = RedirectResourceLibrary.resource(named: "noopmp4-1s")
        XCTAssertEqual(mp4?.name, "noop-1s.mp4")
        XCTAssertEqual(mp4?.content.count, 3753)
        XCTAssertEqual(mp4?.mimeType, "video/mp4")

        let mp3 = RedirectResourceLibrary.resource(named: "noopmp3-0.1s")
        XCTAssertEqual(mp3?.name, "noop-0.1s.mp3")
        XCTAssertEqual(mp3?.content.count, 813)

        let ima = RedirectResourceLibrary.resource(named: "google-ima.js")
        XCTAssertEqual(ima?.content.count, 14911, "google-ima.js is the largest stub and the easiest to truncate")
    }

    func testEveryRedirectTokenTheShippingListsUseResolves() {
        let tokensInUse = [
            "noopjs", "noopjs:10", "noop.js", "noop.js:10", "nooptext", "nooptext:-1", "noop.txt",
            "noopjson", "noopframe", "noop.html", "noop.css", "1x1.gif", "2x2.png", "32x32.png",
            "noopmp3-0.1s", "noop-0.1s.mp3", "noopmp4-1s", "noop-1s.mp4", "noop-1s.mp4:10",
            "noopvast-3.0", "noopvmap-1.0", "empty", "none:10",
            "google-ima.js", "google-ima.js:5", "google-ima.js:10",
            "googlesyndication_adsbygoogle.js", "googletagmanager_gtm.js", "googletagmanager_gtm.js:10",
            "google-analytics_analytics.js", "chartbeat.js", "fingerprint2.js", "prebid-ads.js",
            "nobab2.js:10", "fuckadblock.js-3.2.0:5", "popads.net.js", "hd-main.js", "amazon_apstag.js",
            "doubleclick_instream_ad_status.js:5",
        ]
        for token in tokensInUse {
            let bare = token.split(separator: ":").count > 1 && Int(token.split(separator: ":").last!) != nil
                ? String(token[token.startIndex..<token.lastIndex(of: ":")!])
                : token
            XCTAssertTrue(
                RedirectResourceLibrary.isKnownToken(bare),
                "\(bare) is named by a list Orbit ships but resolves to nothing, so every rule using it is dropped"
            )
        }
    }

    // MARK: - Catalogue and migration

    func testUBlockOriginFiltersAreEnabledByDefault() {
        XCTAssertEqual(FilterListCatalog.defaultEnabledIDs,
                       ["EasyList", "EasyPrivacy", "uBlock", FilterListCatalog.orbitUnbreakID])
        XCTAssertTrue(FilterListCatalog.descriptor(id: "uBlock")?.isDefaultEnabled == true)
    }
}

// MARK: - Migration

@MainActor
final class ContentBlockingUBlockListMigrationTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "OrbitTests.UBlockMigration.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testAnExistingProfileGetsTheUBlockListOnceAndOnlyOnce() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(["EasyList", "EasyPrivacy"], forKey: "contentBlocking.enabledLists")

        let expected = ["EasyList", "EasyPrivacy", "uBlock", FilterListCatalog.orbitUnbreakID]
        let migrated = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(migrated.enabledListIDs, Set(expected),
                       "an existing selection must gain the countermeasure list")
        XCTAssertEqual(defaults.stringArray(forKey: "contentBlocking.enabledLists"),
                       expected.sorted(),
                       "and the change must be persisted, not only held in memory")

        defaults.set(["EasyList", "EasyPrivacy"], forKey: "contentBlocking.enabledLists")
        let reopened = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(reopened.enabledListIDs, ["EasyList", "EasyPrivacy"],
                       "the migration is one-shot; re-adding a list the user removed would be a bug that never stops happening")
    }

    func testAFreshProfileTakesTheCatalogueDefaultsWithoutMigrating() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let controller = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(controller.enabledListIDs, FilterListCatalog.defaultEnabledIDs)
        XCTAssertNil(defaults.stringArray(forKey: "contentBlocking.enabledLists"),
                     "a profile that has never chosen must not be given a persisted selection it did not make")
    }

    func testAProfileThatAlreadyHadTheListIsLeftAlone() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let existing = ["EasyList", "uBlock", FilterListCatalog.orbitUnbreakID]
        defaults.set(existing, forKey: "contentBlocking.enabledLists")
        let controller = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(controller.enabledListIDs, Set(existing))
        XCTAssertEqual(defaults.stringArray(forKey: "contentBlocking.enabledLists"), existing,
                       "nothing to add, so nothing to rewrite — EasyPrivacy must not reappear either")
    }

    func testAnExistingProfileGetsTheUnbreakListOnceAndOnlyOnce() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(["EasyList", "uBlock"], forKey: "contentBlocking.enabledLists")

        let migrated = ContentBlockingController(defaults: defaults)
        XCTAssertTrue(migrated.enabledListIDs.contains(FilterListCatalog.orbitUnbreakID),
                      "a profile that predates the unbreak list must still get the site fixes")

        defaults.set(["EasyList", "uBlock"], forKey: "contentBlocking.enabledLists")
        let reopened = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(reopened.enabledListIDs, ["EasyList", "uBlock"],
                       "one-shot: a user who turned the list off must not have it turned back on")
    }
}
