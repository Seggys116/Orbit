import XCTest

final class GenericClassDeinitGuardTests: XCTestCase {

    func test_everyGenericClassDeclaresAnExplicitDeinit() throws {
        let sources = try sourceFiles(under: productionRoot())
        XCTAssertGreaterThan(
            sources.count, 100,
            "Walked \(sources.count) source files under Orbit/. That is far too few — the path resolution is wrong and this test is passing because it is looking at nothing."
        )

        var offences: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
            for declaration in Self.genericClasses(in: text) where !declaration.body.contains("deinit") {
                offences.append("\(relative):\(declaration.line): \(declaration.name)")
            }
        }

        XCTAssertEqual(
            offences, [],
            """
            A generic class has no explicit deinit. Xcode 26.6's SIL optimiser crashes in \
            EarlyPerfInliner on the SYNTHESISED destructor of a generic class once the \
            deployment target is 14.6, so the Release archive dies with a compiler stack \
            dump naming <Type>CfD and no source location. Declaring `deinit {}` steps \
            around it. Delete these once the toolchain is fixed and a Release archive \
            still builds. Occurrences:
            \(offences.joined(separator: "\n"))
            """
        )
    }

    func test_theScanFindsGenericClassesAndIgnoresEverythingElse() {
        let sample = """
        final class Plain { }
        struct Boxed<T> { let value: T }
        private final class Missing<T> {
            let value: T
        }
        final class Guarded<Value: Codable> {
            deinit {}
        }
        public class Sub<Content: View>: NSHostingView<Content> {
            deinit {}
        }
        // A comment naming class Commented<T> must not count.
        """

        let found = Self.genericClasses(in: sample)
        XCTAssertEqual(
            found.map(\.name).sorted(), ["Guarded", "Missing", "Sub"],
            "The scan must find every generic class and nothing else. Found: \(found.map(\.name))"
        )
        XCTAssertEqual(
            found.filter { !$0.body.contains("deinit") }.map(\.name), ["Missing"],
            "Only the generic class without a deinit may be reported as an offence."
        )
    }

    // MARK: - Scanning

    struct GenericClass {
        var name: String
        var line: Int
        var body: String
    }

    static func genericClasses(in text: String) -> [GenericClass] {
        var result: [GenericClass] = []
        let lines = text.components(separatedBy: "\n")

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
            guard let range = raw.range(of: #"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*<"#, options: .regularExpression) else { continue }

            let declaration = raw[range]
            let name = declaration
                .replacingOccurrences(of: "class", with: "")
                .replacingOccurrences(of: "<", with: "")
                .trimmingCharacters(in: .whitespaces)

            // Body runs from this line's opening brace to its matching close.
            let fromDeclaration = lines[index...].joined(separator: "\n")
            guard let open = fromDeclaration.firstIndex(of: "{") else { continue }
            var depth = 0
            var cursor = open
            var body = ""
            while cursor < fromDeclaration.endIndex {
                let character = fromDeclaration[cursor]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
                cursor = fromDeclaration.index(after: cursor)
            }
            result.append(GenericClass(name: name, line: index + 1, body: body))
        }
        return result
    }

    // MARK: - Walking the tree

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit")
    }

    private func sourceFiles(under root: URL) throws -> [URL] {
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
