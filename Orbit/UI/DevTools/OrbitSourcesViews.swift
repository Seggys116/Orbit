// Subviews for the Sources pane.

import AppKit
import SwiftUI

// MARK: - Tab strip

struct SourcesTabStrip: View {
    var tabs: [SourceTab]
    var activeID: String?
    var onSelect: (String) -> Void
    var onClose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabCell(tab)
                }
            }
        }
        .frame(height: 30)
        .background(InspectChrome.surface)
    }

    private func tabCell(_ tab: SourceTab) -> some View {
        let active = tab.id == activeID
        return HStack(spacing: 4) {
            // The select target covers the label only, so it does not sit on top of the close button.
            HStack(spacing: 4) {
                Image(systemName: tab.fileType.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(active ? InspectChrome.accent : InspectChrome.muted)
                Text(tab.displayName)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(active ? InspectChrome.ink : InspectChrome.muted)
                if tab.isModified {
                    Circle()
                        .fill(InspectChrome.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Modified")
                }
            }
            .contentShape(Rectangle())
            .overlay(InspectHitTarget { onSelect(tab.id) })
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .overlay(InspectHitTarget { onClose(tab.id) })
                .accessibilityLabel("Close \(tab.displayName)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // The active tab is the one that joins the editor below it: same surface, no extra colour.
        .background(active ? InspectChrome.panel : Color.clear)
        .overlay(alignment: .trailing) {
            InspectChrome.hairline.frame(width: 1)
        }
    }
}

// MARK: - Tree row

struct SourcesTreeRowView: View {
    var row: SourceTreeItem
    var isSelected: Bool
    var onTap: () -> Void
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * 14 + 4)
            if row.isExpandable {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .overlay(InspectHitTarget { onToggle() })
            } else {
                Color.clear.frame(width: 14)
            }
            rowContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(InspectHitTarget { onTap() })
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .background(isSelected ? InspectChrome.selection : Color.clear)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row.kind {
        case .originHeader(let origin, let count):
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(Color.secondary)
                Text(origin).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.primary)
                Spacer(minLength: 4)
                Text("\(count)").font(InspectChrome.caption).foregroundStyle(Color.secondary.opacity(0.6)).padding(.trailing, 6)
            }
        case .folder(let name, let count):
            HStack(spacing: 4) {
                Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 10.5)).foregroundStyle(Color(nsColor: .systemYellow))
                Text(name).font(InspectChrome.mono).foregroundStyle(Color.primary)
                Spacer(minLength: 4)
                Text("\(count)").font(InspectChrome.caption).foregroundStyle(Color.secondary.opacity(0.6)).padding(.trailing, 6)
            }
        case .file(let file):
            HStack(spacing: 4) {
                Image(systemName: file.fileType.symbol).font(.system(size: 10.5)).foregroundStyle(fileTypeColor(file.fileType))
                Text(file.displayName).font(InspectChrome.mono).foregroundStyle(Color.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.trailing, 6)
        case .originalSourceHeader:
            HStack(spacing: 4) {
                Image(systemName: "map").font(.system(size: 10)).foregroundStyle(Color.secondary)
                Text("Original Sources").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.primary)
            }
        case .originalFile(let orig):
            HStack(spacing: 4) {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 10.5)).foregroundStyle(Color(nsColor: .systemGreen))
                Text(orig.displayName).font(InspectChrome.mono).foregroundStyle(Color.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.trailing, 6)
        case .snippetsHeader:
            HStack(spacing: 4) {
                Image(systemName: "scroll").font(.system(size: 10)).foregroundStyle(Color.secondary)
                Text("Snippets").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.primary)
            }
        case .snippet(let snippet):
            HStack(spacing: 4) {
                Image(systemName: "scroll").font(.system(size: 10.5)).foregroundStyle(Color(nsColor: .systemPurple))
                Text(snippet.name).font(InspectChrome.mono).foregroundStyle(Color.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.trailing, 6)
        }
    }

    private func fileTypeColor(_ ft: SourceFileType) -> Color {
        switch ft {
        case .script, .inlineScript, .blobScript, .dataScript, .workerScript: return Color(nsColor: .systemYellow)
        case .stylesheet, .inlineStyle, .adoptedStylesheet: return Color(nsColor: .systemBlue)
        case .document: return Color(nsColor: .systemOrange)
        case .image: return Color(nsColor: .systemPink)
        case .font: return Color(nsColor: .systemTeal)
        case .media: return Color(nsColor: .systemPurple)
        case .wasm: return Color(nsColor: .systemGreen)
        default: return Color.secondary
        }
    }
}

