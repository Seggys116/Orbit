// Sub-views for the Elements pane: tree rows, style rules, computed, box model, listeners, accessibility.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tree Row

/// The clickable controls inside a tree row that must win over the row's own click target.
private enum ElRowControl: CaseIterable, Hashable {
    case disclosure, layoutBadge
}

private struct ElRowControlBoundsKey: PreferenceKey {
    static let defaultValue: [ElRowControl: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ElRowControl: Anchor<CGRect>], nextValue: () -> [ElRowControl: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ElTreeRowView: View {
    var row: ElFlatRow
    var session: OrbitInspectSession
    /// The row never prints narrower than this, so its hover and selection fill spans the tree's scrollable width.
    var minWidth: CGFloat = 0

    @State private var isHovering = false
    @FocusState private var editFocused: Bool

    private var model: OrbitElementsModel { session.elements }
    private var isSelected: Bool { model.selectedID == row.nodeID && !row.isClosingTag }
    private var isFlashing: Bool { model.flashedNodes.contains(row.nodeID) }

    /// Width of one monospaced glyph at the code size, for locating clicks inside the tag text and sizing the tree.
    static let glyphWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// Each indent level is a 1pt guide with 7.5pt either side; the disclosure column is 16pt.
    static let indentWidth: CGFloat = 16
    static let disclosureWidth: CGFloat = 16

    /// Room after the text for its trailing padding and the layout badge.
    static let trailingRoom: CGFloat = 96

    /// The width the row needs to print in full, estimated from its text so rows that are not on screen need no layout.
    static func contentWidth(of row: ElFlatRow) -> CGFloat {
        CGFloat(row.depth) * indentWidth + disclosureWidth
            + CGFloat(OrbitElementsLogic.displayColumns(of: row)) * glyphWidth + trailingRoom
    }

    /// The widest row's width, which the tree scrolls horizontally to reach.
    static func contentWidth(of rows: [ElFlatRow]) -> CGFloat {
        rows.reduce(0) { max($0, contentWidth(of: $1)) }
    }

    private var isEditingTagName: Bool { model.inlineEdit == .tagName(row.nodeID) && !row.isClosingTag }
    private var isEditingText: Bool { model.inlineEdit == .text(row.nodeID) && !row.isClosingTag }

    var body: some View {
        HStack(spacing: 0) {
            indentGuides
            disclosureTriangle
            rowContent
            layoutBadge
            Spacer(minLength: 0)
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .frame(minHeight: InspectChrome.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .overlay(hitTarget)
        // AppKit hit-tests the topmost view first, so the chevron and layout badge targets are lifted above the row's.
        .overlayPreferenceValue(ElRowControlBoundsKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(ElRowControl.allCases.filter { anchors[$0] != nil }, id: \.self) { control in
                    let rect = proxy[anchors[control]!]
                    InspectHitTarget { perform(control) }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .overlay(alignment: .top) { dropLine(at: .lineAbove) }
        .overlay(alignment: .bottom) { dropLine(at: .lineBelow) }
        .overlay { dropOutline }
        .onHover { hovering in
            isHovering = hovering
            if row.node.kind == "el" && !row.isClosingTag {
                if hovering { session.highlight(nodeID: row.nodeID) }
                else { session.clearHighlight() }
            }
        }
        .onDrop(of: [.plainText], delegate: ElRowDropDelegate(row: row, model: model))
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
    }

    // MARK: Background

    private var rowBackgroundColor: Color {
        if isFlashing { return InspectChrome.accent.opacity(0.16) }
        if isSelected { return InspectChrome.selection }
        if isHovering { return InspectChrome.hover }
        return .clear
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
            .fill(rowBackgroundColor)
            .padding(.horizontal, 4)
            .orbitAnimation(OrbitMotion.fade, value: isHovering)
            .orbitAnimation(OrbitMotion.fade, value: isFlashing)
    }

    // MARK: Drop indicator

    private var indicator: ElDropIndicator? {
        guard let indicator = model.dropIndicator,
              indicator.rowNodeID == row.nodeID, indicator.isClosingTag == row.isClosingTag else { return nil }
        return indicator
    }

    /// A line with a leading dot, indented to the level the dragged node would land in.
    @ViewBuilder
    private func dropLine(at style: ElDropIndicator.Style) -> some View {
        if let indicator, indicator.style == style {
            HStack(spacing: 0) {
                Circle().fill(InspectChrome.accent).frame(width: 6, height: 6)
                Rectangle().fill(InspectChrome.accent).frame(height: 2)
            }
            .padding(.leading, CGFloat(indicator.indentLevel) * Self.indentWidth + Self.disclosureWidth - 3)
            .padding(.trailing, 4)
            .offset(y: style == .lineAbove ? -1 : 1)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var dropOutline: some View {
        if let indicator, indicator.style == .outline {
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .strokeBorder(InspectChrome.accent, lineWidth: 1.5)
                .padding(.horizontal, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Layout badge

    @ViewBuilder
    private var layoutBadge: some View {
        if !row.isClosingTag, let kind = model.layoutKinds[row.nodeID] {
            let active = model.layoutOverlays[row.nodeID] == kind
            Text(kind.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? OrbitNeutral.onAccent : InspectChrome.muted)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                        .fill(active ? InspectChrome.accent : InspectChrome.hover)
                )
                .contentShape(Rectangle())
                .anchorPreference(key: ElRowControlBoundsKey.self, value: .bounds) { [.layoutBadge: $0] }
                .padding(.trailing, 8)
                .orbitTooltip(active ? "Hide the \(kind.label) overlay on the page" : "Show the \(kind.label) overlay on the page")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.label) overlay")
                .accessibilityValue(active ? "On" : "Off")
                .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Indent guides

    private var indentGuides: some View {
        ForEach(0..<row.depth, id: \.self) { _ in
            Rectangle()
                .fill(InspectChrome.hairline)
                .frame(width: 1)
                .padding(.leading, 7.5)
                .padding(.trailing, 7.5)
        }
    }

    // MARK: Disclosure triangle

    @ViewBuilder
    private var disclosureTriangle: some View {
        if row.hasChildren && !row.isClosingTag {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(InspectChrome.muted)
                .rotationEffect(row.isExpanded ? .degrees(90) : .zero)
                .orbitAnimation(OrbitMotion.quick, value: row.isExpanded)
                .frame(width: Self.disclosureWidth, height: InspectChrome.rowHeight)
                .anchorPreference(key: ElRowControlBoundsKey.self, value: .bounds) { [.disclosure: $0] }
                .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
        } else {
            Spacer().frame(width: Self.disclosureWidth)
        }
    }

    // MARK: Row content

    @ViewBuilder
    private var rowContent: some View {
        switch row.node.kind {
        case "el":
            elementContent
        case "text":
            textNodeContent
        case "comment":
            commentContent
        case "doctype":
            doctypeContent
        case "shadow":
            Text("#shadow-root")
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .fixedSize()
                .padding(.trailing, 8)
        default:
            Text(row.node.name)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .fixedSize()
                .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var elementContent: some View {
        if row.isClosingTag {
            closingTagContent
        } else {
            openingTagContent
        }
    }

    /// Separate runs so the tag name can swap for a text field. The attribute run keeps its full width; the tree scrolls to it.
    private var openingTagContent: some View {
        HStack(spacing: 0) {
            Text("<")
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .fixedSize()
            tagNameView
            attributesText
                .font(InspectChrome.mono)
                .fixedSize()
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var tagNameView: some View {
        if isEditingTagName {
            TextField("tag", text: Binding(get: { model.inlineEditText }, set: { model.inlineEditText = $0 }))
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.tagColor)
                .autocorrectionDisabled()
                .focused($editFocused)
                .frame(width: max(32, CGFloat(model.inlineEditText.count + 2) * Self.glyphWidth))
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous).fill(InspectChrome.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                        .strokeBorder(InspectChrome.accent, lineWidth: 1)
                )
                .onAppear { editFocused = true }
                .onSubmit { model.commitInlineEdit() }
                .onKeyPress(.escape) { model.cancelInlineEdit(); return .handled }
                .onChange(of: editFocused) { _, focused in
                    if !focused, isEditingTagName { model.commitInlineEdit() }
                }
                .accessibilityLabel("Tag name")
        } else {
            Text(row.node.name)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.tagColor)
                .fixedSize()
        }
    }

    /// The attribute list and the closing bracket, as concatenated `Text` so it renders as one run.
    private var attributesText: Text {
        var t = Text("")
        for key in row.node.attrs.keys.sorted() {
            t = t + Text(" \(key)").foregroundStyle(InspectChrome.attributeNameColor)
            if let val = row.node.attrs[key], !val.isEmpty {
                t = t + Text("=\"").foregroundStyle(InspectChrome.muted)
                t = t + Text(OrbitElementsLogic.displayedAttributeValue(val)).foregroundStyle(InspectChrome.attributeValueColor)
                t = t + Text("\"").foregroundStyle(InspectChrome.muted)
            }
        }
        let tail: String
        if row.hasChildren && !row.isExpanded {
            tail = ">…</\(row.node.name)>"
        } else {
            tail = ">"
        }
        t = t + Text(tail).foregroundStyle(InspectChrome.muted)
        return t
    }

    private var closingTagContent: some View {
        Text("</\(row.node.name)>")
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .fixedSize()
            .padding(.trailing, 8)
    }

    @ViewBuilder
    private var textNodeContent: some View {
        if isEditingText {
            TextField("text", text: Binding(get: { model.inlineEditText }, set: { model.inlineEditText = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.stringColor)
                .lineLimit(1...6)
                .focused($editFocused)
                // Sized to the text so a long node is reached by scrolling the tree; only text past the cap wraps.
                .frame(width: min(max(160, CGFloat(model.inlineEditText.count + 2) * Self.glyphWidth), 900), alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous).fill(InspectChrome.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                        .strokeBorder(InspectChrome.accent, lineWidth: 1)
                )
                .padding(.trailing, 8)
                .onAppear { editFocused = true }
                .onSubmit { model.commitInlineEdit() }
                .onKeyPress(.escape) { model.cancelInlineEdit(); return .handled }
                .onChange(of: editFocused) { _, focused in
                    if !focused, isEditingText { model.commitInlineEdit() }
                }
                .accessibilityLabel("Text content")
        } else {
            Text(row.node.text.isEmpty ? "#text" : "\"\(OrbitElementsLogic.singleLine(row.node.text))\"")
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.stringColor)
                .fixedSize()
                .padding(.trailing, 8)
        }
    }

    private var commentContent: some View {
        Text("<!-- \(OrbitElementsLogic.singleLine(row.node.text)) -->")
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .italic()
            .fixedSize()
            .padding(.trailing, 8)
    }

    private var doctypeContent: some View {
        Text("<!DOCTYPE \(OrbitElementsLogic.singleLine(row.node.text))>")
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .fixedSize()
            .padding(.trailing, 8)
    }

    // MARK: Hit target

    private func perform(_ control: ElRowControl) {
        switch control {
        case .disclosure: model.toggleExpand(nodeID: row.nodeID)
        case .layoutBadge: model.toggleLayoutOverlay(nodeID: row.nodeID)
        }
    }

    /// The tag name's extent along the row, from the row's leading edge.
    private var tagNameRange: ClosedRange<CGFloat> {
        let start = CGFloat(row.depth) * Self.indentWidth + Self.disclosureWidth + Self.glyphWidth
        return start...(start + CGFloat(row.node.name.count) * Self.glyphWidth)
    }

    private var hitTarget: some View {
        InspectHitTarget(drag: dragSource, located: { point, clicks in
            guard !row.isClosingTag, !isEditingTagName, !isEditingText else { return }
            model.selectRow(nodeID: row.nodeID)
            guard clicks >= 2 else { return }
            switch row.node.kind {
            case "el" where tagNameRange.contains(point.x):
                model.beginTagRename(nodeID: row.nodeID)
            case "text", "comment":
                model.beginTextEdit(nodeID: row.nodeID)
            default:
                break
            }
        })
    }

    private var dragSource: InspectDragSource? {
        guard !row.isClosingTag, OrbitElementsLogic.canDrag(nodeID: row.nodeID, nodes: model.nodes, parents: model.parentLookup) else {
            return nil
        }
        let id = row.nodeID
        return InspectDragSource(
            payload: "orbit.element-node:\(id)",
            onBegan: { model.beginDrag(nodeID: id) },
            onEnded: { model.endDrag() }
        )
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if row.node.kind == "text" || row.node.kind == "comment", !row.isClosingTag {
            Button("Edit text") { model.beginTextEdit(nodeID: row.nodeID) }
            Button("Delete node", role: .destructive) { model.deleteNode(nodeID: row.nodeID) }
        }
        if row.node.kind == "el" && !row.isClosingTag {
            Button("Edit as HTML") { model.requestOuterHTML(nodeID: row.nodeID) }
            Button("Rename tag") { model.beginTagRename(nodeID: row.nodeID) }
            if let kind = model.layoutKinds[row.nodeID] {
                let active = model.layoutOverlays[row.nodeID] == kind
                Button(active ? "Hide \(kind.label) overlay" : "Show \(kind.label) overlay") {
                    model.toggleLayoutOverlay(nodeID: row.nodeID)
                }
            }
            Divider()
            Button("Copy outerHTML") { model.copyOuterHTML(nodeID: row.nodeID) }
            Button("Copy selector") { model.copySelector() }
            Button("Copy full selector") { model.copyFullSelector() }
            Button("Copy XPath") { model.copyXPath() }
            Button("Copy JS path") { model.copyJSPath() }
            Divider()
            Button("Scroll into view") { model.scrollIntoView(nodeID: row.nodeID) }
            Button("Focus element") { model.focusNode(nodeID: row.nodeID) }
            Button("Hide element") { model.hideNode(nodeID: row.nodeID) }
            Button("Duplicate") { model.duplicateNode(nodeID: row.nodeID) }
            Divider()
            Menu("Force state") {
                let states = ["hover", "active", "focus", "focus-within", "focus-visible", "visited"]
                let current = model.forcedStates[row.nodeID] ?? []
                ForEach(states, id: \.self) { state in
                    Button(action: {
                        var next = current
                        if next.contains(state) { next.remove(state) }
                        else { next.insert(state) }
                        model.setForcedStates(nodeID: row.nodeID, states: next)
                    }) {
                        Label(
                            ":\(state)",
                            systemImage: current.contains(state) ? "checkmark" : ""
                        )
                    }
                }
            }
            Divider()
            Button("Delete node", role: .destructive) { model.deleteNode(nodeID: row.nodeID) }
        }
    }
}

// MARK: - Drop target

/// Turns a drag hovering a tree row into an insertion indicator, and the drop into a move.
struct ElRowDropDelegate: DropDelegate {
    var row: ElFlatRow
    var model: OrbitElementsModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggingNodeID != nil
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: model.dropIndicator == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        model.clearDrop(row: row)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.commitDrop()
    }

    private func update(_ info: DropInfo) {
        model.updateDrop(row: row, fraction: info.location.y / InspectChrome.rowHeight)
    }
}

// MARK: - Breadcrumb bar

struct ElBreadcrumbBar: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        let path = model.selectionPath.compactMap { model.nodes[$0] }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Text(" > ")
                            .font(InspectChrome.mono)
                            .foregroundStyle(InspectChrome.muted)
                    }
                    crumb(node: node, isCurrent: index == path.count - 1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
        .background(InspectChrome.surface)
    }

    private func crumb(node: ElNodeInfo, isCurrent: Bool) -> some View {
        let label = nodeLabel(node)
        return Text(label)
            .font(InspectChrome.mono)
            .foregroundStyle(isCurrent ? InspectChrome.ink : InspectChrome.muted)
            .padding(.horizontal, 3)
            .background(
                isCurrent
                    ? RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                        .fill(InspectChrome.selection)
                    : nil
            )
            .contentShape(Rectangle())
            .overlay(
                InspectHitTarget {
                    model.selectRow(nodeID: node.id)
                }
            )
    }

    private func nodeLabel(_ node: ElNodeInfo) -> String {
        var label = node.name
        if let id = node.attrs["id"], !id.isEmpty { label += "#\(id)" }
        else if let cls = node.attrs["class"] {
            let first = cls.split(separator: " ").prefix(2).joined(separator: ".")
            if !first.isEmpty { label += ".\(first)" }
        }
        return label
    }
}

// MARK: - Styles Pane

struct ElStylesPane: View {
    var session: OrbitInspectSession

    @State private var editTarget: ElEditTarget? = nil
    @State private var editText: String = ""

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if model.styleRules.isEmpty && model.selectedID != nil {
                    InspectEmptyState(
                        symbol: "paintbrush",
                        title: "No styles",
                        message: "This element has no matched CSS rules."
                    )
                    .frame(maxWidth: .infinity)
                }
                if model.inactiveRuleCount > 0 {
                    inactiveToggle
                }
                ForEach(model.displayedStyleRules) { rule in
                    ElStyleRuleView(
                        rule: rule,
                        session: session,
                        editTarget: $editTarget,
                        editText: $editText,
                        onReveal: { href, line in session.reveal(sourceURL: href, line: line) },
                        onMakeEditable: { href in model.makeEditable(href: href) }
                    )
                }
                // "+" button to add new rule
                if model.selectedID != nil {
                    addRuleButton
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Chrome hides rules whose @media/@container condition does not hold; this shows them, dimmed.
    private var inactiveToggle: some View {
        HStack(spacing: 6) {
            Text(model.showInactiveRules
                 ? "Showing \(model.inactiveRuleCount) inactive rule\(model.inactiveRuleCount == 1 ? "" : "s")"
                 : "\(model.inactiveRuleCount) inactive rule\(model.inactiveRuleCount == 1 ? "" : "s") hidden")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
            Spacer()
            InspectTextButton(model.showInactiveRules ? "Hide inactive" : "Show all") {
                model.showInactiveRules.toggle()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var addRuleButton: some View {
        InspectTextButton("+", systemImage: nil, enabled: true, prominent: false) {
            let sel = OrbitElementsLogic.cssSelector(
                for: model.selectionPath.compactMap { model.nodes[$0] }
            )
            model.addRule(selector: sel)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

struct ElEditTarget: Equatable {
    enum Field: Equatable {
        case propName, propValue, selectorText
    }
    var ruleID: String
    var declIndex: Int
    var field: Field
}

struct ElStyleRuleView: View {
    var rule: ElStyleRule
    var session: OrbitInspectSession
    @Binding var editTarget: ElEditTarget?
    @Binding var editText: String
    var onReveal: (String, Int?) -> Void
    var onMakeEditable: (String) -> Void

    @State private var selectorEditActive = false
    @State private var selectorEditText = ""

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rule.isHeader {
                inheritedHeader
            } else {
                ruleHeader
                if !rule.isCrossOrigin {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rule.declarations.enumerated()), id: \.element.id) { idx, decl in
                            ElDeclarationRow(
                                decl: decl,
                                ruleID: rule.id,
                                declIndex: idx,
                                editTarget: $editTarget,
                                editText: $editText,
                                onValueCommit: { prop, val, prio in
                                    commitEdit(prop: prop, val: val, prio: prio, decl: decl)
                                },
                                onPropCommit: { oldProp, newProp in
                                    renameProp(oldProp: oldProp, newProp: newProp)
                                },
                                onToggle: { toggleDeclaration(decl: decl) },
                                onDelete: { removeDeclaration(decl: decl) }
                            )
                        }
                        newDeclarationRow
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .opacity(rule.isInactive ? 0.45 : 1)
        .orbitTooltip(rule.isInactive ? "This rule's condition does not hold right now." : "")
    }

    @ViewBuilder
    private var inheritedHeader: some View {
        Text(rule.ancestorLabel ?? "Inherited")
            .font(InspectChrome.sectionTitle)
            .foregroundStyle(InspectChrome.muted)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var ruleHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(rule.conditionLines.enumerated()), id: \.offset) { _, line in
            HStack(spacing: 4) {
                Text(line)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.keywordColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        HStack(spacing: 4) {
            if rule.ruleType == "inline" {
                Text("element.style")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(InspectChrome.tagColor)
            } else if rule.isCrossOrigin {
                Text(URL(string: rule.sheetHref ?? "")?.lastPathComponent ?? "stylesheet")
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.muted)
                Text("(cross-origin, read-only)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.warnColor)
                Spacer()
                InspectTextButton("Make editable") {
                    if let href = rule.sheetHref { onMakeEditable(href) }
                }
            } else {
                // Selector (editable)
                if selectorEditActive {
                    TextField("Selector", text: $selectorEditText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(InspectChrome.tagColor)
                        .onSubmit {
                            model.setRuleSelector(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath, selector: selectorEditText)
                            selectorEditActive = false
                        }
                        .onKeyPress(.escape) { selectorEditActive = false; return .handled }
                        .frame(maxWidth: 240)
                } else {
                    Text(rule.selector)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(InspectChrome.tagColor)
                        .lineLimit(2)
                        .overlay(
                            InspectHitTarget(doubleAction: {
                                guard rule.sheetIdx >= 0 else { return }
                                selectorEditText = rule.selector
                                selectorEditActive = true
                            }, action: {})
                        )
                }
                specificityBadges
                Spacer()
                sourceLabel
            }
        }
    }

    }  // closes ruleHeader

    @ViewBuilder
    private var specificityBadges: some View {
        let spec = rule.specificity
        if spec.count >= 3 && (spec[0] > 0 || spec[1] > 0 || spec[2] > 0) {
            HStack(spacing: 1) {
                ForEach(0..<min(spec.count, 3), id: \.self) { i in
                    Text("\(spec[i])")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(InspectChrome.muted)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(InspectChrome.hover))
                }
            }
        }
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if let href = rule.sheetHref, !href.isEmpty {
            let filename = URL(string: href)?.lastPathComponent ?? href
            let display = rule.sourceLine != nil ? "\(filename):\(rule.sourceLine!)" : filename
            Text(display)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.accent)
                .lineLimit(1)
                .contentShape(Rectangle())
                .overlay(
                    InspectHitTarget {
                        onReveal(href, rule.sourceLine)
                    }
                )
        }
    }

    @ViewBuilder
    private var newDeclarationRow: some View {
        let newTarget = ElEditTarget(ruleID: rule.id, declIndex: -1, field: .propName)
        let isEditing = editTarget == newTarget

        HStack(spacing: 0) {
            if isEditing {
                ElNewDeclarationEditor(
                    ruleID: rule.id,
                    suggestions: model.cssPropertyList,
                    onCommit: { prop, val in
                        commitNew(prop: prop, val: val)
                        editTarget = nil
                    },
                    onCancel: { editTarget = nil }
                )
            } else {
                Text(" ").font(InspectChrome.mono).foregroundStyle(.clear)
                    .overlay(
                        InspectHitTarget {
                            editTarget = newTarget
                            editText = ""
                        }
                    )
            }
        }
        .frame(minHeight: 18)
    }

    private func commitEdit(prop: String, val: String, prio: String, decl: ElDeclaration) {
        if rule.ruleType == "inline" {
            model.setInlineProperty(property: prop, value: val, priority: prio)
        } else if rule.sheetIdx >= 0 {
            model.setRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                  property: prop, value: val, priority: prio)
        }
    }

    private func renameProp(oldProp: String, newProp: String) {
        model.renameDeclaration(from: oldProp, to: newProp, in: rule)
    }

    private func toggleDeclaration(decl: ElDeclaration) {
        model.setDeclarationEnabled(decl.disabled, property: decl.property, in: rule)
    }

    private func removeDeclaration(decl: ElDeclaration) {
        if rule.ruleType == "inline" {
            model.removeInlineProperty(property: decl.property)
        } else if rule.sheetIdx >= 0 {
            model.removeRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath, property: decl.property)
        }
    }

    private func commitNew(prop: String, val: String) {
        if rule.ruleType == "inline" {
            model.setInlineProperty(property: prop, value: val)
        } else if rule.sheetIdx >= 0 {
            model.setRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath, property: prop, value: val)
        }
    }
}

struct ElDeclarationRow: View {
    var decl: ElDeclaration
    var ruleID: String
    var declIndex: Int
    @Binding var editTarget: ElEditTarget?
    @Binding var editText: String
    var onValueCommit: (String, String, String) -> Void
    var onPropCommit: (String, String) -> Void
    var onToggle: () -> Void
    var onDelete: () -> Void

    @State private var showColorPicker = false
    @State private var colorPickerText = ""
    @State private var rowHovering = false

    @State private var showLonghands = false
    /// The name just committed; the value edit must target it because the row shows the old name until the page answers.
    @State private var renamedTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if showLonghands {
                ForEach(decl.longhands) { longhand in
                    ElLonghandRow(longhand: longhand, priority: decl.priority, onValueCommit: onValueCommit)
                }
            }
        }
    }

    private var mainRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Checked while the declaration applies; an empty box once unchecked.
            Image(systemName: decl.disabled ? "square" : "checkmark.square")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(decl.disabled ? InspectChrome.muted2 : InspectChrome.muted)
                .frame(width: 16, height: InspectChrome.rowHeight)
                .overlay(InspectHitTarget { onToggle() })
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            // Shorthand disclosure, like Chrome's: expands to the longhands it sets.
            Group {
                if decl.isShorthand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(InspectChrome.muted)
                        .rotationEffect(showLonghands ? .degrees(90) : .zero)
                        .frame(width: 12, height: InspectChrome.rowHeight)
                        .overlay(InspectHitTarget { showLonghands.toggle() })
                        .accessibilityLabel(showLonghands ? "Collapse \(decl.property)" : "Expand \(decl.property)")
                } else {
                    Color.clear.frame(width: 12, height: InspectChrome.rowHeight)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            // Property name
            propNameField
            Text(": ").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            // Value. Its ";" is part of the value's own text, so a wrapped value ends with it on its last line.
            propValueField
            if editTarget == ElEditTarget(ruleID: ruleID, declIndex: declIndex, field: .propValue) {
                // While the value is being edited, !important and ";" follow the field.
                if decl.isImportant {
                    Text(" !important").font(InspectChrome.mono).foregroundStyle(InspectChrome.badColor)
                }
                Text(";").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            }

            // var() resolved hint
            if let computed = decl.computedValue, !computed.isEmpty, computed != decl.value {
                Text(" → \(computed)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .opacity(decl.disabled ? 0.5 : 1)
        .frame(minHeight: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                .fill(rowHovering ? InspectChrome.hover : Color.clear)
        )
        .onHover { rowHovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: rowHovering)
        .contextMenu {
            Button("Delete") { onDelete() }
            Button("Toggle (disable/enable)") { onToggle() }
            if decl.isImportant {
                Button("Remove !important") {
                    onValueCommit(decl.property, decl.value, "")
                }
            } else {
                Button("Add !important") {
                    onValueCommit(decl.property, decl.value, "important")
                }
            }
        }
    }

    @ViewBuilder
    private var propNameField: some View {
        let target = ElEditTarget(ruleID: ruleID, declIndex: declIndex, field: .propName)
        let isEditing = editTarget == target
        if isEditing {
            TextField("property", text: $editText)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.attributeNameColor)
                .frame(minWidth: 60)
                .onSubmit {
                    if editText != decl.property {
                        onPropCommit(decl.property, editText)
                        renamedTo = editText
                    }
                    // move to value editing
                    let nextTarget = ElEditTarget(ruleID: ruleID, declIndex: declIndex, field: .propValue)
                    editTarget = nextTarget
                    editText = decl.value
                }
                .onKeyPress(.escape) { editTarget = nil; return .handled }
                .onAppear { }
        } else {
            // One line, always: the value wraps instead.
            Text(decl.property)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.attributeNameColor)
                .strikethrough(decl.overridden || decl.disabled, color: InspectChrome.muted)
                .lineLimit(1)
                .fixedSize()
                .overlay(
                    InspectHitTarget(doubleAction: {
                        editTarget = target
                        editText = decl.property
                    }, action: {})
                )
        }
    }

    @ViewBuilder
    private var propValueField: some View {
        let target = ElEditTarget(ruleID: ruleID, declIndex: declIndex, field: .propValue)
        let isEditing = editTarget == target
        let isColor = OrbitElementsLogic.isColorValue(decl.value)

        if isEditing {
            HStack(spacing: 2) {
                if isColor {
                    ElColorSwatch(rgba: OrbitElementsLogic.parseRGBA(decl.value) ?? .init(r: 0, g: 0, b: 0, a: 1))
                        .frame(width: 14, height: 14)
                }
                ElInlineValueEditor(
                    value: $editText,
                    property: decl.property,
                    onCommit: {
                        let property = renamedTo ?? decl.property
                        if editText != decl.value || renamedTo == nil {
                            onValueCommit(property, editText, decl.priority)
                        }
                        renamedTo = nil
                        editTarget = nil
                    },
                    onCancel: { renamedTo = nil; editTarget = nil }
                )
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if isColor, let rgba = OrbitElementsLogic.parseRGBA(decl.value) {
                    ElColorSwatch(rgba: rgba)
                        .frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        .popover(isPresented: $showColorPicker) {
                            ElColorPickerPopover(
                                initialRGBA: rgba,
                                onCommit: { newRGBA in
                                    let newVal = OrbitElementsLogic.formatHex(newRGBA)
                                    onValueCommit(decl.property, newVal, decl.priority)
                                }
                            )
                        }
                        .overlay(InspectHitTarget { showColorPicker.toggle() })
                }
                (Text(decl.value)
                    .foregroundStyle(decl.overridden || decl.disabled ? InspectChrome.muted : InspectChrome.ink)
                    .strikethrough(decl.overridden || decl.disabled, color: InspectChrome.muted)
                 + Text(decl.isImportant ? " !important" : "").foregroundStyle(InspectChrome.badColor)
                 + Text(";").foregroundStyle(InspectChrome.muted))
                    .font(InspectChrome.mono)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(
                        InspectHitTarget(doubleAction: {
                            editTarget = target
                            editText = decl.value
                        }, action: {})
                    )
            }
        }
    }
}

// MARK: - Longhand row (inside an expanded shorthand)

/// One longhand of an expanded shorthand. Its value is editable on its own; the edit goes to the same rule.
struct ElLonghandRow: View {
    var longhand: ElDeclaration
    var priority: String
    var onValueCommit: (String, String, String) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: 28, height: 1)
            Text(longhand.property)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.attributeNameColor.opacity(0.8))
                .strikethrough(longhand.overridden || longhand.disabled, color: InspectChrome.muted)
                .lineLimit(1)
                .fixedSize()
            Text(": ").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            if isEditing {
                ElInlineValueEditor(
                    value: $editText,
                    property: longhand.property,
                    onCommit: {
                        onValueCommit(longhand.property, editText, priority)
                        isEditing = false
                    },
                    onCancel: { isEditing = false }
                )
            } else {
                (Text(longhand.value)
                    .foregroundStyle(longhand.overridden || longhand.disabled ? InspectChrome.muted : InspectChrome.ink2)
                    .strikethrough(longhand.overridden || longhand.disabled, color: InspectChrome.muted)
                 + Text(";").foregroundStyle(InspectChrome.muted))
                    .font(InspectChrome.mono)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(InspectHitTarget(doubleAction: {
                        editText = longhand.value
                        isEditing = true
                    }, action: {}))
            }
            if isEditing {
                Text(";").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: InspectChrome.rowHeight)
    }
}

// MARK: - Inline value editor with Up/Down increment

struct ElInlineValueEditor: View {
    @Binding var value: String
    var property: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        TextField("", text: $value)
            .textFieldStyle(.plain)
            .font(InspectChrome.mono)
            .frame(minWidth: 40)
            .onSubmit { onCommit() }
            .onKeyPress(.escape) { onCancel(); return .handled }
            .onKeyPress(.upArrow) {
                value = OrbitElementsLogic.incrementValue(value, by: 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                value = OrbitElementsLogic.incrementValue(value, by: -1)
                return .handled
            }
    }
}

// MARK: - New declaration editor

struct ElNewDeclarationEditor: View {
    var ruleID: String
    var suggestions: [String]
    var onCommit: (String, String) -> Void
    var onCancel: () -> Void

    @State private var propText = ""
    @State private var valText = ""
    @State private var phase = 0  // 0 = entering prop, 1 = entering value
    @State private var filteredSuggestions: [String] = []
    @FocusState private var propFocus: Bool
    @FocusState private var valFocus: Bool

    var body: some View {
        HStack(spacing: 0) {
            if phase == 0 {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("property", text: $propText)
                        .textFieldStyle(.plain)
                        .font(InspectChrome.mono)
                        .focused($propFocus)
                        .onChange(of: propText) { old, new in
                            filteredSuggestions = suggestions.filter {
                                $0.hasPrefix(new.lowercased())
                            }.prefix(8).map { $0 }
                        }
                        .onSubmit {
                            if !propText.isEmpty { phase = 1; valFocus = true }
                        }
                        .onKeyPress(.escape) { onCancel(); return .handled }
                        .frame(minWidth: 80)
                    if !filteredSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredSuggestions, id: \.self) { s in
                                Text(s).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                                    .padding(.horizontal, 6)
                                    .frame(minHeight: 18)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .overlay(InspectHitTarget { propText = s; phase = 1; valFocus = true })
                            }
                        }
                        .background(InspectChrome.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: OrbitRadius.xs)
                                .strokeBorder(InspectChrome.hairline)
                        )
                        .shadow(radius: 4)
                    }
                }
                .onAppear { propFocus = true }
            } else {
                Text(propText).font(InspectChrome.mono).foregroundStyle(InspectChrome.attributeNameColor)
                Text(": ").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                TextField("value", text: $valText)
                    .textFieldStyle(.plain)
                    .font(InspectChrome.mono)
                    .focused($valFocus)
                    .onSubmit {
                        if !propText.isEmpty {
                            onCommit(propText, valText)
                        } else {
                            onCancel()
                        }
                    }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    .frame(minWidth: 80)
                    .onAppear { valFocus = true }
            }
        }
    }
}

// MARK: - Color swatch

struct ElColorSwatch: View {
    var rgba: OrbitElementsLogic.CSSRGBA

    var body: some View {
        let color = Color(red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(InspectChrome.hairline, lineWidth: 0.5)
            )
    }
}

// MARK: - Color picker popover

struct ElColorPickerPopover: View {
    var initialRGBA: OrbitElementsLogic.CSSRGBA
    var onCommit: (OrbitElementsLogic.CSSRGBA) -> Void

    @State private var hexText: String
    @State private var rText: String
    @State private var gText: String
    @State private var bText: String
    @State private var aText: String

    init(initialRGBA: OrbitElementsLogic.CSSRGBA, onCommit: @escaping (OrbitElementsLogic.CSSRGBA) -> Void) {
        self.initialRGBA = initialRGBA
        self.onCommit = onCommit
        let hex = OrbitElementsLogic.formatHex(initialRGBA)
        self._hexText = State(initialValue: hex)
        self._rText = State(initialValue: String(Int(clamping: initialRGBA.r)))
        self._gText = State(initialValue: String(Int(clamping: initialRGBA.g)))
        self._bText = State(initialValue: String(Int(clamping: initialRGBA.b)))
        self._aText = State(initialValue: String(format: "%.2f", initialRGBA.a))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Preview swatch
            let previewRGBA = OrbitElementsLogic.parseRGBA(hexText) ??
                              OrbitElementsLogic.CSSRGBA(r: 0, g: 0, b: 0, a: 1)
            RoundedRectangle(cornerRadius: OrbitRadius.xs)
                .fill(Color(red: previewRGBA.r/255, green: previewRGBA.g/255, blue: previewRGBA.b/255, opacity: previewRGBA.a))
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: OrbitRadius.xs).strokeBorder(InspectChrome.hairline))

            // Hex
            HStack {
                Text("Hex").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted).frame(width: 28)
                TextField("", text: $hexText)
                    .textFieldStyle(.plain)
                    .font(InspectChrome.mono)
                    .onSubmit { commitHex() }
            }

