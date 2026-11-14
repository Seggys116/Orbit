// Foundation-only (no AppKit, SwiftUI or WebKit): compiled into both the app and the unit-test bundle with OrbitInspectDecode.swift.

import Foundation

struct ElNodeInfo: Identifiable, Equatable, Hashable {
    var id: Int
    var kind: String
    var name: String
    var attrs: [String: String]
    /// Taken from `childNodes.length`, so it can exceed the number of visible children.
    var childCount: Int
    var text: String
}

struct ElFlatRow: Identifiable, Equatable {
    struct RowID: Hashable, Equatable {
        var nodeID: Int
        var isClosingTag: Bool
    }
    var id: RowID
    var nodeID: Int
    var depth: Int
    var isExpanded: Bool
    var hasChildren: Bool
    var isClosingTag: Bool
    var node: ElNodeInfo
}


enum ElSearchMode: String, Equatable, CaseIterable {
    case text, selector, xpath
    var label: String {
        switch self {
        case .text:     return "Text"
        case .selector: return "CSS"
        case .xpath:    return "XPath"
        }
    }
}


enum OrbitElementsLogic {

    /// CSS specificity [ids, classes+attrs+pseudoClasses, elements+pseudoElements]; approximate beyond the common cases.
    static func specificity(for selector: String) -> [Int] {
        var ids = 0, classAttrs = 0, elements = 0
        var idx = selector.startIndex
        while idx < selector.endIndex {
            let c = selector[idx]
            if c == "#" {
                ids += 1
                idx = selector.index(after: idx)
                idx = skipIdent(selector, from: idx)
            } else if c == "." {
                classAttrs += 1
                idx = selector.index(after: idx)
                idx = skipIdent(selector, from: idx)
            } else if c == "[" {
                classAttrs += 1
                while idx < selector.endIndex && selector[idx] != "]" {
                    idx = selector.index(after: idx)
                }
                if idx < selector.endIndex { idx = selector.index(after: idx) }
            } else if c == ":" {
                idx = selector.index(after: idx)
                if idx < selector.endIndex && selector[idx] == ":" {
                    elements += 1
                    idx = selector.index(after: idx)
                } else {
                    classAttrs += 1
                }
                idx = skipIdent(selector, from: idx)
                if idx < selector.endIndex && selector[idx] == "(" {
                    var depth = 1; idx = selector.index(after: idx)
                    while idx < selector.endIndex && depth > 0 {
                        if selector[idx] == "(" { depth += 1 }
                        else if selector[idx] == ")" { depth -= 1 }
                        idx = selector.index(after: idx)
                    }
                }
            } else if c.isLetter || c == "_" {
                elements += 1
                idx = skipIdent(selector, from: idx)
            } else if c == "*" {
                idx = selector.index(after: idx)
            } else {
                idx = selector.index(after: idx)
            }
        }
        return [ids, classAttrs, elements]
    }

    private static func skipIdent(_ s: String, from start: String.Index) -> String.Index {
        var idx = start
        while idx < s.endIndex {
            let c = s[idx]
            guard c.isLetter || c.isNumber || c == "-" || c == "_" else { break }
            idx = s.index(after: idx)
        }
        return idx
    }

