import AppKit
import SwiftUI

// MARK: - Entry row

/// One row in the console log. Fixed 3-column grid: [icon 20pt][message fill][source 130pt].
struct ConEntryRow: View {
    var entry: ConEntry
    var model: OrbitConsoleModel
    var session: OrbitInspectSession

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            levelIcon
            messageArea
            sourceLabel
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .contextMenu { contextMenuItems }
    }


    private var levelIcon: some View {
        Group {
            if let symbol = entry.level.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
            } else {
                Color.clear
            }
        }
        .frame(width: 20, alignment: .center)
    }

    private var iconColor: Color {
        switch entry.level.background {
        case .error: return InspectChrome.badColor
        case .warn:  return InspectChrome.warnColor
        case .info:  return InspectChrome.attributeValueColor
        default:     return InspectChrome.muted
        }
    }


    private var messageArea: some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.groupDepth > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .padding(.trailing, 8)
                    .padding(.leading, CGFloat(entry.groupDepth - 1) * 12)
            }

            VStack(alignment: .leading, spacing: 2) {
                if entry.isGroupStart {
                    groupRow
                } else {
                    argsContent
                }
                // Stack trace (collapsed by default for non-error)
                if !entry.stackFrames.isEmpty && (entry.level.isError || entry.level == .assert_) {
                    stackFramesView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
        }
    }

    private var groupRow: some View {
        HStack(spacing: 4) {
            let isCollapsed = model.collapsedGroupIds.contains(entry.id)
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .overlay(InspectHitTarget { model.toggleGroup(entry.id) })
                .accessibilityLabel(isCollapsed ? "Expand group" : "Collapse group")

            argsContent
        }
    }

    @ViewBuilder
    private var argsContent: some View {
        if entry.level == .navigation {
            Text(entry.plainText)
                .font(InspectChrome.caption)
                .foregroundStyle(.secondary)
                .italic()
        } else if entry.level == .command {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(entry.plainText)
                    .font(InspectChrome.mono)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        } else if let tableRows = entry.tableRows, !tableRows.isEmpty {
            ConTableView(rows: tableRows)
        } else if entry.args.isEmpty {
            EmptyView()
        } else if let fmt = entry.formatString {
            ConFormattedArgsView(formatString: fmt, args: entry.args, model: model, session: session)
        } else {
            ConArgsView(args: entry.args, model: model, session: session)
        }

        if entry.repeatCount > 1 {
            Text("\(entry.repeatCount)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OrbitNeutral.onAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(InspectChrome.badColor))
                .accessibilityLabel("Repeated \(entry.repeatCount) times")
        }
    }

    @ViewBuilder
    private var stackFramesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entry.stackFrames.prefix(12), id: \.self) { frame in
                HStack(spacing: 4) {
                    Text(frame.displayName)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(frame.shortURL)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(Color.accentColor)
                        .overlay(InspectHitTarget {
                            session.reveal(sourceURL: frame.url, line: frame.line, column: frame.column)
                        })
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.top, 2)
    }


    private var sourceLabel: some View {
        Group {
            if !entry.sourceURL.isEmpty {
                Text(entry.shortSource)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(InspectChrome.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .overlay(InspectHitTarget {
                        session.reveal(sourceURL: entry.sourceURL, line: entry.sourceLine, column: entry.sourceColumn)
                    })
            }
        }
        .frame(width: 130, alignment: .trailing)
    }


    private var rowBackground: some View {
        let tint: Color
        switch entry.level.background {
        case .error: tint = InspectChrome.badColor.opacity(isHovered ? 0.14 : 0.08)
        case .warn:  tint = InspectChrome.warnColor.opacity(isHovered ? 0.14 : 0.08)
        case .info:  tint = InspectChrome.attributeValueColor.opacity(isHovered ? 0.10 : 0.05)
        case .none:  tint = isHovered ? InspectChrome.hover : Color.clear
        }
        return tint
    }


    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy message") { model.copyEntry(entry) }
        if !entry.stackFrames.isEmpty {
            Button("Copy stack trace") { model.copyEntryStack(entry) }
        }
        if entry.args.first?.isExpandable == true {
            Button("Copy as JSON") { model.copyEntryAsJSON(entry) }
            Button("Store as global variable") { model.storeAsGlobal(entry) }
        }
        if !entry.sourceURL.isEmpty {
            Divider()
            Button("Reveal in Sources") {
                session.reveal(sourceURL: entry.sourceURL, line: entry.sourceLine, column: entry.sourceColumn)
            }
        }
    }
}