            // RGB
            colorRow(label: "R", text: $rText)
            colorRow(label: "G", text: $gText)
            colorRow(label: "B", text: $bText)
            colorRow(label: "A", text: $aText)
        }
        .padding(12)
        .frame(width: 180)
    }

    private func colorRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted).frame(width: 16)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .onSubmit { commitRGB() }
        }
    }

    private func commitHex() {
        var h = hexText.trimmingCharacters(in: .whitespaces)
        if !h.hasPrefix("#") { h = "#" + h }
        if let rgba = OrbitElementsLogic.parseRGBA(h) { onCommit(rgba) }
    }

    private func commitRGB() {
        let r = Double(rText) ?? 0
        let g = Double(gText) ?? 0
        let b = Double(bText) ?? 0
        let a = Double(aText) ?? 1
        onCommit(OrbitElementsLogic.CSSRGBA(r: r, g: g, b: b, a: a))
    }
}

// MARK: - Computed Pane

struct ElComputedPane: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                InspectSearchField(placeholder: "Filter properties", text: Binding(
                    get: { model.filterComputedText },
                    set: { model.filterComputedText = $0 }
                ))
                InspectChip("All", selected: model.showAllComputed) {
                    model.showAllComputed.toggle()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Rectangle().fill(InspectChrome.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredComputedProperties) { prop in
                        ElComputedRow(prop: prop, session: session)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct ElComputedRow: View {
    var prop: ElComputedProperty
    var session: OrbitInspectSession
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if OrbitElementsLogic.isColorValue(prop.value),
               let rgba = OrbitElementsLogic.parseRGBA(prop.value) {
                ElColorSwatch(rgba: rgba).frame(width: 12, height: 12)
            }
            Text(prop.property)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.attributeNameColor)
                .frame(minWidth: 120, alignment: .leading)
            Text(prop.value)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if prop.isInherited {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                    .foregroundStyle(InspectChrome.muted)
            }
            if let sel = prop.winningSelector, !sel.isEmpty {
                Text(sel)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onHover { isHovering = $0 }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: InspectChrome.rowHeight)
        .background(isHovering ? InspectChrome.hover : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Layout / Box Model Pane

struct ElLayoutPane: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let bm = model.boxModel {
                    ElBoxModelView(boxModel: bm, session: session)
                    ElPositionView(boxModel: bm, session: session)
                } else {
                    InspectEmptyState(
                        symbol: "square.dashed",
                        title: "No layout data",
                        message: "Select an element to see its box model."
                    )
                }
            }
            .padding(12)
        }
    }
}

