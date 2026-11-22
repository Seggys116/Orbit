import XCTest

// The sources under test are compiled directly into the test bundle, so there is no @testable import.

final class OrbitInspectConsoleTests: XCTestCase {


    func test_parseFormatString_noSpecifiers_returnsSingleTextRun() {
        let (runs, first) = OrbitConsoleLogic.parseFormatString("hello world", argCount: 1)
        XCTAssertEqual(runs, [.text("hello world")])
        XCTAssertEqual(first, 1)
    }

    func test_parseFormatString_stringSpec() {
        let (runs, first) = OrbitConsoleLogic.parseFormatString("hello %s world", argCount: 2)
        XCTAssertEqual(runs, [
            .text("hello "),
            .substitution(argIndex: 1, spec: .string_),
            .text(" world")
        ])
        XCTAssertEqual(first, 2)
    }

    func test_parseFormatString_multipleSpecs() {
        let (runs, first) = OrbitConsoleLogic.parseFormatString("%d + %d = %d", argCount: 4)
        XCTAssertEqual(runs.count, 5)
        XCTAssertEqual(runs[0], .substitution(argIndex: 1, spec: .decimal))
        XCTAssertEqual(runs[1], .text(" + "))
        XCTAssertEqual(runs[2], .substitution(argIndex: 2, spec: .decimal))
        XCTAssertEqual(runs[3], .text(" = "))
        XCTAssertEqual(runs[4], .substitution(argIndex: 3, spec: .decimal))
        XCTAssertEqual(first, 4)
    }

    func test_parseFormatString_cssSpec() {
        let (runs, _) = OrbitConsoleLogic.parseFormatString("before %c after", argCount: 2)
        XCTAssertEqual(runs[1], .substitution(argIndex: 1, spec: .css))
    }

    func test_parseFormatString_escapedPercent() {
        let (runs, _) = OrbitConsoleLogic.parseFormatString("100%%", argCount: 1)
        XCTAssertEqual(runs, [.text("100%")])
    }

    func test_parseFormatString_missingArgs_fallbackToLiteralSpec() {
        // When there aren't enough args, the %s is kept as literal text
        let (runs, _) = OrbitConsoleLogic.parseFormatString("name: %s", argCount: 1)
        XCTAssertEqual(runs, [.text("name: %s")])
    }

    func test_parseFormatString_allSpecTypes() {
        let specs: [(String, ConFormatSpec)] = [
            ("%s", .string_), ("%d", .decimal), ("%i", .integer),
            ("%f", .float), ("%o", .object), ("%O", .objectXML)
        ]
        for (fmt, expected) in specs {
            let (runs, _) = OrbitConsoleLogic.parseFormatString(fmt, argCount: 2)
            XCTAssertEqual(runs, [.substitution(argIndex: 1, spec: expected)],
                           "Expected spec \(expected) for format \(fmt)")
        }
    }


    func test_parseCSSStyle_color() {
        let style = OrbitConsoleLogic.parseCSSStyle("color: red")
        XCTAssertEqual(style.color, "red")
    }

    func test_parseCSSStyle_multiple() {
        let style = OrbitConsoleLogic.parseCSSStyle("color: #ff0000; font-weight: bold; font-size: 14px")
        XCTAssertEqual(style.color, "#ff0000")
        XCTAssertEqual(style.fontWeight, "bold")
        XCTAssertEqual(style.fontSize, "14px")
    }

    func test_parseCSSStyle_backgroundShorthand() {
        let style = OrbitConsoleLogic.parseCSSStyle("background: blue")
        XCTAssertEqual(style.backgroundColor, "blue")
    }

    func test_parseCSSStyle_empty() {
        let style = OrbitConsoleLogic.parseCSSStyle("")
        XCTAssertTrue(style.isEmpty)
    }

    func test_parseCSSStyle_italic() {
        let style = OrbitConsoleLogic.parseCSSStyle("font-style: italic")
        XCTAssertTrue(style.isItalic)
    }

    func test_parseCSSStyle_bold700() {
        let style = OrbitConsoleLogic.parseCSSStyle("font-weight: 700")
        XCTAssertTrue(style.isBold)
    }


