import XCTest

// Whole suite excluded on GitHub-hosted runners: needs a real running app, not a headless VM.
final class ProductCopyLeakGuardTests: XCTestCase {

    private static let forbiddenPatterns: [String] = [
        #"\bArc\b"#,
        #"\bArc's\b"#,
        #"arc\.net"#,
        #"arc://"#,
    ]

    private static let allowedLiteralSubstrings: [String] = [
        "Arc Spaces",
        "from Arc.",
        "from Arc —",
        "from Arc but not transferred",
        "read Arc's saved logins",
        "Arc's login sessions could not be read",
        "Arc logins weren't brought across",
        "Arc has no saved encryption key",
        "Arc's encryption key",
        "Arc's keychain item",
        "Arc's cookie key",
        "Arc encrypted these cookies",
        "an Arc cookie",
        "An Arc cookie",
        "from Arc (",
        "Couldn't bring these Arc shortcuts across",
        "could be read from Arc but there was no browsing session",
    ]

    private static let allowedExactLiterals: [String] = [
        "Arc",
        "Library/Application Support/Arc",
        "Library/Application Support/Arc/User Data",
        "Arc Safe Storage",
    ]

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noUserFacingStringLiteralNamesAnotherBrowser

    func test_noUserFacingStringLiteralNamesAnotherBrowser() throws {
        let sources = try swiftFiles(under: productionRoot())
        XCTAssertGreaterThan(
            sources.count, 100,
            "Walked \(sources.count) Swift files under Orbit/. That is far too few — the path resolution below is wrong, and this test is passing because it is looking at nothing."
        )

        var leaks: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineNumber, literal) in Self.userFacingStringLiterals(in: text) {
                guard Self.namesAnotherBrowser(literal) else { continue }
                guard !Self.allowedLiteralSubstrings.contains(where: { literal.contains($0) }) else { continue }
                guard !Self.allowedExactLiterals.contains(literal) else { continue }
                let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
                leaks.append("\(relative):\(lineNumber): \"\(literal.prefix(160))\"")
            }
        }

        XCTAssertEqual(
            leaks, [],
            """
            Another product's name is in a string literal that can reach an Orbit user. \
            Rewrite the copy to say Orbit's own reason rather than citing a different \
            browser; keep the provenance in a comment beside it. If the literal genuinely \
            has to name the product, add it to `allowedLiteralSubstrings` with a reason. \
            Leaks:
            \(leaks.joined(separator: "\n"))
            """
        )
    }

    // MARK: - "Max" naming Orbit's own feature set

    private static let forbiddenMaxProductNamePatterns: [String] = [
        #"\bMax\b"#,
        #"OrbitMax"#,
    ]

    private static let allowedMaxProductNameLiteralSubstrings: [String] = []

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noStringLiteralNamesOrbitsFeatureSetMax

    func test_noStringLiteralNamesOrbitsFeatureSetMax() throws {
        let sources = try swiftFiles(under: productionRoot())

        var leaks: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineNumber, literal) in Self.userFacingStringLiterals(in: text) {
                guard Self.namesOrbitsFeatureSetMax(literal) else { continue }
                guard !Self.allowedMaxProductNameLiteralSubstrings.contains(where: { literal.contains($0) }) else { continue }
                let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
                leaks.append("\(relative):\(lineNumber): \"\(literal.prefix(160))\"")
            }
        }

        XCTAssertEqual(
            leaks, [],
            """
            A string literal names Orbit's own AI feature set "Max" — that is Arc's \
            product name for the same feature set, and it happened for real: the whole \
            suite (Tidy Tabs, Tidy Downloads, Ask on Page, Instant Links, the ChatGPT \
            Command Bar entry) was renamed from "Max" to "Assist" specifically to fix \
            it. Rewrite the copy to say "Assist" or to describe the feature without \
            naming it at all; keep any citation of Arc's real "Max" naming in a comment \
            beside it, the way `AssistProvider.swift` and `AssistSettingsPane.swift` do. \
            Leaks:
            \(leaks.joined(separator: "\n"))
            """
        )
    }

    static func namesOrbitsFeatureSetMax(_ literal: String) -> Bool {
        forbiddenMaxProductNamePatterns.contains { pattern in
            literal.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - Surviving `OrbitMax*` / `…Orbit.max-provider` identifiers

    private static let forbiddenMaxIdentifierPatterns: [String] = [
        #"^OrbitMax"#,
        #"Orbit\.max-provider"#,
    ]

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noSurvivingMaxUserDefaultsKeyOrKeychainServiceLiteral

    func test_noSurvivingMaxUserDefaultsKeyOrKeychainServiceLiteral() throws {
        let sources = try swiftFiles(under: productionRoot())

        var leaks: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineNumber, literal) in Self.userFacingStringLiterals(in: text) {
                let hit = Self.forbiddenMaxIdentifierPatterns.contains { pattern in
                    literal.range(of: pattern, options: .regularExpression) != nil
                }
                guard hit else { continue }
                let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
                leaks.append("\(relative):\(lineNumber): \"\(literal.prefix(160))\"")
            }
        }

        XCTAssertEqual(
            leaks, [],
            """
            A `UserDefaults` key or Keychain service literal still uses the pre-rename \
            "Max" form (`OrbitMax*`, or a Keychain service ending `Orbit.max-provider`). \
            Every one of these was renamed to the `OrbitAssist*` / \
            `…Orbit.assist-provider` form; rename this straggler to match rather than \
            adding an exception — a key or service string is never legitimately allowed \
            to keep the old name, because nothing reads it any more once its callers are \
            renamed, and a leftover key silently orphans whatever the user had stored \
            under it. Leaks:
            \(leaks.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Plan/tier/subscription language

    private static let forbiddenPlanTierPatterns: [String] = [
        #"\bplan\b"#, #"\bplans\b"#,
        #"\btier\b"#, #"\btiers\b"#,
        #"\bsubscription\b"#, #"\bsubscriptions\b"#,
        #"\bupgrade\b"#, #"\bupgrades\b"#, #"\bupgraded\b"#, #"\bupgrading\b"#,
        #"\bunlock\b"#, #"\bunlocks\b"#, #"\bunlocked\b"#, #"\bunlocking\b"#,
        #"\bpremium\b"#,
        #"\bpaywall\b"#, #"\bpaywalled\b"#,
    ]

    private static let allowedPlanTierExactLiterals: [String] = [
        "upgrade",
        "unlock",
    ]
    private static let allowedPlanTierLiteralSubstrings: [String] = [
        "unlock your keychain",
        "keychain couldn't be unlocked",
    ]

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noUserFacingStringLiteralDescribesFeaturesAsPlanOrTier

    func test_noUserFacingStringLiteralDescribesFeaturesAsPlanOrTier() throws {
        let sources = try swiftFiles(under: productionRoot())

        var leaks: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineNumber, literal) in Self.userFacingStringLiterals(in: text) {
                let hit = Self.forbiddenPlanTierPatterns.contains { pattern in
                    literal.range(of: pattern, options: .regularExpression) != nil
                }
                guard hit else { continue }
                guard !Self.allowedPlanTierExactLiterals.contains(literal) else { continue }
                guard !Self.allowedPlanTierLiteralSubstrings.contains(where: { literal.contains($0) }) else { continue }
                let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
                leaks.append("\(relative):\(lineNumber): \"\(literal.prefix(160))\"")
            }
        }

        XCTAssertEqual(
            leaks, [],
            """
            A string literal describes an Orbit feature using plan/tier/subscription/\
            upgrade/unlock language. Orbit sells nothing and has no tiers — every \
            feature is just on or off — so rewrite the copy to describe what the \
            feature does rather than what it costs or requires. If the literal is a \
            genuine exception (an OS-level concept like unlocking the login keychain, \
            or a software update rather than a feature), add it to \
            `allowedPlanTierExactLiterals` or `allowedPlanTierLiteralSubstrings` with a \
            reason. Leaks:
            \(leaks.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Literal extraction

    static func userFacingStringLiterals(in text: String) -> [(line: Int, literal: String)] {
        var found: [(Int, String)] = []
        var inBlockComment = false

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            var line = rawLine

            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlockComment = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = String(line[line.startIndex..<start.lowerBound]) + String(line[end.upperBound...])
                } else {
                    line = String(line[line.startIndex..<start.lowerBound])
                    inBlockComment = true
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }

            line = Self.strippingTrailingLineComment(line)

            for literal in Self.doubleQuotedLiterals(in: line) {
                found.append((index + 1, literal))
            }
        }
        return found
    }

    static func strippingTrailingLineComment(_ line: String) -> String {
        var insideLiteral = false
        var escaped = false
        var previous: Character?
        var result = ""
        for character in line {
            if escaped {
                escaped = false
                result.append(character)
                previous = character
                continue
            }
            if character == "\\" && insideLiteral {
                escaped = true
                result.append(character)
                previous = character
                continue
            }
            if character == "\"" { insideLiteral.toggle() }
            if character == "/", previous == "/", !insideLiteral {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }

    static func doubleQuotedLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var insideLiteral = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if insideLiteral, character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                if insideLiteral {
                    literals.append(current)
                    current = ""
                }
                insideLiteral.toggle()
                continue
            }
            if insideLiteral { current.append(character) }
        }
        return literals
    }

    static func namesAnotherBrowser(_ literal: String) -> Bool {
        forbiddenPatterns.contains { pattern in
            literal.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - Walking the tree

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // OrbitTests/ProductCopyLeakGuardTests.swift
            .deletingLastPathComponent()      // OrbitTests/
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Orbit")
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
