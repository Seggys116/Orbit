// Foundation-only (no AppKit, SwiftUI or WebKit): compiled into both the app target and the unit-test bundle.

import Foundation

enum SourceFileType: String, Hashable, Sendable {
    case document
    case script
    case stylesheet
    case image
    case font
    case media
    case wasm
    case inlineScript     // <script> without src
    case inlineStyle      // <style> element
    case blobScript       // blob: URL
    case dataScript       // data: URL
    case adoptedStylesheet
    case workerScript
    case snippet          // user scratch snippet
    case other

    var symbol: String {
        switch self {
        case .document:          return "doc.text"
        case .script:            return "curlybraces"
        case .stylesheet:        return "paintbrush"
        case .image:             return "photo"
        case .font:              return "textformat"
        case .media:             return "film"
        case .wasm:              return "cpu"
        case .inlineScript:      return "curlybraces.square"
        case .inlineStyle:       return "paintbrush.pointed"
        case .blobScript:        return "link"
        case .dataScript:        return "link"
        case .adoptedStylesheet: return "paintbrush.fill"
        case .workerScript:      return "person.fill"
        case .snippet:           return "scroll"
        case .other:             return "doc"
        }
    }

    var isTextSource: Bool {
        switch self {
        case .image, .font, .media: return false
        default: return true
        }
    }

    static func from(mimeType: String, url: String) -> SourceFileType {
        let m = mimeType.lowercased()
        if m.contains("javascript") || m.contains("ecmascript") { return .script }
        if m.contains("css") { return .stylesheet }
        if m.contains("html") { return .document }
        if m.contains("wasm") { return .wasm }
        if m.hasPrefix("image/") { return .image }
        if m.hasPrefix("font/") || m.contains("woff") || m.contains("truetype") || m.contains("opentype") { return .font }
        if m.hasPrefix("video/") || m.hasPrefix("audio/") { return .media }
        let u = url.lowercased()
        if u.hasSuffix(".js") || u.hasSuffix(".mjs") || u.hasSuffix(".jsx") || u.hasSuffix(".ts") || u.hasSuffix(".tsx") { return .script }
        if u.hasSuffix(".css") || u.hasSuffix(".scss") || u.hasSuffix(".less") { return .stylesheet }
        if u.hasSuffix(".html") || u.hasSuffix(".htm") { return .document }
        if u.hasSuffix(".wasm") { return .wasm }
        if u.hasSuffix(".png") || u.hasSuffix(".jpg") || u.hasSuffix(".jpeg") || u.hasSuffix(".svg") || u.hasSuffix(".gif") || u.hasSuffix(".webp") { return .image }
        if u.hasPrefix("blob:") { return .blobScript }
        if u.hasPrefix("data:") { return .dataScript }
        return .other
    }
}


struct SourceFile: Identifiable, Hashable, Sendable {
    /// Stable ID: URL for external resources; "inline:\(pageURL):\(line):\(index)" for inline blocks.
    var id: String
    var url: String
    var displayName: String
    var origin: String
    var pathComponents: [String]
    var fileType: SourceFileType
    var mimeType: String
    var inlineLine: Int?
    var inlineIndex: Int?
    var declaredSourceURL: String?

    static func make(url rawURL: String, mimeType: String, inlineLine: Int? = nil, inlineIndex: Int? = nil, declaredSourceURL: String? = nil, type typeOverride: SourceFileType? = nil) -> SourceFile {
        let ft = typeOverride ?? SourceFileType.from(mimeType: mimeType, url: rawURL)
        let (origin, pathComponents, displayName) = urlParts(rawURL, ft: ft)
        let stableID = inlineLine != nil ? "inline:\(rawURL):\(inlineLine ?? 0):\(inlineIndex ?? 0)" : rawURL
        return SourceFile(
            id: stableID,
            url: rawURL,
            displayName: displayName,
            origin: origin,
            pathComponents: pathComponents,
            fileType: ft,
            mimeType: mimeType,
            inlineLine: inlineLine,
            inlineIndex: inlineIndex,
            declaredSourceURL: declaredSourceURL
        )
    }

    private static func urlParts(_ raw: String, ft: SourceFileType) -> (origin: String, path: [String], name: String) {
        if raw.hasPrefix("(inline) ") {
            return ("inline", [], raw)
        }
        guard let url = URL(string: raw), let host = url.host else {
            if raw.hasPrefix("blob:") { return ("blob:", [], "blob…") }
            if raw.hasPrefix("data:") { return ("data:", [], "data:…") }
            return ("other", [], (raw as NSString).lastPathComponent)
        }
        let origin = url.port != nil ? "\(host):\(url.port!)" : host
        var parts = url.pathComponents.filter { $0 != "/" }
        if var last = parts.last {
            if let q = last.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                last = String(last[..<q])
            }
            if last.isEmpty { parts.removeLast() }
            else { parts[parts.endIndex - 1] = last }
        }
        let name = parts.last ?? host
        let path = parts.count > 1 ? Array(parts.dropLast()) : []
        return (origin, path, name)
    }
}