    func test_parseStack_webKitFormat() {
        let stack = "myFn@https://example.com/app.js:42:10"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].function, "myFn")
        XCTAssertEqual(frames[0].url, "https://example.com/app.js")
        XCTAssertEqual(frames[0].line, 42)
        XCTAssertEqual(frames[0].column, 10)
    }

    func test_parseStack_webKitAnonymousFrame() {
        let stack = "@https://example.com/app.js:5:1"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].function, "")
        XCTAssertTrue(frames[0].isAnonymous)
    }

    func test_parseStack_v8Format() {
        let stack = "    at myFn (https://example.com/app.js:42:10)"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].function, "myFn")
        XCTAssertEqual(frames[0].line, 42)
        XCTAssertEqual(frames[0].column, 10)
    }

    func test_parseStack_v8AnonymousFrame() {
        let stack = "    at https://example.com/app.js:10:5"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].function, "")
        XCTAssertEqual(frames[0].line, 10)
    }

    func test_parseStack_multiFrame() {
        let stack = """
        foo@https://host/a.js:1:2
        bar@https://host/b.js:3:4
        @https://host/c.js:5:6
        """
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].function, "foo")
        XCTAssertEqual(frames[1].function, "bar")
        XCTAssertEqual(frames[2].function, "")
    }

    func test_parseStack_evalFrame() {
        // eval frames often have "eval code@" prefix
        let stack = "eval code@https://example.com/app.js:1:1"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].function, "eval code")
    }

    func test_parseStack_fileWithColons() {
        // TypeScript source map path with scheme colon: webpack://…
        let stack = "Component@webpack://app/src/Comp.tsx:15:8"
        let frames = OrbitConsoleLogic.parseStack(stack)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].url, "webpack://app/src/Comp.tsx")
        XCTAssertEqual(frames[0].line, 15)
    }

    func test_parseStack_emptyInput() {
        XCTAssertEqual(OrbitConsoleLogic.parseStack("").count, 0)
    }


    func test_filterQuery_plainText() {
        let q = OrbitConsoleLogic.parseFilterQuery("hello")
        XCTAssertEqual(q.text, "hello")
        XCTAssertFalse(q.isRegex)
        XCTAssertFalse(q.isNegated)
        XCTAssertNil(q.urlFilter)
    }

    func test_filterQuery_regex() {
        let q = OrbitConsoleLogic.parseFilterQuery("/foo.*/")
        XCTAssertEqual(q.text, "foo.*")
        XCTAssertTrue(q.isRegex)
        XCTAssertFalse(q.isNegated)
    }

    func test_filterQuery_negation() {
        let q = OrbitConsoleLogic.parseFilterQuery("-noise")
        XCTAssertEqual(q.text, "noise")
        XCTAssertTrue(q.isNegated)
        XCTAssertFalse(q.isRegex)
    }

    func test_filterQuery_negatedRegex() {
        let q = OrbitConsoleLogic.parseFilterQuery("-/debug.*/")
        XCTAssertEqual(q.text, "debug.*")
        XCTAssertTrue(q.isRegex)
        XCTAssertTrue(q.isNegated)
    }

    func test_filterQuery_urlFilter() {
        let q = OrbitConsoleLogic.parseFilterQuery("url:app.js")
        XCTAssertEqual(q.urlFilter, "app.js")
        XCTAssertTrue(q.text.isEmpty)
    }

    func test_filterQuery_empty() {
        let q = OrbitConsoleLogic.parseFilterQuery("")
        XCTAssertTrue(q.isEmpty)
    }

    func test_filterMatches_casInsensitive() {
        var q = ConFilterQuery()
        q.text = "HELLO"
        XCTAssertTrue(OrbitConsoleLogic.matches(text: "hello world", query: q))
    }

    func test_filterMatches_regex_valid() {
        var q = ConFilterQuery()
        q.text = "^Error"
        q.isRegex = true
        XCTAssertTrue(OrbitConsoleLogic.matches(text: "Error: something", query: q))
        XCTAssertFalse(OrbitConsoleLogic.matches(text: "Something Error", query: q))
    }

    func test_filterMatches_regex_invalid_fallsBack() {
        var q = ConFilterQuery()
        q.text = "[["   // invalid regex
        q.isRegex = true
        // Invalid regex → no match, doesn't crash
        XCTAssertFalse(OrbitConsoleLogic.matches(text: "anything", query: q))
    }

    func test_filterMatches_negated() {
        var q = ConFilterQuery()
        q.text = "noise"
        q.isNegated = true
        XCTAssertTrue(OrbitConsoleLogic.matches(text: "important message", query: q))
        XCTAssertFalse(OrbitConsoleLogic.matches(text: "noise: blah", query: q))
    }

    func test_filterMatches_urlFilter() {
        var q = ConFilterQuery()
        q.urlFilter = "app.js"
        XCTAssertTrue(OrbitConsoleLogic.matches(text: "https://host/app.js", query: q))
        XCTAssertFalse(OrbitConsoleLogic.matches(text: "other.js", query: q))
    }

    // MARK: - Repeat grouping

    func test_repeatKey_log_returns_key() {
        let key = OrbitConsoleLogic.repeatKey(level: .log, plainText: "hello")
        XCTAssertNotNil(key)
        XCTAssertEqual(key, OrbitConsoleLogic.repeatKey(level: .log, plainText: "hello"))
    }

    func test_repeatKey_navigation_returns_nil() {
        XCTAssertNil(OrbitConsoleLogic.repeatKey(level: .navigation, plainText: "x"))
    }

    func test_repeatKey_command_returns_nil() {
        XCTAssertNil(OrbitConsoleLogic.repeatKey(level: .command, plainText: "x"))
    }

    func test_repeatKey_diffLevels_notEqual() {
        let k1 = OrbitConsoleLogic.repeatKey(level: .log, plainText: "x")
        let k2 = OrbitConsoleLogic.repeatKey(level: .error, plainText: "x")
        XCTAssertNotNil(k1)
        XCTAssertNotNil(k2)
        XCTAssertNotEqual(k1, k2)
    }

    func test_repeatKey_diffText_notEqual() {
        let k1 = OrbitConsoleLogic.repeatKey(level: .log, plainText: "a")
        let k2 = OrbitConsoleLogic.repeatKey(level: .log, plainText: "b")
        XCTAssertNotEqual(k1, k2)
    }

    // MARK: - History navigation

    func test_history_push_and_up() {
        var h = ConHistory()
        h.push("cmd1")
        h.push("cmd2")
        XCTAssertEqual(h.up(), "cmd2")
        XCTAssertEqual(h.up(), "cmd1")
        XCTAssertEqual(h.up(), "cmd1") // clamps at oldest
    }

    func test_history_down_past_end_returns_empty() {
        var h = ConHistory()
        h.push("cmd1")
        _ = h.up()
        XCTAssertEqual(h.down(), "")
    }

    func test_history_push_deduplicates() {
        var h = ConHistory()
        h.push("dup")
        h.push("other")
        h.push("dup")
        XCTAssertEqual(h.entries, ["other", "dup"])
    }

    func test_history_push_caps_at_200() {
        var h = ConHistory()
        for i in 0..<250 { h.push("cmd\(i)") }
        XCTAssertEqual(h.entries.count, 200)
    }

    func test_history_resetCursor() {
        var h = ConHistory()
        h.push("a"); h.push("b")
        _ = h.up()
        h.resetCursor()
        XCTAssertEqual(h.cursor, h.entries.count)
    }

    func test_history_upDown_roundtrip() {
        var h = ConHistory()
        h.push("first")
        h.push("second")
        h.push("third")
        _ = h.up() // third
        _ = h.up() // second
        let backToThird = h.down()
        XCTAssertEqual(backToThird, "third")
    }

    // MARK: - Input completeness heuristic

    func test_isInputComplete_simpleExpr() {
        XCTAssertTrue(OrbitConsoleLogic.isInputComplete("1 + 2"))
    }

    func test_isInputComplete_closedBraces() {
        XCTAssertTrue(OrbitConsoleLogic.isInputComplete("{ a: 1 }"))
    }

    func test_isInputComplete_openBrace() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("function foo() {"))
    }

    func test_isInputComplete_openParen() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("console.log("))
    }

    func test_isInputComplete_trailingDot() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("document."))
    }

    func test_isInputComplete_trailingPlus() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("1 +"))
    }

    func test_isInputComplete_trailingAnd() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("a &&"))
    }

    func test_isInputComplete_emptyString() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete(""))
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("   "))
    }

    func test_isInputComplete_openString() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("\"unclosed"))
    }

    func test_isInputComplete_unclosedBlockComment() {
        XCTAssertFalse(OrbitConsoleLogic.isInputComplete("/* comment"))
    }

    func test_isInputComplete_multilineCompleteFunction() {
        let js = "function greet(name) {\n  return 'Hello ' + name;\n}"
        XCTAssertTrue(OrbitConsoleLogic.isInputComplete(js))
    }

    func test_isInputComplete_lineComment_doesNotBlock() {
        XCTAssertTrue(OrbitConsoleLogic.isInputComplete("1 + 2 // comment"))
    }

    // MARK: - Autocomplete ranking

    func test_rankCompletions_prefixMatchFirst() {
        let candidates = ["foo", "bar", "football", "foobar"]
        let ranked = OrbitConsoleLogic.rankCompletions(candidates, prefix: "foo")
        XCTAssertTrue(ranked.first == "foo" || ranked.first == "football")
        // All "foo*" before "bar"
        XCTAssertFalse(ranked.contains("bar"))
    }

    func test_rankCompletions_emptyPrefixSortsAlpha() {
        let candidates = ["z", "a", "m"]
        let ranked = OrbitConsoleLogic.rankCompletions(candidates, prefix: "")
        XCTAssertEqual(ranked, ["a", "m", "z"])
    }

    func test_rankCompletions_exactMatchFirst() {
        let candidates = ["foo", "foobar"]
        let ranked = OrbitConsoleLogic.rankCompletions(candidates, prefix: "foo")
        XCTAssertEqual(ranked.first, "foo")
    }

    func test_rankCompletions_caseInsensitiveFilter() {
        let candidates = ["Foo", "bar", "FOO"]
        let ranked = OrbitConsoleLogic.rankCompletions(candidates, prefix: "fo")
        XCTAssertEqual(ranked.count, 2)  // "Foo" and "FOO" match
    }

    // MARK: - Copy all

    private func logEntry(_ id: String, _ args: [ConSerializedValue]) -> ConEntry {
        var entry = ConEntry.command(id: id, text: "", depth: 0)
        entry.level = .log
        entry.args = args
        entry.plainText = args.map { $0.plainText }.joined(separator: " ")
        return entry
    }

    func test_allMessagesText_oneLinePerEntryInOrder() {
        let entries = [
            logEntry("a", [.string_("first")]),
            logEntry("b", [.string_("count"), .number(3), .boolean(true)]),
            logEntry("c", [.null_]),
        ]
        XCTAssertEqual(OrbitConsoleLogic.allMessagesText(entries), "first\ncount 3 true\nnull")
    }

    func test_allMessagesText_matchesPerRowCopyFormat() {
        let entry = logEntry("a", [.string_("x"), .undefined_])
        XCTAssertEqual(OrbitConsoleLogic.allMessagesText([entry]),
                       entry.args.map { $0.plainText }.joined(separator: " "))
    }

    func test_allMessagesText_empty() {
        XCTAssertEqual(OrbitConsoleLogic.allMessagesText([]), "")
    }

    func test_jsonArrayText_empty() {
        XCTAssertEqual(OrbitConsoleLogic.jsonArrayText([]), "[]")
    }

    func test_jsonArrayText_isValidJSONAndKeepsOrder() throws {
        let text = OrbitConsoleLogic.jsonArrayText([
            .json("{\n  \"a\": 1\n}"),
            .text("plain \"quoted\" message"),
            .json("[1, 2]"),
        ])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
        )
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual((parsed[0] as? [String: Int]), ["a": 1])
        XCTAssertEqual(parsed[1] as? String, "plain \"quoted\" message")
        XCTAssertEqual((parsed[2] as? [Int]), [1, 2])
    }

    func test_jsonArrayText_unparseableJSONBecomesString() throws {
        // The page falls back to String(o), e.g. "[object Object]", when JSON.stringify throws.
        let text = OrbitConsoleLogic.jsonArrayText([.json("[object Object]")])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        XCTAssertEqual(parsed.first as? String, "[object Object]")
    }

    func test_jsonArrayText_multilineMessageStaysValid() throws {
        let text = OrbitConsoleLogic.jsonArrayText([.text("line one\nline two")])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        XCTAssertEqual(parsed.first as? String, "line one\nline two")
    }

    // MARK: - ConStackFrame helpers

    func test_stackFrame_shortURL_withLine() {
        let f = ConStackFrame(function: "fn", url: "https://host/src/App.jsx", line: 42, column: 1)
        XCTAssertEqual(f.shortURL, "App.jsx:42")
    }

    func test_stackFrame_shortURL_noLine() {
        let f = ConStackFrame(function: "", url: "https://host/bundle.js", line: 0, column: 0)
        XCTAssertEqual(f.shortURL, "bundle.js")
    }

    func test_stackFrame_displayName_anonymous() {
        let f = ConStackFrame(function: "", url: "u", line: 1, column: 1)
        XCTAssertEqual(f.displayName, "(anonymous)")
    }

    func test_stackFrame_displayName_named() {
        let f = ConStackFrame(function: "myFn", url: "u", line: 1, column: 1)
        XCTAssertEqual(f.displayName, "myFn")
    }

    // MARK: - ConLevel helpers

    func test_level_isError() {
        XCTAssertTrue(ConLevel.error.isError)
        XCTAssertTrue(ConLevel.exception.isError)
        XCTAssertTrue(ConLevel.unhandledRejection.isError)
        XCTAssertTrue(ConLevel.assert_.isError)
        XCTAssertFalse(ConLevel.warn.isError)
        XCTAssertFalse(ConLevel.log.isError)
    }

    func test_level_filterLevelMatches() {
        XCTAssertTrue(ConFilterLevel.errors.matches(.error))
        XCTAssertTrue(ConFilterLevel.errors.matches(.exception))
        XCTAssertFalse(ConFilterLevel.errors.matches(.warn))
        XCTAssertTrue(ConFilterLevel.warnings.matches(.warn))
        XCTAssertFalse(ConFilterLevel.warnings.matches(.error))
        XCTAssertTrue(ConFilterLevel.logs.matches(.log))
        XCTAssertTrue(ConFilterLevel.logs.matches(.count))
        XCTAssertTrue(ConFilterLevel.verbose.matches(.debug))
        XCTAssertTrue(ConFilterLevel.verbose.matches(.resourceError))
        XCTAssertTrue(ConFilterLevel.all.matches(.log))
        XCTAssertTrue(ConFilterLevel.all.matches(.warn))
        XCTAssertFalse(ConFilterLevel.all.matches(.navigation))
    }

    // MARK: - ConSerializedValue decode

    func test_decode_string() {
        let v = ConSerializedValue.decode(["k": "s", "v": "hello"])
        XCTAssertEqual(v, .string_("hello"))
    }

    func test_decode_number() {
        let v = ConSerializedValue.decode(["k": "n", "v": 42.0])
        XCTAssertEqual(v, .number(42))
    }

    func test_decode_numberSpecial() {
        let v = ConSerializedValue.decode(["k": "n", "s": "NaN"])
        XCTAssertEqual(v, .numberSpecial("NaN"))
    }

    func test_decode_boolean() {
        let v = ConSerializedValue.decode(["k": "b", "v": true])
        XCTAssertEqual(v, .boolean(true))
    }

    func test_decode_null() {
        XCTAssertEqual(ConSerializedValue.decode(["k": "nu"]), .null_)
    }

    func test_decode_undefined() {
        XCTAssertEqual(ConSerializedValue.decode(["k": "u"]), .undefined_)
    }

    func test_decode_unknown_returns_undefined() {
        XCTAssertEqual(ConSerializedValue.decode(["k": "???"]), .undefined_)
    }

    func test_decode_ref() {
        let v = ConSerializedValue.decode(["k": "ref", "id": 1, "preview": "{a: 1}", "cls": "Object"])
        if case .ref(let id, let preview, let cls, _) = v {
            XCTAssertEqual(id, 1)
            XCTAssertEqual(preview, "{a: 1}")
            XCTAssertEqual(cls, "Object")
        } else {
            XCTFail("Expected .ref")
        }
    }

    func test_value_preview_string() {
        let v = ConSerializedValue.string_("hello")
        XCTAssertEqual(v.preview, "\"hello\"")
    }

    func test_value_plainText_string() {
        let v = ConSerializedValue.string_("hello")
        XCTAssertEqual(v.plainText, "hello")
    }

    func test_value_registryId_primitive_isNil() {
        XCTAssertNil(ConSerializedValue.string_("x").registryId)
        XCTAssertNil(ConSerializedValue.number(1).registryId)
        XCTAssertNil(ConSerializedValue.null_.registryId)
    }

    func test_value_registryId_ref_notNil() {
        let v = ConSerializedValue.ref(id: 5, preview: "", cls: "Object", length: nil)
        XCTAssertEqual(v.registryId, 5)
    }

    // MARK: - Log storage (OrbitRingBuffer<ConEntry>)

    func test_entryLog_trimsToCapacityKeepingTheNewestInOrder() {
        var log = OrbitRingBuffer<ConEntry>(capacity: 5000)
        for n in 0..<5003 { log.append(ConEntry.command(id: "c\(n)", text: "cmd \(n)", depth: 0)) }
        XCTAssertEqual(log.count, 5000)
        XCTAssertEqual(log.first?.id, "c3", "the three oldest entries were dropped")
        XCTAssertEqual(log.last?.id, "c5002")
        XCTAssertEqual(log.map(\.id), (3..<5003).map { "c\($0)" })
    }

    func test_entryLog_repeatCountBumpOnTheNewestEntryPersists() {
        var log = OrbitRingBuffer<ConEntry>(capacity: 3)
        for n in 0..<5 { log.append(ConEntry.navigation(id: "n\(n)", url: "https://example.com/\(n)")) }
        // The model folds a repeated message into the last entry by position.
        log[log.count - 1].repeatCount += 1
        XCTAssertEqual(log.last?.repeatCount, 2)
        XCTAssertEqual(log.dropLast().map(\.repeatCount), [1, 1])
    }

    func test_entryLog_filterKeepsLogOrderAfterWrap() {
        var log = OrbitRingBuffer<ConEntry>(capacity: 4)
        for n in 0..<7 {
            log.append(n % 2 == 0
                ? ConEntry.command(id: "c\(n)", text: "x", depth: 0)
                : ConEntry.navigation(id: "n\(n)", url: "u"))
        }
        // Holds n3, c4, n5, c6.
        XCTAssertEqual(log.filter { ConFilterLevel.logs.matches($0.level) }.map(\.id), ["c4", "c6"])
    }

    func test_filterLevelCounts_matchPerLevelScan() {
        let levels: [ConLevel] = [
            .log, .info, .warn, .error, .exception, .debug, .resourceError, .navigation, .command,
        ]
        let entries = levels.enumerated().map { index, level -> ConEntry in
            var entry = ConEntry.command(id: "e\(index)", text: "x", depth: 0)
            entry.level = level
            return entry
        }

        let counts = OrbitConsoleLogic.levelCounts(of: entries)

        XCTAssertEqual(
            counts,
            [.all: 9, .errors: 2, .warnings: 1, .info: 1, .logs: 2, .verbose: 2],
            "All counts every entry including the navigation separator; errors are error+exception; logs are log+command; verbose is debug+resourceError"
        )
    }

    func test_filterLevelCounts_emptyLogHasOnlyTheAllChip() {
        XCTAssertEqual(OrbitConsoleLogic.levelCounts(of: [ConEntry]()), [.all: 0])
    }

    // MARK: - Hostile numbers from the page

    /// JSON allows any double; a page can post 1e300 for any integer field. Decoding must clamp, never trap.
    func test_integerDecode_clampsOutOfRangeAndNonFiniteValues() {
        XCTAssertEqual(OrbitInspectDecode.integer(["v": 1e300], "v"), Int.max)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": -1e300], "v"), Int.min)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": Double.nan], "v"), 0)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": Double.infinity], "v"), Int.max)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": NSNumber(value: 1e300)], "v"), Int.max)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": 2.6], "v"), 3)
        XCTAssertEqual(OrbitInspectDecode.integer(["v": "12"], "v"), 0)
        XCTAssertEqual(Int(clamping: 9.3e18), Int.max)
        XCTAssertEqual(Int(clamping: -9.3e18), Int.min)
        // Decoded from a real JSON string, the way page messages arrive.
        let parsed = try? JSONSerialization.jsonObject(with: Data(#"{"t":"hello","version":1e300}"#.utf8)) as? [String: Any]
        XCTAssertEqual(OrbitInspectDecode.integer(parsed ?? [:], "version"), Int.max)
    }

    func test_refLengthDecode_clampsHostileLength() {
        let value = ConSerializedValue.decode(["k": "ref", "id": 1, "len": 1e300, "preview": "x", "cls": "Array"])
        guard case .ref(_, _, _, let length) = value else { return XCTFail("expected a ref, got \(value)") }
        XCTAssertEqual(length, Int.max)
    }

    /// A bare string at the top level makes JSONSerialization raise an exception `try?` cannot catch.
    func test_jsonLiteral_wrapsAnyValueSafely() {
        XCTAssertEqual(OrbitInspectDecode.jsonLiteral("a\"b"), #""a\"b""#)
        XCTAssertEqual(OrbitInspectDecode.jsonLiteral(["x", "y"]), #"["x","y"]"#)
        XCTAssertEqual(OrbitInspectDecode.jsonLiteral(3), "3")
        XCTAssertNil(OrbitInspectDecode.jsonLiteral(Double.nan))
    }
}
