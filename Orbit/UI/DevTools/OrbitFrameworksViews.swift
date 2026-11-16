import AppKit
import SwiftUI

// MARK: - Technology sidebar row

struct FWTechRow: View {
    var detection: FWDetected
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(confidenceColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(detection.displayName)
                    .font(InspectChrome.label)
                    .lineLimit(1)
                Text(detection.category.rawValue)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            if !detection.evidence.isEmpty {
                Text("Evidence").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                Divider()
                ForEach(detection.evidence, id: \.self) { ev in
                    Text(ev).font(InspectChrome.caption)
                }
            }
        }
    }

    private var confidenceColor: Color {
        switch detection.confidence {
        case .certain: return InspectChrome.goodColor
        case .likely: return InspectChrome.warnColor
        case .possible: return InspectChrome.badColor
        }
    }
}

// MARK: - Technologies detail tab

struct FWTechnologiesTab: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession
    /// The side list that normally owns the filter is hidden in a narrow or docked pane, so the tab carries its own.
    var showsFilter = false

    var body: some View {
        if model.detections.isEmpty {
            InspectEmptyState(
                symbol: "shippingbox",
                title: "No technologies detected",
                message: "Press Refresh to scan the current page. Detection reads JavaScript globals, DOM attributes, script URLs, response headers, and meta tags."
            )
        } else {
            VStack(spacing: 0) {
                if showsFilter {
                    InspectSearchField(placeholder: "Filter", text: Binding(
                        get: { model.techFilter },
                        set: { model.techFilter = $0 }
                    ))
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                    InspectDivider()
                }
                technologyList
            }
        }
    }

    private var technologyList: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(FWCategory.allCases, id: \.self) { category in
                        let group = model.filteredDetections.filter { $0.category == category }
                        if !group.isEmpty {
                            InspectSectionHeader(category.rawValue)
                                .padding(.horizontal, InspectChrome.panelPadding)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group) { d in
                                FWTechDetailRow(detection: d)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
    }
}

struct FWTechDetailRow: View {
    var detection: FWDetected

    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(confidenceColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(detection.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(detection.confidence.label)
                            .font(InspectChrome.caption)
                            .foregroundStyle(InspectChrome.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(InspectChrome.hover))
                    }
                }
                Spacer(minLength: 0)
                InspectTextButton(showEvidence ? "Hide evidence" : "Evidence") {
                    showEvidence.toggle()
                }
                .padding(.trailing, InspectChrome.panelPadding)
            }
            .frame(minHeight: InspectChrome.rowHeight + 4)
            .padding(.leading, InspectChrome.panelPadding)
            .overlay(InspectHitTarget { showEvidence.toggle() })

            if showEvidence {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detection.evidence, id: \.self) { ev in
                        Text(ev)
                            .font(InspectChrome.mono)
                            .foregroundStyle(InspectChrome.muted)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, InspectChrome.panelPadding + 18)
                .padding(.bottom, 6)
            }
        }
    }

    private var confidenceColor: Color {
        switch detection.confidence {
        case .certain: return InspectChrome.goodColor
        case .likely: return InspectChrome.warnColor
        case .possible: return InspectChrome.badColor
        }
    }
}

// MARK: - Components tab

