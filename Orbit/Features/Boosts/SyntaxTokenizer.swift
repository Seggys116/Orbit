import AppKit
import Foundation
import SwiftUI

enum SyntaxLanguage {
    case css
    case javaScript
}

enum SyntaxTokenizer {

    private static let cssKeywordColor = NSColor(red: 0.85, green: 0.45, blue: 0.95, alpha: 1)
    private static let cssPropertyColor = NSColor(red: 0.42, green: 0.68, blue: 1.0, alpha: 1)
    private static let stringColor = NSColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1)
    private static let commentColor = NSColor(red: 0.52, green: 0.56, blue: 0.6, alpha: 1)
    private static let numberColor = NSColor(red: 0.68, green: 0.85, blue: 0.55, alpha: 1)
    private static let keywordColor = NSColor(red: 0.98, green: 0.42, blue: 0.55, alpha: 1)
    private static let punctuationColor = NSColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 1)
    private static let baseColor = NSColor(white: 0.92, alpha: 1)

    private static let jsKeywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "break", "continue", "class", "extends", "new", "typeof",
        "instanceof", "true", "false", "null", "undefined", "this", "async", "await",
        "import", "export", "default", "try", "catch", "finally", "throw", "of", "in",
        "delete", "void", "yield", "static", "get", "set", "super",
    ]

    static func applyHighlighting(to textView: NSTextView, language: SyntaxLanguage) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        let font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: baseColor, .font: font], range: full)

        let string = text as String
        for token in tokens(in: string, language: language) {
            let range = NSRange(token.range, in: string)
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { continue }
            storage.addAttribute(.foregroundColor, value: token.color, range: range)
        }
        storage.endEditing()
    }

    private struct Token {
        var range: Range<String.Index>
        var color: NSColor
    }

    private static func tokens(in text: String, language: SyntaxLanguage) -> [Token] {
        switch language {
        case .css: return cssTokens(in: text)
        case .javaScript: return jsTokens(in: text)
        }
    }

    // MARK: - CSS

    private static let cssRegex: NSRegularExpression = {
        // Alternation order matters: comments/strings must match before later branches can re-match their contents.
        let pattern = #"""
        (?<comment>/\*[\s\S]*?\*/)|\
        (?<string>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|\
        (?<atrule>@[a-zA-Z-]+)|\
        (?<important>!important)|\
        (?<hex>#[0-9a-fA-F]{3,8}\b)|\
        (?<number>-?\b\d+\.?\d*(px|em|rem|%|vh|vw|s|ms|deg)?\b)|\
        (?<property>[a-zA-Z-]+(?=\s*:))|\
        (?<selector>[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=[\s,.:#\[{]))
        """#
        return (try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace])) ?? NSRegularExpression()
    }()

    private static func cssTokens(in text: String) -> [Token] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [Token] = []
        cssRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            let groups: [(String, NSColor)] = [
                ("comment", commentColor), ("string", stringColor), ("atrule", cssKeywordColor),
                ("important", cssKeywordColor), ("hex", numberColor), ("number", numberColor),
                ("property", cssPropertyColor), ("selector", cssKeywordColor),
            ]
            for (name, color) in groups {
                let groupRange = match.range(withName: name)
                guard groupRange.location != NSNotFound, let range = Range(groupRange, in: text) else { continue }
                result.append(Token(range: range, color: color))
                return
            }
        }
        return result
    }

    // MARK: - JavaScript

    private static let jsRegex: NSRegularExpression = {
        let pattern = #"""
        (?<comment>//.*$|/\*[\s\S]*?\*/)|\
        (?<string>`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|\
        (?<number>-?\b\d+\.?\d*\b)|\
        (?<word>\b[a-zA-Z_$][a-zA-Z0-9_$]*\b)
        """#
        return (try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace, .anchorsMatchLines])) ?? NSRegularExpression()
    }()

    private static func jsTokens(in text: String) -> [Token] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var result: [Token] = []
        jsRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            if let range = namedRange(match, "comment", in: text) {
                result.append(Token(range: range, color: commentColor)); return
            }
            if let range = namedRange(match, "string", in: text) {
                result.append(Token(range: range, color: stringColor)); return
            }
            if let range = namedRange(match, "number", in: text) {
                result.append(Token(range: range, color: numberColor)); return
            }
            if let range = namedRange(match, "word", in: text) {
                let word = String(text[range])
                if jsKeywords.contains(word) {
                    result.append(Token(range: range, color: keywordColor))
                } else if let next = text[range.upperBound...].first, next == "(" {
                    result.append(Token(range: range, color: cssPropertyColor))
                }
            }
        }
        return result
    }

    private static func namedRange(_ match: NSTextCheckingResult, _ name: String, in text: String) -> Range<String.Index>? {
        let groupRange = match.range(withName: name)
        guard groupRange.location != NSNotFound else { return nil }
        return Range(groupRange, in: text)
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: SyntaxLanguage
    var onChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = context.coordinator
        textView.string = text
        textView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        textView.textColor = NSColor(white: 0.92, alpha: 1)
        textView.insertionPointColor = .white
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.textView = textView
        SyntaxTokenizer.applyHighlighting(to: textView, language: language)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            SyntaxTokenizer.applyHighlighting(to: textView, language: language)
            textView.selectedRanges = selectedRanges
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var language: SyntaxLanguage
        var onChange: ((String) -> Void)?
        weak var textView: NSTextView?

        init(text: Binding<String>, language: SyntaxLanguage, onChange: ((String) -> Void)?) {
            self.text = text
            self.language = language
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newValue = textView.string
            text.wrappedValue = newValue
            SyntaxTokenizer.applyHighlighting(to: textView, language: language)
            onChange?(newValue)
        }
    }
}
