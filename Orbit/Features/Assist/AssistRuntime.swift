import Foundation

@MainActor
final class AssistRuntime {

    static let shared = AssistRuntime()

    /// Not `private` — a test constructs its own runtime rather than sharing history.
    init() {}

    // MARK: - Building the production sink

    /// Returns `nil` for Assist switched off, no provider, or a non-persistent (incognito) session. Checks the session flag, not `AppEnvironment.isIncognito`, so a UI-layer refactor can't get it wrong.
    static func productionSink(for contents: (any WebContents)?) -> AssistSink? {
        guard AssistSettings.isEnabled else { return nil }
        let config = AssistSettings.providerConfig
        guard config.isConfigured else { return nil }
        if let contents, !contents.session.isPersistent { return nil }

        let client = AssistProviderClient(config: config)
        return AssistSink(
            generate: { request in try await client.generate(request) },
            pageText: { [weak contents] in
                guard let contents else { return nil }
                return await PageTextExtractor.extract(from: contents)
            }
        )
    }

    static func providerOnlySink() -> AssistSink? {
        guard AssistSettings.isEnabled else { return nil }
        let config = AssistSettings.providerConfig
        guard config.isConfigured else { return nil }
        let client = AssistProviderClient(config: config)
        return AssistSink(
            generate: { request in try await client.generate(request) },
            pageText: { nil }
        )
    }

    // MARK: - Ask on Page (spec §6.7, §6.12)

    struct Answer: Equatable, Sendable {
        var question: String
        var text: String
        var truncationNotice: String?
        /// `nil` unless the quote was verified verbatim in the sent text — see `verifiedQuote(_:in:)`.
        var quote: String?
    }

    func askOnPage(question: String, sink: AssistSink) async throws -> Answer {
        guard AssistSettings.isAskOnPageEnabled else { throw AssistError.featureDisabled("Ask on Page") }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AssistError.noPageText }
        guard let extract = await sink.pageText() else { throw AssistError.noPageText }

