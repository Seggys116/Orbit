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

    var body: some View {
        if model.detections.isEmpty {
            InspectEmptyState(
                symbol: "shippingbox",
                title: "No technologies detected",
                message: "Press Refresh to scan the current page. Detection reads JavaScript globals, DOM attributes, script URLs, response headers, and meta tags."
            )
        } else {
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
                InspectSplit(key: "fw.components", defaultFraction: 0.45, minFirst: 180, minSecond: 200, stackBelow: 0) {
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
            InspectSplit(key: "fw.data", defaultFraction: 0.30, minFirst: 140, minSecond: 240) {
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

            if route.isCurrent {
                Text("current").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(InspectChrome.goodColor.opacity(0.15)))
            }

            Text(route.source).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            Spacer(minLength: 0)
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

// MARK: - Dev server tab

struct FWDevServerTab: View {
    var model: OrbitFrameworksModel
    var session: OrbitInspectSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hmrSection
                if let overlay = model.overlayInfo {
                    InspectDivider().padding(.vertical, 8)
                    overlaySection(overlay: overlay)
                }
                Spacer(minLength: 20)
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    private var hmrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Hot Module Replacement")
            if let kind = model.hmrStatus.kind {
                FWKeyValueRow(name: "dev server", value: kind, editable: false, onEdit: { _ in })
                if let url = model.hmrStatus.wsURL {
                    FWKeyValueRow(name: "WebSocket", value: url, editable: false, onEdit: { _ in })
                }
                FWKeyValueRow(name: "connected", value: model.hmrStatus.connected ? "yes" : "unknown",
                              editable: false, onEdit: { _ in })
            } else {
                Text("No HMR connection detected. Dev servers are identified from WebSocket URLs in the network log (/_next/webpack-hmr, /_next/turbopack-hmr, vite-hmr, /__webpack_hmr, /hmr).")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func overlaySection(overlay: FWOverlayInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                InspectSectionHeader("Error Overlay")
                Circle().fill(InspectChrome.badColor).frame(width: 8, height: 8)
            }
            Text(overlay.message)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.badColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let file = overlay.file {
                HStack(spacing: 6) {
                    Text(file + (overlay.line.map { ":\($0)" } ?? ""))
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.muted)
                        .textSelection(.enabled)
                    InspectTextButton("Sources") {
                        session.reveal(sourceURL: file, line: overlay.line, column: overlay.col)
                    }
                    InspectTextButton("Editor") {
                        OrbitInspectEditorLauncher.open(sourceURL: file, line: overlay.line, column: overlay.col, session: session)
                    }
                }
            }
        }
    }
}