struct SourceTreeItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case originHeader(String, Int)          // origin label, total file count
        case folder(String, Int)                // folder name, file count under it
        case file(SourceFile)
        case originalSourceHeader               // "Original Sources" section
        case originalFile(OriginalSourceFile)
        case snippetsHeader
        case snippet(SourceSnippet)
    }
    var id: String
    var kind: Kind
    var depth: Int
    var isExpandable: Bool
    var isExpanded: Bool
}

struct OriginalSourceFile: Identifiable, Hashable, Sendable {
    var id: String        // typically the webpack:// or ./src/... path
    var displayPath: String
    var origin: String    // "webpack://", "vite://", etc.
    var pathComponents: [String]
    var displayName: String
    var generatedFileID: String   // which generated file this comes from
}

struct SourceSnippet: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var code: String
}

enum SourceTreeBuilder {

    struct FolderNode {
        var name: String
        var files: [SourceFile] = []
        var subfolders: [String: FolderNode] = [:]
    }

    static func buildFlatRows(
        files: [SourceFile],
        originalFiles: [OriginalSourceFile],
        snippets: [SourceSnippet],
        expandedIDs: Set<String>,
        filterQuery: String,
        preferOriginals: Bool
    ) -> [SourceTreeItem] {
        let filtered: [SourceFile]
        if filterQuery.isEmpty {
            filtered = files
        } else {
            filtered = files.filter { SourceFuzzyMatcher.matches(query: filterQuery, in: $0.displayName) || SourceFuzzyMatcher.matches(query: filterQuery, in: $0.url) }
        }

        var rows: [SourceTreeItem] = []

        var originOrder: [String] = []
        var byOrigin: [String: [SourceFile]] = [:]
        for file in filtered {
            if byOrigin[file.origin] == nil {
                originOrder.append(file.origin)
                byOrigin[file.origin] = []
            }
            byOrigin[file.origin]!.append(file)
        }

        for origin in originOrder {
            let originFiles = byOrigin[origin] ?? []
            let originID = "origin:\(origin)"
            let isExpanded = expandedIDs.contains(originID)
            rows.append(SourceTreeItem(
                id: originID,
                kind: .originHeader(origin, originFiles.count),
                depth: 0,
                isExpandable: true,
                isExpanded: isExpanded
            ))
            if isExpanded {
                let tree = buildFolderTree(originFiles)
                appendFolder(tree, depth: 1, expandedIDs: expandedIDs, into: &rows)
            }
        }

        if preferOriginals, !originalFiles.isEmpty {
            let sectionID = "section:originals"
            let isExpanded = expandedIDs.contains(sectionID)
            rows.append(SourceTreeItem(id: sectionID, kind: .originalSourceHeader, depth: 0, isExpandable: true, isExpanded: isExpanded))
            if isExpanded {
                let filteredOriginals = filterQuery.isEmpty ? originalFiles : originalFiles.filter { SourceFuzzyMatcher.matches(query: filterQuery, in: $0.displayPath) }
                for orig in filteredOriginals {
                    rows.append(SourceTreeItem(id: "orig:\(orig.id)", kind: .originalFile(orig), depth: 1, isExpandable: false, isExpanded: false))
                }
            }
        }

        let snippetSectionID = "section:snippets"
        let snippetsExpanded = expandedIDs.contains(snippetSectionID)
        rows.append(SourceTreeItem(id: snippetSectionID, kind: .snippetsHeader, depth: 0, isExpandable: true, isExpanded: snippetsExpanded))
        if snippetsExpanded {
            for snippet in snippets {
                rows.append(SourceTreeItem(id: "snippet:\(snippet.id)", kind: .snippet(snippet), depth: 1, isExpandable: false, isExpanded: false))
            }
        }

        return rows
    }

    private static func buildFolderTree(_ files: [SourceFile]) -> FolderNode {
        var root = FolderNode(name: "")
        for file in files {
            insert(file: file, into: &root)
        }
        return root
    }

    // Workaround: pass by inout root
    private static func insert(file: SourceFile, into root: inout FolderNode) {
        if file.pathComponents.isEmpty {
            root.files.append(file)
            return
        }
        var parts = file.pathComponents
        let first = parts.removeFirst()
        if root.subfolders[first] == nil {
            root.subfolders[first] = FolderNode(name: first)
        }
        var sub = root.subfolders[first]!
        insertRemaining(file: file, remainingPath: parts, into: &sub)
        root.subfolders[first] = sub
    }

