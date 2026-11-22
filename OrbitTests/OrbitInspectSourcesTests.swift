// Unit tests for the Sources tool; OrbitInspectSourcesLogic.swift and OrbitInspectDecode.swift are compiled directly (no @testable import).

import XCTest

final class OrbitInspectSourcesTests: XCTestCase {


    func testVLQDecodeZero() throws {
        let result = try SourceVLQ.decode("A")
        XCTAssertEqual(result, [0])
    }

    func testVLQDecodePositive() throws {
        let result = try SourceVLQ.decode("C")
        XCTAssertEqual(result, [1])
    }

    func testVLQDecodeNegative() throws {
        let result = try SourceVLQ.decode("D")
        XCTAssertEqual(result, [-1])
    }

    func testVLQDecodeMultipleContinuation() throws {
        // "gB" is two sextets: g sets the continuation bit with value 0, B adds 1 << 5 = 32, and 32 >> 1 = 16.
        let result = try SourceVLQ.decode("gB")
        XCTAssertEqual(result, [16])
    }

    func testVLQDecodeMultipleValues() throws {
        let result = try SourceVLQ.decode("AAAA")
        XCTAssertEqual(result, [0, 0, 0, 0])
    }

    func testVLQDecodeInvalidChar() {
        XCTAssertThrowsError(try SourceVLQ.decode("!")) { error in
            guard case SourceVLQ.Error.invalidCharacter = error else {
                XCTFail("Expected invalidCharacter error, got \(error)")
                return
            }
        }
    }

    func testVLQDecodeEmptyString() throws {
        let result = try SourceVLQ.decode("")
        XCTAssertEqual(result, [])
    }

    // MARK: - Source map parser

    func testSourceMappingURLDetectionJS() {
        let text = "var x = 1;\n//# sourceMappingURL=app.js.map\n"
        XCTAssertEqual(SourceMapParser.sourceMappingURL(in: text), "app.js.map")
    }

    func testSourceMappingURLDetectionCSS() {
        let text = "body { color: red; }\n/*# sourceMappingURL=style.css.map */"
        XCTAssertEqual(SourceMapParser.sourceMappingURL(in: text), "style.css.map")
    }

    func testSourceMappingURLOldSyntax() {
        let text = "var x = 1;\n//@ sourceMappingURL=app.js.map"
        XCTAssertEqual(SourceMapParser.sourceMappingURL(in: text), "app.js.map")
    }

    func testSourceMappingURLAbsent() {
        let text = "var x = 1; // no map here"
        XCTAssertNil(SourceMapParser.sourceMappingURL(in: text))
    }

