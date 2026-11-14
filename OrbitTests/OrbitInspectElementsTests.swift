// Unit tests for OrbitElementsLogic, compiled directly with OrbitInspectElementsLogic.swift and OrbitInspectDecode.swift (no app import).

import XCTest

final class OrbitInspectElementsTests: XCTestCase {

    // MARK: Specificity

    func testSpecificityID() {
        let s = OrbitElementsLogic.specificity(for: "#foo")
        XCTAssertEqual(s[0], 1, "one ID")
        XCTAssertEqual(s[1], 0)
        XCTAssertEqual(s[2], 0)
    }

    func testSpecificityClass() {
        let s = OrbitElementsLogic.specificity(for: ".bar")
        XCTAssertEqual(s[0], 0)
        XCTAssertEqual(s[1], 1, "one class")
        XCTAssertEqual(s[2], 0)
    }

    func testSpecificityElement() {
        let s = OrbitElementsLogic.specificity(for: "div")
        XCTAssertEqual(s[0], 0)
        XCTAssertEqual(s[1], 0)
        XCTAssertEqual(s[2], 1, "one element")
    }

    func testSpecificityCombined() {
        // #main .nav > a  -> [1, 1, 1]
        let s = OrbitElementsLogic.specificity(for: "#main .nav > a")
        XCTAssertEqual(s[0], 1, "one ID")
        XCTAssertEqual(s[1], 1, "one class")
        XCTAssertEqual(s[2], 1, "one element")
    }

    func testCompareSpecificity() {
        XCTAssertGreaterThan(
            OrbitElementsLogic.compareSpecificity([1, 0, 0], [0, 1, 0]),
            0, "#id beats .class"
        )
        XCTAssertLessThan(
            OrbitElementsLogic.compareSpecificity([0, 1, 0], [1, 0, 0]),
            0
        )
        XCTAssertEqual(
            OrbitElementsLogic.compareSpecificity([0, 2, 1], [0, 2, 1]),
            0
        )
    }

    // MARK: Color Parsing