    private static func insertRemaining(file: SourceFile, remainingPath: [String], into node: inout FolderNode) {
        if remainingPath.isEmpty {
            node.files.append(file)
            return
        }
        var parts = remainingPath
        let first = parts.removeFirst()
        if node.subfolders[first] == nil {
            node.subfolders[first] = FolderNode(name: first)
        }
        var sub = node.subfolders[first]!
        insertRemaining(file: file, remainingPath: parts, into: &sub)
        node.subfolders[first] = sub
    }

    private static func folderFileCount(_ node: FolderNode) -> Int {
        node.files.count + node.subfolders.values.reduce(0) { $0 + folderFileCount($1) }
    }

    private static func appendFolder(_ node: FolderNode, depth: Int, expandedIDs: Set<String>, into rows: inout [SourceTreeItem]) {
        let sortedFolders = node.subfolders.keys.sorted()
        for folderName in sortedFolders {
            let sub = node.subfolders[folderName]!
            let folderID = "folder:\(depth):\(folderName)"
            let count = folderFileCount(sub)
            let isExpanded = expandedIDs.contains(folderID)
            rows.append(SourceTreeItem(id: folderID, kind: .folder(folderName, count), depth: depth, isExpandable: true, isExpanded: isExpanded))
            if isExpanded {
                appendFolder(sub, depth: depth + 1, expandedIDs: expandedIDs, into: &rows)
            }
        }
        let sortedFiles = node.files.sorted { $0.displayName < $1.displayName }
        for file in sortedFiles {
            rows.append(SourceTreeItem(id: "file:\(file.id)", kind: .file(file), depth: depth, isExpandable: false, isExpanded: false))
        }
    }
}

enum SourceFuzzyMatcher {
    static func matches(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        let ql = query.lowercased()
        let tl = text.lowercased()
        var qi = ql.startIndex
        for tc in tl {
            if tc == ql[qi] {
                qi = ql.index(after: qi)
                if qi == ql.endIndex { return true }
            }
        }
        return false
    }

    struct Match: Sendable {
        var text: String
        var score: Int
        var matchedRanges: [Range<String.Index>]
    }

    static func rank(query: String, candidates: [String]) -> [Match] {
        guard !query.isEmpty else {
            return candidates.map { Match(text: $0, score: 0, matchedRanges: []) }
        }
        return candidates.compactMap { score(query: query, text: $0) }
            .sorted { $0.score > $1.score }
    }

    private static func score(query: String, text: String) -> Match? {
        let ql = query.lowercased()
        let tl = text.lowercased()
        var qi = ql.startIndex
        var matchedRanges: [Range<String.Index>] = []
        var score = 0
        var consecutive = 0
        var ti = tl.startIndex
        var originalTi = text.startIndex
        while ti < tl.endIndex, qi < ql.endIndex {
            if tl[ti] == ql[qi] {
                let range = originalTi ..< text.index(after: originalTi)
                matchedRanges.append(range)
                consecutive += 1
                score += consecutive * 2
                if ti == tl.startIndex || !tl[tl.index(before: ti)].isLetter {
                    score += 5
                }
                qi = ql.index(after: qi)
            } else {
                consecutive = 0
            }
            ti = tl.index(after: ti)
            originalTi = text.index(after: originalTi)
        }
        guard qi == ql.endIndex else { return nil }
        // Prefer shorter texts (more relevant match) and texts where query is a prefix
        score -= text.count / 4
        if tl.hasPrefix(ql) { score += 15 }
        return Match(text: text, score: score, matchedRanges: matchedRanges)
    }
}

enum SourceVLQ {
    enum Error: Swift.Error { case invalidCharacter(Character), unexpectedEnd, tooLarge }

    private static let chars: [Character: Int] = {
        var m: [Character: Int] = [:]
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (index, char) in alphabet.enumerated() { m[char] = index }
        return m
    }()

    static func decode(_ encoded: String) throws -> [Int] {
        var values: [Int] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            var result = 0
            var shift = 0
            var hasContinuation = true
            while hasContinuation {
                guard index < encoded.endIndex else { throw Error.unexpectedEnd }
                let char = encoded[index]
                index = encoded.index(after: index)
                guard let sextet = chars[char] else { throw Error.invalidCharacter(char) }
                hasContinuation = (sextet & 0x20) != 0
                // Source map values are 32-bit; a longer run is malformed or hostile and would overflow the running columns.
                guard shift <= 30 else { throw Error.tooLarge }
                result |= (sextet & 0x1F) << shift
                shift += 5
            }
            let isNegative = (result & 1) != 0
            let magnitude = result >> 1
            values.append(isNegative ? -magnitude : magnitude)
        }
        return values
    }
}

struct SourceMapV3: Sendable {
    static let maxSectionOffsetLine = 1_000_000

    var version: Int
    var file: String
    var sourceRoot: String
    var sources: [String]
    var sourcesContent: [String?]
    var names: [String]
    var mappings: String
    var sections: [SourceMapSection]
}

