import AppKit
import SwiftUI

@MainActor
@Observable
final class RichTextController {
    weak var textView: NSTextView?
    var onChange: ((NSAttributedString) -> Void)?

    private static let bodyFont = NSFont.systemFont(ofSize: 14)
    private static let headingFonts: [CGFloat] = [22, 18, 15] // H1, H2, H3

    // MARK: - Character styling

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveRange(textView)
        guard range.length > 0 else {
            textView.typingAttributes[.underlineStyle] = isUnderlined(at: range) ? nil : NSUnderlineStyle.single.rawValue
            return
        }
        let currentlyUnderlined = isUnderlined(at: range)
        storage.beginEditing()
        if currentlyUnderlined {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        storage.endEditing()
        notifyChanged()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveRange(textView)
        let manager = NSFontManager.shared
        guard range.length > 0 else {
            let base = (textView.typingAttributes[.font] as? NSFont) ?? RichTextController.bodyFont
            let hasTrait = manager.traits(of: base).contains(trait)
            textView.typingAttributes[.font] = hasTrait ? manager.convert(base, toNotHaveTrait: trait) : manager.convert(base, toHaveTrait: trait)
            return
        }
        let baseFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? RichTextController.bodyFont
        let hasTrait = manager.traits(of: baseFont).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? RichTextController.bodyFont
            let newFont = hasTrait ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: subrange)
        }
        storage.endEditing()
        notifyChanged()
    }

    private func isUnderlined(at range: NSRange) -> Bool {
        guard let storage = textView?.textStorage, range.location < storage.length else { return false }
        let value = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
        return (value ?? 0) != 0
    }

    // MARK: - Paragraph styling

    // level 0 = Heading 1 ... 2 = Heading 3, nil = body text.
    func applyHeading(_ level: Int?) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = currentParagraphRange(textView)
        let size = level.flatMap { RichTextController.headingFonts.indices.contains($0) ? RichTextController.headingFonts[$0] : nil } ?? 14
        let weight: NSFont.Weight = level == nil ? .regular : .bold
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: paragraphRange)
        storage.endEditing()
        notifyChanged()
    }

    func toggleBulletList() {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = currentParagraphRange(textView)
        let text = storage.string as NSString
        let line = text.substring(with: paragraphRange)
        storage.beginEditing()
        if line.hasPrefix("•\t") {
            storage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: 2), with: "")
        } else {
            storage.replaceCharacters(in: NSRange(location: paragraphRange.location, length: 0), with: "•\t")
        }
        storage.endEditing()
        notifyChanged()
    }

    // MARK: - Links

    func applyLink(url: URL) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveRange(textView)
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.link, value: url as NSURL, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        storage.endEditing()
        notifyChanged()
    }

    // MARK: - Helpers

    private func effectiveRange(_ textView: NSTextView) -> NSRange {
        textView.selectedRange()
    }

    private func currentParagraphRange(_ textView: NSTextView) -> NSRange {
        let text = textView.string as NSString
        return text.paragraphRange(for: textView.selectedRange())
    }

    func notifyChanged() {
        guard let textView else { return }
        onChange?(textView.attributedString())
    }
}

struct RichTextEditorView: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var controller: RichTextController
    var onEdit: (() -> Void)?

    // Read here, not in updateNSView: @Environment is only live during body/update evaluation.
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(attributedText: $attributedText, onEdit: onEdit) }

    private var documentAppearance: NSAppearance? {
        let resolved = OrbitInternalPageChrome.documentColorScheme(system: colorScheme)
        return NSAppearance(named: resolved == .dark ? .darkAqua : .aqua)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(attributedText)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.displaysLinkToolTips = true
        textView.backgroundColor = OrbitInternalPageChrome.surfaceNSColor
        // usesFindBar must be true: performTextFinderAction: (Find, Find and Replace, Find Next/Previous)
        // is answered by NSTextView only when it has a find bar, otherwise those menu rows stay grey.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.appearance = documentAppearance
        controller.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = OrbitInternalPageChrome.surfaceNSColor
        scrollView.appearance = documentAppearance
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Full attributed-string equality, not just plain-string: two notes can share text with
        // different formatting, and a plain-string compare would leave stale formatting on screen.
        if !textView.attributedString().isEqual(to: attributedText) {
            // Clamped rather than reapplied verbatim: this also fires on a document switch to
            // shorter content, and an out-of-bounds NSRange on selectedRanges is a real crash risk.
            let newLength = (attributedText.string as NSString).length
            let selectedRanges = textView.selectedRanges.map { value -> NSValue in
                var range = value.rangeValue
                range.location = min(range.location, newLength)
                range.length = min(range.length, newLength - range.location)
                return NSValue(range: range)
            }
            textView.textStorage?.setAttributedString(attributedText)
            textView.selectedRanges = selectedRanges
        }
        textView.backgroundColor = OrbitInternalPageChrome.surfaceNSColor
        nsView.backgroundColor = OrbitInternalPageChrome.surfaceNSColor
        textView.appearance = documentAppearance
        nsView.appearance = documentAppearance

        // Refreshed every call, not only in makeCoordinator(): otherwise onEdit/attributedText stay
        // bound to whichever RichTextEditorView existed when this representable was first created.
        context.coordinator.onEdit = onEdit
        context.coordinator.attributedText = $attributedText
        controller.textView = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var attributedText: Binding<NSAttributedString>
        var onEdit: (() -> Void)?

        init(attributedText: Binding<NSAttributedString>, onEdit: (() -> Void)?) {
            self.attributedText = attributedText
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            attributedText.wrappedValue = textView.attributedString()
            onEdit?()
        }
    }
}