    func testParseSimpleSourceMap() {
        let json: [String: Any] = [
            "version": 3,
            "sources": ["src/app.ts"],
            "names": [],
            "mappings": "AAAA",
            "sourceRoot": "",
        ]
        guard let map = SourceMapParser.parse(json: json) else {
            XCTFail("parse returned nil")
            return
        }
        XCTAssertEqual(map.version, 3)
        XCTAssertEqual(map.sources, ["src/app.ts"])
        let parsed = SourceMapParser.parseMappings(map)
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].count, 1)
        XCTAssertEqual(parsed.lines[0][0].generatedColumn, 0)
        XCTAssertEqual(parsed.lines[0][0].sourceIndex, 0)
        XCTAssertEqual(parsed.lines[0][0].originalLine, 0)
        XCTAssertEqual(parsed.lines[0][0].originalColumn, 0)
    }

    func testOriginalPositionLookup() {
        let json: [String: Any] = [
            "version": 3,
            "sources": ["src/app.ts"],
            "names": [],
            "mappings": "AAAA,SAAS,CAAC",  // generated line 0 has two segments
            "sourceRoot": "",
        ]
        guard let map = SourceMapParser.parse(json: json) else { XCTFail(); return }
        let parsed = SourceMapParser.parseMappings(map)
        let pos = parsed.originalPosition(line: 0, column: 0)
        XCTAssertNotNil(pos)
        XCTAssertEqual(pos?.source, "src/app.ts")
        XCTAssertEqual(pos?.line, 0)
    }

    func testOriginalPositionOutOfBounds() {
        let json: [String: Any] = [
            "version": 3,
            "sources": ["src/app.ts"],
            "names": [],
            "mappings": "AAAA",
            "sourceRoot": "",
        ]
        guard let map = SourceMapParser.parse(json: json) else { XCTFail(); return }
        let parsed = SourceMapParser.parseMappings(map)
        let pos = parsed.originalPosition(line: 99, column: 0)
        XCTAssertNil(pos)
    }

    func testSourceMapWithSourcesContent() {
        let json: [String: Any] = [
            "version": 3,
            "sources": ["src/app.ts"],
            "sourcesContent": ["const x = 1;"],
            "names": [],
            "mappings": "AAAA",
            "sourceRoot": "",
        ]
        guard let map = SourceMapParser.parse(json: json) else { XCTFail(); return }
        XCTAssertEqual(map.sourcesContent.count, 1)
        XCTAssertEqual(map.sourcesContent[0], "const x = 1;")
    }

    // MARK: - Tree builder

    func testTreeBuilderGroupsByOrigin() {
        let files = [
            SourceFile.make(url: "https://example.com/app.js", mimeType: "text/javascript"),
            SourceFile.make(url: "https://cdn.example.com/lib.js", mimeType: "text/javascript"),
        ]
        var expanded: Set<String> = ["origin:example.com", "origin:cdn.example.com"]
        let rows = SourceTreeBuilder.buildFlatRows(files: files, originalFiles: [], snippets: [], expandedIDs: expanded, filterQuery: "", preferOriginals: false)
        let originHeaders = rows.filter { if case .originHeader = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(originHeaders.count, 1)
    }

    func testTreeBuilderFiltersByQuery() {
        let files = [
            SourceFile.make(url: "https://example.com/app.js", mimeType: "text/javascript"),
            SourceFile.make(url: "https://example.com/style.css", mimeType: "text/css"),
        ]
        let expanded: Set<String> = ["origin:example.com"]
        let rows = SourceTreeBuilder.buildFlatRows(files: files, originalFiles: [], snippets: [], expandedIDs: expanded, filterQuery: "app", preferOriginals: false)
        let fileRows = rows.filter { if case .file(let f) = $0.kind { return f.displayName.contains("app") }; return false }
        XCTAssertEqual(fileRows.count, 1)
    }

    func testTreeBuilderNestedFolders() {
        let files = [
            SourceFile.make(url: "https://example.com/static/js/app.js", mimeType: "text/javascript"),
            SourceFile.make(url: "https://example.com/static/css/style.css", mimeType: "text/css"),
        ]
        var expanded: Set<String> = [
            "origin:example.com",
            "folder:1:static",
            "folder:2:js",
            "folder:2:css",
        ]
        let rows = SourceTreeBuilder.buildFlatRows(files: files, originalFiles: [], snippets: [], expandedIDs: expanded, filterQuery: "", preferOriginals: false)
        XCTAssertGreaterThan(rows.count, 2)
    }

    // MARK: - Fuzzy matcher

    func testFuzzyMatcherMatchesSubsequence() {
        XCTAssertTrue(SourceFuzzyMatcher.matches(query: "app", in: "application.js"))
        XCTAssertTrue(SourceFuzzyMatcher.matches(query: "apjs", in: "application.js"))
        XCTAssertFalse(SourceFuzzyMatcher.matches(query: "xyz", in: "application.js"))
    }

    func testFuzzyMatcherCaseInsensitive() {
        XCTAssertTrue(SourceFuzzyMatcher.matches(query: "APP", in: "application.js"))
        XCTAssertTrue(SourceFuzzyMatcher.matches(query: "App", in: "Application.js"))
    }

    func testFuzzyMatcherEmpty() {
        XCTAssertTrue(SourceFuzzyMatcher.matches(query: "", in: "anything"))
    }

    func testFuzzyMatcherRankOrdering() throws {
        let candidates = ["application.js", "app.js", "api.ts"]
        let results = SourceFuzzyMatcher.rank(query: "app", candidates: candidates)
        let appIdx = try XCTUnwrap(results.firstIndex(where: { $0.text == "app.js" }))
        let applicationIdx = try XCTUnwrap(results.firstIndex(where: { $0.text == "application.js" }))
        XCTAssertLessThan(appIdx, applicationIdx)
        XCTAssertEqual(results.map(\.text), ["app.js", "application.js"], "api.ts has no second p and must not match")
        XCTAssertEqual(results.map(\.score), [31, 29])
    }

    // MARK: - JSON pretty printer

    func testJSONPrettyPrintBasic() {
        let input = #"{"a":1,"b":"hello","c":[1,2,3]}"#
        let result = SourcePrettyPrinter.json(input)
        XCTAssertTrue(result.text.contains("\"a\": 1"), "Should have spaced colon")
        XCTAssertTrue(result.text.contains("\n"), "Should have newlines")
    }

    func testJSONPrettyPrintIdempotent() {
        let input = #"{"key":"value"}"#
        let once = SourcePrettyPrinter.json(input)
        let twice = SourcePrettyPrinter.json(once.text)
        XCTAssertEqual(once.text, "{\n  \"key\": \"value\"\n}")
        XCTAssertEqual(twice.text, once.text)
    }

    func testJSONPrettyPrintPreservesStrings() {
        let input = #"{"key":"{\"nested\":true}"}"#
        let result = SourcePrettyPrinter.json(input)
        let expected = ["{", #"  "key": "{\"nested\":true}""#, "}"].joined(separator: "\n")
        XCTAssertEqual(result.text, expected)
    }

    func testJSONPrettyPrintLinemap() {
        let input = #"{"a":1}"#
        let result = SourcePrettyPrinter.json(input)
        XCTAssertFalse(result.linemap.isEmpty || result.reverseLinemap.isEmpty, "Should have line mappings")
    }


    func testCSSPrettyPrintBasic() {
        let input = "body{color:red;font-size:16px;}.title{font-weight:bold;}"
        let result = SourcePrettyPrinter.css(input)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(lines, [
            "body {",
            "  color:red;",
            "  font-size:16px;",
            "}",
            ".title {",
            "  font-weight:bold;",
            "}",
        ])
    }

    func testCSSPrettyPrintDoesNotCorruptStrings() {
        let input = #"a::before{content:"{"}"#
        let result = SourcePrettyPrinter.css(input)
        let expected = ["a::before {", #"  content:"{""#, "}"].joined(separator: "\n")
        XCTAssertEqual(result.text, expected)
    }


    func testJSPrettyPrintBasic() {
        let input = "function f(){var x=1;if(x){return x;}}"
        let result = SourcePrettyPrinter.js(input)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(4)), [
            "function f() {",
            "  var x=1;",
            "  if(x) {",
            "    return x;",
        ])
        XCTAssertEqual(lines.dropFirst(4).map { $0.trimmingCharacters(in: .whitespaces) }, ["}", "}", ""])
    }

    func testJSPrettyPrintPreservesStrings() {
        let input = #"var s = "hello {world}";"#
        let result = SourcePrettyPrinter.js(input)
        XCTAssertTrue(result.text.contains("\"hello {world}\""), "String content should be preserved")
    }


    func testHTMLTokenizerBasic() {
        let html = "<div class=\"foo\">Hello</div>"
        let tokens = HTMLTokenizer.tokenize(html)
        XCTAssertFalse(tokens.isEmpty)
        let tagTokens = tokens.filter { $0.kind == .tag }
        XCTAssertTrue(tagTokens.contains(where: { html[$0.range] == "div" }))
        let attrTokens = tokens.filter { $0.kind == .attribute }
        XCTAssertTrue(attrTokens.contains(where: { html[$0.range] == "class" }))
    }

    func testHTMLTokenizerComment() {
        let html = "<!-- This is a comment --><p>text</p>"
        let tokens = HTMLTokenizer.tokenize(html)
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 1)
    }


    func testJSONTokenizerBasic() {
        let json = #"{"key": "value", "num": 42, "flag": true}"#
        let tokens = JSONTokenizer.tokenize(json)
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertGreaterThanOrEqual(strings.count, 2, "Should find at least 2 strings")
        let numbers = tokens.filter { $0.kind == .number }
        XCTAssertGreaterThanOrEqual(numbers.count, 1)
        let keywords = tokens.filter { $0.kind == .keyword }
        XCTAssertTrue(keywords.contains(where: { json[$0.range] == "true" }))
    }


    func testFileTypeFromMimeType() {
        XCTAssertEqual(SourceFileType.from(mimeType: "text/javascript", url: ""), .script)
        XCTAssertEqual(SourceFileType.from(mimeType: "text/css", url: ""), .stylesheet)
        XCTAssertEqual(SourceFileType.from(mimeType: "text/html", url: ""), .document)
        XCTAssertEqual(SourceFileType.from(mimeType: "image/png", url: ""), .image)
        XCTAssertEqual(SourceFileType.from(mimeType: "application/wasm", url: ""), .wasm)
    }

    func testFileTypeFromURL() {
        XCTAssertEqual(SourceFileType.from(mimeType: "", url: "app.js"), .script)
        XCTAssertEqual(SourceFileType.from(mimeType: "", url: "style.css"), .stylesheet)
        XCTAssertEqual(SourceFileType.from(mimeType: "", url: "index.html"), .document)
        XCTAssertEqual(SourceFileType.from(mimeType: "", url: "logo.png"), .image)
        XCTAssertEqual(SourceFileType.from(mimeType: "", url: "blob:https://example.com/abc"), .blobScript)
    }


    func testLanguageDetection() {
        XCTAssertEqual(SourceLanguage.detect(url: "app.ts", mimeType: ""), .typeScript)
        XCTAssertEqual(SourceLanguage.detect(url: "app.tsx", mimeType: ""), .typeScript)
        XCTAssertEqual(SourceLanguage.detect(url: "app.js", mimeType: ""), .javaScript)
        XCTAssertEqual(SourceLanguage.detect(url: "style.css", mimeType: ""), .css)
        XCTAssertEqual(SourceLanguage.detect(url: "index.html", mimeType: ""), .html)
        XCTAssertEqual(SourceLanguage.detect(url: "data.json", mimeType: ""), .json)
    }

    // MARK: - EditorPaths (shared type from OrbitInspectDecode.swift)

    func testEditorPathsResolvesWebpackURL() {
        let result = OrbitInspectEditorPaths.resolve("webpack://_N_E/./app/page.tsx")
        XCTAssertNil(result.absolute, "Webpack URLs are not absolute paths")
        XCTAssertTrue(result.relatives.contains("app/page.tsx"), "Should strip webpack prefix and namespace")
    }

    func testEditorPathsResolvesFileURL() {
        let result = OrbitInspectEditorPaths.resolve("file:///Users/me/project/src/App.tsx")
        XCTAssertEqual(result.absolute, "/Users/me/project/src/App.tsx")
    }

    func testEditorPathsResolvesHTTPURL() {
        let result = OrbitInspectEditorPaths.resolve("http://localhost:3000/src/App.tsx")
        XCTAssertTrue(result.relatives.contains(where: { $0.contains("App.tsx") }))
    }


    func testJSONLinemapRoundtrip() {
        // A single-line JSON object should map original line 0 to pretty line 0
        let input = #"{"a":1}"#
        let result = SourcePrettyPrinter.json(input)
        XCTAssertEqual(result.linemap[0], 0, "Original line 0 should map to pretty line 0")
    }

    func testCSSLinemapNonEmpty() {
        let input = "body{color:red;}\n.title{font-weight:bold;}"
        let result = SourcePrettyPrinter.css(input)
        XCTAssertFalse(result.linemap.isEmpty)
        XCTAssertFalse(result.reverseLinemap.isEmpty)
    }

    // MARK: - Hostile source maps

    /// Source map values are 32-bit; a longer VLQ run is rejected rather than summed into an overflow.
    func test_vlqDecode_rejectsValuesWiderThan32Bits() {
        XCTAssertThrowsError(try SourceVLQ.decode(String(repeating: "/", count: 20) + "A"))
        XCTAssertEqual(try SourceVLQ.decode("AAgBC"), [0, 0, 16, 1])
    }

    func test_parseMappings_withHugeSegmentsDoesNotTrap() {
        let huge = String(repeating: "/", count: 6) + "D" // just inside 32 bits, repeated so sums grow large
        let line = Array(repeating: huge + huge + huge + huge, count: 2000).joined(separator: ",")
        let map = SourceMapV3(version: 3, file: "", sourceRoot: "", sources: ["a"], sourcesContent: [nil], names: [],
                              mappings: Array(repeating: line, count: 4).joined(separator: ";"), sections: [])
        let parsed = SourceMapParser.parseMappings(map)
        XCTAssertEqual(parsed.lines.count, 4)
    }

    /// An index map section must not make the merge pad a billion lines, or index below zero.
    func test_indexMapSections_outOfRangeOffsetsAreDropped() {
        let inner: [String: Any] = ["version": 3, "sources": ["a.js"], "names": [], "mappings": "AAAA"]
        let json: [String: Any] = ["version": 3, "sections": [
            ["offset": ["line": 1_000_000_000, "column": 0], "map": inner],
            ["offset": ["line": -5, "column": 0], "map": inner],
            ["offset": ["line": 2, "column": 0], "map": inner],
        ]]
        let parsed = SourceMapParser.parse(json: json)
        XCTAssertEqual(parsed?.sections.count, 1)
        XCTAssertEqual(parsed?.sections.first?.offsetLine, 2)
    }
}