// MARK: - Inline args (no format string)

struct ConArgsView: View {
    var args: [ConSerializedValue]
    var model: OrbitConsoleModel
    var session: OrbitInspectSession

    var body: some View {
        // Wrap args in a flowing horizontal layout
        WrappingArgsLayout(args: args, model: model, session: session)
    }
}

/// Horizontal flow of value tokens that wraps to next line.
struct WrappingArgsLayout: View {
    var args: [ConSerializedValue]
    var model: OrbitConsoleModel
    var session: OrbitInspectSession

    var body: some View {
        FlowLayout(spacing: 4) {
            // Arguments of a logged entry never reorder, so position is a stable identity.
            ForEach(args.indices, id: \.self) { index in
                ConValueView(value: args[index], model: model, session: session, inline: true)
            }
        }
    }
}

// MARK: - Formatted args (%s %d %c etc.)

struct ConFormattedArgsView: View {
    var formatString: String
    var args: [ConSerializedValue]
    var model: OrbitConsoleModel
    var session: OrbitInspectSession

    var body: some View {
        let (runs, firstUnused) = OrbitConsoleLogic.parseFormatString(formatString, argCount: args.count)
        VStack(alignment: .leading, spacing: 2) {
            FlowLayout(spacing: 0) {
                ForEach(runs.indices, id: \.self) { index in
                    runView(runs[index])
                }
            }
            // Extra args that weren't consumed by format specifiers
            if firstUnused < args.count {
                FlowLayout(spacing: 4) {
                    ForEach(firstUnused..<args.count, id: \.self) { index in
                        ConValueView(value: args[index], model: model, session: session, inline: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func runView(_ run: ConFormatRun) -> some View {
        switch run {
        case .text(let t):
            Text(t).font(InspectChrome.mono).foregroundStyle(.primary)
        case .substitution(let idx, let spec):
            if args.indices.contains(idx) {
                specView(args[idx], spec: spec)
            }
        case .styledText(let t, let style):
            Text(t)
                .font(styledFont(style))
                .foregroundStyle(styledColor(style))
        }
    }

    @ViewBuilder
    private func specView(_ val: ConSerializedValue, spec: ConFormatSpec) -> some View {
        switch spec {
        case .string_:
            Text(val.plainText).font(InspectChrome.mono).foregroundStyle(.primary)
        case .decimal, .integer, .float:
            Text(val.plainText).font(InspectChrome.mono).foregroundStyle(InspectChrome.numberColor)
        case .css:
            // %c: next run of text is styled — handled at ConFormattedArgsView level
            EmptyView()
        case .object, .objectXML:
            ConValueView(value: val, model: model, session: session, inline: true)
        }
    }

    private func styledFont(_ s: ConCSSStyle) -> Font {
        var f = InspectChrome.mono
        if s.isBold && s.isItalic { f = .system(size: 11.5, design: .monospaced).bold().italic() }
        else if s.isBold { f = Font.system(size: 11.5, design: .monospaced).bold() }
        else if s.isItalic { f = Font.system(size: 11.5, design: .monospaced).italic() }
        return f
    }

    private func styledColor(_ s: ConCSSStyle) -> Color {
        guard let c = s.color, !c.isEmpty else { return .primary }
        return Color(cssColor: c) ?? .primary
    }
}

// MARK: - Single value renderer

struct ConValueView: View {
    var value: ConSerializedValue
    var model: OrbitConsoleModel
    var session: OrbitInspectSession
    var inline: Bool = false
    var depth: Int = 0

    @State private var expanded = false

    var body: some View {
        if value.isExpandable {
            expandableView
        } else {
            primitiveText
        }
    }


    private var primitiveText: some View {
        Group {
            switch value {
            case .string_(let s):
                Text(inline ? "\"\(s.prefix(200))\"" : s)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.stringColor)
                    .textSelection(.enabled)
            case .number(let n):
                Text(ConValueFormat.number(n))
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.numberColor)
            case .numberSpecial(let s):
                Text(s)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.numberColor.opacity(0.7))
            case .boolean(let b):
                Text(b ? "true" : "false")
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.keywordColor)
            case .null_:
                Text("null")
                    .font(InspectChrome.mono)
                    .foregroundStyle(.secondary)
            case .undefined_:
                Text("undefined")
                    .font(InspectChrome.mono)
                    .foregroundStyle(.secondary)
            case .bigint(let s):
                Text(s)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.numberColor)
            case .symbol(let s):
                Text(s)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.tagColor)
            default:
                Text(value.preview)
                    .font(InspectChrome.mono)
                    .foregroundStyle(.primary)
            }
        }
    }