    static func compareSpecificity(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] - b[i] }
        }
        return 0
    }


    struct CSSRGBA: Equatable {
        var r: Double   // 0–255
        var g: Double
        var b: Double
        var a: Double   // 0–1
    }

    static func parseRGBA(_ css: String) -> CSSRGBA? {
        let s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("rgb") {
            let isA = s.hasPrefix("rgba")
            let inner = String(s.dropFirst(isA ? 5 : 4).dropLast())
            let parts = inner
                .components(separatedBy: CharacterSet(charactersIn: ",/ "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            if parts.count >= 3 {
                return CSSRGBA(r: parts[0], g: parts[1], b: parts[2], a: parts.count >= 4 ? parts[3] : 1)
            }
        }
        if s.hasPrefix("hsl") {
            let isA = s.hasPrefix("hsla")
            let inner = String(s.dropFirst(isA ? 5 : 4).dropLast())
            let parts = inner
                .components(separatedBy: CharacterSet(charactersIn: ",/ "))
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") }
                .compactMap { Double($0) }
            if parts.count >= 3 {
                let rgb = hslToRGB(h: parts[0] / 360, s: parts[1] / 100, l: parts[2] / 100)
                return CSSRGBA(r: rgb.0 * 255, g: rgb.1 * 255, b: rgb.2 * 255,
                            a: parts.count >= 4 ? parts[3] : 1)
            }
        }
        if s.hasPrefix("#") {
            return parseHex(String(s.dropFirst()))
        }
        return namedColorTable[s.lowercased()]
    }

    private static func parseHex(_ hex: String) -> CSSRGBA? {
        func byte(_ s: Substring) -> Double? {
            guard let v = Int(s, radix: 16) else { return nil }
            return Double(v)
        }
        switch hex.count {
        case 3:
            guard let r = byte(String(hex.prefix(1) + hex.prefix(1))[...]),
                  let g = byte(String(hex.dropFirst(1).prefix(1) + hex.dropFirst(1).prefix(1))[...]),
                  let b = byte(String(hex.dropFirst(2).prefix(1) + hex.dropFirst(2).prefix(1))[...])
            else { return nil }
            return CSSRGBA(r: r, g: g, b: b, a: 1)
        case 4:
            guard let r = byte(String(hex.prefix(1) + hex.prefix(1))[...]),
                  let g = byte(String(hex.dropFirst(1).prefix(1) + hex.dropFirst(1).prefix(1))[...]),
                  let b = byte(String(hex.dropFirst(2).prefix(1) + hex.dropFirst(2).prefix(1))[...]),
                  let a = byte(String(hex.dropFirst(3).prefix(1) + hex.dropFirst(3).prefix(1))[...])
            else { return nil }
            return CSSRGBA(r: r, g: g, b: b, a: a / 255)
        case 6:
            guard let r = byte(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2)]),
                  let g = byte(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)]),
                  let b = byte(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)])
            else { return nil }
            return CSSRGBA(r: r, g: g, b: b, a: 1)
        case 8:
            guard let r = byte(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2)]),
                  let g = byte(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)]),
                  let b = byte(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)]),
                  let a = byte(hex[hex.index(hex.startIndex, offsetBy: 6)..<hex.index(hex.startIndex, offsetBy: 8)])
            else { return nil }
            return CSSRGBA(r: r, g: g, b: b, a: a / 255)
        default:
            return nil
        }
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: Double) -> Double {
            var t = t < 0 ? t + 1 : (t > 1 ? t - 1 : t)
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return (hue(h + 1/3), hue(h), hue(h - 1/3))
    }

    static func relativeLuminance(_ rgba: CSSRGBA) -> Double {
        func linearize(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgba.r) + 0.7152 * linearize(rgba.g) + 0.0722 * linearize(rgba.b)
    }

    static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func formatHex(_ rgba: CSSRGBA) -> String {
        let r = Int(rgba.r.clamped(0, 255).rounded())
        let g = Int(rgba.g.clamped(0, 255).rounded())
        let b = Int(rgba.b.clamped(0, 255).rounded())
        if rgba.a >= 1.0 - 1e-6 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        let a = Int((rgba.a * 255).clamped(0, 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func formatRGBA(_ rgba: CSSRGBA) -> String {
        let r = Int(rgba.r.clamped(0, 255).rounded())
        let g = Int(rgba.g.clamped(0, 255).rounded())
        let b = Int(rgba.b.clamped(0, 255).rounded())
        if rgba.a >= 1.0 - 1e-6 {
            return "rgb(\(r), \(g), \(b))"
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, rgba.a)
    }

    static func isColorValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return v.hasPrefix("#") || v.hasPrefix("rgb") || v.hasPrefix("hsl") ||
               v.hasPrefix("color(") || v.hasPrefix("lab(") || v.hasPrefix("oklch(") ||
               namedColorTable[v] != nil
    }

    static func incrementValue(_ value: String, by delta: Double) -> String {
        var numStart: String.Index? = nil
        var numEnd:   String.Index? = nil
        var hasDot = false
        var idx = value.startIndex

        let leadingMinus = idx < value.endIndex && value[idx] == "-"
        if leadingMinus { idx = value.index(after: idx) }

        while idx < value.endIndex {
            let c = value[idx]
            if c.isNumber {
                if numStart == nil { numStart = leadingMinus ? value.startIndex : idx }
                numEnd = value.index(after: idx)
            } else if c == "." && !hasDot && numStart != nil {
                hasDot = true
                numEnd = value.index(after: idx)
            } else {
                break
            }
            idx = value.index(after: idx)
        }

        guard let ns = numStart, let ne = numEnd else { return value }
        let numStr = String(value[ns..<ne])
        guard let num = Double(numStr) else { return value }

        let newNum = num + delta
        let formatted: String
        if hasDot {
            let places = numStr.components(separatedBy: ".").last?.count ?? 2
            formatted = String(format: "%.\(max(places, 0))f", newNum)
        } else {
            formatted = delta == floor(delta) ? String(Int(newNum.rounded())) : String(format: "%.2f", newNum)
        }
        return value.replacingCharacters(in: ns..<ne, with: formatted)
    }


    static func camelToKebab(_ name: String) -> String {
        var result = ""
        for c in name {
            if c.isUppercase { result += "-" + c.lowercased() }
            else { result.append(c) }
        }
        return result
    }


    static func flattenTree(
        rootIDs: [Int],
        nodes: [Int: ElNodeInfo],
        children: [Int: [Int]],
        expanded: Set<Int>
    ) -> [ElFlatRow] {
        var rows: [ElFlatRow] = []
        rows.reserveCapacity(64)

        func visit(_ nodeID: Int, depth: Int) {
            guard let node = nodes[nodeID] else { return }
            let knownChildren = children[nodeID]
            let hasChildren: Bool
            if let known = knownChildren { hasChildren = !known.isEmpty }
            else { hasChildren = node.childCount > 0 }
            let isExp = expanded.contains(nodeID)

            rows.append(ElFlatRow(
                id: .init(nodeID: nodeID, isClosingTag: false),
                nodeID: nodeID, depth: depth,
                isExpanded: isExp, hasChildren: hasChildren,
                isClosingTag: false, node: node
            ))

            if isExp, let childIDs = knownChildren {
                for childID in childIDs { visit(childID, depth: depth + 1) }
                if node.kind == "el" && !childIDs.isEmpty {
                    rows.append(ElFlatRow(
                        id: .init(nodeID: nodeID, isClosingTag: true),
                        nodeID: nodeID, depth: depth,
                        isExpanded: true, hasChildren: true,
                        isClosingTag: true, node: node
                    ))
                }
            }
        }

        for rootID in rootIDs { visit(rootID, depth: 0) }
        return rows
    }


    static func matchesSearch(_ node: ElNodeInfo, query: String, mode: ElSearchMode) -> Bool {
        guard !query.isEmpty else { return false }
        let q = query.lowercased()
        switch mode {
        case .text:
            if node.name.lowercased().contains(q) { return true }
            if node.text.lowercased().contains(q) { return true }
            for (k, v) in node.attrs {
                if k.lowercased().contains(q) || v.lowercased().contains(q) { return true }
            }
            return false
        case .selector:
            guard node.kind == "el" else { return false }
            if q.hasPrefix("#") {
                return node.attrs["id"] == String(q.dropFirst())
            }
            if q.hasPrefix(".") {
                let cls = q.dropFirst()
                return node.attrs["class"]?.split(separator: " ").contains(cls) ?? false
            }
            return node.name == q
        case .xpath:
            guard node.kind == "el" else { return false }
            let tag = q.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return node.name == tag.lowercased()
        }
    }


    static func cssSelector(for path: [ElNodeInfo]) -> String {
        guard let node = path.last, node.kind == "el" else { return "*" }
        if let id = node.attrs["id"], !id.isEmpty { return "#\(id)" }
        var part = node.name
        if let cls = node.attrs["class"] {
            part += cls.split(separator: " ").prefix(2).map { ".\($0)" }.joined()
        }
        return part
    }

    static func fullSelector(for path: [ElNodeInfo]) -> String {
        path.filter { $0.kind == "el" }.map { node -> String in
            if let id = node.attrs["id"], !id.isEmpty { return "#\(id)" }
            var part = node.name
            if let cls = node.attrs["class"] {
                part += cls.split(separator: " ").prefix(2).map { ".\($0)" }.joined()
            }
            return part
        }.joined(separator: " > ")
    }

    static func xpath(for path: [ElNodeInfo]) -> String {
        "/" + path.filter { $0.kind == "el" }.map { "/\($0.name)" }.joined()
    }

    static func jsPath(for path: [ElNodeInfo]) -> String {
        guard let node = path.last, node.kind == "el" else { return "document" }
        if let id = node.attrs["id"], !id.isEmpty {
            return "document.getElementById(\"\(id)\")"
        }
        return "document.querySelector(\"\(cssSelector(for: path))\")"
    }


    static let inheritableProperties: Set<String> = [
        "color", "cursor", "direction", "font", "font-family", "font-kerning",
        "font-optical-sizing", "font-size", "font-size-adjust", "font-stretch",
        "font-style", "font-variant", "font-variant-caps", "font-variant-ligatures",
        "font-variant-numeric", "font-weight", "letter-spacing", "line-height",
        "list-style", "list-style-image", "list-style-position", "list-style-type",
        "orphans", "pointer-events", "quotes", "tab-size", "text-align",
        "text-align-last", "text-decoration", "text-indent", "text-justify",
        "text-orientation", "text-shadow", "text-transform", "visibility",
        "white-space", "widows", "word-break", "word-spacing", "word-wrap",
        "writing-mode", "border-collapse", "border-spacing", "caption-side",
        "empty-cells"
    ]


    static let namedColorTable: [String: CSSRGBA] = {
        var t: [String: CSSRGBA] = [:]
        for (name, rgb) in [
            ("red",     (255.0, 0.0,   0.0)),   ("green",   (0.0,   128.0, 0.0)),
            ("blue",    (0.0,   0.0,   255.0)),  ("black",   (0.0,   0.0,   0.0)),
            ("white",   (255.0, 255.0, 255.0)),  ("yellow",  (255.0, 255.0, 0.0)),
            ("orange",  (255.0, 165.0, 0.0)),    ("purple",  (128.0, 0.0,   128.0)),
            ("pink",    (255.0, 192.0, 203.0)),  ("gray",    (128.0, 128.0, 128.0)),
            ("grey",    (128.0, 128.0, 128.0)),  ("cyan",    (0.0,   255.0, 255.0)),
            ("magenta", (255.0, 0.0,   255.0)),  ("brown",   (165.0, 42.0,  42.0)),
            ("lime",    (0.0,   255.0, 0.0)),    ("navy",    (0.0,   0.0,   128.0)),
            ("teal",    (0.0,   128.0, 128.0)),  ("maroon",  (128.0, 0.0,   0.0)),
            ("silver",  (192.0, 192.0, 192.0)),  ("aqua",    (0.0,   255.0, 255.0)),
            ("fuchsia", (255.0, 0.0,   255.0)),  ("coral",   (255.0, 127.0, 80.0)),
        ] {
            t[name] = CSSRGBA(r: rgb.0, g: rgb.1, b: rgb.2, a: 1)
        }
        t["transparent"] = CSSRGBA(r: 0, g: 0, b: 0, a: 0)
        return t
    }()
}

/// The raw value is also the badge label, so it stays a lowercase CSS keyword.
enum ElLayoutKind: String, Equatable, Sendable {
    case flex, grid

    var label: String { rawValue }

    init?(display: String) {
        switch display.trimmingCharacters(in: .whitespaces).lowercased() {
        case "flex", "inline-flex": self = .flex
        case "grid", "inline-grid": self = .grid
        default: return nil
        }
    }
}

/// One undoable edit. `entry` is the id the page assigned when it journaled the inverse operation.
struct ElEditRecord: Equatable, Sendable {
    var entry: Int
    var label: String
}

/// The page holds the inverse operations keyed by `entry`; this type decides order and capacity.
struct ElEditHistory: Equatable, Sendable {
    static let capacity = 200

    private(set) var undoStack: [ElEditRecord] = []
    private(set) var redoStack: [ElEditRecord] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// A new edit invalidates redo; the oldest edits fall off at `capacity`. Returns the entries the page can forget.
    @discardableResult
    mutating func push(_ record: ElEditRecord) -> [Int] {
        var forgotten = redoStack.map(\.entry)
        redoStack.removeAll()
        undoStack.append(record)
        if undoStack.count > Self.capacity {
            let overflow = undoStack.count - Self.capacity
            forgotten.append(contentsOf: undoStack.prefix(overflow).map(\.entry))
            undoStack.removeFirst(overflow)
        }
        return forgotten
    }

    mutating func undo() -> ElEditRecord? {
        guard let record = undoStack.popLast() else { return nil }
        redoStack.append(record)
        return record
    }

    mutating func redo() -> ElEditRecord? {
        guard let record = redoStack.popLast() else { return nil }
        undoStack.append(record)
        return record
    }

    mutating func discard(entry: Int) {
        undoStack.removeAll { $0.entry == entry }
        redoStack.removeAll { $0.entry == entry }
    }

    @discardableResult
    mutating func clear() -> [Int] {
        let forgotten = undoStack.map(\.entry) + redoStack.map(\.entry)
        undoStack.removeAll()
        redoStack.removeAll()
        return forgotten
    }
}

enum ElDropPosition: Equatable, Sendable {
    case before, inside, after

    /// Elements accept a drop inside their middle half; text and comment rows split in two because they cannot have children.
    static func zone(fraction: Double, canContainChildren: Bool) -> ElDropPosition {
        let f = min(max(fraction, 0), 1)
        if canContainChildren {
            if f < 0.28 { return .before }
            if f > 0.72 { return .after }
            return .inside
        }
        return f < 0.5 ? .before : .after
    }
}

struct ElDropPlacement: Equatable, Sendable {
    var parentID: Int
    var beforeID: Int?
}

extension OrbitElementsLogic {


    static func parentMap(children: [Int: [Int]]) -> [Int: Int] {
        var parents: [Int: Int] = [:]
        parents.reserveCapacity(children.count * 2)
        for (parent, kids) in children {
            for kid in kids { parents[kid] = parent }
        }
        return parents
    }

    static func isInSubtree(_ node: Int, of ancestor: Int, parents: [Int: Int]) -> Bool {
        var current: Int? = node
        var steps = 0
        while let id = current, steps < 512 {
            if id == ancestor { return true }
            current = parents[id]
            steps += 1
        }
        return false
    }

    /// The root, doctype and shadow roots stay where they are.
    static func canDrag(nodeID: Int, nodes: [Int: ElNodeInfo], parents: [Int: Int]) -> Bool {
        guard let node = nodes[nodeID], parents[nodeID] != nil else { return false }
        return node.kind == "el" || node.kind == "text" || node.kind == "comment"
    }

    /// `truncatedParents` have only part of their child list loaded; appending to one would land in the wrong place.
    static func dropPlacement(
        moving: Int,
        target: Int,
        isClosingTag: Bool,
        position: ElDropPosition,
        nodes: [Int: ElNodeInfo],
        children: [Int: [Int]],
        parents: [Int: Int],
        truncatedParents: Set<Int> = []
    ) -> ElDropPlacement? {
        guard canDrag(nodeID: moving, nodes: nodes, parents: parents), let targetNode = nodes[target] else { return nil }

        func siblingAfter(_ id: Int, in parent: Int) -> Int? {
            guard let kids = children[parent], let index = kids.firstIndex(of: id), index + 1 < kids.count else { return nil }
            return kids[index + 1]
        }

        let parent: Int
        let before: Int?

        if isClosingTag {
            if position == .after {
                guard let p = parents[target] else { return nil }
                parent = p
                before = siblingAfter(target, in: p)
            } else {
                parent = target
                before = nil
            }
        } else {
            switch position {
            case .before:
                guard let p = parents[target] else { return nil }
                parent = p
                before = target
            case .inside:
                guard targetNode.kind == "el" else { return nil }
                parent = target
                before = nil
            case .after:
                if let kids = children[target], let first = kids.first, targetNode.kind == "el" {
                    // The row's children are drawn right below it, so "after" it means "before its first child".
                    parent = target
                    before = first
                } else {
                    guard let p = parents[target] else { return nil }
                    parent = p
                    before = siblingAfter(target, in: p)
                }
            }
        }

        guard let parentNode = nodes[parent], parentNode.kind == "el" || parentNode.kind == "shadow" else { return nil }
        if before == nil, truncatedParents.contains(parent) { return nil }
        if isInSubtree(parent, of: moving, parents: parents) { return nil }

        if let currentParent = parents[moving], currentParent == parent {
            if before == moving || before == siblingAfter(moving, in: parent) { return nil }
            if before == nil, siblingAfter(moving, in: parent) == nil { return nil }
        }
        return ElDropPlacement(parentID: parent, beforeID: before)
    }

    static func isValidTagName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." )
        }
    }

    static func renameCommand(id: Int, from current: String, to proposed: String) -> [String: Any]? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name != current.lowercased(), isValidTagName(name) else { return nil }
        return ["op": "el.rename", "id": id, "name": name]
    }

    static func moveCommand(id: Int, placement: ElDropPlacement) -> [String: Any] {
        var command: [String: Any] = ["op": "el.move", "id": id, "parentId": placement.parentID]
        if let before = placement.beforeID { command["beforeId"] = before }
        return command
    }

    static func editTextCommand(id: Int, original: String, edited: String) -> [String: Any]? {
        guard edited != original else { return nil }
        return ["op": "el.editText", "id": id, "text": edited]
    }

    static func editHTMLCommand(id: Int, original: String, edited: String) -> [String: Any]? {
        guard edited != original, !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ["op": "el.editHTML", "id": id, "html": edited]
    }

    static func layoutOverlayCommand(id: Int, kind: ElLayoutKind, on: Bool) -> [String: Any] {
        ["op": "el.layoutOverlay", "id": id, "kind": kind.rawValue, "on": on]
    }

    static func undoCommand(entry: Int) -> [String: Any] { ["op": "el.undo", "entry": entry] }
    static func redoCommand(entry: Int) -> [String: Any] { ["op": "el.redo", "entry": entry] }
    static func discardCommand(entries: [Int]) -> [String: Any] { ["op": "el.discard", "entries": entries] }

    // MARK: HTML syntax tokens

    enum HTMLTokenKind: Equatable, Sendable {
        case punctuation, tagName, attributeName, attributeValue, comment, doctype
    }

    /// A highlighted run. `range` is in UTF-16 offsets so it maps straight onto an `NSRange`.
    struct HTMLToken: Equatable, Sendable {
        var range: Range<Int>
        var kind: HTMLTokenKind
    }

    /// Forgiving by design: half-typed markup still tokenizes, it never fails.
    static func htmlTokens(_ source: String) -> [HTMLToken] {
        let u = Array(source.utf16)
        let n = u.count
        var tokens: [HTMLToken] = []
        var i = 0

        func at(_ index: Int) -> UInt16 { index < n ? u[index] : 0 }
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func matches(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf16)
            guard index + pattern.count <= n else { return false }
            for k in 0..<pattern.count where u[index + k] != pattern[k] { return false }
            return true
        }
        func find(_ text: String, from index: Int) -> Int? {
            let pattern = Array(text.utf16)
            guard !pattern.isEmpty, n >= pattern.count else { return nil }
            var k = index
            while k + pattern.count <= n {
                if u[k] == pattern[0], matches(text, at: k) { return k }
                k += 1
            }
            return nil
        }
        func emit(_ lower: Int, _ upper: Int, _ kind: HTMLTokenKind) {
            if upper > lower { tokens.append(HTMLToken(range: lower..<upper, kind: kind)) }
        }

        while i < n {
            guard u[i] == 0x3C else { i += 1; continue }                       // "<"
            if matches("<!--", at: i) {
                let end = find("-->", from: i + 4).map { $0 + 3 } ?? n
                emit(i, end, .comment)
                i = end
                continue
            }
            if at(i + 1) == 0x21 {                                              // "<!"
                let end = find(">", from: i + 2).map { $0 + 1 } ?? n
                emit(i, end, .doctype)
                i = end
                continue
            }
            let closing = at(i + 1) == 0x2F                                    // "</"
            let nameStart = i + (closing ? 2 : 1)
            guard isLetter(at(nameStart)) else { i += 1; continue }

            emit(i, nameStart, .punctuation)
            var cursor = nameStart
            while cursor < n, !isSpace(u[cursor]), u[cursor] != 0x3E, u[cursor] != 0x2F { cursor += 1 }
            emit(nameStart, cursor, .tagName)
            let tagName = String(decoding: u[nameStart..<cursor], as: UTF16.self).lowercased()

            while cursor < n, u[cursor] != 0x3E {
                if isSpace(u[cursor]) { cursor += 1; continue }
                if u[cursor] == 0x2F { emit(cursor, cursor + 1, .punctuation); cursor += 1; continue }
                let attrStart = cursor
                while cursor < n, !isSpace(u[cursor]), u[cursor] != 0x3D, u[cursor] != 0x3E, u[cursor] != 0x2F { cursor += 1 }
                if cursor == attrStart { cursor += 1; continue }
                emit(attrStart, cursor, .attributeName)
                var look = cursor
                while look < n, isSpace(u[look]) { look += 1 }
                guard at(look) == 0x3D else { continue }                       // "=" or a bare attribute
                emit(look, look + 1, .punctuation)
                cursor = look + 1
                while cursor < n, isSpace(u[cursor]) { cursor += 1 }
                let valueStart = cursor
                if at(cursor) == 0x22 || at(cursor) == 0x27 {
                    let quote = u[cursor]
                    cursor += 1
                    while cursor < n, u[cursor] != quote { cursor += 1 }
                    if cursor < n { cursor += 1 }
                } else {
                    while cursor < n, !isSpace(u[cursor]), u[cursor] != 0x3E { cursor += 1 }
                }
                emit(valueStart, cursor, .attributeValue)
            }
            if cursor < n { emit(cursor, cursor + 1, .punctuation); cursor += 1 }
            i = cursor

            // Script and style bodies are not markup.
            if !closing, ["script", "style", "textarea", "title"].contains(tagName) {
                let lowered = Array(source.lowercased().utf16)
                if lowered.count == n {
                    let needle = Array("</\(tagName)".utf16)
                    var k = i
                    var found: Int?
                    while k + needle.count <= n {
                        if lowered[k] == needle[0], Array(lowered[k..<(k + needle.count)]) == needle { found = k; break }
                        k += 1
                    }
                    i = found ?? n
                }
            }
        }
        return tokens
    }
}


private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { min(max(self, low), high) }
}