struct SourceMapSection: Sendable {
    var offsetLine: Int
    var offsetColumn: Int
    var map: SourceMapV3
}

struct SourceMapMapping: Sendable {
    var generatedColumn: Int
    var sourceIndex: Int    // -1 if no source info
    var originalLine: Int
    var originalColumn: Int
    var nameIndex: Int      // -1 if no name
}

struct ParsedMappings: Sendable {
    var lines: [[SourceMapMapping]]
    var sources: [String]
    var sourcesContent: [String?]
    var names: [String]
    var sourceRoot: String

    func originalPosition(line: Int, column: Int) -> (source: String, line: Int, column: Int, name: String?)? {
        guard line >= 0, line < lines.count else { return nil }
        let segments = lines[line]
        guard !segments.isEmpty else { return nil }
        var lo = 0
        var hi = segments.count - 1
        var best: SourceMapMapping? = nil
        // Binary search for the last segment whose generatedColumn is at or before `column`.
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].generatedColumn <= column {
                best = segments[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let m = best, m.sourceIndex >= 0, m.sourceIndex < sources.count else { return nil }
        let rawSource = sources[m.sourceIndex]
        let source = sourceRoot.isEmpty ? rawSource : (sourceRoot.hasSuffix("/") ? sourceRoot + rawSource : sourceRoot + "/" + rawSource)
        let name = m.nameIndex >= 0 && m.nameIndex < names.count ? names[m.nameIndex] : nil
        return (source: source, line: m.originalLine, column: m.originalColumn, name: name)
    }

    func generatedPosition(sourceURL: String, line: Int, column: Int) -> (line: Int, column: Int)? {
        let sourceIdx = sources.firstIndex(where: { src in
            let full = sourceRoot.isEmpty ? src : (sourceRoot.hasSuffix("/") ? sourceRoot + src : sourceRoot + "/" + src)
            return full == sourceURL || src == sourceURL
        })
        guard let si = sourceIdx else { return nil }
        for (lineIdx, segments) in lines.enumerated() {
            for seg in segments where seg.sourceIndex == si && seg.originalLine == line {
                if seg.originalColumn <= column {
                    return (lineIdx, seg.generatedColumn)
                }
            }
        }
        return nil
    }
}

enum SourceMapParser {

    static func parse(json: [String: Any]) -> SourceMapV3? {
        let version = json["version"] as? Int ?? 3
        if let sections = json["sections"] as? [[String: Any]] {
            let parsedSections: [SourceMapSection] = sections.compactMap { sec in
                guard let offset = sec["offset"] as? [String: Any],
                      let offsetLine = offset["line"] as? Int,
                      let offsetColumn = offset["column"] as? Int,
                      // The merge pads lines up to the offset, so an absurd or negative offset would exhaust memory or index below zero.
                      (0...SourceMapV3.maxSectionOffsetLine).contains(offsetLine), offsetColumn >= 0, offsetColumn < 10_000_000,
                      let mapJSON = sec["map"] as? [String: Any],
                      let innerMap = parse(json: mapJSON) else { return nil }
                return SourceMapSection(offsetLine: offsetLine, offsetColumn: offsetColumn, map: innerMap)
            }
            return SourceMapV3(version: version, file: json["file"] as? String ?? "", sourceRoot: "", sources: [], sourcesContent: [], names: [], mappings: "", sections: parsedSections)
        }
        guard let mappingsString = json["mappings"] as? String else { return nil }
        let sources = json["sources"] as? [String] ?? []
        let sourcesContent: [String?] = (json["sourcesContent"] as? [Any] ?? []).map { $0 as? String }
        let names = json["names"] as? [String] ?? []
        let sourceRoot = json["sourceRoot"] as? String ?? ""
        return SourceMapV3(version: version, file: json["file"] as? String ?? "", sourceRoot: sourceRoot, sources: sources, sourcesContent: sourcesContent, names: names, mappings: mappingsString, sections: [])
    }

    static func parseMappings(_ map: SourceMapV3) -> ParsedMappings {
        if !map.sections.isEmpty {
            return parseSections(map.sections)
        }
        return parseFlat(map)
    }