    private var expandableView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                previewLabel
            }
            .contentShape(Rectangle())
            .overlay(InspectHitTarget {
                toggleExpand()
            })

            if expanded {
                expandedContent
                    .padding(.leading, 14)
            }
        }
    }

    private var previewLabel: some View {
        Group {
            switch value {
            case .domNode(_, let nid, let p):
                HStack(spacing: 0) {
                    Text(p)
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.tagColor)
                        .overlay(InspectHitTarget {
                            session.reveal(nodeID: nid)
                        })
                }
            case .error_(_, let p, _):
                Text(p)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.badColor)
            case .function_(_, let p):
                Text(p)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.keywordColor)
            case .date_(_, let p):
                Text(p)
                    .font(InspectChrome.mono)
                    .foregroundStyle(.secondary)
            default:
                Text(value.preview)
                    .font(InspectChrome.mono)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let regId = value.registryId {
            switch model.expandedProps[regId] {
            case nil:
                EmptyView()
            case .loading:
                Text("Loading…").font(InspectChrome.monoSmall).foregroundStyle(.secondary)
            case .error(let msg):
                Text(msg).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.badColor)
            case .loaded(let own, let proto):
                loadedPropsView(own: own, proto: proto)
            }
        }
    }

    private func loadedPropsView(own: [ConPropDescriptor], proto: ConSerializedValue?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(own) { prop in
                ConPropRow(prop: prop, model: model, session: session, depth: depth + 1)
            }
            if let proto {
                ConPropRow(
                    prop: ConPropDescriptor(
                        name: "[[Prototype]]",
                        value: proto,
                        writable: false,
                        enumerable: false,
                        configurable: false,
                        isGetter: false
                    ),
                    model: model, session: session, depth: depth + 1
                )
            }
        }
    }

    private func toggleExpand() {
        expanded.toggle()
        if expanded, let id = value.registryId {
            model.requestExpansion(registryId: id)
        }
    }
}

// MARK: - Property row in expanded tree

