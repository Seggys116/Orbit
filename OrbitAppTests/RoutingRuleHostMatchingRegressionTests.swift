//  Regression guard: matchingRoutingRule used to do a raw substring test against the host,
//  so a short pattern could match a domain that merely contains it mid-label.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class RoutingRuleHostMatchingRegressionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func url(_ string: String) -> URL { URL(string: string)! }

    private var editor: AirTrafficControlEditor {
        AirTrafficControlEditor(
            rules: Binding(
                get: { self.env.state.routingRules },
                set: { self.env.state.routingRules = $0 }
            )
        )
    }

    private func firstSpaceID() -> SpaceID {
        if let id = env.spaces.first?.id { return id }
        return env.createSpace(
            name: "Test Space",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: env.createDefaultProfileIfNeeded()
        )
    }

    func test_aBarePatternFragment_mustNotMatchAHostThatMerelyContainsItMidLabel() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID()))
        defer { editor.remove(ruleID) }
        editor.pattern(for: ruleID).wrappedValue = "store"

        XCTAssertNil(env.matchingRoutingRule(for: url("https://chromewebstore.google.com/detail/x")))

        editor.pattern(for: ruleID).wrappedValue = "web"
        XCTAssertNil(env.matchingRoutingRule(for: url("https://chromewebstore.google.com/detail/x")))
    }

    // A user routing a whole domain must still catch every subdomain, including
    // chromewebstore.google.com — it really is one.
    func test_aWholeDomainPattern_stillMatchesTheDomainItselfAndEverySubdomain() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID()))
        defer { editor.remove(ruleID) }
        editor.pattern(for: ruleID).wrappedValue = "google.com"

        XCTAssertNotNil(env.matchingRoutingRule(for: url("https://google.com/search")))
        XCTAssertNotNil(env.matchingRoutingRule(for: url("https://meet.google.com/x")))
        XCTAssertNotNil(env.matchingRoutingRule(for: url("https://chromewebstore.google.com/detail/x")))
        XCTAssertNil(env.matchingRoutingRule(for: url("https://notgoogle.com/x")))
    }

    // LinksSettingsWiringTests's contains-mode test uses a pattern equal to the host, which
    // can't distinguish substring from suffix matching. This one actually exercises a subdomain.
    func test_containsMatchType_stillCatchesARealSubdomain() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID()))
        defer { editor.remove(ruleID) }
        editor.matchType(for: ruleID).wrappedValue = .contains
        editor.pattern(for: ruleID).wrappedValue = "nytimes.com"

        XCTAssertEqual(env.matchingRoutingRule(for: url("https://cooking.nytimes.com/recipes/1"))?.id, ruleID)
    }

    func test_matchingIsCaseInsensitive() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID()))
        defer { editor.remove(ruleID) }
        editor.pattern(for: ruleID).wrappedValue = "Google.com"

        XCTAssertNotNil(env.matchingRoutingRule(for: url("https://www.google.com/search")))
    }

    func test_hostMatchesRoutingPattern_directly() {
        XCTAssertTrue(AppEnvironment.hostMatchesRoutingPattern(host: "google.com", pattern: "google.com"))
        XCTAssertTrue(AppEnvironment.hostMatchesRoutingPattern(host: "meet.google.com", pattern: "google.com"))
        XCTAssertTrue(AppEnvironment.hostMatchesRoutingPattern(host: "chromewebstore.google.com", pattern: "google.com"))
        XCTAssertFalse(AppEnvironment.hostMatchesRoutingPattern(host: "chromewebstore.google.com", pattern: "store"))
        XCTAssertFalse(AppEnvironment.hostMatchesRoutingPattern(host: "chromewebstore.google.com", pattern: "web"))
        XCTAssertFalse(AppEnvironment.hostMatchesRoutingPattern(host: "notgoogle.com", pattern: "google.com"))
        XCTAssertFalse(AppEnvironment.hostMatchesRoutingPattern(host: "google.com", pattern: ""))
    }
}