struct ElBoxModelView: View {
    var boxModel: ElBoxModel
    var session: OrbitInspectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        InspectSectionHeader("Box model")
        // Nested box diagram
        ZStack {
            // Margin layer
            boxLayer(label: "margin", color: Color.orange.opacity(0.3)) {
                // Border layer
                boxLayer(label: "border", color: Color.yellow.opacity(0.35)) {
                    // Padding layer
                    boxLayer(label: "padding", color: Color.green.opacity(0.3)) {
                        // Content
                        VStack(spacing: 2) {
                            Text("\(Int(clamping: boxModel.width)) × \(Int(clamping: boxModel.height))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(InspectChrome.muted)
                        }
                        .frame(minWidth: 60, minHeight: 36)
                        .background(Color.blue.opacity(0.15))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Editable values grid
        ElSpacingGrid(
            top: boxModel.marginTop, right: boxModel.marginRight,
            bottom: boxModel.marginBottom, left: boxModel.marginLeft,
            label: "margin",
            onEdit: { edge, val in editMargin(edge: edge, val: val) }
        )
        ElSpacingGrid(
            top: boxModel.paddingTop, right: boxModel.paddingRight,
            bottom: boxModel.paddingBottom, left: boxModel.paddingLeft,
            label: "padding",
            onEdit: { edge, val in editPadding(edge: edge, val: val) }
        )
        } // end VStack
    }

    private func boxLayer<Content: View>(
        label: String,
        color: Color,
        @ViewBuilder inner: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(label).font(.system(size: 9)).foregroundStyle(InspectChrome.muted)
                Spacer()
            }
            HStack(spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundStyle(InspectChrome.muted).padding(4)
                inner()
                Text(label).font(.system(size: 9)).foregroundStyle(InspectChrome.muted).padding(4)
            }
            HStack {
                Spacer()
                Text(label).font(.system(size: 9)).foregroundStyle(InspectChrome.muted)
                Spacer()
            }
        }
        .background(color)
        .padding(4)
    }

    private func editMargin(edge: String, val: String) {
        session.elements.setInlineProperty(property: "margin-\(edge)", value: val)
    }

    private func editPadding(edge: String, val: String) {
        session.elements.setInlineProperty(property: "padding-\(edge)", value: val)
    }
}

struct ElSpacingGrid: View {
    var top: String; var right: String; var bottom: String; var left: String
    var label: String
    var onEdit: (String, String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(label.prefix(1).uppercased() + label.dropFirst())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(InspectChrome.muted)
            // Four equal columns that share whatever width the detail pane has, so a narrow dock never clips an edge.
            HStack(spacing: 6) {
                edgeField(edge: "top", value: top)
                edgeField(edge: "right", value: right)
                edgeField(edge: "bottom", value: bottom)
                edgeField(edge: "left", value: left)
            }
        }
    }