// MARK: - SourcesEditorView (NSViewRepresentable)

struct SourcesEditorView: NSViewRepresentable {
    var text: String
    var language: SourceLanguage
    var isEditable: Bool
    var wordWrap: Bool
    var fontSize: CGFloat
    var revealLine: Int?      // 1-based, scroll-to + flash highlight
    var onEdit: ((String) -> Void)?

    func makeCoordinator() -> SourcesEditorCoordinator {
        SourcesEditorCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SourcesEditorScrollView()
        let textView = SourcesTextView()

        configureTextView(textView, scrollView: scrollView, coordinator: context.coordinator)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.onEdit = onEdit
        context.coordinator.language = language

        let rulerView = SourcesLineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        rulerView.textView = textView
        scrollView.verticalRulerView = rulerView
        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        context.coordinator.rulerView = rulerView

        applyAppearance(textView: textView, scrollView: scrollView)
        updateText(text, in: textView, language: language, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SourcesTextView else { return }
        applyAppearance(textView: textView, scrollView: nsView)

        if textView.string != text {
            let selection = textView.selectedRanges
            updateText(text, in: textView, language: language, coordinator: context.coordinator)
            let len = (textView.string as NSString).length
            textView.selectedRanges = selection.filter { r in
                NSMaxRange(r.rangeValue) <= len
            }
        }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        context.coordinator.language = language
        context.coordinator.onEdit = onEdit

        // Only scroll to the line when it has changed
        if revealLine != context.coordinator.lastRevealedLine {
            context.coordinator.lastRevealedLine = revealLine
            if let line = revealLine { revealLineInView(textView: textView, scrollView: nsView, line: line) }
        }
        nsView.verticalRulerView?.needsDisplay = true
    }

    // MARK: - Helpers

    private func configureTextView(_ textView: NSTextView, scrollView: NSScrollView, coordinator: SourcesEditorCoordinator) {
        textView.isRichText = false
        textView.allowsUndo = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = wordWrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wordWrap
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = coordinator
        textView.isSelectable = true
        textView.isEditable = isEditable

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
    }

    private func applyAppearance(textView: NSTextView, scrollView: NSScrollView) {
        let isDark = textView.effectiveAppearance.name != .aqua
        let palette = SyntaxPalette.make(dark: isDark)
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.plain
        scrollView.backgroundColor = palette.background
    }

    private func updateText(_ text: String, in textView: NSTextView, language: SourceLanguage, coordinator: SourcesEditorCoordinator) {
        textView.string = text
        guard let storage = textView.textStorage else { return }
        let isDark = textView.effectiveAppearance.name != .aqua
        let palette = SyntaxPalette.make(dark: isDark)
        coordinator.palette = palette
        if text.count < 500_000 {
            SourceHighlighter.apply(to: storage, language: language, palette: palette)
        } else {
            let full = NSRange(location: 0, length: (text as NSString).length)
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            storage.setAttributes([.foregroundColor: palette.plain, .font: font], range: full)
        }
        coordinator.rulerView?.needsDisplay = true
    }

    private func revealLineInView(textView: NSTextView, scrollView: NSScrollView, line: Int) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let nsText = textView.string as NSString
        var currentLine = 1
        var lineStart = 0
        var lineEnd = 0
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .byLines) { _, lineRange, enclosingRange, stop in
            if currentLine == line {
                lineStart = enclosingRange.location
                lineEnd = NSMaxRange(enclosingRange)
                stop.pointee = true
            }
            currentLine += 1
        }
        guard currentLine >= line else { return }
        let range = NSRange(location: lineStart, length: max(1, lineEnd - lineStart))
        textView.scrollRangeToVisible(range)
        if let storage = textView.textStorage {
            let isDark = textView.effectiveAppearance.name != .aqua
            let highlight = NSColor.systemYellow.withAlphaComponent(isDark ? 0.4 : 0.5)
            storage.addAttribute(.backgroundColor, value: highlight, range: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak storage] in
                guard let storage else { return }
                storage.removeAttribute(.backgroundColor, range: range)
            }
        }
    }
}