    func testParseRGBHex6() {
        let c = OrbitElementsLogic.parseRGBA("#FF0000")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 255, accuracy: 0.1)
        XCTAssertEqual(c!.g, 0,   accuracy: 0.1)
        XCTAssertEqual(c!.b, 0,   accuracy: 0.1)
        XCTAssertEqual(c!.a, 1.0, accuracy: 0.01)
    }

    func testParseHex3() {
        let c = OrbitElementsLogic.parseRGBA("#F00")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 255, accuracy: 1)
        XCTAssertEqual(c!.g, 0,   accuracy: 1)
        XCTAssertEqual(c!.b, 0,   accuracy: 1)
    }

    func testParseRGBFunction() {
        let c = OrbitElementsLogic.parseRGBA("rgb(128, 64, 32)")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 128, accuracy: 0.1)
        XCTAssertEqual(c!.g, 64,  accuracy: 0.1)
        XCTAssertEqual(c!.b, 32,  accuracy: 0.1)
    }

    func testParseRGBAFunction() {
        let c = OrbitElementsLogic.parseRGBA("rgba(0, 0, 0, 0.5)")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.a, 0.5, accuracy: 0.01)
    }

    func testParseHSL() {
        // hsl(0, 100%, 50%) = pure red
        let c = OrbitElementsLogic.parseRGBA("hsl(0, 100%, 50%)")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 255, accuracy: 2)
        XCTAssertEqual(c!.g, 0,   accuracy: 2)
        XCTAssertEqual(c!.b, 0,   accuracy: 2)
    }

    func testParseNamedColor() {
        let c = OrbitElementsLogic.parseRGBA("red")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 255, accuracy: 0.1)
    }

    func testParseTransparent() {
        let c = OrbitElementsLogic.parseRGBA("transparent")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.a, 0, accuracy: 0.01)
    }

    func testParseInvalid() {
        XCTAssertNil(OrbitElementsLogic.parseRGBA("notacolor"))
        XCTAssertNil(OrbitElementsLogic.parseRGBA(""))
        XCTAssertNil(OrbitElementsLogic.parseRGBA("10px"))
    }

    func testFormatHexOpaque() {
        let hex = OrbitElementsLogic.formatHex(.init(r: 255, g: 0, b: 0, a: 1))
        XCTAssertEqual(hex, "#FF0000")
    }

    func testFormatHexAlpha() {
        let hex = OrbitElementsLogic.formatHex(.init(r: 255, g: 0, b: 0, a: 0.5))
        XCTAssertTrue(hex.hasPrefix("#FF0000"), "should start with #FF0000, got \(hex)")
        XCTAssertEqual(hex.count, 9, "8 hex digits + #, got \(hex)")
    }

    func testContrastRatioBlackWhite() {
        let white = OrbitElementsLogic.relativeLuminance(.init(r: 255, g: 255, b: 255, a: 1))
        let black = OrbitElementsLogic.relativeLuminance(.init(r: 0,   g: 0,   b: 0,   a: 1))
        let cr = OrbitElementsLogic.contrastRatio(white, black)
        XCTAssertEqual(cr, 21.0, accuracy: 0.1, "black/white contrast is 21:1")
    }

    func testContrastRatioSameColor() {
        let lum = OrbitElementsLogic.relativeLuminance(.init(r: 128, g: 0, b: 0, a: 1))
        let cr = OrbitElementsLogic.contrastRatio(lum, lum)
        XCTAssertEqual(cr, 1.0, accuracy: 0.01, "identical colors have contrast ratio 1")
    }

    func testIsColorValue() {
        XCTAssertTrue(OrbitElementsLogic.isColorValue("#FF0000"))
        XCTAssertTrue(OrbitElementsLogic.isColorValue("rgb(0,0,0)"))
        XCTAssertTrue(OrbitElementsLogic.isColorValue("rgba(0,0,0,1)"))
        XCTAssertTrue(OrbitElementsLogic.isColorValue("hsl(0,100%,50%)"))
        XCTAssertTrue(OrbitElementsLogic.isColorValue("red"))
        XCTAssertFalse(OrbitElementsLogic.isColorValue("10px"))
        XCTAssertFalse(OrbitElementsLogic.isColorValue("bold"))
        XCTAssertFalse(OrbitElementsLogic.isColorValue("flex"))
    }

    // MARK: CSS Value Increment

    func testIncrementPx() {
        XCTAssertEqual(OrbitElementsLogic.incrementValue("10px", by: 1),  "11px")
        XCTAssertEqual(OrbitElementsLogic.incrementValue("10px", by: -1), "9px")
        XCTAssertEqual(OrbitElementsLogic.incrementValue("10px", by: 10), "20px")
    }

    func testIncrementDecimal() {
        let result = OrbitElementsLogic.incrementValue("1.5em", by: 0.1)
        // 1.5 + 0.1 = 1.6, formatted to 1 decimal place
        XCTAssertTrue(result.contains("1.6"), "expected 1.6em, got \(result)")
    }

    func testIncrementNegative() {
        XCTAssertEqual(OrbitElementsLogic.incrementValue("-5px", by: 1), "-4px")
    }

    func testIncrementNoNumber() {
        XCTAssertEqual(OrbitElementsLogic.incrementValue("auto", by: 1), "auto")
    }

    func testIncrementPercent() {
        XCTAssertEqual(OrbitElementsLogic.incrementValue("50%", by: 5), "55%")
    }

    // MARK: camelToKebab

    func testCamelToKebab() {
        XCTAssertEqual(OrbitElementsLogic.camelToKebab("backgroundColor"), "background-color")
        XCTAssertEqual(OrbitElementsLogic.camelToKebab("borderTopWidth"),  "border-top-width")
        XCTAssertEqual(OrbitElementsLogic.camelToKebab("color"),           "color")
        XCTAssertEqual(OrbitElementsLogic.camelToKebab("zIndex"),          "z-index")
        XCTAssertEqual(OrbitElementsLogic.camelToKebab("fontSize"),        "font-size")
    }

    // MARK: Tree Flattening

    func testFlattenEmpty() {
        let rows = OrbitElementsLogic.flattenTree(rootIDs: [], nodes: [:], children: [:], expanded: [])
        XCTAssertTrue(rows.isEmpty)
    }

    func testFlattenSingleCollapsedWithChildren() {
        let html = ElNodeInfo(id: 1, kind: "el", name: "html", attrs: [:], childCount: 2, text: "")
        let rows = OrbitElementsLogic.flattenTree(
            rootIDs: [1],
            nodes: [1: html],
            children: [:],
            expanded: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isExpanded)
        XCTAssertTrue(rows[0].hasChildren)
    }

    func testFlattenExpandedTwoChildren() {
        let html = ElNodeInfo(id: 1, kind: "el", name: "html", attrs: [:], childCount: 2, text: "")
        let head = ElNodeInfo(id: 2, kind: "el", name: "head", attrs: [:], childCount: 0, text: "")
        let body = ElNodeInfo(id: 3, kind: "el", name: "body", attrs: [:], childCount: 0, text: "")
        let rows = OrbitElementsLogic.flattenTree(
            rootIDs: [1],
            nodes: [1: html, 2: head, 3: body],
            children: [1: [2, 3]],
            expanded: [1]
        )
        // html-open, head, body, html-close
        XCTAssertEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isClosingTag, "first row is opening html")
        XCTAssertEqual(rows[0].nodeID, 1)
        XCTAssertEqual(rows[1].nodeID, 2, "head")
        XCTAssertEqual(rows[2].nodeID, 3, "body")
        XCTAssertTrue(rows[3].isClosingTag, "last is closing html")
        XCTAssertEqual(rows[3].nodeID, 1)
    }

    func testFlattenDepthIsCorrect() {
        let a = ElNodeInfo(id: 1, kind: "el", name: "a", attrs: [:], childCount: 1, text: "")
        let b = ElNodeInfo(id: 2, kind: "el", name: "b", attrs: [:], childCount: 1, text: "")
        let c = ElNodeInfo(id: 3, kind: "el", name: "c", attrs: [:], childCount: 0, text: "")
        let rows = OrbitElementsLogic.flattenTree(
            rootIDs: [1],
            nodes: [1: a, 2: b, 3: c],
            children: [1: [2], 2: [3]],
            expanded: [1, 2]
        )
        // a-open(0), b-open(1), c(2), b-close(1), a-close(0)
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
    }

    func testFlattenTextNodeHasNoClosingTag() {
        let div  = ElNodeInfo(id: 1, kind: "el",   name: "div",   attrs: [:], childCount: 1, text: "")
        let text = ElNodeInfo(id: 2, kind: "text",  name: "#text", attrs: [:], childCount: 0, text: "hello")
        let rows = OrbitElementsLogic.flattenTree(
            rootIDs: [1],
            nodes: [1: div, 2: text],
            children: [1: [2]],
            expanded: [1]
        )
        // div-open, text, div-close
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows[1].isClosingTag, "text node row is not a closing tag")
    }

    // MARK: Search Matching

    func testSearchByTagText() {
        let node = ElNodeInfo(id: 1, kind: "el", name: "div", attrs: [:], childCount: 0, text: "")
        XCTAssertTrue(OrbitElementsLogic.matchesSearch(node, query: "div", mode: .text))
        XCTAssertFalse(OrbitElementsLogic.matchesSearch(node, query: "span", mode: .text))
    }

    func testSearchByAttr() {
        let node = ElNodeInfo(id: 1, kind: "el", name: "div",
                              attrs: ["class": "hero-section"], childCount: 0, text: "")
        XCTAssertTrue(OrbitElementsLogic.matchesSearch(node, query: "hero", mode: .text))
    }

    func testSearchByTextContent() {
        let node = ElNodeInfo(id: 1, kind: "text", name: "#text",
                              attrs: [:], childCount: 0, text: "hello world")
        XCTAssertTrue(OrbitElementsLogic.matchesSearch(node, query: "hello", mode: .text))
        XCTAssertFalse(OrbitElementsLogic.matchesSearch(node, query: "goodbye", mode: .text))
    }

    func testSearchByCSSId() {
        let node = ElNodeInfo(id: 1, kind: "el", name: "div",
                              attrs: ["id": "main"], childCount: 0, text: "")
        XCTAssertTrue(OrbitElementsLogic.matchesSearch(node, query: "#main", mode: .selector))
        XCTAssertFalse(OrbitElementsLogic.matchesSearch(node, query: "#other", mode: .selector))
    }

    func testSearchByCSSClass() {
        let node = ElNodeInfo(id: 1, kind: "el", name: "p",
                              attrs: ["class": "lead text-muted"], childCount: 0, text: "")
        XCTAssertTrue(OrbitElementsLogic.matchesSearch(node, query: ".lead", mode: .selector))
        XCTAssertFalse(OrbitElementsLogic.matchesSearch(node, query: ".missing", mode: .selector))
    }

    func testEmptyQueryReturnsFalse() {
        let node = ElNodeInfo(id: 1, kind: "el", name: "div", attrs: [:], childCount: 0, text: "")
        XCTAssertFalse(OrbitElementsLogic.matchesSearch(node, query: "", mode: .text))
    }

    // MARK: Path Selectors

    func testCssSelectorPrefersID() {
        let path = [ElNodeInfo(id: 1, kind: "el", name: "div",
                               attrs: ["id": "hero", "class": "section"],
                               childCount: 0, text: "")]
        XCTAssertEqual(OrbitElementsLogic.cssSelector(for: path), "#hero")
    }

    func testCssSelectorFallsToTagClass() {
        let path = [ElNodeInfo(id: 1, kind: "el", name: "p",
                               attrs: ["class": "lead"],
                               childCount: 0, text: "")]
        let sel = OrbitElementsLogic.cssSelector(for: path)
        XCTAssertTrue(sel.contains("p"), "should contain tag name")
        XCTAssertTrue(sel.contains("lead"), "should contain class")
    }

    func testXpathGeneration() {
        let path: [ElNodeInfo] = [
            .init(id: 1, kind: "el", name: "html", attrs: [:], childCount: 1, text: ""),
            .init(id: 2, kind: "el", name: "body", attrs: [:], childCount: 1, text: ""),
            .init(id: 3, kind: "el", name: "div",  attrs: [:], childCount: 0, text: ""),
        ]
        let xpath = OrbitElementsLogic.xpath(for: path)
        XCTAssertTrue(xpath.contains("html"), "xpath should contain html")
        XCTAssertTrue(xpath.contains("body"), "xpath should contain body")
        XCTAssertTrue(xpath.contains("div"),  "xpath should contain div")
        XCTAssertTrue(xpath.hasPrefix("/"),   "xpath should start with /")
    }

    // MARK: Edit history (undo / redo)

    func testHistoryUndoThenRedoReplaysInOrder() {
        var history = ElEditHistory()
        history.push(ElEditRecord(entry: 1, label: "Edit style"))
        history.push(ElEditRecord(entry: 2, label: "Move node"))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoLabel, "Move node")

        XCTAssertEqual(history.undo()?.entry, 2, "undo takes the newest edit first")
        XCTAssertEqual(history.undo()?.entry, 1)
        XCTAssertNil(history.undo(), "nothing left to undo")
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redoLabel, "Edit style")

        XCTAssertEqual(history.redo()?.entry, 1, "redo replays the oldest undone edit first")
        XCTAssertEqual(history.redo()?.entry, 2)
        XCTAssertNil(history.redo())
        XCTAssertFalse(history.canRedo)
    }

    func testHistoryNewEditClearsRedoAndReportsForgottenEntries() {
        var history = ElEditHistory()
        history.push(ElEditRecord(entry: 1, label: "a"))
        history.push(ElEditRecord(entry: 2, label: "b"))
        _ = history.undo()
        _ = history.undo()
        XCTAssertEqual(history.redoStack.map(\.entry), [2, 1])

        let forgotten = history.push(ElEditRecord(entry: 3, label: "c"))
        XCTAssertEqual(Set(forgotten), [1, 2], "the page can drop the inverses of edits that can no longer be redone")
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoStack.map(\.entry), [3])
    }

    func testHistoryCapacityDropsTheOldestEdits() {
        var history = ElEditHistory()
        var forgotten: [Int] = []
        for n in 1...(ElEditHistory.capacity + 3) {
            forgotten += history.push(ElEditRecord(entry: n, label: "e\(n)"))
        }
        XCTAssertEqual(history.undoStack.count, ElEditHistory.capacity)
        XCTAssertEqual(history.undoStack.first?.entry, 4, "the three oldest fell off")
        XCTAssertEqual(forgotten, [1, 2, 3])
        XCTAssertEqual(history.undoStack.last?.entry, ElEditHistory.capacity + 3)
    }

    func testHistoryDiscardRemovesAFailedEntryFromBothStacks() {
        var history = ElEditHistory()
        history.push(ElEditRecord(entry: 1, label: "a"))
        history.push(ElEditRecord(entry: 2, label: "b"))
        _ = history.undo()          // entry 2 is now redoable
        history.discard(entry: 2)
        XCTAssertFalse(history.canRedo)
        history.discard(entry: 1)
        XCTAssertFalse(history.canUndo)
    }

    func testHistoryClearReturnsEveryEntry() {
        var history = ElEditHistory()
        history.push(ElEditRecord(entry: 1, label: "a"))
        history.push(ElEditRecord(entry: 2, label: "b"))
        _ = history.undo()
        XCTAssertEqual(Set(history.clear()), [1, 2])
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testUndoRedoDiscardCommandArguments() {
        let undo = OrbitElementsLogic.undoCommand(entry: 7)
        XCTAssertEqual(undo["op"] as? String, "el.undo")
        XCTAssertEqual(undo["entry"] as? Int, 7)
        XCTAssertEqual(OrbitElementsLogic.redoCommand(entry: 7)["op"] as? String, "el.redo")
        let discard = OrbitElementsLogic.discardCommand(entries: [1, 2])
        XCTAssertEqual(discard["op"] as? String, "el.discard")
        XCTAssertEqual(discard["entries"] as? [Int], [1, 2])
    }

    // MARK: Edit commands

    func testRenameCommandNormalizesAndValidates() throws {
        let command = try XCTUnwrap(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "  SECTION "))
        XCTAssertEqual(command["op"] as? String, "el.rename")
        XCTAssertEqual(command["id"] as? Int, 4)
        XCTAssertEqual(command["name"] as? String, "section", "tag names are lowercased and trimmed")

        XCTAssertNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "DIV"), "same name in another case is not a rename")
        XCTAssertNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: ""))
        XCTAssertNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "1abc"))
        XCTAssertNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "a b"))
        XCTAssertNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "<script>"))
        XCTAssertNotNil(OrbitElementsLogic.renameCommand(id: 4, from: "div", to: "my-widget"), "custom element names are valid")
    }

    func testIsValidTagName() {
        XCTAssertTrue(OrbitElementsLogic.isValidTagName("h1"))
        XCTAssertTrue(OrbitElementsLogic.isValidTagName("x-foo.bar"))
        XCTAssertFalse(OrbitElementsLogic.isValidTagName("-x"))
        XCTAssertFalse(OrbitElementsLogic.isValidTagName(""))
        XCTAssertFalse(OrbitElementsLogic.isValidTagName("é"))
    }

    func testEditHTMLCommandSkipsUnchangedAndBlankMarkup() throws {
        XCTAssertNil(OrbitElementsLogic.editHTMLCommand(id: 2, original: "<p>a</p>", edited: "<p>a</p>"))
        XCTAssertNil(OrbitElementsLogic.editHTMLCommand(id: 2, original: "<p>a</p>", edited: "  \n "),
                     "blank markup would silently delete the element")
        let command = try XCTUnwrap(OrbitElementsLogic.editHTMLCommand(id: 2, original: "<p>a</p>", edited: "<p>b</p>"))
        XCTAssertEqual(command["op"] as? String, "el.editHTML")
        XCTAssertEqual(command["id"] as? Int, 2)
        XCTAssertEqual(command["html"] as? String, "<p>b</p>")
    }

    func testEditTextCommandSkipsUnchangedText() throws {
        XCTAssertNil(OrbitElementsLogic.editTextCommand(id: 9, original: "hi", edited: "hi"))
        let command = try XCTUnwrap(OrbitElementsLogic.editTextCommand(id: 9, original: "hi", edited: "hello"))
        XCTAssertEqual(command["op"] as? String, "el.editText")
        XCTAssertEqual(command["text"] as? String, "hello")
        XCTAssertNotNil(OrbitElementsLogic.editTextCommand(id: 9, original: "hi", edited: ""), "clearing text is a real edit")
    }

    func testLayoutOverlayCommandArguments() {
        let on = OrbitElementsLogic.layoutOverlayCommand(id: 5, kind: .grid, on: true)
        XCTAssertEqual(on["op"] as? String, "el.layoutOverlay")
        XCTAssertEqual(on["kind"] as? String, "grid")
        XCTAssertEqual(on["on"] as? Bool, true)
        XCTAssertEqual(OrbitElementsLogic.layoutOverlayCommand(id: 5, kind: .flex, on: false)["on"] as? Bool, false)
    }

    func testLayoutKindFromDisplay() {
        XCTAssertEqual(ElLayoutKind(display: "flex"), .flex)
        XCTAssertEqual(ElLayoutKind(display: "inline-flex"), .flex)
        XCTAssertEqual(ElLayoutKind(display: " Grid "), .grid)
        XCTAssertEqual(ElLayoutKind(display: "inline-grid"), .grid)
        XCTAssertNil(ElLayoutKind(display: "block"))
        XCTAssertNil(ElLayoutKind(display: "contents"))
    }

    // MARK: Drag and drop

    /// html(1) > body(2) > [header(3), main(4) > [p(5), text(6)], footer(7)]; head(8) under html.
    private func sampleTree() -> (nodes: [Int: ElNodeInfo], children: [Int: [Int]], parents: [Int: Int]) {
        func el(_ id: Int, _ name: String, kids: Int = 0) -> ElNodeInfo {
            ElNodeInfo(id: id, kind: "el", name: name, attrs: [:], childCount: kids, text: "")
        }
        let nodes: [Int: ElNodeInfo] = [
            1: el(1, "html", kids: 2), 8: el(8, "head"), 2: el(2, "body", kids: 3),
            3: el(3, "header"), 4: el(4, "main", kids: 2), 5: el(5, "p"),
            6: ElNodeInfo(id: 6, kind: "text", name: "#text", attrs: [:], childCount: 0, text: "hi"),
            7: el(7, "footer"),
        ]
        let children: [Int: [Int]] = [1: [8, 2], 2: [3, 4, 7], 4: [5, 6]]
        return (nodes, children, OrbitElementsLogic.parentMap(children: children))
    }

    private func place(
        moving: Int, onto target: Int, _ position: ElDropPosition, closing: Bool = false,
        truncated: Set<Int> = []
    ) -> ElDropPlacement? {
        let tree = sampleTree()
        return OrbitElementsLogic.dropPlacement(
            moving: moving, target: target, isClosingTag: closing, position: position,
            nodes: tree.nodes, children: tree.children, parents: tree.parents, truncatedParents: truncated)
    }

    func testParentMapLinksEveryChild() {
        let parents = sampleTree().parents
        XCTAssertEqual(parents[5], 4)
        XCTAssertEqual(parents[4], 2)
        XCTAssertEqual(parents[2], 1)
        XCTAssertNil(parents[1], "the root has no parent")
    }

    func testDropBeforeASiblingInsertsAheadOfIt() {
        XCTAssertEqual(place(moving: 7, onto: 3, .before), ElDropPlacement(parentID: 2, beforeID: 3))
    }

    func testDropAfterASiblingInsertsBeforeTheNextOne() {
        // Move footer(7) after header(3): it lands before main(4).
        XCTAssertEqual(place(moving: 7, onto: 3, .after), ElDropPlacement(parentID: 2, beforeID: 4))
    }

    func testDropAfterTheLastSiblingAppends() {
        XCTAssertEqual(place(moving: 3, onto: 7, .after), ElDropPlacement(parentID: 2, beforeID: nil))
    }

    func testDropInsideAnElementAppendsAsLastChild() {
        XCTAssertEqual(place(moving: 7, onto: 4, .inside), ElDropPlacement(parentID: 4, beforeID: nil))
    }

    func testDropAfterAnExpandedParentMeansFirstChild() {
        // main(4) has loaded children, so "after" its row is "before its first child" (p, id 5).
        XCTAssertEqual(place(moving: 7, onto: 4, .after), ElDropPlacement(parentID: 4, beforeID: 5))
    }

    func testDropOnClosingTagAboveAppendsInsideAndBelowGoesAfter() {
        XCTAssertEqual(place(moving: 7, onto: 4, .before, closing: true), ElDropPlacement(parentID: 4, beforeID: nil))
        XCTAssertEqual(place(moving: 3, onto: 4, .after, closing: true), ElDropPlacement(parentID: 2, beforeID: 7))
    }

    func testDropIntoOwnSubtreeIsRejected() {
        XCTAssertNil(place(moving: 4, onto: 5, .inside), "main cannot move into its own child, p")
        XCTAssertNil(place(moving: 2, onto: 4, .inside), "body cannot move into its own descendant")
        XCTAssertNil(place(moving: 4, onto: 4, .inside), "a node cannot move into itself")
    }

    func testDropOntoTheRootNeighbourhoodIsRejected() {
        XCTAssertNil(place(moving: 3, onto: 1, .before), "nothing can go before the root")
        XCTAssertNil(place(moving: 3, onto: 1, .after, closing: true), "nothing can go after the root")
    }

    func testDropWhereTheNodeAlreadyIsIsRejected() {
        XCTAssertNil(place(moving: 3, onto: 3, .before), "before itself")
        XCTAssertNil(place(moving: 3, onto: 4, .before), "already directly before main")
        XCTAssertNil(place(moving: 7, onto: 4, .after, closing: true), "already last under body")
    }

    func testDropInsideATextNodeIsRejected() {
        XCTAssertNil(place(moving: 7, onto: 6, .inside), "text nodes cannot have children")
    }

    func testDropAppendIntoAPartlyLoadedParentIsRejected() {
        XCTAssertNil(place(moving: 7, onto: 4, .inside, truncated: [4]),
                     "appending would land after children the tree has not loaded yet")
    }

    func testOnlyElementsTextAndCommentsCanBeDragged() {
        let tree = sampleTree()
        XCTAssertTrue(OrbitElementsLogic.canDrag(nodeID: 5, nodes: tree.nodes, parents: tree.parents))
        XCTAssertTrue(OrbitElementsLogic.canDrag(nodeID: 6, nodes: tree.nodes, parents: tree.parents))
        XCTAssertFalse(OrbitElementsLogic.canDrag(nodeID: 1, nodes: tree.nodes, parents: tree.parents), "the root")
        XCTAssertFalse(OrbitElementsLogic.canDrag(nodeID: 99, nodes: tree.nodes, parents: tree.parents))
    }

    func testDropZonesSplitRowsByWhatTheyCanContain() {
        XCTAssertEqual(ElDropPosition.zone(fraction: 0.1, canContainChildren: true), .before)
        XCTAssertEqual(ElDropPosition.zone(fraction: 0.5, canContainChildren: true), .inside)
        XCTAssertEqual(ElDropPosition.zone(fraction: 0.9, canContainChildren: true), .after)
        XCTAssertEqual(ElDropPosition.zone(fraction: 0.4, canContainChildren: false), .before)
        XCTAssertEqual(ElDropPosition.zone(fraction: 0.6, canContainChildren: false), .after)
        XCTAssertEqual(ElDropPosition.zone(fraction: -3, canContainChildren: true), .before, "out-of-range pointer clamps")
    }

    func testMoveCommandArguments() {
        let withAnchor = OrbitElementsLogic.moveCommand(id: 7, placement: ElDropPlacement(parentID: 2, beforeID: 3))
        XCTAssertEqual(withAnchor["op"] as? String, "el.move")
        XCTAssertEqual(withAnchor["id"] as? Int, 7)
        XCTAssertEqual(withAnchor["parentId"] as? Int, 2)
        XCTAssertEqual(withAnchor["beforeId"] as? Int, 3)

        let appended = OrbitElementsLogic.moveCommand(id: 7, placement: ElDropPlacement(parentID: 2, beforeID: nil))
        XCTAssertNil(appended["beforeId"], "no anchor means append")
    }

    // MARK: HTML syntax tokens

    private func tokens(_ source: String) -> [(String, OrbitElementsLogic.HTMLTokenKind)] {
        let units = Array(source.utf16)
        return OrbitElementsLogic.htmlTokens(source).map { token in
            (String(decoding: units[token.range], as: UTF16.self), token.kind)
        }
    }

    func testHTMLTokensForAnElementWithAnAttribute() {
        let result = tokens(#"<div class="a">hi</div>"#)
        XCTAssertEqual(result.map(\.0), ["<", "div", "class", "=", "\"a\"", ">", "</", "div", ">"])
        XCTAssertEqual(result.map(\.1), [
            .punctuation, .tagName, .attributeName, .punctuation, .attributeValue, .punctuation,
            .punctuation, .tagName, .punctuation,
        ])
    }

    func testHTMLTokensLeaveTextBetweenTagsUnmarked() {
        let text = tokens("<b>bold</b>").map(\.0)
        XCTAssertFalse(text.contains("bold"))
    }

    func testHTMLTokensHandleCommentsDoctypeAndUnquotedValues() {
        XCTAssertEqual(tokens("<!-- note -->").first?.1, .comment)
        XCTAssertEqual(tokens("<!-- note -->").first?.0, "<!-- note -->")
        XCTAssertEqual(tokens("<!DOCTYPE html>").first?.1, .doctype)
        let unquoted = tokens("<input type=text disabled>")
        XCTAssertTrue(unquoted.contains { $0.0 == "text" && $0.1 == .attributeValue })
        XCTAssertTrue(unquoted.contains { $0.0 == "disabled" && $0.1 == .attributeName })
    }

    func testHTMLTokensAreForgivingAboutUnfinishedMarkup() {
        let unterminated = tokens(#"<a href="x"#)
        XCTAssertEqual(unterminated.map(\.0), ["<", "a", "href", "=", "\"x"])
        XCTAssertEqual(tokens("<!-- never closed").first?.0, "<!-- never closed")
        XCTAssertTrue(tokens("a < b and c > d").isEmpty, "a bare less-than is text, not a tag")
    }

    func testHTMLTokensSkipScriptAndStyleBodies() {
        let result = tokens("<script>if (a<b) { x = \"<i>\" }</script><p>")
        let names = result.filter { $0.1 == .tagName }.map(\.0)
        XCTAssertEqual(names, ["script", "script", "p"], "markup-looking text inside a script is not tokenized")
    }

    func testHTMLTokenRangesAreUTF16OffsetsSoTheyMapOntoNSRange() {
        // The emoji is two UTF-16 units; the tag after it must start at offset 3.
        let source = "😀<b>"
        let tokenList = OrbitElementsLogic.htmlTokens(source)
        XCTAssertEqual(tokenList.first?.range, 2..<3)
        XCTAssertEqual(tokenList.dropFirst().first?.range, 3..<4)
    }
}
