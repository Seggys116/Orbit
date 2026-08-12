import XCTest

final class ContentBlockingUnbreakListTests: XCTestCase {

    // MARK: - Fixtures

    // Verbatim from EasyPrivacy: line 2340 carries no domain= and no
    // $third-party, so it matches a site's own first-party origin too.
    private enum EasyPrivacyExcerpt {
        static let statsigRules = """
        [Adblock Plus 2.0]
        ! Title: EasyPrivacy
        /statsig-proxy/*
        ||statsig.com^$third-party
        ||statsigapi.net^$third-party
        """
    }

    private static var unbreakListURL: URL {
        let descriptor = FilterListCatalog.descriptor(id: FilterListCatalog.orbitUnbreakID)
        let resource = descriptor?.bundledResource
        return URL(fileURLWithPath: #filePath)     // OrbitTests/ContentBlockingUnbreakListTests.swift
            .deletingLastPathComponent()            // OrbitTests/
            .deletingLastPathComponent()            // repository root
            .appendingPathComponent("Orbit/Resources/ContentBlocking")
            .appendingPathComponent(resource?.name ?? "")
            .appendingPathExtension(resource?.fileExtension ?? "")
    }

    private func unbreakListText() throws -> String {
        try String(contentsOf: Self.unbreakListURL, encoding: .utf8)
    }

    private func makeRuleSet(withUnbreakList includeUnbreak: Bool) throws -> ContentBlockerRuleSet {
        var set = ContentBlockerRuleSet()
        set.add(listText: EasyPrivacyExcerpt.statsigRules, listID: "EasyPrivacy")
        if includeUnbreak {
            set.add(listText: try unbreakListText(), listID: FilterListCatalog.orbitUnbreakID)
        }
        return set
    }

    // MARK: - The list itself

    func testTheBundledListParsesWithoutErrorsIntoASingleExceptionRule() throws {
        var set = ContentBlockerRuleSet()
        set.add(listText: try unbreakListText(), listID: FilterListCatalog.orbitUnbreakID)

        XCTAssertEqual(set.stats.exceptionRules, 1)
        XCTAssertEqual(set.networkRuleCount, 1)
        XCTAssertEqual(set.stats.blockingRules, 0, "an unbreak list must never block anything")
        XCTAssertEqual(set.stats.cosmeticRules, 0)
        XCTAssertEqual(set.stats.unsupportedRules, 0,
                       "every rule in Orbit's own list must be one the engine actually honours")
        XCTAssertEqual(set.stats.invalidRegexRules, 0)
    }

    func testTheCatalogueShipsTheListInTheBundleAndEnablesItByDefault() throws {
        let descriptor = try XCTUnwrap(FilterListCatalog.descriptor(id: FilterListCatalog.orbitUnbreakID))

        XCTAssertTrue(descriptor.isBundled, "the unbreak list must not depend on a network fetch")
        XCTAssertEqual(descriptor.bundledResource?.name, "orbit-unbreak")
        XCTAssertEqual(descriptor.bundledResource?.fileExtension, "txt")
        XCTAssertTrue(descriptor.urls.isEmpty, "a bundled list has no remote source to go stale")
        XCTAssertEqual(descriptor.category, .compatibility)
        XCTAssertEqual(FilterListCategory.compatibility.displayName, "Site Fixes")
        XCTAssertNotNil(FilterListCategory.compatibility.settingsRowTitle,
                        "the list has to be visible and togglable wherever the other lists are")
        XCTAssertEqual(FilterListCatalog.lists(in: .compatibility).map(\.id),
                       [FilterListCatalog.orbitUnbreakID])
        XCTAssertTrue(descriptor.isDefaultEnabled)
        XCTAssertTrue(FilterListCatalog.defaultEnabledIDs.contains(FilterListCatalog.orbitUnbreakID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.unbreakListURL.path),
                      "the descriptor names \(Self.unbreakListURL.lastPathComponent), which is not on disk")
    }

    // MARK: - linear.app

    func testLinearsOwnStatsigProxyBootstrapIsBlockedWithoutTheListAndAllowedWithIt() throws {
        let withoutUnbreak = try makeRuleSet(withUnbreakList: false)
        let withUnbreak = try makeRuleSet(withUnbreakList: true)
        let document = "https://linear.app/orbit/inbox"

        for url in [
            "https://linear.app/statsig-proxy/v1/initialize",
            "https://linear.app/statsig-proxy/v1/rgstr",
        ] {
            let before = withoutUnbreak.decision(
                forURL: url, documentURL: document, resourceType: .xmlhttprequest
            )
            XCTAssertTrue(before.isBlocked,
                          "the bug being fixed is that EasyPrivacy blocks \(url); the fixture no longer reproduces it")

            let after = withUnbreak.decision(
                forURL: url, documentURL: document, resourceType: .xmlhttprequest
            )
            XCTAssertFalse(after.isBlocked, "\(url) must be allowed once the unbreak list is compiled in")
            guard case .exempted(let rule, let listID) = after else {
                return XCTFail("expected .exempted for \(url), got \(after)")
            }
            XCTAssertEqual(rule, "@@||linear.app/statsig-proxy/$first-party")
            XCTAssertEqual(listID, FilterListCatalog.orbitUnbreakID)
        }
    }

    // sendBeacon leaves as a ping, not an XHR, so the exception must not be type-scoped.
    func testTheExceptionCoversTheBeaconLegOfTheSameBootstrap() throws {
        let set = try makeRuleSet(withUnbreakList: true)
        let decision = set.decision(
            forURL: "https://linear.app/statsig-proxy/v1/rgstr",
            documentURL: "https://linear.app/orbit/inbox",
            resourceType: .ping
        )
        XCTAssertFalse(decision.isBlocked)
    }

    func testLinearsOrdinaryResourcesResolveExactlyAsBefore() throws {
        let withoutUnbreak = try makeRuleSet(withUnbreakList: false)
        let withUnbreak = try makeRuleSet(withUnbreakList: true)
        let document = "https://linear.app/orbit/inbox"

        for (url, type) in [
            ("https://linear.app/static/app.js", ContentBlockingResourceType.script),
            ("https://linear.app/api/graphql", .xmlhttprequest),
            ("https://linear.app/icon.png", .image),
        ] {
            XCTAssertFalse(withoutUnbreak.decision(forURL: url, documentURL: document, resourceType: type).isBlocked)
            let after = withUnbreak.decision(forURL: url, documentURL: document, resourceType: type)
            XCTAssertFalse(after.isBlocked)
            guard case .allow = after else {
                return XCTFail("\(url) was already allowed and must stay a plain .allow, got \(after)")
            }
        }
    }

    // MARK: - Negative controls

    func testStatsigStaysBlockedOnEveryOtherOriginAndForEveryThirdParty() throws {
        let set = try makeRuleSet(withUnbreakList: true)

        let stillBlocked: [(url: String, document: String, reason: String)] = [
            (
                "https://api.statsig.com/v1/initialize",
                "https://linear.app/orbit/inbox",
                "a third-party Statsig endpoint is not linear.app's own origin, even on linear.app"
            ),
            (
                "https://api.statsig.com/v1/rgstr",
                "https://linear.app/orbit/inbox",
                "the exception must not follow the SDK to Statsig's own hosts"
            ),
            (
                "https://someothersite.com/statsig-proxy/v1/initialize",
                "https://someothersite.com/dashboard",
                "the exception must be scoped to linear.app, not to the /statsig-proxy/ path"
            ),
            (
                "https://api.statsig.com/v1/initialize",
                "https://someothersite.com/dashboard",
                "unrelated sites must be untouched"
            ),
            (
                "https://evil.example/collect?next=linear.app/statsig-proxy/v1/initialize",
                "https://evil.example/",
                "linear.app appearing in a query string is not linear.app serving the request"
            ),
        ]

        for probe in stillBlocked {
            let decision = set.decision(
                forURL: probe.url, documentURL: probe.document, resourceType: .xmlhttprequest
            )
            XCTAssertTrue(decision.isBlocked, "\(probe.url) must stay blocked: \(probe.reason) — got \(decision)")
        }
    }

    // A page linear.app is embedded in is a different party; the exception is
    // for linear.app bootstrapping itself, nothing else.
    func testTheExceptionDoesNotApplyWhenLinearIsTheThirdParty() throws {
        let set = try makeRuleSet(withUnbreakList: true)
        let decision = set.decision(
            forURL: "https://linear.app/statsig-proxy/v1/initialize",
            documentURL: "https://someothersite.com/embed",
            resourceType: .xmlhttprequest
        )
        XCTAssertTrue(decision.isBlocked, "$first-party must keep the exception off cross-site requests, got \(decision)")
    }
}