// MARK: - Coordinator

final class SourcesEditorCoordinator: NSObject, NSTextViewDelegate {
    weak var textView: SourcesTextView?
    weak var scrollView: NSScrollView?
    weak var rulerView: SourcesLineNumberRulerView?
    var onEdit: ((String) -> Void)?
    var language: SourceLanguage = .other
    var palette: SyntaxPalette = SyntaxPalette.make(dark: true)
    var lastRevealedLine: Int? = nil
    private var debounceTask: Task<Void, Never>? = nil

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let newText = textView.string
        rulerView?.needsDisplay = true
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, weak textView] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, let textView else { return }
            if let storage = textView.textStorage, newText.count < 500_000 {
                SourceHighlighter.apply(to: storage, language: self.language, palette: self.palette)
            }
            self.rulerView?.needsDisplay = true
            self.onEdit?(newText)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        rulerView?.needsDisplay = true
        textView?.needsDisplay = true
    }
}

// MARK: - NSTextView subclass (current-line highlight)

final class SourcesTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Current-line highlight (only when no selection)
        guard let lm = layoutManager,
              let container = textContainer,
              !selectedRanges.isEmpty else { return }
        guard let selValue = selectedRanges.first?.rangeValue, selValue.length == 0 else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: selValue.location, length: 0), actualCharacterRange: nil)
        let lineRect = lm.lineFragmentRect(forGlyphAt: max(0, glyphRange.location), effectiveRange: nil, withoutAdditionalLayout: true)
        guard lineRect != .zero else { return }
        let y = lineRect.minY + textContainerInset.height
        let isDark = effectiveAppearance.name != .aqua
        NSColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.05 : 0.04).setFill()
        NSRect(x: bounds.minX, y: y, width: bounds.width, height: lineRect.height).fill()
    }
}

// MARK: - Scroll view (redraws ruler on scroll)

final class SourcesEditorScrollView: NSScrollView {
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        verticalRulerView?.needsDisplay = true
    }
}

// MARK: - Line number ruler view