struct ConPropRow: View {
    var prop: ConPropDescriptor
    var model: OrbitConsoleModel
    var session: OrbitInspectSession
    var depth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(prop.name)
                .font(InspectChrome.monoSmall)
                .foregroundStyle(prop.enumerable ? InspectChrome.attributeNameColor : .secondary)
            Text(":")
                .font(InspectChrome.monoSmall)
                .foregroundStyle(.secondary)
            if depth < 4 {
                ConValueView(value: prop.value, model: model, session: session, inline: true, depth: depth)
            } else {
                Text(prop.value.preview)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Table view for console.table

struct ConTableView: View {
    var rows: [[String: ConSerializedValue]]

    private var columns: [String] {
        var seen: [String] = []
        var set: Set<String> = []
        for row in rows {
            for key in row.keys where !set.contains(key) {
                seen.append(key)
                set.insert(key)
            }
        }
        return seen
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(columns, id: \.self) { col in
                        Text(col)
                            .font(InspectChrome.monoSmall)
                            .foregroundStyle(.secondary)
                            .fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                // Table rows are immutable once logged, so their position is a stable identity.
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(columns, id: \.self) { col in
                            Text(rows[index][col]?.plainText ?? "")
                                .font(InspectChrome.monoSmall)
                                .foregroundStyle(InspectChrome.ink)
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(InspectChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous))
    }
}

// MARK: - REPL input view

/// Multi-line NSTextView: Enter runs, Shift+Enter inserts a newline, up/down walks history, Tab autocompletes.
struct ConInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onHistoryUp: () -> String?
    var onHistoryDown: () -> String?
    var focusRequested: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let tv = scrollView.documentView as! NSTextView
        context.coordinator.textView = tv
        tv.delegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.textContainer?.lineBreakMode = .byWordWrapping
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        if focusRequested {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConInputView
        weak var textView: NSTextView?

        init(_ parent: ConInputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if OrbitConsoleLogic.isInputComplete(textView.string) {
                    parent.onSubmit()
                    return true
                }
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                if let prev = parent.onHistoryUp() {
                    textView.string = prev
                    parent.text = prev
                    textView.setSelectedRange(NSRange(location: prev.count, length: 0))
                    return true
                }
                return false
            }
            if selector == #selector(NSResponder.moveDown(_:)) {
                if let next = parent.onHistoryDown() {
                    textView.string = next
                    parent.text = next
                    textView.setSelectedRange(NSRange(location: next.count, length: 0))
                    return true
                }
                return false
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                // Tab = accept first autocomplete (handled in parent)
                return false
            }
            return false
        }
    }
}

// MARK: - Flow layout (wrapping horizontal layout)

/// Wraps children like CSS `flex-wrap: wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    /// Narrowed to the row so a long token wraps inside the message column instead of drawing over its neighbour.
    private func measure(_ sub: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = sub.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite, maxWidth > 0 else { return ideal }
        let fitted = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(fitted.width, maxWidth), height: fitted.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 800
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = measure(sub, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var rowSubviews: [(sub: LayoutSubview, size: CGSize, x: CGFloat)] = []

        func placeRow() {
            for (sub, size, sx) in rowSubviews {
                sub.place(at: CGPoint(x: sx, y: y + (rowHeight - size.height) / 2),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
            }
        }

        for sub in subviews {
            let size = measure(sub, maxWidth: bounds.width)
            if !rowSubviews.isEmpty && x + size.width > bounds.maxX {
                placeRow()
                rowSubviews.removeAll()
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            rowSubviews.append((sub, size, x))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        placeRow()
    }
}

// MARK: - Color+CSS helper

extension Color {
    /// Parse a CSS color name or hex value into a SwiftUI Color.
    init?(cssColor: String) {
        let c = cssColor.trimmingCharacters(in: .whitespaces).lowercased()
        switch c {
        case "red":     self = .red
        case "blue":    self = .blue
        case "green":   self = .green
        case "orange":  self = .orange
        case "purple":  self = .purple
        case "yellow":  self = .yellow
        case "gray", "grey": self = .gray
        case "white":   self = .white
        case "black":   self = .black
        case "cyan":    self = .cyan
        case "pink":    self = .pink
        default:
            // Try hex #rrggbb or #rgb
            var hex = c
            if hex.hasPrefix("#") { hex.removeFirst() }
            if hex.count == 3 {
                let r = hex.prefix(1); let g = hex.dropFirst(1).prefix(1); let b = hex.dropFirst(2).prefix(1)
                hex = "\(r)\(r)\(g)\(g)\(b)\(b)"
            }
            guard hex.count == 6, let val = UInt64(hex, radix: 16) else { return nil }
            self = Color(red: Double((val >> 16) & 0xFF) / 255,
                         green: Double((val >> 8) & 0xFF) / 255,
                         blue: Double(val & 0xFF) / 255)
        }
    }
}