    private static func parseFlat(_ map: SourceMapV3) -> ParsedMappings {
        var lines: [[SourceMapMapping]] = []
        var gcol = 0
        var sourceIdx = 0
        var origLine = 0
        var origCol = 0
        var nameIdx = 0

        let lineStrings = map.mappings.split(separator: ";", omittingEmptySubsequences: false)
        for lineStr in lineStrings {
            gcol = 0
            var line: [SourceMapMapping] = []
            if !lineStr.isEmpty {
                for segStr in lineStr.split(separator: ",") {
                    guard let values = try? SourceVLQ.decode(String(segStr)), !values.isEmpty else { continue }
                    gcol &+= values[0]
                    if values.count >= 4 {
                        sourceIdx &+= values[1]
                        origLine &+= values[2]
                        origCol &+= values[3]
                        let ni: Int
                        if values.count >= 5 {
                            nameIdx &+= values[4]
                            ni = nameIdx
                        } else {
                            ni = -1
                        }
                        line.append(SourceMapMapping(generatedColumn: gcol, sourceIndex: sourceIdx, originalLine: origLine, originalColumn: origCol, nameIndex: ni))
                    } else {
                        line.append(SourceMapMapping(generatedColumn: gcol, sourceIndex: -1, originalLine: -1, originalColumn: -1, nameIndex: -1))
                    }
                }
            }
            lines.append(line)
        }
        return ParsedMappings(lines: lines, sources: map.sources, sourcesContent: map.sourcesContent, names: map.names, sourceRoot: map.sourceRoot)
    }

    private static func parseSections(_ sections: [SourceMapSection]) -> ParsedMappings {
        var allLines: [[SourceMapMapping]] = []
        for section in sections.sorted(by: { $0.offsetLine < $1.offsetLine || ($0.offsetLine == $1.offsetLine && $0.offsetColumn < $1.offsetColumn) }) {
            let inner = parseFlat(section.map)
            while allLines.count <= section.offsetLine {
                allLines.append([])
            }
            for (lineIdx, segs) in inner.lines.enumerated() {
                let destLine = section.offsetLine + lineIdx
                while allLines.count <= destLine { allLines.append([]) }
                let adjustedSegs = segs.map { seg -> SourceMapMapping in
                    let adjustedGcol = lineIdx == 0 ? seg.generatedColumn &+ section.offsetColumn : seg.generatedColumn
                    return SourceMapMapping(generatedColumn: adjustedGcol, sourceIndex: seg.sourceIndex, originalLine: seg.originalLine, originalColumn: seg.originalColumn, nameIndex: seg.nameIndex)
                }
                allLines[destLine].append(contentsOf: adjustedSegs)
            }
        }
        var sources: [String] = []
        var sourcesContent: [String?] = []
        var names: [String] = []
        for section in sections {
            sources.append(contentsOf: section.map.sources)
            sourcesContent.append(contentsOf: section.map.sourcesContent)
            names.append(contentsOf: section.map.names)
        }
        return ParsedMappings(lines: allLines, sources: sources, sourcesContent: sourcesContent, names: names, sourceRoot: "")
    }

    static func sourceMappingURL(in text: String) -> String? {
        // JS files use a line comment (//# or //@) and CSS files a block comment for sourceMappingURL.
        let patterns = [
            #"//[#@]\s*sourceMappingURL=([^\s]+)"#,
            #"/\*#\s*sourceMappingURL=([^\s*]+)\s*\*/"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges >= 2 {
                let r = match.range(at: 1)
                if let range = Range(r, in: text) {
                    let url = String(text[range])
                    if !url.isEmpty && (url.hasPrefix("data:") ? url.count < 2_000_000 : true) {
                        return url
                    }
                }
            }
        }
        return nil
    }
}

struct PrettyResult: Sendable {
    var text: String
    var linemap: [Int: Int]
    var reverseLinemap: [Int: Int]

    static let identity = PrettyResult(text: "", linemap: [:], reverseLinemap: [:])
}

enum SourcePrettyPrinter {


    static func json(_ input: String) -> PrettyResult {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PrettyResult(text: input, linemap: [:], reverseLinemap: [:])
        }
        var out = ""
        out.reserveCapacity(input.count * 2)
        var indentLevel = 0
        var inString = false
        var escaped = false
        var prettyLine = 0
        var origLine = 0
        var linemap: [Int: Int] = [:]
        var reverseLinemap: [Int: Int] = [:]
        linemap[0] = 0
        reverseLinemap[0] = 0

        func recordLine() {
            prettyLine += 1
            if linemap[origLine] == nil { linemap[origLine] = prettyLine }
            reverseLinemap[prettyLine] = origLine
        }
        func indent() -> String { String(repeating: "  ", count: indentLevel) }
        func newline() { out += "\n"; recordLine() }

