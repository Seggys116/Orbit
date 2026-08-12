//  Foundation only — symlinked into OrbitTests/ReusedAssistSources/.

import Foundation

// MARK: - Errors

enum LinkPreviewFetchError: LocalizedError, Equatable, Sendable {
    case unsupportedScheme
    case transport(String)
    case http(status: Int)
    case unsupportedContentType(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            return "This link cannot be previewed."
        case .transport(let message):
            return "Could not reach the page: \(message)"
        case .http(let status):
            return "The page returned HTTP \(status)."
        case .unsupportedContentType(let contentType):
            return "This page is not a web page Orbit can preview (\(contentType))."
        case .decodingFailed:
            return "This page's content could not be read as text."
        }
    }
}

// MARK: - Fetcher

enum LinkPreviewFetcher {

    static let maxBytes = 512 * 1_024
    static let textCharacterBudget = 6_000
    static let requestTimeout: TimeInterval = 8

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) OrbitLinkPreview/1.0 Safari/605.1.15"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    struct LinkPreviewPageData: Equatable, Sendable {
        var sourceURL: URL
        var imageURL: URL?
        var title: String?
        var description: String?
        var pageText: PageTextExtract
    }

    static func fetchPreviewData(
        for url: URL,
        session: URLSession = LinkPreviewFetcher.session
    ) async throws -> LinkPreviewPageData {
        try validateScheme(url)

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestTimeout

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await boundedBody(for: request, session: session)
        } catch let error as LinkPreviewFetchError {
            throw error
        } catch {
            throw LinkPreviewFetchError.transport(error.localizedDescription)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LinkPreviewFetchError.decodingFailed
        }

        let finalURL = response.url ?? url
        let imageURL = extractImageURL(fromHTML: html, pageURL: finalURL)
        let title = extractTitle(fromHTML: html)
        let description = extractDescription(fromHTML: html)
        let readable = readableText(fromHTML: html)
        let (truncatedText, totalCharacters) = truncate(readable, budget: textCharacterBudget)

        let pageText = PageTextExtract(
            title: title ?? "",
            url: finalURL.absoluteString,
            text: truncatedText,
            totalCharacters: totalCharacters
        )
        return LinkPreviewPageData(sourceURL: finalURL, imageURL: imageURL, title: title, description: description, pageText: pageText)
    }

    static func validateScheme(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
            throw LinkPreviewFetchError.unsupportedScheme
        }
    }

    @discardableResult
    static func validateResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw LinkPreviewFetchError.transport("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinkPreviewFetchError.http(status: http.statusCode)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("html") else {
            throw LinkPreviewFetchError.unsupportedContentType(contentType.isEmpty ? "(none)" : contentType)
        }
        return http
    }

    private static func boundedBody(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (byteStream, response) = try await session.bytes(for: request)
        try validateResponse(response)

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1_024))
        for try await byte in byteStream {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return (data, response)
    }

    // MARK: - `<meta>` extraction

    /// Falls back to a favicon or placeholder never — `nil` means the page declared no image.
    static func extractImageURL(fromHTML html: String, pageURL: URL) -> URL? {
        let raw = metaContent(properties: ["og:image", "og:image:url"], in: html)
            ?? metaContent(properties: ["twitter:image", "twitter:image:src"], in: html)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw, relativeTo: pageURL)?.absoluteURL
    }

    static func extractTitle(fromHTML html: String) -> String? {
        metaContent(properties: ["og:title"], in: html) ?? extractDocumentTitle(fromHTML: html)
    }

    static func extractDescription(fromHTML html: String) -> String? {
        metaContent(properties: ["og:description"], in: html)
    }

    static func extractDocumentTitle(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let decoded = decodeHTMLEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    static func metaContent(properties: [String], in html: String) -> String? {
        let wanted = Set(properties.map { $0.lowercased() })
        for tag in metaTags(in: html) {
            let key = (attributeValue("property", in: tag) ?? attributeValue("name", in: tag))?.lowercased()
            guard let key, wanted.contains(key) else { continue }
            guard let content = attributeValue("content", in: tag), !content.isEmpty else { continue }
            return decodeHTMLEntities(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func metaTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func attributeValue(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\#(escapedName)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for groupIndex in [1, 2] {
            if let range = Range(match.range(at: groupIndex), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }

    // MARK: - Readable text

    /// `<script>`/`<style>`/`<noscript>`/`<svg>` removed with their contents — a `<script>` body left in could smuggle instructions to the model.
    static func readableText(fromHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg"] {
            text = stripElementAndContents(tag, from: text)
        }
        text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripElementAndContents(_ tagName: String, from html: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: tagName)
        let pattern = "<\(escaped)\\b[^>]*>[\\s\\S]*?</\(escaped)\\s*>"
        return html.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }

    static func truncate(_ text: String, budget: Int) -> (text: String, totalCharacters: Int) {
        let total = text.count
        guard total > budget else { return (text, total) }
        return (String(text.prefix(budget)), total)
    }

    // MARK: - Entity decoding

    static func decodeHTMLEntities(_ string: String) -> String {
        var result = decodeNumericEntities(string)
        // &amp; must decode last, or a double-encoded &amp;lt; becomes < instead of the literal &lt;.
        for (entity, replacement) in namedEntitiesAmpersandLast {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static func decodeNumericEntities(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#x?[0-9A-Fa-f]+;"#, options: [.caseInsensitive]) else { return string }
        let ns = string as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            if let scalarValue = numericEntityScalarValue(token), let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else {
                result += token
            }
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    private static func numericEntityScalarValue(_ token: String) -> Int? {
        let inner = token.dropFirst(2).dropLast()
        if inner.hasPrefix("x") || inner.hasPrefix("X") {
            return Int(inner.dropFirst(), radix: 16)
        }
        return Int(inner)
    }

    private static let namedEntitiesAmpersandLast: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"),
        ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ("&copy;", "\u{00A9}"), ("&reg;", "\u{00AE}"), ("&trade;", "\u{2122}"),
        ("&eacute;", "\u{00E9}"), ("&Eacute;", "\u{00C9}"), ("&egrave;", "\u{00E8}"), ("&agrave;", "\u{00E0}"),
        ("&ccedil;", "\u{00E7}"), ("&ouml;", "\u{00F6}"), ("&uuml;", "\u{00FC}"), ("&auml;", "\u{00E4}"),
        ("&ntilde;", "\u{00F1}"), ("&deg;", "\u{00B0}"), ("&middot;", "\u{00B7}"), ("&bull;", "\u{2022}"),
        ("&amp;", "&"),
    ]
}
