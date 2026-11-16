import SwiftUI

struct OrbitElementsPane: View {
    var session: OrbitInspectSession

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            InspectDivider()
            if model.isLoading && model.visibleRows.isEmpty {
                loadingView
            } else if model.visibleRows.isEmpty {
                InspectEmptyState(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: "No elements",
                    message: "Press the refresh button to load the page's DOM tree."
                )
            } else {
                mainSplit
            }
            InspectDivider()
            ElBreadcrumbBar(session: session)
        }
        .background(InspectChrome.panel)
        .background(ElUndoKeyCatcher(model: model))
        .overlay(outerHTMLEditorOverlay, alignment: .bottom)
        .orbitAnimation(OrbitMotion.standard, value: model.outerHTMLNodeID != nil)
    }

    /// One row at the narrowest dock width: the mode is a compact menu and the match stepper shows only while there are matches.
    private var searchBar: some View {
        HStack(spacing: 6) {
            InspectSearchField(placeholder: "Search", text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ))
            .frame(minWidth: 60)
            ElSearchModeMenu(model: model)
            if !model.searchMatches.isEmpty {
                Text("\(model.searchIndex + 1)/\(model.searchMatches.count)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                InspectIconButton(symbol: "chevron.up", help: "Previous match") { model.searchPrev() }
                InspectIconButton(symbol: "chevron.down", help: "Next match")    { model.searchNext() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Undo and redo for DOM and style edits, above the tree where the edits happen.
    private var treeToolbar: some View {
        HStack(spacing: 2) {
            InspectIconButton(
                symbol: "arrow.uturn.backward",
                help: model.history.undoLabel.map { "Undo \($0.lowercased())" } ?? "Undo",
                enabled: model.canUndo
            ) { model.undo() }
            InspectIconButton(
                symbol: "arrow.uturn.forward",
                help: model.history.redoLabel.map { "Redo \($0.lowercased())" } ?? "Redo",
                enabled: model.canRedo
            ) { model.redo() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
    }

    /// Styles goes under the tree when docked to a side or when the pane is narrow, and beside it otherwise.
    /// The orientation is part of the stored split key: a fraction of a height means something else than one of a width.
    private var mainSplit: some View {
        GeometryReader { geo in
            let docked = session.dock == .left || session.dock == .right
            let stacked = OrbitElementsLogic.detailStacks(dockedToSide: docked, width: geo.size.width)
            InspectSplit(
                key: stacked ? "elements.tree-detail.stacked" : "elements.tree-detail",
                defaultFraction: stacked ? 0.5 : 0.45,
                minFirst: 160, minSecond: 180,
                // The split stacks below this width; the rule above already decided, so it is all or nothing.
                stackBelow: stacked ? .infinity : 0
            ) {
                treePanel
            } second: {
                detailPanel
            }
            // The split keeps its dragged fraction in state, which must not carry over to the other orientation.
            .id(stacked)
        }
    }

    private var treePanel: some View {
        VStack(spacing: 0) {
            treeToolbar
            InspectDivider()
            ElTreeScroll(session: session)
        }
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            tabStrip
            InspectDivider()
            tabContent
        }
    }

    /// Scrolls horizontally so the five detail tabs never clip in a narrow detail pane.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(ElDetailTab.allCases) { tab in
                    InspectChip(tab.title, selected: model.detailTab == tab) {
                        model.detailTab = tab
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var tabContent: some View {
        if model.selectedID == nil {
            InspectEmptyState(
                symbol: "cursorarrow.click",
                title: "Select an element",
                message: "Click an element in the tree or use the picker to inspect it."
            )
        } else {
            switch model.detailTab {
            case .styles:
                ElStylesPane(session: session)
            case .computed:
                ElComputedPane(session: session)
            case .layout:
                ElLayoutPane(session: session)
            case .listeners:
                ElListenersPane(session: session)
            case .accessibility:
                ElA11yPane(session: session)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading DOM tree…")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var outerHTMLEditorOverlay: some View {
        if model.outerHTMLNodeID != nil {
            ElOuterHTMLEditor(session: session)
                .padding(8)
                .transition(.opacity.combined(with: .offset(y: 12)))
        }
    }
}

/// The DOM tree. It scrolls both ways: rows print in full, so a long line or a deep node is reached by scrolling right.
/// The rows stay in a `LazyVStack`, and the scrollable width comes from the rows' text, not from laying them all out.
private struct ElTreeScroll: View {
    var session: OrbitInspectSession

    @FocusState private var treeFocused: Bool
    @State private var position = ScrollPosition()
    @State private var scrollOffset = ElTreeScrollOffset()
    @State private var widest = ElTreeWidthCache()

    /// The tree's vertical padding, which offsets the first row from the top of the content.
    private static let verticalPadding: CGFloat = 4

    private var model: OrbitElementsModel { session.elements }

    var body: some View {
        let contentWidth = widest.width(revision: model.rowsRevision) {
            ElTreeRowView.contentWidth(of: model.visibleRows)
        }
        GeometryReader { geo in
            let rowWidth = max(geo.size.width, contentWidth)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visibleRows) { row in
                        ElTreeRowView(row: row, session: session, minWidth: rowWidth)
                    }
                    // Show more for nodes with truncated children
                    ForEach(model.showMoreOffsets.keys.sorted(), id: \.self) { nodeID in
                        if expanded(nodeID) {
                            showMoreButton(nodeID: nodeID)
                        }
                    }
                }
                .padding(.vertical, Self.verticalPadding)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                scrollOffset.y = offset
            }
            .focusable()
            .focused($treeFocused)
            .onChange(of: treeFocused) { _, focused in model.treeIsFocused = focused }
            .onKeyPress { press in
                handleKeyPress(press)
            }
            .onChange(of: model.autoScroll) { _, request in
                guard let request, let top = rowTop(of: request.above), let bottom = rowTop(of: request.below) else { return }
                reveal(from: top, to: bottom + InspectChrome.rowHeight, viewportHeight: geo.size.height)
            }
            .onChange(of: model.selectedID) { _, newID in
                guard let id = newID, let top = rowTop(of: ElFlatRow.RowID(nodeID: id, isClosingTag: false)) else { return }
                center(rowTop: top, viewportHeight: geo.size.height)
            }
        }
    }

    // The vertical moves set only y, so a tree scrolled to the right to edit a node stays where it is.

    private func rowTop(of id: ElFlatRow.RowID) -> CGFloat? {
        model.visibleRows.firstIndex(where: { $0.id == id })
            .map { Self.verticalPadding + CGFloat($0) * InspectChrome.rowHeight }
    }

    private func center(rowTop: CGFloat, viewportHeight: CGFloat) {
        let contentHeight = Self.verticalPadding * 2 + CGFloat(model.visibleRows.count) * InspectChrome.rowHeight
        let target = rowTop + InspectChrome.rowHeight / 2 - viewportHeight / 2
        let clamped = min(max(target, 0), max(0, contentHeight - viewportHeight))
        withOrbitAnimation(OrbitMotion.quick) { position.scrollTo(y: clamped) }
    }

    /// Scrolls the least distance that brings `top...bottom` into view.
    private func reveal(from top: CGFloat, to bottom: CGFloat, viewportHeight: CGFloat) {
        let offset = scrollOffset.y
        let target: CGFloat
        if top < offset { target = top }
        else if bottom > offset + viewportHeight { target = bottom - viewportHeight }
        else { return }
        withOrbitAnimation(OrbitMotion.quick) { position.scrollTo(y: max(0, target)) }
    }

    private func expanded(_ nodeID: Int) -> Bool {
        model.expanded.contains(nodeID)
    }

    private func showMoreButton(nodeID: Int) -> some View {
        let loaded = model.childrenMap[nodeID]?.count ?? 0
        let total = model.nodes[nodeID]?.childCount ?? 0
        let remaining = total - loaded
        return Group {
            if remaining > 0 {
                HStack {
                    Spacer().frame(width: CGFloat(model.visibleRows.first(where: { $0.nodeID == nodeID })?.depth ?? 0) * 16 + 20)
                    InspectTextButton("Show \(min(remaining, 200)) more of \(remaining)") {
                        model.loadMoreChildren(nodeID: nodeID)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(minHeight: InspectChrome.rowHeight)
            }
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // KeyEquivalent is a struct so we compare with == rather than using switch
        let k = press.key
        if k == .upArrow    { model.moveSelection(by: -1); return .handled }
        if k == .downArrow  { model.moveSelection(by: 1);  return .handled }
        if k == .leftArrow  {
            if let id = model.selectedID { model.collapseOrMoveToParent(nodeID: id) }
            return .handled
        }
        if k == .rightArrow {
            if let id = model.selectedID { model.expandOrMoveToFirstChild(nodeID: id) }
            return .handled
        }
        if k == .return {
            // Return edits the selected node, like double-clicking it: text nodes edit their text, elements rename.
            if let id = model.selectedID, let node = model.nodes[id] {
                if node.kind == "text" || node.kind == "comment" { model.beginTextEdit(nodeID: id) }
                else { model.beginTagRename(nodeID: id) }
            }
            return .handled
        }
        if k == .delete || k == .deleteForward {
            if let id = model.selectedID { model.deleteNode(nodeID: id) }
            return .handled
        }
        return .ignored
    }
}

/// The tree's vertical scroll offset. Kept out of observation: it changes on every scroll tick and only a drag reads it.
private final class ElTreeScrollOffset {
    var y: CGFloat = 0
}

/// The widest row's width, measured once per set of visible rows rather than on every body pass while scrolling.
private final class ElTreeWidthCache {
    private var revision = -1
    private var cached: CGFloat = 0

    func width(revision: Int, measure: () -> CGFloat) -> CGFloat {
        if revision != self.revision {
            cached = measure()
            self.revision = revision
        }
        return cached
    }
}

/// The search mode as a compact menu: its current name and a chevron, so the search bar stays on one row.
private struct ElSearchModeMenu: View {
    var model: OrbitElementsModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(model.searchMode.label)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(InspectChrome.ink)
        .padding(.horizontal, 8)
        .frame(height: InspectChrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(hovering ? InspectChrome.selection : InspectChrome.hover)
        )
        .fixedSize()
        .overlay(InspectMenuTarget {
            ElSearchMode.allCases.map { mode in
                InspectMenuItem(title: mode.label, checked: model.searchMode == mode) { model.searchMode = mode }
            }
        })
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .orbitTooltip("Search mode")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search mode")
        .accessibilityValue(model.searchMode.label)
        .accessibilityAddTraits(.isButton)
    }
}