    private func edgeField(edge: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(edge)
                .font(.system(size: 9))
                .foregroundStyle(InspectChrome.muted)
            ElEditableBoxValue(value: value) { newVal in
                onEdit(edge, newVal)
            }
        }
        .frame(minWidth: 28, maxWidth: .infinity)
    }
}

struct ElEditableBoxValue: View {
    var value: String
    var onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        if isEditing {
            TextField("", text: $editText)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onSubmit { onCommit(editText); isEditing = false }
                .onKeyPress(.escape) { isEditing = false; return .handled }
                .onAppear { editText = value }
        } else {
            Text(value)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .overlay(
                    InspectHitTarget(doubleAction: { isEditing = true }, action: {})
                )
        }
    }
}

struct ElPositionView: View {
    var boxModel: ElBoxModel
    var session: OrbitInspectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            InspectSectionHeader("Position")
            HStack(spacing: 8) {
                labelVal("display", boxModel.display)
                labelVal("position", boxModel.position)
                if boxModel.position != "static" {
                    labelVal("top", boxModel.top)
                    labelVal("left", boxModel.left)
                }
            }
            overlayToggle(.flex, available: boxModel.isFlex)
            overlayToggle(.grid, available: boxModel.isGrid)
        }
    }

    /// A toggle for the on-page overlay, shown only for containers of that kind.
    @ViewBuilder
    private func overlayToggle(_ kind: ElLayoutKind, available: Bool) -> some View {
        if available, let id = session.elements.selectedID {
            let model = session.elements
            InspectChip("Show \(kind.label) overlay", selected: model.layoutOverlays[id] == kind) {
                if model.layoutKinds[id] == nil { model.noteLayoutKind(kind, for: id) }
                model.toggleLayoutOverlay(nodeID: id)
            }
        }
    }

    private func labelVal(_ label: String, _ val: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            Text(val).font(InspectChrome.mono)
        }
    }
}