        for char in input {
            if char == "\n" { origLine += 1 }
            if escaped { out.append(char); escaped = false; continue }
            if inString {
                if char == "\\" { out.append(char); escaped = true }
                else if char == "\"" { out.append(char); inString = false }
                else { out.append(char) }
                continue
            }
            switch char {
            case "{", "[":
                out.append(char)
                indentLevel += 1
                newline()
                out += indent()
            case "}", "]":
                indentLevel = max(0, indentLevel - 1)
                newline()
                out += indent()
                out.append(char)
            case ",":
                out.append(char)
                newline()
                out += indent()
            case ":":
                out += ": "
            case "\"":
                out.append(char)
                inString = true
            case " ", "\t", "\r", "\n":
                break // Skip original whitespace outside strings
            default:
                out.append(char)
            }
        }
        return PrettyResult(text: out, linemap: linemap, reverseLinemap: reverseLinemap)
    }


    static func css(_ input: String) -> PrettyResult {
        var out = ""
        out.reserveCapacity(input.count)
        var indentLevel = 0
        var inString = false
        var stringChar: Character = "\""
        var inComment = false
        var prevChar: Character = " "
        var prettyLine = 0
        var origLine = 0
        var linemap: [Int: Int] = [:]
        var reverseLinemap: [Int: Int] = [:]
        linemap[0] = 0
        reverseLinemap[0] = 0

        func recordLine() {
            prettyLine += 1
            if linemap[origLine] == nil { linemap[origLine] = prettyLine }
            reverseLinemap[prettyLine] = origLine
        }
        func indent() -> String { String(repeating: "  ", count: indentLevel) }
        func newline() { out += "\n"; recordLine() }

        var chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { origLine += 1 }
            if inComment {
                out.append(c)
                if c == "/" && prevChar == "*" { inComment = false; newline() }
                prevChar = c
                i += 1
                continue
            }
            if inString {
                out.append(c)
                if c == stringChar && prevChar != "\\" { inString = false }
                prevChar = c
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                out += indent() + "/*"
                i += 2
                inComment = true
                prevChar = "*"
                continue
            }
            if c == "\"" || c == "'" {
                inString = true
                stringChar = c
                out.append(c)
            } else if c == "{" {
                out += " {\n"
                recordLine()
                indentLevel += 1
                out += indent()
            } else if c == "}" {
                newline()
                indentLevel = max(0, indentLevel - 1)
                out += indent() + "}\n"
                recordLine()
                out += indent()
            } else if c == ";" {
                out += ";\n"
                recordLine()
                out += indent()
            } else if c == "\n" || c == "\r" {
                if !out.isEmpty && out.last != " " && out.last != "\n" { out += " " }
            } else if c == " " || c == "\t" {
                if !out.isEmpty && out.last != " " && out.last != "\n" { out += " " }
            } else {
                out.append(c)
            }
            prevChar = c
            i += 1
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return PrettyResult(text: trimmed, linemap: linemap, reverseLinemap: reverseLinemap)
    }


    static func js(_ input: String) -> PrettyResult {
        // Not a full parser: it handles the common minified pattern of semicolons as separators and braces for blocks.
        var out = ""
        out.reserveCapacity(input.count)
        var indent = 0
        var inString = false
        var stringChar: Character = "\""
        var inTemplate = false
        var templateDepth = 0
        var inLineComment = false
        var inBlockComment = false
        var prevNonSpace: Character = " "
        var prettyLine = 0
        var origLine = 0
        var linemap: [Int: Int] = [:]
        var reverseLinemap: [Int: Int] = [:]
        linemap[0] = 0
        reverseLinemap[0] = 0

        func recordLine() {
            prettyLine += 1
            if linemap[origLine] == nil { linemap[origLine] = prettyLine }
            reverseLinemap[prettyLine] = origLine
        }
        func indentStr() -> String { String(repeating: "  ", count: max(0, indent)) }
        func newlineAndIndent() { out += "\n"; recordLine(); out += indentStr() }

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { origLine += 1 }

            if inLineComment {
                out.append(c)
                if c == "\n" { inLineComment = false; newlineAndIndent() }
                i += 1
                continue
            }
            if inBlockComment {
                out.append(c)
                if c == "/" && i > 0 && chars[i - 1] == "*" { inBlockComment = false }
                i += 1
                continue
            }
            if inString || inTemplate {
                out.append(c)
                if inTemplate && c == "{" && i > 0 && chars[i - 1] == "$" {
                    templateDepth += 1
                }
                if (inString && c == stringChar && (i == 0 || chars[i - 1] != "\\")) {
                    inString = false
                }
                if inTemplate && c == "`" && templateDepth == 0 { inTemplate = false }
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count {
                if chars[i + 1] == "/" { inLineComment = true; out += "//"; i += 2; continue }
                if chars[i + 1] == "*" { inBlockComment = true; out += "/*"; i += 2; continue }
            }
            if c == "\"" || c == "'" { inString = true; stringChar = c; out.append(c); i += 1; continue }
            if c == "`" { inTemplate = true; templateDepth = 0; out.append(c); i += 1; continue }

            switch c {
            case "{":
                out += " {"
                indent += 1
                newlineAndIndent()
            case "}":
                indent = max(0, indent - 1)
                while !out.isEmpty && out.last == " " { out.removeLast() }
                if !out.isEmpty && out.last != "\n" { newlineAndIndent() }
                out += "}"
                // Peek: if next non-space is not , ; ) ], add newline
                var j = i + 1
                while j < chars.count && (chars[j] == " " || chars[j] == "\t") { j += 1 }
                let next: Character = j < chars.count ? chars[j] : " "
                if next != "," && next != ";" && next != ")" && next != "]" && next != "." {
                    newlineAndIndent()
                }
            case ";":
                out += ";"
                newlineAndIndent()
            case "\n", "\r":
                if !out.isEmpty && out.last == " " { out.removeLast() }
                if !out.isEmpty && out.last != "\n" { newlineAndIndent() }
            case " ", "\t":
                if !out.isEmpty && out.last != " " && out.last != "\n" { out += " " }
            default:
                out.append(c)
            }
            if c != " " && c != "\t" && c != "\n" && c != "\r" { prevNonSpace = c }
            i += 1
        }
        return PrettyResult(text: out, linemap: linemap, reverseLinemap: reverseLinemap)
    }


    static func html(_ input: String) -> PrettyResult {
        var out = ""
        out.reserveCapacity(input.count)
        var indent = 0
        var prettyLine = 0
        var origLine = 0
        var linemap: [Int: Int] = [:]
        var reverseLinemap: [Int: Int] = [:]
        linemap[0] = 0
        reverseLinemap[0] = 0

        func recordLine() {
            prettyLine += 1
            if linemap[origLine] == nil { linemap[origLine] = prettyLine }
            reverseLinemap[prettyLine] = origLine
        }
        func indentStr() -> String { String(repeating: "  ", count: max(0, indent)) }

        var i = input.startIndex
        let noIndentTags: Set<String> = ["html", "head", "body"]
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let rawTags: Set<String> = ["script", "style", "pre", "textarea"]
        var rawTag: String? = nil

        while i < input.endIndex {
            let c = input[i]
            if c == "\n" { origLine += 1 }
            if let rt = rawTag {
                let close = "</" + rt
                let remaining = String(input[i...])
                if remaining.lowercased().hasPrefix(close) {
                    rawTag = nil
                    indent = max(0, indent - 1)
                    out += "\n"
                    recordLine()
                    out += indentStr()
                } else {
                    out.append(c)
                    if c == "\n" { recordLine() }
                }
                i = input.index(after: i)
                continue
            }
            if c == "<" {
                var j = input.index(after: i)
                while j < input.endIndex && input[j] != ">" { j = input.index(after: j) }
                if j < input.endIndex { j = input.index(after: j) }
                let tagText = String(input[i..<j])
                let isClose = tagText.hasPrefix("</")
                let tagName = extractTagName(tagText).lowercased()
                if isClose {
                    indent = max(0, indent - 1)
                    if !out.isEmpty && out.last != "\n" { out += "\n"; recordLine() }
                    out += indentStr()
                } else {
                    if !out.isEmpty && out.last != "\n" { out += "\n"; recordLine() }
                    out += indentStr()
                }
                out += tagText
                if !isClose && !voidTags.contains(tagName) && !tagText.hasSuffix("/>") {
                    indent += 1
                    if rawTags.contains(tagName) { rawTag = tagName }
                }
                if !isClose && !voidTags.contains(tagName) { out += "\n"; recordLine() }
                i = j
            } else if c == "\n" || c == "\r" {
                i = input.index(after: i)
            } else {
                var j = i
                while j < input.endIndex && input[j] != "<" { j = input.index(after: j) }
                let text = String(input[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out += "\n"
                    recordLine()
                    out += indentStr() + text
                }
                i = j
            }
        }
        return PrettyResult(text: out, linemap: linemap, reverseLinemap: reverseLinemap)
    }

    private static func extractTagName(_ tag: String) -> String {
        var s = tag.dropFirst() // Remove <
        if s.hasPrefix("/") { s = s.dropFirst() }
        let name = String(s.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }))
        return name
    }
}

