import XCTest

final class TestFileCoverageGuardTests: XCTestCase {

    private static var thisDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static var productionSourceRoot: URL {
        thisDirectory.deletingLastPathComponent().appendingPathComponent("Orbit", isDirectory: true)
    }

    /// `ModalHangGuardObserver.swift` stores `private weak var currentTestCase: XCTestCase?`,
    /// which trips check 1's `": XCTestCase"` heuristic despite not being a test.
    private static let knownSupportFileNames: Set<String> = [
        "TestDoubles.swift", "RenderHarness.swift", "KeyEventFixtures.swift", "MockWebContents.swift",
        "ModalHangGuardObserver.swift",
    ]

    /// `TestDoubles.swift`'s doubles intentionally share names with real `Orbit/**` types.
    private static let shadowCheckExemptFileNames: Set<String> = ["TestDoubles.swift"]

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
            whether project.pbxproj's membershipExceptions (or, for a \
            PBXFileSystemSynchronizedRootGroup exception set) excludes the file from this \
            target's Sources build phase, or whether its XCTestCase subclass was renamed/removed \
            without deleting the file.
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
            A same-named local type in a target that can't @testable import Orbit is almost \
            always a hand-typed mirror standing in for the real one — exactly the pattern that \
            let a mirror drift silently out of sync with production while its tests kept passing. \
            Either delete the local declaration and reach the real type (via the hosted \
            OrbitAppTests target, or by symlinking the real file into this folder the way \
            OrbitTests/ReusedCommandBarSources/ does — see OrbitTests/README.md), or, if it's a \
            deliberate, currently-necessary double, add its file name to \
            TestFileCoverageGuardTests.shadowCheckExemptFileNames with a comment explaining why \
            (see the exception already documented there for TestDoubles.swift).
            """
        )
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
        // Anchored to the start of a line and run over comment-stripped source: an earlier unanchored pattern matched English prose in comments as readily as real declarations, tripping this guard against innocent files.
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

    /// Not a full lexer: a `//` inside a string literal is blanked too, which
    /// can only make this guard see fewer declarations, never invent one.
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

    // MARK: - Loaded XCTestCase subclasses via XCTest's own discovery

    /// Uses `XCTestSuite.default` rather than walking `objc_copyClassList` by
    /// hand: an earlier version did that and crashed reproducibly inside the
    /// Objective-C runtime in both targets.
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