// MARK: - Event Listeners Pane

struct ElListenersPane: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event listeners").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectChip("Ancestors", selected: model.includeAncestorListeners) {
                    model.includeAncestorListeners.toggle()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Rectangle().fill(InspectChrome.hairline).frame(height: 1)
            if model.eventListeners.isEmpty {
                InspectEmptyState(
                    symbol: "bolt",
                    title: "No listeners",
                    message: "No event listeners captured. Only listeners added after the inspector was installed are shown."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.eventListeners) { listener in
                            ElListenerRow(listener: listener, session: session)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct ElListenerRow: View {
    var listener: ElEventListener
    var session: OrbitInspectSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(InspectChrome.muted)
                    .frame(width: 12)
                Text(listener.eventType)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(InspectChrome.tagColor)
                if listener.isWindow {
                    Text("window").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                } else if listener.isAncestor {
                    Text("ancestor").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
                HStack(spacing: 4) {
                    if listener.capture { badge("capture") }
                    if listener.passive  { badge("passive") }
                    if listener.once     { badge("once") }
                }
                Spacer()
                if listener.addedBeforeInspector && listener.sourceURL == nil {
                    Text("added before the inspector opened")
                        .font(InspectChrome.caption)
                        .foregroundStyle(InspectChrome.muted)
                        .orbitTooltip("Orbit records where a listener was added only while the inspector is open.")
                }
                if let url = listener.sourceURL {
                    let file = URL(string: url)?.lastPathComponent ?? url
                    let display = listener.sourceLine != nil ? "\(file):\(listener.sourceLine!)" : file
                    Text(display)
                        .font(InspectChrome.caption)
                        .foregroundStyle(InspectChrome.accent)
                        .contentShape(Rectangle())
                        .overlay(
                            InspectHitTarget {
                                session.reveal(sourceURL: url, line: listener.sourceLine)
                            }
                        )
                }
            }
            .frame(minHeight: InspectChrome.rowHeight)
            .contentShape(Rectangle())
            .overlay(InspectHitTarget { expanded.toggle() })

            if expanded && !listener.handlerSource.isEmpty {
                Text(listener.handlerSource)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(InspectChrome.muted)
                    .padding(.leading, 20)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(InspectChrome.surface)
            }
        }
        .padding(.horizontal, 8)
    }

    private func badge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(InspectChrome.hover))
    }
}