final class SourcesLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    private static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let gutterWidth: CGFloat = 44

    override var requiredThickness: CGFloat { Self.gutterWidth }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = Self.gutterWidth
    }

    required init(coder: NSCoder) { fatalError("NSCoder init not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let lm = textView.layoutManager,
              let container = textView.textContainer,
              let sv = scrollView else {
            // Fallback: just fill background
            NSColor(white: 0.09, alpha: 1).setFill()
            dirtyRect.fill()
            return
        }

        let isDark = textView.effectiveAppearance.name != .aqua
        let palette = SyntaxPalette.make(dark: isDark)

        palette.lineNumberBg.setFill()
        bounds.fill()

        palette.lineNumberFg.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        path.lineWidth = 1
        path.stroke()

        let visibleRect = sv.documentVisibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.length > 0 else { return }
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let nsText = textView.string as NSString
        var lineNumber = 1
        if charRange.location > 0 {
            let before = NSRange(location: 0, length: charRange.location)
            nsText.enumerateSubstrings(in: before, options: .byLines) { _, _, _, _ in
                lineNumber += 1
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.gutterFont,
            .foregroundColor: palette.lineNumberFg
        ]

        let inset = textView.textContainerInset

        var isFirstFragment = true
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphFrag, _ in
            let charFrag = lm.characterRange(forGlyphRange: glyphFrag, actualGlyphRange: nil)
            let isNewLogicalLine: Bool
            if charFrag.location == 0 {
                isNewLogicalLine = true
            } else {
                let prevChar = nsText.character(at: charFrag.location - 1)
                isNewLogicalLine = prevChar == 0x000A || prevChar == 0x000D || prevChar == 0x2028 || prevChar == 0x2029
            }
            let shouldDraw: Bool
            if isFirstFragment {
                // Always draw the first visible fragment so the gutter isn't empty.
                shouldDraw = true
                isFirstFragment = false
            } else if isNewLogicalLine {
                // Subsequent logical line start: increment then draw.
                lineNumber += 1
                shouldDraw = true
            } else {
                // Word-wrapped continuation: no gutter label.
                shouldDraw = false
            }
            if shouldDraw {
                let yInDoc = usedRect.minY + inset.height
                let yInRuler = yInDoc - visibleRect.minY
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: attrs)
                let drawRect = NSRect(
                    x: 2,
                    y: yInRuler + (usedRect.height - labelSize.height) / 2,
                    width: Self.gutterWidth - 6,
                    height: labelSize.height
                )
                label.draw(in: drawRect, withAttributes: attrs)
            }
        }
    }
}

// MARK: - Find bar

struct SourcesFindBar: View {
    @Binding var query: String
    @Binding var isOpen: Bool
    var caseSensitive: Bool
    var useRegex: Bool
    var matchCount: Int
    var currentMatch: Int
    var onCaseSensitive: () -> Void
    var onRegex: () -> Void
    var onNext: () -> Void
    var onPrev: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
            TextField("Find in file", text: $query)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .focused($focused)
                .onSubmit { onNext() }
            if matchCount > 0 {
                Text("\(currentMatch)/\(matchCount)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            } else if !query.isEmpty {
                Text("No matches")
                    .font(InspectChrome.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            InspectChip("Aa", selected: caseSensitive, action: onCaseSensitive)
            InspectChip(".*", selected: useRegex, action: onRegex)
            InspectIconButton(symbol: "chevron.up", help: "Previous match", action: onPrev)
            InspectIconButton(symbol: "chevron.down", help: "Next match", action: onNext)
            InspectIconButton(symbol: "xmark", help: "Close find bar", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(InspectChrome.surface)
        .overlay(alignment: .top) { InspectChrome.hairline.frame(height: 1) }
        .onAppear { focused = true }
    }
}

// MARK: - Snippet editor

struct SourceSnippetEditorView: View {
    @Binding var snippet: SourceSnippet
    var output: String?
    var onRun: () -> Void
    var onSave: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Snippet name", text: $snippet.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                InspectTextButton("Run", systemImage: "play.fill", prominent: true, action: onRun)
                InspectTextButton("Save", action: onSave)
                InspectTextButton("Delete", action: onDelete)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(InspectChrome.surface)
            InspectChrome.hairline.frame(height: 1)
            SourcesEditorView(
                text: snippet.code,
                language: .javaScript,
                isEditable: true,
                wordWrap: false,
                fontSize: 11.5,
                revealLine: nil,
                onEdit: { snippet.code = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let output {
                InspectChrome.hairline.frame(height: 1)
                ScrollView {
                    Text(output)
                        .font(InspectChrome.mono)
                        .foregroundStyle(output.hasPrefix("Error:") ? Color(nsColor: .systemRed) : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 100)
                .background(InspectChrome.surface)
            }
        }
    }
}
