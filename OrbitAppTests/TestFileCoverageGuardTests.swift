import XCTest

final class TestFileCoverageGuardTests: XCTestCase {

    private static var thisDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static var productionSourceRoot: URL {
        thisDirectory.deletingLastPathComponent().appendingPathComponent("Orbit", isDirectory: true)
    }

    // ModalHangGuardObserver.swift is a true positive for check 1's heuristic; CorpusLiveTestCase.swift
    // is the corpus suites' base class and carries no test of its own.
    private static let knownSupportFileNames: Set<String> = [
        "RenderHarness.swift", "MockWebContents.swift", "ModalHangGuardObserver.swift",
        "CorpusLiveTestCase.swift",
    ]

    private static let shadowCheckExemptFileNames: Set<String> = []

    // MARK: - Check 1: every test file contributes a runnable XCTestCase

    func testEveryTestFileContributesARunnableXCTestCaseToThisBundle() throws {
        let root = Self.thisDirectory
        let swiftFiles = try Self.swiftFiles(under: root)
        XCTAssertFalse(swiftFiles.isEmpty, "No .swift files found under \(root.path) — this guard's own directory walk is broken.")

        let bundle = Bundle(for: Self.self)
        let loadedTestCaseClassNames = Self.loadedXCTestCaseClassNames()
        XCTAssertFalse(
            loadedTestCaseClassNames.isEmpty,
            "XCTestSuite.default found zero XCTestCase subclasses in \(bundle.bundleURL.lastPathComponent) — this guard's own test-discovery walk is broken (it should at least find itself)."
        )

        var darkFiles: [String] = []
        for fileURL in swiftFiles {
            let fileName = fileURL.lastPathComponent
            guard !Self.knownSupportFileNames.contains(fileName) else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                XCTFail("Could not read \(fileURL.path) to check for XCTestCase subclasses.")
                continue
            }
            let looksLikeATestFile = fileName.hasSuffix("Tests.swift") || contents.contains(": XCTestCase")
            guard looksLikeATestFile else { continue }

            let declaredNames = Self.declaredTypeNames(in: contents)
            let contributesARunningTest = !declaredNames.isDisjoint(with: loadedTestCaseClassNames)
            if !contributesARunningTest {
                darkFiles.append(Self.relativePath(of: fileURL, to: root))
            }
        }