// MARK: - Accessibility Pane

struct ElA11yPane: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        if let a11y = model.a11y {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    a11yRow(label: "Role", value: a11y.role, color: InspectChrome.tagColor)
                    if !a11y.name.isEmpty {
                        a11yRow(label: "Name", value: "\"\(a11y.name)\"")
                        a11yRow(label: "Name from", value: a11y.nameFrom, color: InspectChrome.muted)
                    }
                    a11yRow(label: "Focusable", value: a11y.focusable ? "yes" : "no",
                            color: a11y.focusable ? InspectChrome.goodColor : .secondary)
                    if let cr = a11y.contrastRatio {
                        let cr4 = String(format: "%.2f", cr)
                        a11yRow(label: "Contrast",
                                value: "\(cr4) : 1",
                                color: (a11y.wcagAA ?? false) ? InspectChrome.goodColor : InspectChrome.badColor)
                        if let aa = a11y.wcagAA {
                            a11yRow(label: "WCAG AA",
                                    value: aa ? "✓ Pass" : "✗ Fail",
                                    color: aa ? InspectChrome.goodColor : InspectChrome.badColor)
                        }
                    }
                    if !a11y.ariaAttrs.isEmpty {
                        InspectDivider().padding(.vertical, 4)
                        InspectSectionHeader("ARIA attributes").padding(.horizontal, 8)
                        ForEach(a11y.ariaAttrs.sorted(by: { $0.key < $1.key }), id: \.key) { key, val in
                            a11yRow(label: key, value: val)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            InspectEmptyState(
                symbol: "accessibility",
                title: "No accessibility data",
                message: "Select an element to see its accessibility properties."
            )
        }
    }