        let raw = try await sink.generate(
            AssistRequest(
                system: Self.askOnPageSystemPrompt,
                user: Self.askOnPageUserPrompt(question: trimmed, extract: extract),
                maxOutputTokens: 400
            )
        )
        let split = Self.splitQuoteAndAnswer(raw)
        return Answer(
            question: trimmed,
            text: split.answer,
            truncationNotice: extract.truncationNotice,
            quote: Self.verifiedQuote(split.quote, in: extract.text)
        )
    }

    static let askOnPageSystemPrompt = """
        You answer questions about one web page, using only the page text supplied. \
        Reply in exactly this format and nothing else:
        QUOTE: <one sentence copied word for word from the page text that supports your answer, or the word NONE>
        ANSWER: <your answer, at most three sentences>
        Copy the quote exactly as it appears. Do not paraphrase it, do not shorten it, do not add ellipses. \
        If the page does not answer the question, use NONE for the quote and say so in the answer.
        """

    static func splitQuoteAndAnswer(_ raw: String) -> (quote: String?, answer: String) {
        var quote: String?
        var answerLines: [String] = []
        var sawAnswerLabel = false

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !sawAnswerLabel, text.uppercased().hasPrefix("QUOTE:") {
                let value = String(text.dropFirst("QUOTE:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                quote = (value.isEmpty || value.uppercased() == "NONE") ? nil : value
            } else if text.uppercased().hasPrefix("ANSWER:") {
                sawAnswerLabel = true
                answerLines.append(String(text.dropFirst("ANSWER:".count)).trimmingCharacters(in: .whitespaces))
            } else if sawAnswerLabel {
                answerLines.append(String(line))
            }
        }

        let answer = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            return (nil, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (quote, answer)
    }

    /// Containment match only — fuzzy matching would let an invented quote through as verbatim.
    static func verifiedQuote(_ candidate: String?, in pageText: String) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }
        let needle = normalizeForQuoteMatch(trimmed)
        guard !needle.isEmpty else { return nil }
        return normalizeForQuoteMatch(pageText).contains(needle) ? trimmed : nil
    }

    static func normalizeForQuoteMatch(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
        normalized = normalized.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return normalized
    }

    static func askOnPageUserPrompt(question: String, extract: PageTextExtract) -> String {
        """
        Page title: \(extract.title)
        Page URL: \(extract.url)

        Page text:
        \(extract.text)

        Question: \(question)
        """
    }

    // MARK: - Tidy Tab Titles (spec §6.7)

    /// Returns `nil` (not a throw) when the model's answer is unusable; a background rename has no UI to report an error into.
    func tidiedTabTitle(rawTitle: String, url: URL, sink: AssistSink) async throws -> String? {
        guard AssistSettings.isTidyTabTitlesEnabled else { throw AssistError.featureDisabled("Tidy Tab Titles") }
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.tidyTitleMinimumLength else { return nil }

        let answer = try await sink.generate(
            AssistRequest(
                system: Self.tidyTitleSystemPrompt,
                user: "URL: \(url.absoluteString)\nTitle: \(trimmed)",
                maxOutputTokens: 32,
                temperature: 0.0
            )
        )
        return Self.acceptTidiedTitle(answer, original: trimmed)
    }

    static let tidyTitleMinimumLength = 32

    static let tidyTitleSystemPrompt = """
        Shorten a browser tab title so it fits a narrow sidebar. \
        Reply with the shortened title only — no quotes, no punctuation around it, no explanation. \
        Keep the specific subject and drop the site name, section names and marketing suffixes. \
        Use at most six words.
        """

    static func acceptTidiedTitle(_ candidate: String, original: String) -> String? {
        var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if let firstLine = cleaned.split(separator: "\n").first { cleaned = String(firstLine) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count < original.count else { return nil }
        guard cleaned.split(separator: " ").count <= 8 else { return nil }
        return cleaned
    }

    // MARK: - Tidy Tabs (spec §6.7)

    struct TidyTabGroup: Equatable, Sendable {
        var name: String
        var tabIDs: [TabID]
    }

    struct TidyTabCandidate: Equatable, Sendable {
        var id: TabID
        var title: String
        var url: URL
    }

    static let tidyTabsMinimumTabs = 6
    static let tidyTabsMinimumGroupSize = 2

    /// Never falls back to host grouping on failure — that fallback is the separate `AppEnvironment.tidyTodayTabsByHost` path.
    func tidiedTabGroups(candidates: [TidyTabCandidate], sink: AssistSink) async throws -> [TidyTabGroup] {
        guard AssistSettings.isTidyTabsEnabled else { throw AssistError.featureDisabled("Tidy Tabs") }
        guard candidates.count > Self.tidyTabsMinimumTabs else { throw AssistError.featureDisabled("Tidy Tabs") }

        let raw = try await sink.generate(
            AssistRequest(
                system: Self.tidyTabsSystemPrompt,
                user: Self.tidyTabsUserPrompt(candidates: candidates),
                maxOutputTokens: 400,
                temperature: 0.0
            )
        )
        let parsed = Self.parseTidyTabsReply(raw, candidates: candidates)
        let grounded = Self.groundedTidyGroups(parsed, in: candidates)
        guard !grounded.isEmpty else { throw AssistError.emptyCompletion }
        return grounded
    }

    static let tidyTabsSystemPrompt = """
        You group a list of numbered browser tabs by what they are about, for headers in a browser sidebar. \
        Reply in exactly this format and nothing else, one line per group:
        GROUP: <short name, at most three words> | <the numbers of the tabs in this group, comma separated>
        Use the tab titles and addresses given and nothing you know from elsewhere. \
        Every group must contain at least two tabs. Use each number at most once. \
        Leave a tab out entirely rather than forcing it into a group it does not belong in, \
        or put the leftovers in a group named Other. \
        Name a group after what its tabs have in common. Do not number the groups and do not explain them.
        """

    static func tidyTabsUserPrompt(candidates: [TidyTabCandidate]) -> String {
        let lines = candidates.enumerated().map { index, candidate in
            "\(index + 1). \(candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)) — \(candidate.url.absoluteString)"
        }
        return "Tabs:\n" + lines.joined(separator: "\n")
    }

    static func parseTidyTabsReply(_ raw: String, candidates: [TidyTabCandidate]) -> [TidyTabGroup] {
        var groups: [TidyTabGroup] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.uppercased().hasPrefix("GROUP:") else { continue }
            let body = String(text.dropFirst("GROUP:".count))
            let parts = body.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            guard let name = acceptTidyGroupName(parts[0]) else { continue }
            let numbers = parts[1]
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            let ids = numbers.compactMap { number -> TabID? in
                guard number >= 1, number <= candidates.count else { return nil }
                return candidates[number - 1].id
            }
            guard !ids.isEmpty else { continue }
            groups.append(TidyTabGroup(name: name, tabIDs: ids))
        }
        return groups
    }

    static func acceptTidyGroupName(_ candidate: String) -> String? {
        var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = cleaned.first, first.isNumber || first == "-" || first == "*" {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".) "))
        }
        // Trimmed as one combined set, not sequentially — a colon after a quote otherwise survives.
        cleaned = cleaned.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'`:").union(.whitespacesAndNewlines)
        )
        guard !cleaned.isEmpty, cleaned.count <= 32 else { return nil }
        guard cleaned.split(separator: " ").count <= 4 else { return nil }
        return cleaned
    }

    static func groundedTidyGroups(_ groups: [TidyTabGroup], in candidates: [TidyTabCandidate]) -> [TidyTabGroup] {
        let sent = Set(candidates.map(\.id))
        var claimed: Set<TabID> = []
        var result: [TidyTabGroup] = []

        for group in groups {
            var members: [TabID] = []
            for id in group.tabIDs where sent.contains(id) && !claimed.contains(id) {
                claimed.insert(id)
                members.append(id)
            }
            guard members.count >= tidyTabsMinimumGroupSize else {
                // Must give tabs back or a later legitimate group naming the same tab silently loses it.
                claimed.subtract(members)
                continue
            }
            result.append(TidyTabGroup(name: group.name, tabIDs: members))
        }
        return result
    }

    // MARK: - 5-Second Previews (spec §6.7)

    struct LinkPreview: Equatable, Sendable {
        var sourceHost: String
        var imageURL: URL?
        var summary: String
        var items: [Item]
        var truncationNotice: String?

        struct Item: Equatable, Sendable {
            /// Always one of `linkPreviewGlyphs`' values or `linkPreviewNeutralGlyph` — never a model-authored string reaching `Image(systemName:)`.
            var symbolName: String
            var lead: String
            var detail: String
        }
    }

    static let linkPreviewGlyphs: [String: String] = [
        "place": "mappin.and.ellipse",
        "food": "fork.knife",
        "travel": "airplane",
        "time": "clock",
        "money": "dollarsign.circle",
        "person": "person",
        "document": "doc.text",
        "warning": "exclamationmark.triangle",
        "link": "link",
        "star": "star",
    ]

    static let linkPreviewNeutralGlyph = "circle.fill"

    /// Page text comes from `pageData` (fetched over HTTP), never `sink.pageText()`, which reads the active tab's unrelated page.
    func linkPreview(
        sourceURL: URL,
        pageData: LinkPreviewFetcher.LinkPreviewPageData,
        sink: AssistSink
    ) async throws -> LinkPreview {
        guard AssistSettings.isFiveSecondPreviewsEnabled else { throw AssistError.featureDisabled("5-Second Previews") }
        let pageText = pageData.pageText.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pageText.isEmpty else { throw AssistError.noPageText }

        let raw = try await sink.generate(
            AssistRequest(
                system: Self.linkPreviewSystemPrompt,
                user: Self.linkPreviewUserPrompt(pageData: pageData),
                maxOutputTokens: 260,
                temperature: 0.2
            )
        )
        let parsed = Self.parseLinkPreviewReply(raw)
        let summary = parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AssistError.emptyCompletion }

        return LinkPreview(
            sourceHost: sourceURL.host() ?? sourceURL.absoluteString,
            imageURL: pageData.imageURL,
            summary: summary,
            items: Self.groundedItems(parsed.items, in: pageData.pageText.text),
            truncationNotice: pageData.pageText.truncationNotice
        )
    }

    static let linkPreviewSystemPrompt = """
        You summarise one web page for a preview card shown before the reader opens it, using only the page text supplied. \
        Reply in exactly this format and nothing else:
        SUMMARY: <one sentence, at most 30 words, describing what the page is about>
        ITEM: <glyph-key> | <short bold lead phrase, 2-4 words, naming something specific from the page> | <one sentence of detail>
        ITEM: <glyph-key> | <short bold lead phrase, 2-4 words, naming something specific from the page> | <one sentence of detail>
        Include two or three ITEM lines. For <glyph-key> choose only one of exactly these words: \
        place, food, travel, time, money, person, document, warning, link, star. \
        Never describe a detail that is not supported by the page text supplied.
        """

    static func linkPreviewUserPrompt(pageData: LinkPreviewFetcher.LinkPreviewPageData) -> String {
        """
        Page title: \(pageData.title ?? pageData.pageText.title)
        Page URL: \(pageData.pageText.url)

        Page text:
        \(pageData.pageText.text)
        """
    }

    static func parseLinkPreviewReply(_ raw: String) -> (summary: String, items: [LinkPreview.Item]) {
        var summary = ""
        var items: [LinkPreview.Item] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.uppercased().hasPrefix("SUMMARY:") {
                summary = String(text.dropFirst("SUMMARY:".count)).trimmingCharacters(in: .whitespaces)
            } else if text.uppercased().hasPrefix("ITEM:") {
                let body = String(text.dropFirst("ITEM:".count)).trimmingCharacters(in: .whitespaces)
                let parts = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else { continue }
                let symbolName = linkPreviewGlyphs[parts[0].lowercased()] ?? linkPreviewNeutralGlyph
                items.append(LinkPreview.Item(symbolName: symbolName, lead: parts[1], detail: parts[2]))
            }
        }
        return (summary, items)
    }

    /// Whole-word match only — a substring search let "Visit Chichen Itza" ground itself on "Visitors".
    static func groundedItems(_ items: [LinkPreview.Item], in pageText: String) -> [LinkPreview.Item] {
        let normalizedPage = normalizeForQuoteMatch(pageText)
        guard !normalizedPage.isEmpty else { return [] }
        let pageWords = Set(normalizedPage.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !pageWords.isEmpty else { return [] }

        return items.filter { item in
            let tokens = item.lead
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { normalizeForQuoteMatch(String($0)) }
                .filter { $0.count >= 4 && !linkPreviewStopWords.contains($0) }
            guard !tokens.isEmpty else { return false }
            return tokens.contains { pageWords.contains($0) }
        }
    }

    static let linkPreviewStopWords: Set<String> = [
        "this", "that", "with", "from", "your", "have", "will", "about", "into",
        "there", "their", "what", "when", "where", "which", "while", "these",
        "those", "here", "were", "been", "being", "does", "each", "some", "them",
        "than", "then", "over", "under", "such", "only", "also", "more", "most",
    ]

    // MARK: - Tidy Downloads (spec §6.7)

    func tidiedDownloadName(
        originalFileName: String,
        sourceURL: URL,
        pageTitle: String?,
        sink: AssistSink
    ) async throws -> String? {
        guard AssistSettings.isTidyDownloadsEnabled else { throw AssistError.featureDisabled("Tidy Downloads") }
        guard Self.filenameLooksOpaque(originalFileName) else { return nil }

        let base = (originalFileName as NSString).deletingPathExtension
        let ext = (originalFileName as NSString).pathExtension

        let answer = try await sink.generate(
            AssistRequest(
                system: Self.tidyDownloadSystemPrompt,
                user: """
                    Current file name: \(base)
                    File extension: \(ext)
                    Downloaded from: \(sourceURL.absoluteString)
                    Page title: \(pageTitle ?? "")
                    """,
                maxOutputTokens: 48,
                temperature: 0.0
            )
        )
        return Self.acceptTidiedFileName(answer, extension: ext)
    }

    static let tidyDownloadSystemPrompt = """
        Give a downloaded file a meaningful name. \
        Reply with the file name only, without the extension, without quotes and without a path. \
        Describe what the file is, using the page it came from. \
        Use at most eight words. Do not use the characters / \\ : * ? " < > |
        """

    static func filenameLooksOpaque(_ fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return true }

        let lowered = base.lowercased()
        if ["download", "file", "document", "untitled", "attachment", "image", "unnamed"].contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        let letters = base.filter { $0.isLetter }
        let digitsAndDashes = base.filter { $0.isNumber || $0 == "-" || $0 == "_" }
        if base.count >= 16, base.allSatisfy({ $0.isHexDigit || $0 == "-" || $0 == "_" }) { return true }
        if base.count >= 8, Double(digitsAndDashes.count) / Double(base.count) > 0.6 { return true }
        let words = base.split(whereSeparator: { !$0.isLetter })
        if letters.count < 4 || words.allSatisfy({ $0.count <= 3 }) { return true }
        return false
    }

    static func acceptTidiedFileName(_ candidate: String, extension ext: String) -> String? {
        var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = cleaned.split(separator: "\n").first { cleaned = String(firstLine) }
        cleaned = cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        cleaned.removeAll { "*?\"<>|".contains($0) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 120 else { return nil }
        if !ext.isEmpty, cleaned.lowercased().hasSuffix("." + ext.lowercased()) {
            cleaned = String(cleaned.dropLast(ext.count + 1))
        }
        guard !cleaned.isEmpty else { return nil }
        return ext.isEmpty ? cleaned : cleaned + "." + ext
    }
}