        XCTAssertTrue(
            darkFiles.isEmpty,
            """
            The following file(s) look like test files (name ends "Tests.swift", or declare a \
            ": XCTestCase" subclass) but contributed zero XCTestCase subclasses to the running \
            \(bundle.bundleURL.lastPathComponent) bundle: \(darkFiles.joined(separator: ", ")). \
            This is the exact silent-exclusion failure mode this guard exists to catch — check \
            whether project.pbxproj excludes the file from this target's Sources build phase, \
            whether TEST_HOST/BUNDLE_LOADER still point at Orbit.app, or whether its \
            XCTestCase subclass was renamed/removed without deleting the file.
            """
        )
    }

    // MARK: - Check 2: no hidden mirror of a production type

    func testNoTestFileShadowsAProductionTypeNameWithoutTestableImport() throws {
        let root = Self.thisDirectory
        let productionNames = try Self.declaredTopLevelTypeNames(under: Self.productionSourceRoot)
        XCTAssertFalse(
            productionNames.isEmpty,
            "Found zero declared types under \(Self.productionSourceRoot.path) — this guard's production-source walk is broken (it should find hundreds)."
        )

        var shadowingFiles: [String: Set<String>] = [:]
        let swiftFiles = try Self.swiftFiles(under: root)
        for fileURL in swiftFiles {
            let fileName = fileURL.lastPathComponent
            guard !Self.shadowCheckExemptFileNames.contains(fileName) else { continue }
            guard try !Self.isSymbolicLink(fileURL) else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            guard !contents.contains("@testable import Orbit") else { continue }

            let declaredNames = Self.declaredTypeNames(in: contents)
            let shadowed = declaredNames.intersection(productionNames)
            if !shadowed.isEmpty {
                shadowingFiles[Self.relativePath(of: fileURL, to: root), default: []].formUnion(shadowed)
            }
        }

        XCTAssertTrue(
            shadowingFiles.isEmpty,
            """
            The following non-symlinked test file(s), none of which `@testable import Orbit`, \
            declare a type whose name is also declared somewhere under Orbit/**: \
            \(shadowingFiles.map { "\($0.key) (\($0.value.sorted().joined(separator: ", ")))" }.sorted().joined(separator: "; ")). \
            Every file in this hosted target can `@testable import Orbit` and reach the real \
            type directly — add that import instead of a local declaration, or, if it's a \
            deliberate double, add its file name to \
            TestFileCoverageGuardTests.shadowCheckExemptFileNames with a comment explaining why.
            """
        )
    }

    // MARK: - Check 3: `AppEnvironment.demo` is evaluated exactly once per file
    // Counts per file, not per test method, since a same-file helper calling AppEnvironment.demo is textually invisible from the caller's body.

    private static let multipleDemoEnvironmentsExemptFileNames: Set<String> = [
        "TestFileCoverageGuardTests.swift", // matches its own literal string
        "SplitDropZoneOverlayPageInteractionRegressionTests.swift", // verified: 9 distinct test methods
        "PageClipShapeHitTestEvidenceTests.swift", // verified: 5 distinct test methods
        // Two XCTestCase classes in one file, each binding its own `private lazy var env`.
        "AppEnvironmentDataResetTests.swift",
    ]

    func testEveryTestFileEvaluatesTheDemoEnvironmentAtMostOnce() throws {
        let root = Self.thisDirectory
        var computedBindings: [String] = []
        var repeatedEvaluations: [String] = []

        for fileURL in try Self.swiftFiles(under: root) {
            let fileName = fileURL.lastPathComponent
            guard try !Self.isSymbolicLink(fileURL) else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var evaluations = 0
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = Self.strippingStringLiterals(from: line.trimmingCharacters(in: .whitespaces))
                guard !trimmed.hasPrefix("//") else { continue }
                guard trimmed.contains("AppEnvironment.demo") else { continue }
                evaluations += 1

                let isComputedBinding = trimmed.contains("var ")
                    && trimmed.contains("{")
                    && trimmed.contains("}")
                    && !trimmed.contains("=")
                if isComputedBinding {
                    computedBindings.append("\(Self.relativePath(of: fileURL, to: root)): \(trimmed)")
                }
            }

            if evaluations > 1, !Self.multipleDemoEnvironmentsExemptFileNames.contains(fileName) {
                repeatedEvaluations.append("\(Self.relativePath(of: fileURL, to: root)) (\(evaluations)x)")
            }
        }

        XCTAssertTrue(
            computedBindings.isEmpty,
            """
            The following line(s) bind `AppEnvironment.demo` as a computed property: \
            \(computedBindings.joined(separator: "; ")). `AppEnvironment.demo` returns a NEW \
            environment on every access, so a computed binding hands each `env.` a different \
            object and nothing written through it can be read back. Use a stored \
            `private lazy var env: AppEnvironment = AppEnvironment.demo` instead — XCTest \
            builds a fresh instance of the test class per test method, so that is both \
            isolated and stable.
            """
        )

        XCTAssertTrue(
            repeatedEvaluations.isEmpty,
            """
            The following file(s) evaluate `AppEnvironment.demo` more than once: \
            \(repeatedEvaluations.joined(separator: ", ")). Each evaluation builds a separate \
            environment, so two of them cannot see each other's state — most often this is a \
            helper method that inlines `AppEnvironment.demo` and is then called several times \
            within one test, which quietly compares unrelated environments. Bind it once as \
            `private lazy var env: AppEnvironment = AppEnvironment.demo` and pass `env` to the \
            helper. If a suite genuinely needs two independent environments, add its file name \
            to TestFileCoverageGuardTests.multipleDemoEnvironmentsExemptFileNames with a \
            comment explaining why.
            """
        )
    }

    private static func strippingStringLiterals(from line: String) -> String {
        var result = ""
        var insideLiteral = false
        var previousWasBackslash = false
        for character in line {
            if character == "\"" && !previousWasBackslash {
                insideLiteral.toggle()
                continue
            }
            previousWasBackslash = (character == "\\") && !previousWasBackslash
            if !insideLiteral { result.append(character) }
        }
        return result
    }

    // MARK: - Directory walk

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink ?? false
    }

    private static func relativePath(of url: URL, to root: URL) -> String {
        url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    }

    // MARK: - Declared type name extraction (heuristic, source-text based)

    private static func declaredTypeNames(in source: String) -> Set<String> {
        var names: Set<String> = []
        // Anchored to line start, run over comment-stripped source.
        let pattern = #"""
        (?m)^[ \t]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|internal|private|fileprivate|open|final|indirect|nonisolated|static)[ \t]+)*(?:class|struct|enum)[ \t]+([A-Za-z_][A-Za-z0-9_]*)
        """#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return names }
        let stripped = sourceStrippingComments(source)
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        regex.enumerateMatches(in: stripped, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range(at: 1), in: stripped) else { return }
            names.insert(String(stripped[matchRange]))
        }
        return names
    }

    // Blanks // and /* */ comments, preserving line structure.
    private static func sourceStrippingComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var inLineComment = false
        var blockDepth = 0
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let following: Character? = next < source.endIndex ? source[next] : nil

            if character == "\n" {
                inLineComment = false
                out.append(character)
                index = next
                continue
            }
            if inLineComment {
                out.append(" ")
                index = next
                continue
            }
            if blockDepth > 0 {
                if character == "*", following == "/" {
                    blockDepth -= 1
                    out.append("  ")
                    index = source.index(after: next)
                    continue
                }
                if character == "/", following == "*" {
                    blockDepth += 1
                    out.append("  ")
                    index = source.index(after: next)
                    continue
                }
                out.append(" ")
                index = next
                continue
            }
            if character == "/", following == "/" {
                inLineComment = true
                out.append("  ")
                index = source.index(after: next)
                continue
            }
            if character == "/", following == "*" {
                blockDepth = 1
                out.append("  ")
                index = source.index(after: next)
                continue
            }
            out.append(character)
            index = next
        }
        return out
    }

    private static func declaredTopLevelTypeNames(under directory: URL) throws -> Set<String> {
        var names: Set<String> = []
        for fileURL in try swiftFiles(under: directory) {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            names.formUnion(declaredTypeNames(in: contents))
        }
        return names
    }

    // MARK: - Loaded XCTestCase subclasses (XCTestSuite.default, not objc_copyClassList -- that crashed)
    private static func loadedXCTestCaseClassNames() -> Set<String> {
        var names: Set<String> = []
        func walk(_ test: XCTest) {
            if let suite = test as? XCTestSuite {
                for child in suite.tests { walk(child) }
            } else {
                let typeName = String(describing: type(of: test))
                names.insert(typeName.components(separatedBy: ".").last ?? typeName)
            }
        }
        walk(XCTestSuite.default)
        return names
    }
}
