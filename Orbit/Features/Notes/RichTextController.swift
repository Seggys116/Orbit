import AppKit
import SwiftUI

@MainActor
@Observable
final class RichTextController {
    weak var textView: NSTextView?
    var onChange: (() -> Void)?

    // Bumped only when NotesEditorView loads a document. updateNSView pushes the binding on a
    // generation change, so a keystroke does not have to copy the whole attributed string into
    // SwiftUI state just to keep the text view from being replaced on the next render.
    @ObservationIgnored var documentGeneration = 0

    // The note a debounced save must write. The body is read from the text view at flush time,
    // not copied on the keystroke. detachedBody is filled only if the text view is going away first.
    @ObservationIgnored var pendingNoteID: UUID?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var detachedBody: NSAttributedString?

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
        guard textView != nil else { return }
        onChange?()
    }
}

enum NotesTextColor {

    // Greyscale near-black or near-white was authored against one appearance and cannot follow the other.
    private static func isSingleAppearanceBodyColor(_ color: NSColor) -> Bool {
        guard color.type != .catalog, let srgb = color.usingColorSpace(.sRGB) else { return false }
        let red = srgb.redComponent, green = srgb.greenComponent, blue = srgb.blueComponent
        guard abs(red - green) < 0.06, abs(green - blue) < 0.06, abs(red - blue) < 0.06 else { return false }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance < 0.35 || luminance > 0.65
    }

    private static func rangesNeedingDynamicColor(in string: NSAttributedString, range: NSRange) -> [NSRange] {
        var found: [NSRange] = []
        string.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            guard let color = value as? NSColor else { found.append(subrange); return }
            if isSingleAppearanceBodyColor(color) { found.append(subrange) }
        }
        return found
    }

    static func applyDynamicTextColor(to storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0, range.upperBound <= storage.length else { return }
        let ranges = rangesNeedingDynamicColor(in: storage, range: range)
        guard !ranges.isEmpty else { return }
        // One processEditing for every run in the edit, not one layout invalidation per run.
        storage.beginEditing()
        for subrange in ranges {
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: subrange)
        }
        storage.endEditing()
    }

    static func normalized(_ input: NSAttributedString) -> NSAttributedString {
        let ranges = rangesNeedingDynamicColor(in: input, range: NSRange(location: 0, length: input.length))
        guard !ranges.isEmpty else { return input }
        let mutable = NSMutableAttributedString(attributedString: input)
        for subrange in ranges {
            mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: subrange)
        }
        return mutable
    }

    @MainActor
    static func normalizeTypingAttributes(of textView: NSTextView) {
        guard let color = textView.typingAttributes[.foregroundColor] as? NSColor else {
            textView.typingAttributes[.foregroundColor] = NSColor.textColor
            return
        }
        guard isSingleAppearanceBodyColor(color) else { return }
        textView.typingAttributes[.foregroundColor] = NSColor.textColor
    }
}

