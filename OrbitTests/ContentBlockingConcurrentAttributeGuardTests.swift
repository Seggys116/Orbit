// @concurrent going missing from ContentBlockingController.buildRuleSet silently
// reintroduces main-actor filter-list parsing (SE-0461 runs on the caller's executor).

import XCTest

final class ContentBlockingConcurrentAttributeGuardTests: XCTestCase {

    private func controllerSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/Engine/ContentBlocking/ContentBlockingController.swift")
    }

    private static let functionsRequiringConcurrent = [
        "private nonisolated static func buildRuleSet(",
        "private nonisolated static func loadOrParseList(",
    ]

    func test_everyOffMainActorParseFunctionCarriesTheConcurrentAttribute() throws {
        let url = controllerSourceURL()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 50, "Walked \(lines.count) lines of \(url.path). That is far too few — the path resolution is wrong and this test would pass vacuously.")

        let missing = Self.functionsRequiringConcurrent.compactMap {
            Self.concurrentAttributeOffence(in: lines, forSignature: $0)
        }

        XCTAssertEqual(
            missing, [],
            """
            One or more functions that must run off the main actor are missing `@concurrent` \
            immediately above their declaration. Under SWIFT_APPROACHABLE_CONCURRENCY a bare \
            `nonisolated` function is `nonisolated(nonsending)` and stays on the CALLER's \
            executor — for these functions that caller is the main actor, so this silently \
            reintroduces roughly a second of filter-list parsing on the main thread during tab \
            materialisation, with no other test in the suite able to see it. Offences:
            \(missing.joined(separator: "\n"))
            """
        )
    }

    func test_theCheckRejectsConcurrentMentionedOnlyInADocCommentAbove() {
        let sample = """
        /// The attribute is load-bearing, see @concurrent below for why.
        private nonisolated static func buildRuleSet() async {}
        """
        let offence = Self.concurrentAttributeOffence(
            in: sample.components(separatedBy: "\n"),
            forSignature: "private nonisolated static func buildRuleSet("
        )
        XCTAssertNotNil(
            offence,
            "a doc comment that merely MENTIONS @concurrent must not satisfy the check — only the bare attribute, alone on its own line, may"
        )
    }

    func test_theCheckAcceptsTheBareAttributeAcrossBlankLines() {
        let sample = """
        @concurrent

        private nonisolated static func buildRuleSet() async {}
        """
        XCTAssertNil(Self.concurrentAttributeOffence(
            in: sample.components(separatedBy: "\n"),
            forSignature: "private nonisolated static func buildRuleSet("
        ))
    }

    func test_theCheckReportsAMissingFunctionAndAFirstLineDeclaration() {
        let signature = "private nonisolated static func buildRuleSet("
        XCTAssertNotNil(Self.concurrentAttributeOffence(in: ["let unrelated = 1"], forSignature: signature))
        XCTAssertNotNil(Self.concurrentAttributeOffence(in: ["\(signature)) async {}"], forSignature: signature))
    }

    // nil when the nearest non-blank line above the declaration is exactly `@concurrent`
    private static func concurrentAttributeOffence(in lines: [String], forSignature signature: String) -> String? {
        guard let index = lines.firstIndex(where: { $0.contains(signature) }) else {
            return "\(signature) — not found in the file at all; the path resolution or the function itself has moved"
        }
        var cursor = index - 1
        while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
            cursor -= 1
        }
        guard cursor >= 0 else {
            return "\(signature) — is the first line of the file, so there is no room for an attribute above it"
        }
        let nearestAboveLine = lines[cursor].trimmingCharacters(in: .whitespaces)
        guard nearestAboveLine == "@concurrent" else {
            return "\(signature) — nearest non-blank line above is `\(nearestAboveLine)`, not `@concurrent`"
        }
        return nil
    }
}