    private func a11yRow(label: String, value: String, color: Color = InspectChrome.ink) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(InspectChrome.mono)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: InspectChrome.rowHeight)
    }
}

// MARK: - outerHTML editor overlay

struct ElOuterHTMLEditor: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    private static let outerRadius = OrbitRadius.lg
    private static let inset: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Edit as HTML")
                    .font(InspectChrome.labelStrong)
                    .foregroundStyle(InspectChrome.ink)
                Spacer(minLength: 8)
                InspectTextButton("Cancel") { model.cancelOuterHTML() }
                InspectTextButton("Apply", enabled: model.outerHTMLLoaded, prominent: true) { model.commitOuterHTML() }
            }
            .padding(Self.inset)
            InspectDivider()
            ElCodeEditor(
                text: Binding(get: { model.outerHTMLText }, set: { model.outerHTMLText = $0 }),
                isEditable: model.outerHTMLLoaded,
                onCommit: { model.commitOuterHTML() },
                onCancel: { model.cancelOuterHTML() }
            )
            .frame(minHeight: 120, maxHeight: 280)
            .background(InspectChrome.surface)
            .clipShape(RoundedRectangle(
                cornerRadius: OrbitRadius.concentric(outer: Self.outerRadius, inset: Self.inset), style: .continuous))
            .padding(Self.inset)
            if let error = model.outerHTMLError {
                Text(error)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.badColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.inset + 2)
                    .padding(.bottom, Self.inset)
            }
            Text("Cmd-Return applies. Esc cancels. Leaving the editor applies.")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.inset + 2)
                .padding(.bottom, Self.inset)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.outerRadius, style: .continuous).fill(InspectChrome.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.outerRadius, style: .continuous)
                .strokeBorder(InspectChrome.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit as HTML")
    }
}