private final class NotesTextView: NSTextView {
    var onWillLeaveWindow: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            onWillLeaveWindow?()
        }
        super.viewWillMove(toWindow: newWindow)
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
        let textView = NotesTextView()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.delegate = context.coordinator
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
        // usesFindBar must be true: performTextFinderAction: (Find, Find and Replace, Find Next/Previous)
        // is answered by NSTextView only when it has a find bar, otherwise those menu rows stay grey.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        context.coordinator.controller = controller
        context.coordinator.installStorageObservation(on: textView)
        textView.onWillLeaveWindow = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.captureDetachedBody(of: textView)
        }
        applyDocument(attributedText, to: textView, coordinator: context.coordinator)
        context.coordinator.appliedGeneration = controller.documentGeneration
        controller.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        applyChrome(to: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.controller = controller
        context.coordinator.installStorageObservation(on: textView)
        // Generation, not attributed-string equality. Two notes can share text with different
        // formatting, so a plain-string compare is not enough. Copying the storage to compare it
        // retained a second document on every update, and a mismatch replaced the storage and
        // re-laid-out the note. load(for:) bumps the generation when it installs a document.
        if context.coordinator.appliedGeneration != controller.documentGeneration {
            applyDocument(attributedText, to: textView, coordinator: context.coordinator)
            context.coordinator.appliedGeneration = controller.documentGeneration
        }
        applyChrome(to: textView, scrollView: nsView)

        // Refreshed every call, not only in makeCoordinator(): otherwise onEdit/attributedText stay
        // bound to whichever RichTextEditorView existed when this representable was first created.
        context.coordinator.onEdit = onEdit
        context.coordinator.attributedText = $attributedText
        controller.textView = textView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.captureDetachedBody(from: nsView)
    }

    // Clamped rather than reapplied verbatim: this also fires on a document switch to shorter
    // content, and an out-of-bounds NSRange on selectedRanges is a real crash risk.
    private func applyDocument(_ attributedText: NSAttributedString, to textView: NSTextView, coordinator: Coordinator) {
        coordinator.isApplyingExternalText = true
        defer {
            coordinator.isApplyingExternalText = false
            coordinator.pendingRepairRange = nil
        }
        let newLength = (attributedText.string as NSString).length
        let selectedRanges = textView.selectedRanges.map { value -> NSValue in
            var range = value.rangeValue
            range.location = min(range.location, newLength)
            range.length = min(range.length, newLength - range.location)
            return NSValue(range: range)
        }
        textView.textStorage?.setAttributedString(attributedText)
        textView.selectedRanges = selectedRanges
        NotesTextColor.normalizeTypingAttributes(of: textView)
    }

    private func applyChrome(to textView: NSTextView, scrollView: NSScrollView?) {
        let appearance = documentAppearance
        let surface = OrbitInternalPageChrome.surfaceNSColor
        if textView.appearance?.name != appearance?.name {
            textView.appearance = appearance
        }
        if textView.backgroundColor != surface {
            textView.backgroundColor = surface
        }
        guard let scrollView else { return }
        if scrollView.appearance?.name != appearance?.name {
            scrollView.appearance = appearance
        }
        if scrollView.backgroundColor != surface {
            scrollView.backgroundColor = surface
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var attributedText: Binding<NSAttributedString>
        var onEdit: (() -> Void)?
        weak var controller: RichTextController?
        var appliedGeneration = -1
        var isApplyingExternalText = false
        var isRepairingColor = false
        var pendingRepairRange: NSRange?
        private weak var observedStorage: NSTextStorage?

        init(attributedText: Binding<NSAttributedString>, onEdit: (() -> Void)?) {
            self.attributedText = attributedText
            self.onEdit = onEdit
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installStorageObservation(on textView: NSTextView) {
            guard let storage = textView.textStorage, observedStorage !== storage else { return }
            if let observedStorage {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSTextStorage.willProcessEditingNotification,
                    object: observedStorage
                )
            }
            observedStorage = storage
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(storageWillProcessEditing(_:)),
                name: NSTextStorage.willProcessEditingNotification,
                object: storage
            )
        }

        // Posted before NSTextView turns the edit into textDidChange, so the repair range is
        // known without walking the rest of the document. Skipped when shouldChangeTextIn already
        // recorded a tighter range, and when the edit is our own colour repair or a document load.
        @objc private func storageWillProcessEditing(_ notification: Notification) {
            guard !isApplyingExternalText, !isRepairingColor, pendingRepairRange == nil else { return }
            guard let storage = notification.object as? NSTextStorage else { return }
            let mask = storage.editedMask
            guard mask.contains(.editedCharacters) || mask.contains(.editedAttributes) else { return }
            var range = storage.editedRange
            guard range.location != NSNotFound else { return }
            let adjustedLength = range.length + storage.changeInLength
            guard adjustedLength > 0 else { return }
            range.length = adjustedLength
            pendingRepairRange = range
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingExternalText, !isRepairingColor else { return true }
            let replacementLength = (replacementString as NSString?)?.length ?? affectedCharRange.length
            guard affectedCharRange.location != NSNotFound, replacementLength > 0 else { return true }
            let inserted = NSRange(location: affectedCharRange.location, length: replacementLength)
            if let existing = pendingRepairRange {
                pendingRepairRange = NSUnionRange(existing, inserted)
            } else {
                pendingRepairRange = inserted
            }
            return true
        }

        func captureDetachedBody(from scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            captureDetachedBody(of: textView)
        }

        func captureDetachedBody(of textView: NSTextView) {
            guard let controller, controller.pendingNoteID != nil, controller.detachedBody == nil else { return }
            controller.detachedBody = textView.attributedString()
        }

        // Fires for every route into the storage: typing, paste, drag, dictation, services and undo.
        // Repairing here rather than from an NSTextStorageDelegate is deliberate — mutating the storage
        // inside didProcessEditing swallows the character edit, and the note then never saves.
        // The repair stays inside the edited range: a full-storage attribute pass invalidates layout
        // from the start of the note, and copying the storage into the binding retained a second
        // document on every keystroke. The text view remains the source of truth until flush.
        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, !isRepairingColor else { return }
            guard let textView = notification.object as? NSTextView else { return }
            NotesTextColor.normalizeTypingAttributes(of: textView)
            let repairRange = takeRepairRange(in: textView)
            if let storage = textView.textStorage, repairRange.length > 0 {
                isRepairingColor = true
                defer { isRepairingColor = false }
                NotesTextColor.applyDynamicTextColor(to: storage, in: repairRange)
            }
            onEdit?()
        }

        private func takeRepairRange(in textView: NSTextView) -> NSRange {
            let length = (textView.string as NSString).length
            let range = pendingRepairRange ?? NSRange(location: NSNotFound, length: 0)
            pendingRepairRange = nil
            return clamped(range, to: length)
        }

        private func clamped(_ range: NSRange, to length: Int) -> NSRange {
            guard length > 0, range.location != NSNotFound, range.location >= 0 else {
                return NSRange(location: 0, length: 0)
            }
            let location = min(range.location, length)
            let end = min(location + max(range.length, 0), length)
            return NSRange(location: location, length: end - location)
        }
    }
}