enum SyntaxTokenKind: Sendable {
    case keyword
    case string
    case comment
    case number
    case property     // CSS property name / JS function name
    case selector     // CSS selector
    case tag          // HTML tag name
    case attribute    // HTML attribute name
    case attributeValue
    case punctuation
    case operator_
    case type_        // TypeScript type name
    case plain
}

struct SyntaxTokenRange: Sendable {
    var range: Range<String.Index>
    var kind: SyntaxTokenKind
}

enum HTMLTokenizer {
    static func tokenize(_ text: String) -> [SyntaxTokenRange] {
        var result: [SyntaxTokenRange] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<" {
                var j = text.index(after: i)
                if text[j...].hasPrefix("!--") {
                    let closeStr = "-->"
                    if let closeRange = text.range(of: closeStr, range: j..<text.endIndex) {
                        result.append(SyntaxTokenRange(range: i..<closeRange.upperBound, kind: .comment))
                        i = closeRange.upperBound
                        continue
                    }
                }
                if text[j...].lowercased().hasPrefix("!doctype") {
                    while j < text.endIndex && text[j] != ">" { j = text.index(after: j) }
                    if j < text.endIndex { j = text.index(after: j) }
                    result.append(SyntaxTokenRange(range: i..<j, kind: .keyword))
                    i = j
                    continue
                }
                let isClose = j < text.endIndex && text[j] == "/"
                if isClose { j = text.index(after: j) }
                let nameStart = j
                while j < text.endIndex && (text[j].isLetter || text[j].isNumber || text[j] == "-" || text[j] == "_" || text[j] == ":") {
                    j = text.index(after: j)
                }
                if j > nameStart {
                    result.append(SyntaxTokenRange(range: nameStart..<j, kind: .tag))
                }
                // Attributes
                while j < text.endIndex && text[j] != ">" {
                    while j < text.endIndex && text[j] == " " { j = text.index(after: j) }
                    if j >= text.endIndex || text[j] == ">" || text[j] == "/" { break }
                    let attrStart = j
                    while j < text.endIndex && text[j] != "=" && text[j] != " " && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    if j > attrStart {
                        result.append(SyntaxTokenRange(range: attrStart..<j, kind: .attribute))
                    }
                    if j < text.endIndex && text[j] == "=" {
                        j = text.index(after: j)
                        if j < text.endIndex && (text[j] == "\"" || text[j] == "'") {
                            let quote = text[j]
                            let valStart = j
                            j = text.index(after: j)
                            while j < text.endIndex && text[j] != quote { j = text.index(after: j) }
                            if j < text.endIndex { j = text.index(after: j) }
                            result.append(SyntaxTokenRange(range: valStart..<j, kind: .attributeValue))
                        }
                    }
                }
                if j < text.endIndex { j = text.index(after: j) }
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return result
    }
}