// MARK: - Code editor

/// Built on `NSTextView` for real undo, selection and large-text performance; commits on Cmd-Return or focus loss.
struct ElCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onCommit: () -> Void
    var onCancel: () -> Void

    /// Past this many characters tokenizing on every keystroke costs more than the colour is worth.
    private static let highlightLimit = 200_000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let textView = ElCodeTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = Coordinator.font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("HTML source")
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.install(on: textView)

        // The editor opens focused so typing and Cmd-Return work immediately.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // The page answered a rejected commit: the editor is live again, so Cmd-Return must work a second time.
        if isEditable { context.coordinator.finished = false }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        var parent: ElCodeEditor
        weak var textView: NSTextView?
        /// Set once the user commits or cancels so the focus loss that follows does not act a second time.
        var finished = false

        init(_ parent: ElCodeEditor) { self.parent = parent }

        func install(on view: ElCodeTextView) {
            view.onCommit = { [weak self] in
                guard let self, !self.finished else { return }
                self.finished = true
                self.parent.onCommit()
            }
            view.onCancel = { [weak self] in
                guard let self, !self.finished else { return }
                self.finished = true
                self.parent.onCancel()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
        }

        /// Focus left the editor: apply, like clicking out of a field in Chrome.
        func textDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            parent.onCommit()
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let source = storage.string
            let full = NSRange(location: 0, length: storage.length)
            let base: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: InspectChrome.Hex.ink.nsColor,
            ]
            storage.beginEditing()
            storage.setAttributes(base, range: full)
            if storage.length <= ElCodeEditor.highlightLimit {
                for token in OrbitElementsLogic.htmlTokens(source) {
                    let range = NSRange(location: token.range.lowerBound, length: token.range.count)
                    guard range.location + range.length <= storage.length else { continue }
                    storage.addAttribute(.foregroundColor, value: Self.color(for: token.kind), range: range)
                }
            }
            storage.endEditing()
            view.typingAttributes = base
        }

        private static func color(for kind: OrbitElementsLogic.HTMLTokenKind) -> NSColor {
            switch kind {
            case .tagName: return InspectChrome.Hex.tag.nsColor
            case .attributeName: return InspectChrome.Hex.attributeName.nsColor
            case .attributeValue: return InspectChrome.Hex.attributeValue.nsColor
            case .comment, .doctype, .punctuation: return InspectChrome.Hex.muted.nsColor
            }
        }
    }
}

/// `NSTextView` that reports Cmd-Return and Esc instead of inserting anything.
final class ElCodeTextView: NSTextView {
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where flags.contains(.command), 76 where flags.contains(.command):   // Cmd-Return, Cmd-Enter
            onCommit()
        case 53:                                                                       // Esc
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Undo and redo key routing

/// AppKit offers key equivalents to the key window's views before the main menu, which is how this sees Cmd-Z at all.
struct ElUndoKeyCatcher: NSViewRepresentable {
    var model: OrbitElementsModel

    func makeNSView(context: Context) -> ElUndoKeyView {
        let view = ElUndoKeyView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ElUndoKeyView, context: Context) {
        view.model = model
    }
}

final class ElUndoKeyView: NSView {
    var model: OrbitElementsModel?
    private var pointerInside = false
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model, window?.isKeyWindow == true else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        // Text editing keeps its own undo.
        if window?.firstResponder is NSText { return false }
        guard pointerInside || model.treeIsFocused else { return false }
        let redo = flags.contains(.shift)
        guard redo ? model.canRedo : model.canUndo else { return false }
        if redo { model.redo() } else { model.undo() }
        return true
    }
}