struct FWComponentsTab: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession

    var body: some View {
        VStack(spacing: 0) {
            componentToolbar
            InspectDivider()
            if model.isTreeLoading && model.componentNodes.isEmpty {
                loadingState
            } else if model.componentNodes.isEmpty {
                emptyState
            } else {
                FWAdaptiveSplit(session: session, key: "fw.components", sideFraction: 0.45, minFirst: 180, minSecond: 200) {
                    componentTree
                } second: {
                    componentDetail
                }
            }
        }
    }

    private var componentToolbar: some View {
        HStack(spacing: 6) {
            InspectSearchField(placeholder: "Filter by name or prop", text: Binding(
                get: { model.componentFilter },
                set: { model.componentFilter = $0 }
            ))
            .frame(minWidth: 80)
            if model.minifiedBanner {
                Text("Names minified").font(InspectChrome.caption).foregroundStyle(InspectChrome.warnColor)
                    .lineLimit(1).fixedSize()
            }
            if model.componentsCapped {
                Text("Capped").font(InspectChrome.caption).foregroundStyle(InspectChrome.warnColor)
                    .lineLimit(1).fixedSize()
                    .orbitTooltip("The tree was truncated at 2000 nodes to avoid hanging the page.")
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Building component tree…").font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        Group {
            if let fw = model.componentFramework {
                InspectEmptyState(
                    symbol: "square.3.layers.3d",
                    title: "No components found",
                    message: "Detected framework: \(fw). The component tree requires a dev build with source maps, or React DevTools hook exposure."
                )
            } else {
                InspectEmptyState(
                    symbol: "square.3.layers.3d",
                    title: "No component tree available",
                    message: "No React root was found on this page. Production builds still expose React roots. If React is present but nothing appears, the DevTools hook may be disabled. Other frameworks (Vue, Angular, Svelte) require developer mode."
                )
            }
        }
    }

    private var componentTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let filter = model.filteredNodeIDs
                ForEach(model.componentRoots, id: \.self) { rootID in
                    FWComponentSubtree(
                        nodeID: rootID,
                        model: model,
                        session: session,
                        filter: filter,
                        depth: 0
                    )
                }
                if model.minifiedBanner {
                    Text("Component names are minified in production builds; the tree is shown as-is.")
                        .font(InspectChrome.caption)
                        .foregroundStyle(InspectChrome.warnColor)
                        .padding(.horizontal, InspectChrome.panelPadding)
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var componentDetail: some View {
        FWComponentDetailView(model: model, session: session)
    }
}

// MARK: - Component tree node (recursive)

struct FWComponentSubtree: View {
    var nodeID: Int
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession
    var filter: Set<Int>?
    var depth: Int

    @State private var expanded: Bool = true

    var body: some View {
        if let node = model.componentNodes.first(where: { $0.id == nodeID }), passes(node: node) {
            VStack(alignment: .leading, spacing: 0) {
                FWComponentRow(node: node, model: model, session: session, expanded: $expanded, depth: depth)
                if expanded {
                    ForEach(node.childIDs, id: \.self) { childID in
                        FWComponentSubtree(nodeID: childID, model: model, session: session,
                                           filter: filter, depth: depth + 1)
                    }
                }
            }
        }
    }

    private func passes(node: FWComponentNode) -> Bool {
        guard let f = filter else { return true }
        return f.contains(node.id) || hasMatchingDescendant(node.id)
    }

    private func hasMatchingDescendant(_ id: Int) -> Bool {
        guard let f = filter, let node = model.componentNodes.first(where: { $0.id == id }) else { return false }
        if f.contains(id) { return true }
        return node.childIDs.contains(where: { hasMatchingDescendant($0) })
    }
}

struct FWComponentRow: View {
    var node: FWComponentNode
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession
    @Binding var expanded: Bool
    var depth: Int

    private var isSelected: Bool { model.selectedNodeID == node.id }

    var body: some View {
        HStack(spacing: 0) {
            // Indent
            Color.clear.frame(width: CGFloat(depth) * 14)

            // Expand/collapse chevron
            if !node.childIDs.isEmpty {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InspectChrome.muted)
                    .frame(width: 16, height: 22)
                    .overlay(InspectHitTarget { expanded.toggle() })
            } else {
                Color.clear.frame(width: 16)
            }

            // Name
            HStack(spacing: 5) {
                Text(node.name)
                    .font(InspectChrome.mono)
                    .foregroundStyle(node.minified ? InspectChrome.warnColor : InspectChrome.tagColor)
                    .lineLimit(1)

                if let key = node.key {
                    Text("key=\(key)").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted2)
                }

                if node.sourceFile != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundStyle(InspectChrome.muted2)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .background(isSelected ? InspectChrome.selection : (isHovered ? InspectChrome.hover : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .padding(.horizontal, 4)
        .overlay(InspectHitTarget {
            model.selectComponent(id: node.id)
        })
        .onHover { over in
            isHovered = over
            if over {
                if let domID = node.domNodeID { session.highlight(nodeID: domID) }
            } else {
                session.clearHighlight()
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }

    @State private var isHovered = false

    @ViewBuilder
    private var contextMenuItems: some View {
        if node.domNodeID != nil {
            Button("Reveal in Elements") { model.revealComponentInElements(id: node.id) }
        }
        if node.sourceFile != nil {
            Button("Reveal in Sources") { model.openSourceForComponent(id: node.id) }
            Button("Open in Editor") { model.openInEditorForComponent(id: node.id) }
        }
        Divider()
        Button("Copy props JSON") { model.copyComponentProps(id: node.id) }
        Button("Store as $r") { model.storeComponentAsGlobal() }
    }
}

// MARK: - Component detail

struct FWComponentDetailView: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession

    private enum Section: String, CaseIterable {
        case props = "Props"
        case hooks = "Hooks (approx.)"
        case source = "Source"
    }

    @State private var section: Section = .props

    var body: some View {
        if let node = model.selectedNode {
            VStack(spacing: 0) {
                detailHeader(node: node)
                InspectDivider()
                sectionPicker
                InspectDivider()
                sectionContent(node: node)
                if let msg = model.editResultMessage {
                    InspectDivider()
                    Text(msg)
                        .font(InspectChrome.caption)
                        .foregroundStyle(InspectChrome.muted)
                        .padding(6)
                }
            }
        } else {
            InspectEmptyState(
                symbol: "curlybraces",
                title: "No component selected",
                message: "Click a component in the tree to inspect its props, hooks, and source location."
            )
        }
    }

    private func detailHeader(node: FWComponentNode) -> some View {
        HStack(spacing: 8) {
            Text(node.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InspectChrome.tagColor)
            if node.minified {
                Text("minified").font(InspectChrome.caption).foregroundStyle(InspectChrome.warnColor)
            }
            Spacer(minLength: 0)
            if node.sourceFile != nil {
                InspectTextButton("Sources") { model.openSourceForComponent(id: node.id) }
                InspectTextButton("Editor") { model.openInEditorForComponent(id: node.id) }
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: 32)
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases, id: \.self) { s in
                InspectChip(s.rawValue, selected: section == s) { section = s }
            }
            Spacer()
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sectionContent(node: FWComponentNode) -> some View {
        ScrollView {
            switch section {
            case .props:
                propsView(node: node)
            case .hooks:
                hooksView(node: node)
            case .source:
                sourceView(node: node)
            }
        }
    }

    private func propsView(node: FWComponentNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if node.props.isEmpty {
                Text("No props").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(InspectChrome.panelPadding)
            } else {
                ForEach(node.props.keys.sorted(), id: \.self) { key in
                    FWKeyValueRow(
                        name: key,
                        value: node.props[key] ?? "",
                        editable: node.domNodeID != nil,
                        onEdit: { newVal in
                            if let domID = node.domNodeID { model.editProp(domNodeID: domID, name: key, value: newVal) }
                        }
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func hooksView(node: FWComponentNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if node.hooks.isEmpty {
                Text("No hooks detected (function components only; class components show state under Props).")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(InspectChrome.panelPadding)
            } else {
                Text("Values are approximate — hook labels are inferred from the memoizedState chain.")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.top, 6)
                ForEach(node.hooks, id: \.index) { hook in
                    FWKeyValueRow(
                        name: "[\(hook.index)] \(hook.label)",
                        value: hook.value,
                        editable: node.domNodeID != nil && hook.label == "state",
                        onEdit: { newVal in
                            if let domID = node.domNodeID { model.editHookState(domNodeID: domID, hookIndex: hook.index, value: newVal) }
                        }
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceView(node: FWComponentNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let file = node.sourceFile {
                FWKeyValueRow(name: "file", value: file, editable: false, onEdit: { _ in })
                if let line = node.sourceLine {
                    FWKeyValueRow(name: "line", value: "\(line)", editable: false, onEdit: { _ in })
                }
                if let col = node.sourceCol {
                    FWKeyValueRow(name: "column", value: "\(col)", editable: false, onEdit: { _ in })
                }
            } else {
                Text("No source location available. Source locations require a development build with _debugSource or _debugStack set by React.")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(InspectChrome.panelPadding)
            }
            if let owner = node.ownerName {
                FWKeyValueRow(name: "rendered by", value: owner, editable: false, onEdit: { _ in })
            }
            if let launchErr = model.launchError {
                Text(launchErr).font(InspectChrome.caption).foregroundStyle(InspectChrome.warnColor)
                    .padding(.horizontal, InspectChrome.panelPadding)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Key-value row with optional inline editing

struct FWKeyValueRow: View {
    var name: String
    var value: String
    var editable: Bool
    var onEdit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(name)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.attributeNameColor)
                .frame(minWidth: 100, alignment: .leading)
                .lineLimit(1)
                .padding(.leading, InspectChrome.panelPadding)

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(InspectChrome.mono)
                    .padding(.horizontal, 4)
                    .onSubmit { commitEdit() }
                    .onExitCommand { editing = false }
            } else {
                Text(value)
                    .font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.attributeValueColor)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)

            if editable && !editing {
                InspectIconButton(symbol: "pencil", help: "Edit value") {
                    draft = value
                    editing = true
                }
            } else if editing {
                InspectIconButton(symbol: "checkmark", help: "Apply") { commitEdit() }
                InspectIconButton(symbol: "xmark", help: "Cancel") { editing = false }
            }
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.trailing, 4)
        .contextMenu {
            Button("Copy value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        }
    }

    private func commitEdit() {
        let v = draft
        editing = false
        onEdit(v)
    }
}

// MARK: - Data tab

struct FWDataTab: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession

    var body: some View {
        if model.isDataLoading && model.dataItems.isEmpty {
            loadingView
        } else if model.dataItems.isEmpty {
            InspectEmptyState(
                symbol: "doc.text.magnifyingglass",
                title: "No framework data",
                message: "Data is extracted from globals like __NEXT_DATA__, __NUXT__, __remixContext, Apollo cache, Redux state, JSON-LD scripts, and more. Navigate to a page that uses one of these."
            )
        } else {
            FWAdaptiveSplit(session: session, key: "fw.data", sideFraction: 0.30, minFirst: 140, minSecond: 240) {
                dataList
            } second: {
                dataDetail
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Extracting data…").font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dataList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.dataItems) { item in
                    FWDataListRow(item: item, selected: model.selectedDataID == item.id)
                        .overlay(InspectHitTarget { model.selectData(id: item.id) })
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var dataDetail: some View {
        Group {
            if let item = model.selectedDataItem {
                FWDataDetailView(item: item, session: session)
            } else {
                InspectEmptyState(symbol: "doc.text", title: "Select an item", message: "")
            }
        }
    }
}

struct FWDataListRow: View {
    var item: FWDataItem
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForKind(item.kind))
                .font(.system(size: 11))
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(InspectChrome.label).lineLimit(1)
                Text(item.kind.rawValue).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
        .background(selected ? InspectChrome.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .padding(.horizontal, 4)
    }

    private func iconForKind(_ kind: FWDataKind) -> String {
        switch kind {
        case .json: return "curlybraces"
        case .flight: return "bolt.horizontal"
        case .globals: return "globe"
        case .scripts: return "doc.plaintext"
        }
    }
}

struct FWDataDetailView: View {
    var item: FWDataItem
    var session: OrbitInspectSession

    @State private var jsonFilter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(item.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if item.rawJSON != nil {
                    InspectTextButton("Copy JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.rawJSON!, forType: .string)
                    }
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .frame(height: 32)
            InspectDivider()
            switch item.kind {
            case .json:
                jsonView
            case .flight:
                flightView
            case .globals:
                globalsView
            case .scripts:
                jsonView
            }
        }
    }

    private var jsonView: some View {
        VStack(spacing: 0) {
            InspectSearchField(placeholder: "Filter", text: $jsonFilter)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
            InspectDivider()
            ScrollView {
                let text = item.rawJSON ?? "(no data)"
                let filtered = jsonFilter.isEmpty ? text : text.components(separatedBy: "\n")
                    .filter { $0.lowercased().contains(jsonFilter.lowercased()) }
                    .joined(separator: "\n")
                Text(filtered.isEmpty ? "(no matches)" : filtered)
                    .font(InspectChrome.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InspectChrome.panelPadding)
            }
        }
    }

    private var flightView: some View {
        VStack(spacing: 0) {
            if item.flightRows.isEmpty {
                InspectEmptyState(symbol: "bolt.horizontal", title: "No flight rows", message: "")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(item.flightRows) { row in
                            FWFlightRowView(row: row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var globalsView: some View {
        VStack(spacing: 0) {
            InspectSearchField(placeholder: "Filter globals", text: $jsonFilter)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
            InspectDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let entries = jsonFilter.isEmpty ? item.globals : item.globals.filter {
                        $0.name.lowercased().contains(jsonFilter.lowercased())
                    }
                    ForEach(entries) { g in
                        FWKeyValueRow(name: g.name, value: g.preview, editable: false, onEdit: { _ in })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct FWFlightRowView: View {
    var row: FWFlightRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.rowID)
                .font(InspectChrome.monoSmall)
                .foregroundStyle(InspectChrome.muted2)
                .frame(width: 30, alignment: .trailing)
            Text(typeLabel)
                .font(InspectChrome.monoSmall)
                .foregroundStyle(typeColor)
                .frame(width: 60, alignment: .leading)
            Text(displayContent)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.ink)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
    }

    private var typeLabel: String {
        switch row.rowType {
        case .moduleRef: return "module"
        case .htmlLinkHint: return "link-hint"
        case .htmlLink: return "link"
        case .text: return "text"
        case .error: return "error"
        case .json: return "json"
        case .routerState: return "router"
        case .unknown: return "?"
        }
    }

    private var typeColor: Color {
        switch row.rowType {
        case .moduleRef: return InspectChrome.attributeNameColor
        case .error: return InspectChrome.badColor
        case .routerState: return InspectChrome.goodColor
        default: return InspectChrome.muted
        }
    }

    private var displayContent: String {
        if let url = row.moduleURL { return url + (row.moduleExport.map { " [\($0)]" } ?? "") }
        if let preview = row.jsonPreview { return preview }
        return row.rawContent.count > 200 ? String(row.rawContent.prefix(200)) + "…" : row.rawContent
    }
}

// MARK: - Routes tab

struct FWRoutesTab: View {
    var model: OrbitFrameworksModel

    var body: some View {
        VStack(spacing: 0) {
            InspectSearchField(placeholder: "Filter routes", text: Binding(
                get: { model.routeFilter },
                set: { model.routeFilter = $0 }
            ))
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if model.isRoutesLoading && model.routes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Loading routes…").font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.routes.isEmpty {
                InspectEmptyState(
                    symbol: "arrow.triangle.branch",
                    title: "No routes found",
                    message: "Routes are extracted from Next.js build manifest, Remix route manifest, and Nuxt router. Page must be served from a framework that exposes its route list."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.filteredRoutes) { route in
                            FWRouteRow(route: route, model: model)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let message = model.routeNavigationMessage {
                InspectDivider()
                Text(message)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct FWRouteRow: View {
    var route: FWRoute
    var model: OrbitFrameworksModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Current indicator
            Circle()
                .fill(route.isCurrent ? InspectChrome.goodColor : Color.clear)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(InspectChrome.muted2, lineWidth: 1))

            Text(route.path)
                .font(InspectChrome.mono)
                .foregroundStyle(route.isDynamic ? InspectChrome.attributeNameColor : InspectChrome.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            if route.isCurrent {
                Text("current").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(InspectChrome.goodColor.opacity(0.15)))
            }

            Spacer(minLength: 0)
            Text(route.source).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                .lineLimit(1).layoutPriority(-1)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
        .background(isHovered ? InspectChrome.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
        .overlay(InspectHitTarget { model.openRoute(path: route.path) })
        .contextMenu {
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(route.path, forType: .string)
            }
        }
    }
}

// MARK: - Adaptive split

/// Two panes side by side, or stacked when the inspector is docked to a side or narrow (the technique the Elements pane uses).
struct FWAdaptiveSplit<First: View, Second: View>: View {
    var session: OrbitInspectSession
    var key: String
    var sideFraction: CGFloat
    var stackedFraction: CGFloat = 0.5
    var minFirst: CGFloat
    var minSecond: CGFloat
    var stackBelowWidth: CGFloat = 560
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    var body: some View {
        GeometryReader { geo in
            let docked = session.dock == .left || session.dock == .right
            let stacked = docked || geo.size.width < stackBelowWidth
            InspectSplit(
                key: stacked ? key + ".stacked" : key,
                defaultFraction: stacked ? stackedFraction : sideFraction,
                minFirst: stacked ? 110 : minFirst, minSecond: stacked ? 130 : minSecond,
                stackBelow: stacked ? .infinity : 0
            ) {
                first()
            } second: {
                second()
            }
            // The split keeps its dragged fraction in state, which must not carry over to the other orientation.
            .id(stacked)
        }
    }
}

// MARK: - Dev server tab

struct FWDevServerTab: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession

    @State private var showAllEvents = false
    @State private var showDetails = false

    var body: some View {
        let resolution = model.devResolution
        let probe = model.effectiveProbe
        let header = FWDevLogic.header(resolution: resolution, state: model.devState, probe: probe)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FWDevHeaderCard(header: header, resolution: resolution, state: model.devState)
                if let text = FWDevLogic.modeExplanation(resolution) {
                    FWDevNote(text: text)
                }
                ForEach(resolution.conflicts, id: \.self) { conflict in
                    FWDevNote(text: conflict, tone: 2)
                }
                issuesSection(resolution: resolution)
                controlsSection(probe: probe)
                infoSection
                timelineSection
                environmentSection
                detailsSection(resolution: resolution)
            }
            .padding(InspectChrome.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Errors

    /// The overlay the framework drew is the fallback for servers whose wire messages were never observed.
    private var displayedIssues: [FWDevIssue] {
        var issues = model.devState.allIssues
        if issues.isEmpty, let overlay = model.overlayInfo {
            issues = [FWDevIssue(severity: .error, origin: .build, message: overlay.message, file: overlay.file,
                                 line: overlay.line, column: overlay.col, frame: overlay.stackText, source: overlay.source)]
        }
        return issues
    }

    @ViewBuilder
    private func issuesSection(resolution: FWDevResolution) -> some View {
        let issues = displayedIssues
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                InspectSectionHeader(issues.isEmpty ? "Errors" : "Errors and warnings",
                                     detail: issues.isEmpty ? nil : "\(issues.count)")
                if !model.devState.runtimeIssues.isEmpty {
                    InspectTextButton("Clear runtime") { model.clearRuntimeIssues() }
                }
            }
            if issues.isEmpty {
                Text(resolution.mode == .development
                     ? "No build or runtime errors reported by the dev server or the page."
                     : "Build errors appear here while a dev server is connected. Runtime errors are collected from the page.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(issues) { issue in
                    FWDevIssueRow(issue: issue, model: model)
                }
            }
            if model.launchAttemptActive {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking the dev server to open the file").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
            } else if let error = model.launchError {
                Text(error).font(InspectChrome.caption).foregroundStyle(InspectChrome.badColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Controls

    private func controlsSection(probe: FWDevProbe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Controls")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(model.devControls) { state in
                    FWDevControlCell(state: state, overlayHidden: probe.overlayHidden,
                                     busy: model.devBusyAction != nil) { model.runControl(state.control) }
                }
            }
            if model.devBusyAction != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
            }
            if let message = model.devActionMessage {
                Text(message)
                    .font(InspectChrome.caption)
                    .foregroundStyle(model.devActionSucceeded ? InspectChrome.muted : InspectChrome.badColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Render and route information

    @ViewBuilder
    private var infoSection: some View {
        let rows = model.devRenderInfo
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                InspectSectionHeader("This page")
                ForEach(rows) { row in FWDevKV(name: row.label, value: row.value) }
            }
        }
    }

    // MARK: Timeline

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @ViewBuilder
    private var timelineSection: some View {
        let events = Array(model.devState.events.reversed())
        let shown = showAllEvents ? events : Array(events.prefix(20))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                InspectSectionHeader("Timeline", detail: events.isEmpty ? nil : "\(events.count)")
                if !events.isEmpty {
                    InspectTextButton("Clear") { model.clearDevTimeline() }
                }
            }
            if events.isEmpty {
                Text("HMR messages, route changes and page errors appear here as they happen.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(shown) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: event.at / 1000)))
                            .font(InspectChrome.monoSmall)
                            .foregroundStyle(InspectChrome.muted2)
                        Circle().fill(Self.color(forTone: event.kind.tone)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title).font(InspectChrome.caption).foregroundStyle(InspectChrome.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if events.count > 20 {
                    InspectTextButton(showAllEvents ? "Show fewer" : "Show all \(events.count)") { showAllEvents.toggle() }
                }
            }
        }
    }

    static func color(forTone tone: Int) -> Color {
        switch tone {
        case 1: return InspectChrome.goodColor
        case 2: return InspectChrome.warnColor
        case 3: return InspectChrome.badColor
        default: return InspectChrome.muted2
        }
    }

    // MARK: Environment

    @ViewBuilder
    private var environmentSection: some View {
        let entries = model.devEnvironment
        if !entries.isEmpty || model.canLoadViteEnv {
            VStack(alignment: .leading, spacing: 4) {
                InspectSectionHeader("Public environment", detail: entries.isEmpty ? nil : "\(entries.count)")
                ForEach(entries) { entry in
                    FWDevKV(name: entry.key, value: entry.value, mono: true)
                }
                if model.canLoadViteEnv && !model.devEnvironment.contains(where: { $0.source == "import.meta.env" }) {
                    HStack(spacing: 6) {
                        InspectTextButton(model.devEnvLoading ? "Reading" : "Read import.meta.env", enabled: !model.devEnvLoading) {
                            model.loadViteEnv()
                        }
                    }
                }
                if let message = model.devEnvMessage {
                    Text(message).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.devResolution.adapter?.id == "next" {
                    Text("Next.js inlines NEXT_PUBLIC_* values into the bundle at build time, so they cannot be listed from the page.")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Details

    private func detailsSection(resolution: FWDevResolution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectTextButton(showDetails ? "Hide connection details" : "Connection details") { showDetails.toggle() }
            if showDetails {
                let sockets = model.devState.sockets.filter { $0.protocolID != nil }
                if sockets.isEmpty {
                    Text("No HMR socket was opened by this page. Sockets opened before Orbit attached are not seen; reload the page to capture them.")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(sockets) { socket in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(socket.url).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("\(socket.protocolID?.title ?? "") · \(socket.transport) · \(Self.stateName(socket.state)) · \(socket.frames) messages")
                            .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    }
                }
                if !resolution.reasons.isEmpty {
                    InspectSectionHeader("Why")
                    ForEach(resolution.reasons, id: \.self) { reason in
                        Text(reason).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func stateName(_ state: FWDevSocketInfo.State) -> String {
        switch state {
        case .connecting: return "connecting"
        case .open: return "open"
        case .closed: return "closed"
        case .failed: return "error"
        }
    }
}

// MARK: - Dev server pieces

struct FWDevPill: View {
    var text: String
    var tone: Int
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(FWDevServerTab.color(forTone: tone)).frame(width: 7, height: 7) }
            Text(text).font(InspectChrome.caption).foregroundStyle(InspectChrome.ink).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(InspectChrome.hover))
        .accessibilityElement(children: .combine)
    }
}

struct FWDevNote: View {
    var text: String
    var tone = 0

    var body: some View {
        Text(text)
            .font(InspectChrome.caption)
            .foregroundStyle(tone == 2 ? InspectChrome.warnColor : InspectChrome.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label over or beside its value, wrapping instead of truncating so a narrow dock stays readable.
struct FWDevKV: View {
    var name: String
    var value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(mono ? InspectChrome.monoSmall : InspectChrome.caption)
                .foregroundStyle(InspectChrome.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct FWDevHeaderCard: View {
    var header: FWDevLogic.Header
    var resolution: FWDevResolution
    var state: FWDevState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(header.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(InspectChrome.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = header.subtitle {
                    Text(subtitle).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: 6) {
                FWDevPill(text: header.modeLabel, tone: resolution.mode == .development ? 1 : 0)
                if let bundler = header.bundlerLabel { FWDevPill(text: bundler, tone: 0) }
                FWDevPill(text: "HMR: " + header.connectionLabel, tone: header.connectionTone, dot: true)
                if resolution.mode == .development { FWDevPill(text: "Build: " + header.buildLabel, tone: header.buildTone, dot: true) }
            }
            if resolution.mode == .development {
                // The age text changes with time, not with state, so it refreshes on its own clock.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(lastUpdateText(now: context.date.timeIntervalSince1970 * 1000))
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous).fill(InspectChrome.surface))
        .overlay(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous).strokeBorder(InspectChrome.hairline, lineWidth: 0.5))
    }

    private func lastUpdateText(now: Double) -> String {
        guard let last = state.lastUpdateAt else { return "No update since this page loaded" }
        let count = state.updateCount
        return "Last update \(FWDevLogic.relativeAge(from: last, to: now)) · \(count) \(count == 1 ? "update" : "updates")"
    }
}

struct FWDevControlCell: View {
    var state: FWDevLogic.ControlState
    var overlayHidden: Bool
    var busy: Bool
    var action: () -> Void

    private var title: String {
        state.control == .toggleOverlay ? (overlayHidden ? "Show overlay" : "Hide overlay") : state.control.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            InspectTextButton(title, systemImage: state.control.symbol, enabled: state.enabled && !busy, action: action)
            Text(state.note)
                .font(InspectChrome.caption)
                .foregroundStyle(state.enabled ? InspectChrome.muted2 : InspectChrome.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FWDevIssueRow: View {
    var issue: FWDevIssue
    var model: OrbitFrameworksModel

    @State private var expanded = false

    private var color: Color { issue.severity == .error ? InspectChrome.badColor : InspectChrome.warnColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(issue.source + (issue.origin == .runtime ? " · runtime" : ""))
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                Spacer(minLength: 0)
            }
            Text(issue.message)
                .font(InspectChrome.mono)
                .foregroundStyle(color)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let location = issue.locationText {
                Text(location)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(InspectChrome.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if expanded, let frame = issue.frame, !frame.isEmpty {
                Text(frame)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(InspectChrome.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6) {
                if issue.file != nil {
                    InspectTextButton("Editor") { model.openIssueInEditor(issue) }
                    InspectTextButton("Sources") { model.revealIssueInSources(issue) }
                }
                if issue.frame != nil || issue.message.count > 240 {
                    InspectTextButton(expanded ? "Less" : "More") { expanded.toggle() }
                }
                InspectTextButton("Copy") {
                    model.session?.copy([issue.message, issue.locationText, issue.frame].compactMap { $0 }.joined(separator: "\n"))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous).fill(InspectChrome.surface))
    }
}