enum JSONTokenizer {
    private static let keywords: Set<String> = ["true", "false", "null"]

    static func tokenize(_ text: String) -> [SyntaxTokenRange] {
        let pattern = #"""
        (?<comment>//.*$|/\*[\s\S]*?\*/)|
        (?<string>"(?:[^"\\]|\\.)*")|
        (?<number>-?\b\d+\.?\d*(?:[eE][+-]?\d+)?\b)|
        (?<word>\b(?:true|false|null)\b)
        """#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace, .anchorsMatchLines]) else { return [] }
        var result: [SyntaxTokenRange] = []
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            func range(named name: String) -> Range<String.Index>? {
                let r = match.range(withName: name)
                guard r.location != NSNotFound else { return nil }
                return Range(r, in: text)
            }
            if let r = range(named: "comment") { result.append(SyntaxTokenRange(range: r, kind: .comment)); return }
            if let r = range(named: "string") { result.append(SyntaxTokenRange(range: r, kind: .string)); return }
            if let r = range(named: "number") { result.append(SyntaxTokenRange(range: r, kind: .number)); return }
            if let r = range(named: "word") { result.append(SyntaxTokenRange(range: r, kind: .keyword)); return }
        }
        return result
    }
}

enum TypeScriptTokenizer {
    static let extraKeywords: Set<String> = [
        "type", "interface", "enum", "namespace", "abstract", "declare", "readonly",
        "as", "from", "implements", "extends", "keyof", "typeof", "infer", "never",
        "any", "unknown", "void", "boolean", "number", "string", "symbol", "object",
        "public", "private", "protected", "override", "satisfies", "using",
    ]
}


enum SourceLanguage: Sendable {
    case javaScript
    case typeScript
    case css
    case scss
    case html
    case json
    case xml
    case svg
    case markdown
    case wasm
    case other

    static func detect(url: String, mimeType: String) -> SourceLanguage {
        let u = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
        if u.hasSuffix(".ts") || u.hasSuffix(".tsx") { return .typeScript }
        if u.hasSuffix(".js") || u.hasSuffix(".mjs") || u.hasSuffix(".jsx") || u.hasSuffix(".cjs") { return .javaScript }
        if u.hasSuffix(".css") { return .css }
        if u.hasSuffix(".scss") || u.hasSuffix(".sass") { return .scss }
        if u.hasSuffix(".html") || u.hasSuffix(".htm") { return .html }
        if u.hasSuffix(".json") || u.hasSuffix(".jsonc") { return .json }
        if u.hasSuffix(".xml") { return .xml }
        if u.hasSuffix(".svg") { return .svg }
        if u.hasSuffix(".md") || u.hasSuffix(".mdx") { return .markdown }
        if u.hasSuffix(".wasm") { return .wasm }
        let m = mimeType.lowercased()
        if m.contains("javascript") || m.contains("ecmascript") { return .javaScript }
        if m.contains("typescript") { return .typeScript }
        if m.contains("css") { return .css }
        if m.contains("html") { return .html }
        if m.contains("json") { return .json }
        if m.contains("xml") { return .xml }
        if m.contains("svg") { return .svg }
        if m.contains("wasm") { return .wasm }
        return .other
    }
}
