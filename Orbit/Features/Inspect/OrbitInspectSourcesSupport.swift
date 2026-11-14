import AppKit
import Foundation
import WebKit

struct SourceFetchResult: Sendable {
    var url: URL
    var text: String
    var encoding: String
    var wasTruncated: Bool
    var mimeType: String
    var responseHeaders: [String: String]
}

enum SourceFetchError: Error {
    case binary
    case tooLarge
    case network(Error)
    case badStatus(Int)
}

/// Fetches natively so cross-origin and CSP-blocked resources still load.
actor SourceFetcher {
    static let shared = SourceFetcher()

    private var cache: [String: SourceFetchResult] = [:]
    private var inFlight: [String: Task<SourceFetchResult, Error>] = [:]

    private static let sizeLimit = 8 * 1024 * 1024  // 8 MB
    private static let hardLimit = 8 * 1024 * 1024 + 4096

    func fetch(urlString: String, webView: WKWebView) async throws -> SourceFetchResult {
        if let cached = cache[urlString] { return cached }
        if let existing = inFlight[urlString] {
            return try await existing.value
        }
        let task = Task<SourceFetchResult, Error> {
            let result = try await Self.performFetch(urlString: urlString, webView: webView)
            return result
        }
        inFlight[urlString] = task
        do {
            let result = try await task.value
            cache[urlString] = result
            inFlight.removeValue(forKey: urlString)
            return result
        } catch {
            inFlight.removeValue(forKey: urlString)
            throw error
        }
    }

    func invalidate(urlString: String) {
        cache.removeValue(forKey: urlString)
    }

    func invalidateAll() {
        cache.removeAll()
        inFlight.forEach { $0.value.cancel() }
        inFlight.removeAll()
    }

    private static func performFetch(urlString: String, webView: WKWebView) async throws -> SourceFetchResult {
        guard let url = URL(string: urlString) else {
            throw SourceFetchError.network(URLError(.badURL))
        }
        // The request carries the page's user agent, referer and matching cookies so authenticated resources still load.
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        request.setValue(webView.customUserAgent ?? defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = webView.url?.absoluteString {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies = await cookieStore.allCookies()
        let relevant = allCookies.filter { cookie in
            guard let host = url.host else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        if !relevant.isEmpty {
            let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceFetchError.network(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SourceFetchError.badStatus(httpResponse.statusCode)
        }
        // Binary resources have no text preview.
        let mime = httpResponse.mimeType ?? ""
        let isBinary = mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.hasPrefix("font/") || mime.contains("wasm") || mime.contains("octet-stream")
        if isBinary { throw SourceFetchError.binary }
        let wasTruncated = data.count > sizeLimit
        let sliced: Data = wasTruncated ? data.prefix(sizeLimit) : data
        let (encoding, encodingName) = Self.detectEncoding(data: sliced, mimeType: mime, headers: httpResponse.allHeaderFields)
        var text = String(data: sliced, encoding: encoding) ?? String(data: sliced, encoding: .isoLatin1) ?? ""
        if wasTruncated { text += "\n// [Orbit Sources: truncated at 8 MB]" }
        var headers: [String: String] = [:]
        for (k, v) in httpResponse.allHeaderFields {
            if let key = k as? String, let val = v as? String { headers[key] = val }
        }
        return SourceFetchResult(url: url, text: text, encoding: encodingName, wasTruncated: wasTruncated, mimeType: mime, responseHeaders: headers)
    }

    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15"

    private static func detectEncoding(data: Data, mimeType: String, headers: [AnyHashable: Any]) -> (String.Encoding, String) {
        if data.prefix(3) == Data([0xEF, 0xBB, 0xBF]) { return (.utf8, "UTF-8") }
        if data.prefix(2) == Data([0xFF, 0xFE]) { return (.utf16LittleEndian, "UTF-16LE") }
        if data.prefix(2) == Data([0xFE, 0xFF]) { return (.utf16BigEndian, "UTF-16BE") }
        let ctHeader = headers["Content-Type"] as? String
        let ctSource = ctHeader ?? (mimeType.isEmpty ? nil : mimeType)
        if let ct = ctSource, let charsetRange = ct.range(of: "charset=", options: .caseInsensitive) {
            var charsetStr = String(ct[charsetRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let semi = charsetStr.firstIndex(of: ";") { charsetStr = String(charsetStr[..<semi]) }
            charsetStr = charsetStr.uppercased().trimmingCharacters(in: .whitespaces)
            if charsetStr == "UTF-8" || charsetStr == "UTF8" { return (.utf8, "UTF-8") }
            if charsetStr == "ISO-8859-1" || charsetStr == "LATIN1" { return (.isoLatin1, "ISO-8859-1") }
            if charsetStr == "UTF-16" { return (.utf16, "UTF-16") }
        }
        // Last resort: a meta charset declared in the first 1 KB.
        if let snippet = String(data: data.prefix(1024), encoding: .utf8) {
            if snippet.contains("charset=utf-8") || snippet.contains("charset=\"utf-8\"") { return (.utf8, "UTF-8") }
        }
        return (.utf8, "UTF-8")
    }
}

enum SourceMapHeaderDetector {
    static func headerURL(from headers: [String: String]) -> String? {
        return headers["SourceMap"] ?? headers["X-SourceMap"] ?? headers["sourcemap"] ?? headers["x-sourcemap"]
    }
}

struct SyntaxPalette: Sendable {
    var keyword: NSColor
    var string: NSColor
    var comment: NSColor
    var number: NSColor
    var property: NSColor
    var selector: NSColor
    var tag: NSColor
    var attribute: NSColor
    var attributeValue: NSColor
    var plain: NSColor
    var currentLine: NSColor
    var background: NSColor
    var lineNumberFg: NSColor
    var lineNumberBg: NSColor

    static func make(dark: Bool) -> SyntaxPalette {
        if dark {
            return SyntaxPalette(
                keyword:        NSColor(red: 0.98, green: 0.42, blue: 0.55, alpha: 1),
                string:         NSColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                comment:        NSColor(red: 0.52, green: 0.56, blue: 0.60, alpha: 1),
                number:         NSColor(red: 0.68, green: 0.85, blue: 0.55, alpha: 1),
                property:       NSColor(red: 0.42, green: 0.68, blue: 1.00, alpha: 1),
                selector:       NSColor(red: 0.85, green: 0.45, blue: 0.95, alpha: 1),
                tag:            NSColor(red: 0.85, green: 0.55, blue: 0.45, alpha: 1),
                attribute:      NSColor(red: 0.60, green: 0.78, blue: 0.50, alpha: 1),
                attributeValue: NSColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                plain:          NSColor(white: 0.92, alpha: 1),
                currentLine:    NSColor(white: 1.00, alpha: 0.05),
                background:     NSColor(white: 0.11, alpha: 1),
                lineNumberFg:   NSColor(white: 0.45, alpha: 1),
                lineNumberBg:   NSColor(white: 0.09, alpha: 1)
            )
        } else {
            return SyntaxPalette(
                keyword:        NSColor(red: 0.82, green: 0.14, blue: 0.38, alpha: 1),
                string:         NSColor(red: 0.72, green: 0.25, blue: 0.10, alpha: 1),
                comment:        NSColor(red: 0.43, green: 0.48, blue: 0.53, alpha: 1),
                number:         NSColor(red: 0.10, green: 0.45, blue: 0.78, alpha: 1),
                property:       NSColor(red: 0.14, green: 0.38, blue: 0.82, alpha: 1),
                selector:       NSColor(red: 0.60, green: 0.12, blue: 0.75, alpha: 1),
                tag:            NSColor(red: 0.70, green: 0.22, blue: 0.10, alpha: 1),
                attribute:      NSColor(red: 0.20, green: 0.55, blue: 0.25, alpha: 1),
                attributeValue: NSColor(red: 0.72, green: 0.25, blue: 0.10, alpha: 1),
                plain:          NSColor(white: 0.10, alpha: 1),
                currentLine:    NSColor(white: 0.00, alpha: 0.04),
                background:     NSColor(white: 0.97, alpha: 1),
                lineNumberFg:   NSColor(white: 0.60, alpha: 1),
                lineNumberBg:   NSColor(white: 0.92, alpha: 1)
            )
        }
    }

    func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword:        return keyword
        case .string:         return string
        case .comment:        return comment
        case .number:         return number
        case .property:       return property
        case .selector:       return selector
        case .tag:            return tag
        case .attribute:      return attribute
        case .attributeValue: return attributeValue
        case .type_:          return property
        case .operator_:      return plain
        case .punctuation:    return plain
        case .plain:          return plain
        }
    }
}

enum SourceHighlighter {
    static func apply(to storage: NSTextStorage, language: SourceLanguage, palette: SyntaxPalette) {
        let text = storage.string
        guard !text.isEmpty else { return }
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        storage.setAttributes([.foregroundColor: palette.plain, .font: font], range: full)
        switch language {
        case .javaScript, .typeScript:
            applyJS(storage: storage, text: text, language: language, palette: palette)
        case .css, .scss:
            applyCSS(storage: storage, text: text, palette: palette)
        case .html, .xml, .svg:
            applyHTML(storage: storage, text: text, palette: palette)
        case .json:
            applyJSON(storage: storage, text: text, palette: palette)
        case .markdown, .wasm, .other:
            break
        }
        storage.endEditing()
    }

    private static func applyJS(storage: NSTextStorage, text: String, language: SourceLanguage, palette: SyntaxPalette) {
        let pattern = #"""
        (?<comment>//.*$|/\*[\s\S]*?\*/)|\
        (?<string>`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|\
        (?<number>-?\b\d+\.?\d*\b)|\
        (?<word>\b[a-zA-Z_$][a-zA-Z0-9_$]*\b)
        """#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace, .anchorsMatchLines]) else { return }
        let jsKeywords: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "class", "extends", "new", "typeof", "instanceof", "true", "false", "null", "undefined", "this", "async", "await", "import", "export", "default", "try", "catch", "finally", "throw", "of", "in", "delete", "void", "yield", "static", "get", "set", "super"]
        let tsKeywords = TypeScriptTokenizer.extraKeywords
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            func applyNamed(_ name: String, color: NSColor) -> Bool {
                let r = match.range(withName: name)
                guard r.location != NSNotFound else { return false }
                storage.addAttribute(.foregroundColor, value: color, range: r)
                return true
            }
            if applyNamed("comment", color: palette.comment) { return }
            if applyNamed("string", color: palette.string) { return }
            if applyNamed("number", color: palette.number) { return }
            let wordRange = match.range(withName: "word")
            if wordRange.location != NSNotFound, let r = Range(wordRange, in: text) {
                let word = String(text[r])
                if jsKeywords.contains(word) || (language == .typeScript && tsKeywords.contains(word)) {
                    storage.addAttribute(.foregroundColor, value: palette.keyword, range: wordRange)
                } else if let nextIdx = text[r.upperBound...].first, nextIdx == "(" {
                    storage.addAttribute(.foregroundColor, value: palette.property, range: wordRange)
                }
            }
        }
    }

    private static func applyCSS(storage: NSTextStorage, text: String, palette: SyntaxPalette) {
        let pattern = #"""
        (?<comment>/\*[\s\S]*?\*/)|\
        (?<string>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|\
        (?<atrule>@[a-zA-Z-]+)|\
        (?<important>!important)|\
        (?<number>-?\b\d+\.?\d*(px|em|rem|%|vh|vw|s|ms|deg|vmin|vmax|ch|ex|fr|turn|rad|grad|dpi|dpcm|dppx)?\b)|\
        (?<property>[a-zA-Z-]+(?=\s*:))|\
        (?<selector>[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=[\s,.:#\[{]))
        """#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace]) else { return }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            let groups: [(String, NSColor)] = [
                ("comment", palette.comment), ("string", palette.string), ("atrule", palette.selector),
                ("important", palette.keyword), ("number", palette.number),
                ("property", palette.property), ("selector", palette.selector),
            ]
            for (name, color) in groups {
                let r = match.range(withName: name)
                if r.location != NSNotFound { storage.addAttribute(.foregroundColor, value: color, range: r); return }
            }
        }
    }

    private static func applyHTML(storage: NSTextStorage, text: String, palette: SyntaxPalette) {
        let tokens = HTMLTokenizer.tokenize(text)
        for token in tokens {
            let nsRange = NSRange(token.range, in: text)
            guard nsRange.location != NSNotFound else { continue }
            storage.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: nsRange)
        }
    }

    private static func applyJSON(storage: NSTextStorage, text: String, palette: SyntaxPalette) {
        let tokens = JSONTokenizer.tokenize(text)
        for token in tokens {
            let nsRange = NSRange(token.range, in: text)
            guard nsRange.location != NSNotFound else { continue }
            storage.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: nsRange)
        }
    }

    static func applyVisible(to storage: NSTextStorage, language: SourceLanguage, palette: SyntaxPalette, visibleRange: NSRange) {
        let text = storage.string
        let nsText = text as NSString
        let start = nsText.lineRange(for: NSRange(location: max(0, visibleRange.location - 1), length: 0)).location
        let end = min(nsText.length, NSMaxRange(nsText.lineRange(for: NSRange(location: min(nsText.length - 1, NSMaxRange(visibleRange)), length: 0))))
        let expandedRange = NSRange(location: start, length: end - start)
        guard expandedRange.length > 0 else { return }
        // A partial range would need context-aware tokenisation, so the full text is re-tokenised and only the expanded range is written; that is still costly for large files.
        apply(to: storage, language: language, palette: palette)
    }
}

enum SourceSnippetsStore {
    private static let key = "orbit.sources.snippets"

    static func load() -> [SourceSnippet] {
        guard let data = OrbitDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SourceSnippet].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ snippets: [SourceSnippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        OrbitDefaults.standard.set(data, forKey: key)
    }
}


enum SourceOverridesStore {
    private static let key = "orbit.sources.cssOverrides"

    static func load(forSite site: String) -> [String: String] {
        let all = OrbitDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return all[site] ?? [:]
    }

    static func save(_ overrides: [String: String], forSite site: String) {
        var all = OrbitDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        all[site] = overrides.isEmpty ? nil : overrides
        OrbitDefaults.standard.set(all, forKey: key)
    }
}
