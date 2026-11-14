// Lives as long as the OrbitInspectSession, so it keeps collecting even when the panel is hidden.

import AppKit


struct ElDeclaration: Identifiable, Equatable {
    var id: String           // "\(ruleID)_\(index)" – stable within a rule
    var property: String
    var value: String
    var priority: String     // "" | "important"
    var disabled: Bool
    var overridden: Bool
    var computedValue: String?  // resolved var() / shorthand expansion
    var longhands: [ElDeclaration] = []
    var isShorthand: Bool { !longhands.isEmpty }
    var isImportant: Bool { priority == "important" }
}

struct ElStyleRule: Identifiable, Equatable {
    var id: String
    var ruleType: String
    var selector: String
    var specificity: [Int]
    var sheetIdx: Int
    var ruleIdx: Int
    var rulePath: [Int]
    var sheetHref: String?
    var sourceLine: Int?
    var mediaQuery: String?
    var supportsQuery: String?
    var groupingRules: [String] = []
    var isInactive: Bool = false
    var declarations: [ElDeclaration]
    var pseudoElement: String?
    var ancestorLabel: String?   // "Inherited from div.foo"
    var isCrossOrigin: Bool { ruleType == "crossorigin" }
    var conditionLines: [String] {
        if !groupingRules.isEmpty { return groupingRules }
        return mediaQuery.map { ["@media \($0)"] } ?? []
    }
    var isHeader: Bool { ruleType == "inherited-header" }
}

struct ElComputedProperty: Identifiable, Equatable {
    var id: String { property }
    var property: String
    var value: String
    var winningRuleID: String?
    var winningSelector: String?
    var isInherited: Bool
}

struct ElBoxModel: Equatable {
    var width:  Double = 0; var height: Double = 0
    var marginTop:  String = "0"; var marginRight:  String = "0"
    var marginBottom: String = "0"; var marginLeft: String = "0"
    var borderTop:  String = "0"; var borderRight:  String = "0"
    var borderBottom: String = "0"; var borderLeft: String = "0"
    var paddingTop: String = "0"; var paddingRight: String = "0"
    var paddingBottom: String = "0"; var paddingLeft: String = "0"
    var position: String = "static"
    var top: String = "auto"; var right: String = "auto"
    var bottom: String = "auto"; var left: String = "auto"
    var display: String = "block"
    var isFlex: Bool = false; var isGrid: Bool = false
}

struct ElEventListener: Identifiable, Equatable {
    var id: String
    var nodeID: Int; var isAncestor: Bool; var isWindow: Bool
    var eventType: String
    var capture: Bool; var passive: Bool; var once: Bool
    var handlerSource: String
    var sourceURL: String?; var sourceLine: Int?
    /// Added while the inspector was closed, when no stack (and so no source location) is captured.
    var addedBeforeInspector: Bool = false
}

struct ElA11y: Equatable {
    var role: String = ""
    var name: String = ""; var nameFrom: String = ""
    var ariaAttrs: [String: String] = [:]
    var focusable: Bool = false
    var contrastRatio: Double? = nil
    var wcagAA:      Bool? { contrastRatio.map { $0 >= 4.5 } }
    var wcagAALarge: Bool? { contrastRatio.map { $0 >= 3.0 } }
}

struct ElDropIndicator: Equatable {
    enum Style: Equatable { case lineAbove, lineBelow, outline }
    var rowNodeID: Int
    var isClosingTag: Bool
    var style: Style
    var indentLevel: Int
    var placement: ElDropPlacement
}

/// `tick` changes on every update so repeated hovers over the same row still scroll, which lets a held drag keep moving the viewport.
struct ElAutoScroll: Equatable {
    var above: ElFlatRow.RowID
    var below: ElFlatRow.RowID
    var tick: Int
}

enum ElDetailTab: String, CaseIterable, Identifiable {
    case styles, computed, layout, listeners, accessibility
    var id: String { rawValue }
    var title: String {
        switch self {
        case .styles:        return "Styles"
        case .computed:      return "Computed"
        case .layout:        return "Layout"
        case .listeners:     return "Listeners"
        case .accessibility: return "Accessibility"
        }
    }
}


@MainActor
@Observable
final class OrbitElementsModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> {
        ["el.dom", "el.children", "el.select", "el.style", "el.computed",
         "el.listeners", "el.a11y", "el.mutation", "el.attrDone", "el.outerHTML",
         "el.boxModel", "el.navigate", "el.snapshotDone",
         "el.edited", "el.editFailed", "el.editDone", "el.text",
         "el.layoutKinds", "el.layoutOverlays"]
    }


    var nodes: [Int: ElNodeInfo]      = [:]
    var childrenMap: [Int: [Int]]     = [:]
    var expanded: Set<Int>            = []
    var selectedID: Int?              = nil
    var selectionPath: [Int]          = []
    var visibleRows: [ElFlatRow]      = []
    var rootIDs: [Int]                = []
    var flashedNodes: Set<Int>        = []
    var isLoading: Bool               = false
    var childrenLoading: Set<Int>     = []  // IDs currently waiting for el.children
    var showMoreOffsets: [Int: Int]   = [:] // nodeID -> next offset to load


    var searchText: String = "" { didSet { updateSearch() } }
    var searchMode: ElSearchMode = .text { didSet { updateSearch() } }
    var searchMatches: [Int] = []
    var searchIndex: Int = 0


    var detailTab: ElDetailTab = .styles { didSet { tabChanged() } }
    var styleRules: [ElStyleRule] = []
    var showInactiveRules = false
    var inactiveRuleCount: Int { styleRules.filter(\.isInactive).count }
    var displayedStyleRules: [ElStyleRule] { showInactiveRules ? styleRules : styleRules.filter { !$0.isInactive } }
    var cssVarList: [String] = []
    var computedProperties: [ElComputedProperty] = []
    var filterComputedText: String = ""
    var showAllComputed: Bool = false
    var boxModel: ElBoxModel? = nil
    var eventListeners: [ElEventListener] = []
    var includeAncestorListeners: Bool = true { didSet { refreshListeners() } }
    var a11y: ElA11y? = nil


    var forcedStates: [Int: Set<String>] = [:]   // nodeID -> set of state names


    var outerHTMLNodeID: Int? = nil
    var outerHTMLText: String = ""
    var outerHTMLOriginal: String = ""
    var outerHTMLLoaded: Bool = false
    var outerHTMLError: String? = nil


    enum InlineEdit: Equatable {
        case tagName(Int)
        case text(Int)
    }

    var inlineEdit: InlineEdit? = nil
    var inlineEditText: String = ""
    @ObservationIgnored private var inlineEditOriginal: String = ""


    @ObservationIgnored var treeIsFocused = false
    private(set) var history = ElEditHistory()
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }


    private(set) var layoutKinds: [Int: ElLayoutKind] = [:]
    private(set) var layoutOverlays: [Int: ElLayoutKind] = [:]


    var draggingNodeID: Int? = nil
    private(set) var dropIndicator: ElDropIndicator? = nil
    private(set) var autoScroll: ElAutoScroll? = nil
    @ObservationIgnored private var autoScrollTick = 0
    @ObservationIgnored private var parentByNode: [Int: Int] = [:]
    @ObservationIgnored private var rowsDirty = false
    @ObservationIgnored private var rowsFlushScheduled = false
    private static let flushDelay: Duration = .milliseconds(16)


    func pageDidReset(preservingLog: Bool) {
        clearTree()
    }

    func panelDidAppear(force: Bool) {
        if force || rootIDs.isEmpty {
            clearTree()
            isLoading = true
            session?.command(["op": "el.snapshot"])
        } else if let id = selectedID {
            requestDetail(nodeID: id)
        }
    }

    func select(nodeID: Int) {
        session?.command(["op": "el.select", "id": nodeID])
    }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        // Each iframe's agent numbers nodes itself, so its mutation, navigation or layout messages name nodes that are not the main frame's.
        guard frame.isMain else { return }
        switch type {
        case "el.dom":          receiveDOM(object)
        case "el.children":     receiveChildren(object)
        case "el.select":       receiveSelect(object)
        case "el.style":        receiveStyle(object)
        case "el.computed":     receiveComputed(object)
        case "el.boxModel":     receiveBoxModel(object)
        case "el.listeners":    receiveListeners(object)
        case "el.a11y":         receiveA11y(object)
        case "el.mutation":     receiveMutation(object)
        case "el.attrDone":     receiveAttrDone(object)
        case "el.outerHTML":    receiveOuterHTML(object)
        case "el.navigate":     clearTree(); isLoading = true; session?.command(["op": "el.snapshot"])
        case "el.snapshotDone": isLoading = false
        case "el.edited":       receiveEdited(object)
        case "el.editFailed":   receiveEditFailed(object)
        case "el.editDone":     receiveEditDone(object)
        case "el.text":         receiveText(object)
        case "el.layoutKinds":  receiveLayoutKinds(object)
        case "el.layoutOverlays": receiveLayoutOverlays(object)
        default: break
        }
    }


    func undo() {
        guard let record = history.undo() else { return }
        session?.command(OrbitElementsLogic.undoCommand(entry: record.entry))
    }

    func redo() {
        guard let record = history.redo() else { return }
        session?.command(OrbitElementsLogic.redoCommand(entry: record.entry))
    }

    private func receiveEdited(_ object: [String: Any]) {
        let record = ElEditRecord(entry: OrbitInspectDecode.integer(object, "entry"),
                                  label: OrbitInspectDecode.string(object, "label"))
        let forgotten = history.push(record)
        if !forgotten.isEmpty { session?.command(OrbitElementsLogic.discardCommand(entries: forgotten)) }
    }

    private func receiveEditFailed(_ object: [String: Any]) {
        history.discard(entry: OrbitInspectDecode.integer(object, "entry"))
        let verb = OrbitInspectDecode.string(object, "direction") == "redo" ? "redo" : "undo"
        session?.notice = "Couldn't \(verb) that edit. The element it changed is no longer on the page."
    }


    func noteLayoutKind(_ kind: ElLayoutKind, for nodeID: Int) {
        layoutKinds[nodeID] = kind
    }

    func toggleLayoutOverlay(nodeID: Int) {
        guard let kind = layoutKinds[nodeID] ?? layoutOverlays[nodeID] else { return }
        let turnOn = layoutOverlays[nodeID] == nil
        layoutOverlays[nodeID] = turnOn ? kind : nil
        session?.command(OrbitElementsLogic.layoutOverlayCommand(id: nodeID, kind: kind, on: turnOn))
    }

    private func receiveLayoutKinds(_ object: [String: Any]) {
        let raw = OrbitInspectDecode.stringMap(object, "kinds")
        var updated = layoutKinds
        for (key, value) in raw {
            guard let id = Int(key) else { continue }
            if let kind = ElLayoutKind(rawValue: value) { updated[id] = kind } else { updated.removeValue(forKey: id) }
        }
        if updated != layoutKinds { layoutKinds = updated }
    }

    private func receiveLayoutOverlays(_ object: [String: Any]) {
        var overlays: [Int: ElLayoutKind] = [:]
        for (key, value) in OrbitInspectDecode.stringMap(object, "overlays") {
            if let id = Int(key), let kind = ElLayoutKind(rawValue: value) { overlays[id] = kind }
        }
        if overlays != layoutOverlays { layoutOverlays = overlays }
    }


    func beginTagRename(nodeID: Int) {
        guard let node = nodes[nodeID], node.kind == "el", parentByNode[nodeID] != nil,
              node.name != "body", node.name != "head" else { return }
        inlineEditOriginal = node.name
        inlineEditText = node.name
        inlineEdit = .tagName(nodeID)
    }

    func beginTextEdit(nodeID: Int) {
        guard let node = nodes[nodeID], node.kind == "text" || node.kind == "comment" else { return }
        inlineEditOriginal = node.text
        inlineEditText = node.text
        inlineEdit = .text(nodeID)
        session?.command(["op": "el.getText", "id": nodeID])
    }

    func commitInlineEdit() {
        guard let edit = inlineEdit else { return }
        inlineEdit = nil
        switch edit {
        case .tagName(let id):
            if let command = OrbitElementsLogic.renameCommand(id: id, from: inlineEditOriginal, to: inlineEditText) {
                session?.command(command)
            }
        case .text(let id):
            if let command = OrbitElementsLogic.editTextCommand(id: id, original: inlineEditOriginal, edited: inlineEditText) {
                session?.command(command)
            }
        }
    }

    func cancelInlineEdit() {
        inlineEdit = nil
    }

    private func receiveText(_ object: [String: Any]) {
        guard case .text(let id) = inlineEdit, id == OrbitInspectDecode.integer(object, "id") else { return }
        let full = OrbitInspectDecode.string(object, "text")
        if inlineEditText == inlineEditOriginal { inlineEditText = full }
        inlineEditOriginal = full
    }


    func beginDrag(nodeID: Int) {
        guard OrbitElementsLogic.canDrag(nodeID: nodeID, nodes: nodes, parents: parentByNode) else { return }
        draggingNodeID = nodeID
    }

    func endDrag() {
        draggingNodeID = nil
        dropIndicator = nil
        autoScroll = nil
    }

    /// Scrolling an already visible row does nothing, so asking for the rows either side of the hovered one only moves the tree near an edge.
    private func requestAutoScroll(around row: ElFlatRow) {
        guard let index = visibleRows.firstIndex(where: { $0.id == row.id }) else { return }
        let above = visibleRows[max(0, index - 2)].id
        let below = visibleRows[min(visibleRows.count - 1, index + 2)].id
        autoScrollTick += 1
        autoScroll = ElAutoScroll(above: above, below: below, tick: autoScrollTick)
    }

    func updateDrop(row: ElFlatRow, fraction: Double) {
        guard let moving = draggingNodeID else { return }
        requestAutoScroll(around: row)
        let canContain = row.node.kind == "el" && !row.isClosingTag
        let position = ElDropPosition.zone(fraction: fraction, canContainChildren: canContain)
        guard let placement = OrbitElementsLogic.dropPlacement(
            moving: moving, target: row.nodeID, isClosingTag: row.isClosingTag, position: position,
            nodes: nodes, children: childrenMap, parents: parentByNode,
            truncatedParents: Set(showMoreOffsets.keys)
        ) else {
            if dropIndicator != nil { dropIndicator = nil }
            return
        }
        let style: ElDropIndicator.Style
        switch position {
        case .inside: style = .outline
        case .before: style = .lineAbove
        case .after: style = .lineBelow
        }
        let indicator = ElDropIndicator(
            rowNodeID: row.nodeID, isClosingTag: row.isClosingTag, style: style,
            indentLevel: depth(of: placement.parentID) + 1, placement: placement
        )
        if indicator != dropIndicator { dropIndicator = indicator }
    }

    func clearDrop(row: ElFlatRow) {
        if let indicator = dropIndicator, indicator.rowNodeID == row.nodeID, indicator.isClosingTag == row.isClosingTag {
            dropIndicator = nil
        }
    }

    @discardableResult
    func commitDrop() -> Bool {
        defer { endDrag() }
        guard let moving = draggingNodeID, let indicator = dropIndicator else { return false }
        session?.command(OrbitElementsLogic.moveCommand(id: moving, placement: indicator.placement))
        expanded.insert(indicator.placement.parentID)
        if childrenMap[indicator.placement.parentID] == nil, let parent = nodes[indicator.placement.parentID], parent.childCount > 0 {
            loadChildren(nodeID: indicator.placement.parentID, offset: 0)
        }
        return true
    }

    var parentLookup: [Int: Int] { parentByNode }

    private func depth(of nodeID: Int) -> Int {
        var depth = 0
        var current = nodeID
        while let parent = parentByNode[current], depth < 512 {
            depth += 1
            current = parent
        }
        return depth
    }


    func toggleExpand(nodeID: Int) {
        if expanded.contains(nodeID) {
            expanded.remove(nodeID)
        } else {
            expanded.insert(nodeID)
            if childrenMap[nodeID] == nil && !childrenLoading.contains(nodeID) {
                loadChildren(nodeID: nodeID, offset: 0)
            }
        }
        rebuildVisibleRows()
    }

    func loadChildren(nodeID: Int, offset: Int) {
        childrenLoading.insert(nodeID)
        session?.command(["op": "el.expand", "id": nodeID, "offset": offset])
    }

    func loadMoreChildren(nodeID: Int) {
        let current = childrenMap[nodeID]?.count ?? 0
        loadChildren(nodeID: nodeID, offset: current)
    }

    func selectRow(nodeID: Int) {
        selectedID = nodeID
        if let path = pathIDs(to: nodeID) { selectionPath = path }
        styleRules = []
        computedProperties = []
        boxModel = nil
        eventListeners = []
        a11y = nil
        session?.command(["op": "el.markSelected", "id": nodeID])
        requestDetail(nodeID: nodeID)
        if detailTab != .styles { session?.command(["op": "el.style", "id": nodeID]) }
    }

    func moveSelection(by delta: Int) {
        guard let current = selectedID else {
            if let first = visibleRows.first { selectRow(nodeID: first.nodeID) }
            return
        }
        if let idx = visibleRows.firstIndex(where: { $0.nodeID == current && !$0.isClosingTag }) {
            let next = (idx + delta).clamped(0, visibleRows.count - 1)
            let row = visibleRows[next]
            if !row.isClosingTag { selectRow(nodeID: row.nodeID) }
        }
    }

    func collapseOrMoveToParent(nodeID: Int) {
        if expanded.contains(nodeID) {
            expanded.remove(nodeID)
            rebuildVisibleRows()
        } else {
            if let idx = selectionPath.firstIndex(of: nodeID), idx > 0 {
                let parentID = selectionPath[idx - 1]
                selectRow(nodeID: parentID)
            }
        }
    }

    func expandOrMoveToFirstChild(nodeID: Int) {
        guard let node = nodes[nodeID], node.kind == "el" else { return }
        if !expanded.contains(nodeID) {
            toggleExpand(nodeID: nodeID)
        } else if let kids = childrenMap[nodeID], let first = kids.first {
            selectRow(nodeID: first)
        }
    }


    func setAttribute(nodeID: Int, name: String, value: String) {
        session?.command(["op": "el.attr", "id": nodeID, "name": name, "value": value])
    }

    func removeAttribute(nodeID: Int, name: String) {
        session?.command(["op": "el.attr", "id": nodeID, "name": name, "remove": true])
    }


    func setInlineProperty(property: String, value: String, priority: String = "") {
        guard let id = selectedID else { return }
        session?.command(["op": "el.setProp", "id": id, "property": property, "value": value, "priority": priority])
    }

    func removeInlineProperty(property: String) {
        guard let id = selectedID else { return }
        session?.command(["op": "el.setProp", "id": id, "property": property, "remove": true])
    }

    func setRuleProperty(sheetIdx: Int, ruleIdx: Int, rulePath: [Int] = [], property: String, value: String, priority: String = "") {
        session?.command(ruleCommand("el.setRuleProp", sheetIdx: sheetIdx, ruleIdx: ruleIdx, rulePath: rulePath, extra: [
            "property": property, "value": value, "priority": priority,
        ]))
    }

    func removeRuleProperty(sheetIdx: Int, ruleIdx: Int, rulePath: [Int] = [], property: String) {
        session?.command(ruleCommand("el.setRuleProp", sheetIdx: sheetIdx, ruleIdx: ruleIdx, rulePath: rulePath, extra: [
            "property": property, "remove": true,
        ]))
    }

    func setDeclarationEnabled(_ enabled: Bool, property: String, in rule: ElStyleRule) {
        if rule.ruleType == "inline" {
            guard let id = selectedID else { return }
            session?.command(["op": "el.toggleDecl", "id": id, "property": property, "enabled": enabled])
        } else if rule.sheetIdx >= 0 {
            session?.command(ruleCommand("el.toggleDecl", sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                         extra: ["property": property, "enabled": enabled]))
        }
    }

    func renameDeclaration(from: String, to: String, in rule: ElStyleRule) {
        let name = to.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != from else { return }
        if rule.ruleType == "inline" {
            guard let id = selectedID else { return }
            session?.command(["op": "el.renameDecl", "id": id, "from": from, "to": name])
        } else if rule.sheetIdx >= 0 {
            session?.command(ruleCommand("el.renameDecl", sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                         extra: ["from": from, "to": name]))
        }
    }

    func setRuleSelector(sheetIdx: Int, ruleIdx: Int, rulePath: [Int] = [], selector: String) {
        session?.command(ruleCommand("el.setRuleSelector", sheetIdx: sheetIdx, ruleIdx: ruleIdx, rulePath: rulePath, extra: [
            "selector": selector,
        ]))
    }

    func deleteRule(sheetIdx: Int, ruleIdx: Int, rulePath: [Int] = []) {
        session?.command(ruleCommand("el.deleteRule", sheetIdx: sheetIdx, ruleIdx: ruleIdx, rulePath: rulePath, extra: [:]))
    }

    private func ruleCommand(_ op: String, sheetIdx: Int, ruleIdx: Int, rulePath: [Int], extra: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = ["op": op, "sheetIdx": sheetIdx, "ruleIdx": ruleIdx]
        if !rulePath.isEmpty { payload["rulePath"] = rulePath }
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    func addRule(selector: String) {
        session?.command(["op": "el.addRule", "selector": selector])
    }


    func setForcedStates(nodeID: Int, states: Set<String>) {
        forcedStates[nodeID] = states
        let arr = Array(states)
        session?.command(["op": "el.forceState", "id": nodeID, "states": arr])
    }


    func scrollIntoView(nodeID: Int) {
        session?.command(["op": "el.scrollIntoView", "id": nodeID])
    }

    func focusNode(nodeID: Int) {
        session?.command(["op": "el.focus", "id": nodeID])
    }

    func hideNode(nodeID: Int) {
        session?.command(["op": "el.hide", "id": nodeID])
    }

    func duplicateNode(nodeID: Int) {
        session?.command(["op": "el.duplicate", "id": nodeID])
    }

    func deleteNode(nodeID: Int) {
        session?.command(["op": "el.remove", "id": nodeID])
    }

    func requestOuterHTML(nodeID: Int) {
        outerHTMLNodeID = nodeID
        outerHTMLText = ""
        outerHTMLOriginal = ""
        outerHTMLLoaded = false
        outerHTMLError = nil
        session?.command(["op": "el.outerHTML", "id": nodeID])
    }

    func commitOuterHTML() {
        guard let id = outerHTMLNodeID, outerHTMLLoaded else { return }
        if let command = OrbitElementsLogic.editHTMLCommand(id: id, original: outerHTMLOriginal, edited: outerHTMLText) {
            session?.command(command)
            // Keep the editor open until the page confirms, so a parse failure does not lose the user's text.
            outerHTMLLoaded = false
        } else {
            outerHTMLNodeID = nil
        }
    }

    func cancelOuterHTML() {
        outerHTMLNodeID = nil
        outerHTMLError = nil
    }

    private func receiveEditDone(_ object: [String: Any]) {
        guard outerHTMLNodeID == OrbitInspectDecode.integer(object, "id") else { return }
        if OrbitInspectDecode.bool(object, "ok") {
            outerHTMLNodeID = nil
            outerHTMLError = nil
        } else {
            outerHTMLError = OrbitInspectDecode.optionalString(object, "error") ?? "The page rejected that markup."
            outerHTMLLoaded = true
        }
    }

    func copyOuterHTML(nodeID: Int) {
        session?.command(["op": "el.outerHTML", "id": nodeID])
    }

    func copySelector() {
        let text = OrbitElementsLogic.cssSelector(for: selectionPath.compactMap { nodes[$0] })
        session?.copy(text)
    }

    func copyFullSelector() {
        let text = OrbitElementsLogic.fullSelector(for: selectionPath.compactMap { nodes[$0] })
        session?.copy(text)
    }

    func copyXPath() {
        let text = OrbitElementsLogic.xpath(for: selectionPath.compactMap { nodes[$0] })
        session?.copy(text)
    }

    func copyJSPath() {
        let text = OrbitElementsLogic.jsPath(for: selectionPath.compactMap { nodes[$0] })
        session?.copy(text)
    }

    func reveal(sourceURL: String, line: Int?) {
        session?.reveal(sourceURL: sourceURL, line: line)
    }


    var filteredComputedProperties: [ElComputedProperty] {
        if filterComputedText.isEmpty && showAllComputed { return computedProperties }
        return computedProperties.filter { prop in
            let matchesFilter = filterComputedText.isEmpty ||
                prop.property.localizedCaseInsensitiveContains(filterComputedText) ||
                prop.value.localizedCaseInsensitiveContains(filterComputedText)
            let matchesAll = showAllComputed || !prop.value.isEmpty
            return matchesFilter && matchesAll
        }
    }

    func searchNext() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchMatches.count
        revealSearchMatch()
    }

    func searchPrev() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + searchMatches.count - 1) % searchMatches.count
        revealSearchMatch()
    }

    private func revealSearchMatch() {
        guard searchIndex < searchMatches.count else { return }
        let id = searchMatches[searchIndex]
        ensureVisible(nodeID: id)
    }


    private func clearTree() {
        nodes.removeAll()
        childrenMap.removeAll()
        expanded.removeAll()
        rootIDs.removeAll()
        visibleRows.removeAll()
        selectedID = nil
        selectionPath = []
        flashedNodes.removeAll()
        childrenLoading.removeAll()
        showMoreOffsets.removeAll()
        styleRules.removeAll()
        computedProperties.removeAll()
        boxModel = nil
        eventListeners.removeAll()
        a11y = nil
        forcedStates.removeAll()
        cssVarList.removeAll()
        outerHTMLNodeID = nil
        inlineEdit = nil
        layoutKinds.removeAll()
        layoutOverlays.removeAll()
        draggingNodeID = nil
        dropIndicator = nil
        parentByNode.removeAll()
        // The tree the edits were made against is gone, so nothing is left to undo.
        let forgotten = history.clear()
        if !forgotten.isEmpty { session?.command(OrbitElementsLogic.discardCommand(entries: forgotten)) }
    }

    private func rebuildVisibleRows() {
        rowsDirty = false
        parentByNode = OrbitElementsLogic.parentMap(children: childrenMap)
        visibleRows = OrbitElementsLogic.flattenTree(
            rootIDs: rootIDs,
            nodes: nodes,
            children: childrenMap,
            expanded: expanded
        )
    }

    /// Bursts of messages rebuild once per frame, except the first rows, which must not flash the empty state.
    private func rowsChanged() {
        if visibleRows.isEmpty {
            rebuildVisibleRows()
            return
        }
        rowsDirty = true
        guard !rowsFlushScheduled else { return }
        rowsFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            self?.rowsFlushScheduled = false
            if self?.rowsDirty == true { self?.rebuildVisibleRows() }
        }
    }

    private func pathIDs(to nodeID: Int) -> [Int]? {
        var path = [nodeID]
        var current = nodeID
        while let parent = parentByNode[current], path.count < 512 {
            path.insert(parent, at: 0)
            current = parent
        }
        return rootIDs.contains(current) ? path : nil
    }

    private func requestDetail(nodeID: Int) {
        switch detailTab {
        case .styles:
            session?.command(["op": "el.style", "id": nodeID])
        case .computed:
            session?.command(["op": "el.computed", "id": nodeID])
        case .layout:
            session?.command(["op": "el.boxModel", "id": nodeID])
        case .listeners:
            session?.command(["op": "el.listeners", "id": nodeID,
                              "includeAncestors": includeAncestorListeners])
        case .accessibility:
            session?.command(["op": "el.a11y", "id": nodeID])
        }
    }

    private func tabChanged() {
        guard let id = selectedID else { return }
        requestDetail(nodeID: id)
    }

    private func refreshListeners() {
        guard let id = selectedID else { return }
        session?.command(["op": "el.listeners", "id": id, "includeAncestors": includeAncestorListeners])
    }

    private func updateSearch() {
        guard !searchText.isEmpty else { searchMatches = []; searchIndex = 0; return }
        searchMatches = nodes.values
            .filter { OrbitElementsLogic.matchesSearch($0, query: searchText, mode: searchMode) }
            .map(\.id)
        searchIndex = 0
    }

    private func ensureVisible(nodeID: Int) {
        var path = [nodeID]
        var current = nodeID
        while let parent = parentByNode[current], path.count < 512 {
            path.insert(parent, at: 0)
            current = parent
        }
        for id in path.dropLast() { expanded.insert(id) }
        rebuildVisibleRows()
        selectRow(nodeID: nodeID)
    }


    private func parseNodeInfo(_ obj: [String: Any]) -> ElNodeInfo {
        ElNodeInfo(
            id:         OrbitInspectDecode.integer(obj, "id"),
            kind:       OrbitInspectDecode.string(obj, "kind").isEmpty ? "el" : OrbitInspectDecode.string(obj, "kind"),
            name:       OrbitInspectDecode.string(obj, "name"),
            attrs:      OrbitInspectDecode.stringMap(obj, "attrs"),
            childCount: OrbitInspectDecode.integer(obj, "childCount"),
            text:       OrbitInspectDecode.string(obj, "text")
        )
    }

    private func receiveDOM(_ object: [String: Any]) {
        guard let parentObj = OrbitInspectDecode.object(object, "parent") else { return }
        let nodesArr = OrbitInspectDecode.objects(object, "nodes")

        let parent = parseNodeInfo(parentObj)
        let childNodes = nodesArr.map(parseNodeInfo)

        nodes[parent.id] = parent
        childrenMap[parent.id] = childNodes.map(\.id)
        for child in childNodes { nodes[child.id] = child }

        childrenLoading.remove(parent.id)

        if rootIDs.isEmpty {
            rootIDs = [parent.id]
            expanded.insert(parent.id)
            if let bodyID = childNodes.first(where: { $0.name == "body" })?.id {
                expanded.insert(bodyID)
                if childrenMap[bodyID] == nil { loadChildren(nodeID: bodyID, offset: 0) }
            }
        }

        rowsChanged()
        isLoading = false
    }

    private func receiveChildren(_ object: [String: Any]) {
        let parentID   = OrbitInspectDecode.integer(object, "id")
        let nodesArr   = OrbitInspectDecode.objects(object, "children")
        let offset     = OrbitInspectDecode.integer(object, "offset")
        let totalCount = OrbitInspectDecode.integer(object, "totalCount")

        let children = nodesArr.map(parseNodeInfo)
        for child in children { nodes[child.id] = child }

        let newIDs = children.map(\.id)
        if offset == 0 {
            childrenMap[parentID] = newIDs
        } else {
            var existing = childrenMap[parentID] ?? []
            existing.append(contentsOf: newIDs)
            childrenMap[parentID] = existing
        }

        let loaded = childrenMap[parentID]?.count ?? 0
        if var parent = nodes[parentID] {
            parent.childCount = totalCount
            nodes[parentID] = parent
        }
        showMoreOffsets[parentID] = loaded < totalCount ? loaded : nil

        childrenLoading.remove(parentID)
        rowsChanged()
    }

    private func receiveSelect(_ object: [String: Any]) {
        let nodeID  = OrbitInspectDecode.integer(object, "id")
        let pathArr = OrbitInspectDecode.objects(object, "path")

        var pathIDs: [Int] = []
        for (i, nodeObj) in pathArr.enumerated() {
            let node = parseNodeInfo(nodeObj)
            nodes[node.id] = node
            pathIDs.append(node.id)
            if i < pathArr.count - 1 { expanded.insert(node.id) }
        }
        selectionPath = pathIDs
        selectedID = nodeID

        rowsChanged()
        requestDetail(nodeID: nodeID)
    }

    private func receiveStyle(_ object: [String: Any]) {
        let nodeID  = OrbitInspectDecode.integer(object, "id")
        guard nodeID == selectedID || selectedID == nil else { return }

        cssVarList = OrbitInspectDecode.strings(object, "cssVars")
        let rulesArr = OrbitInspectDecode.objects(object, "rules")
        styleRules = rulesArr.enumerated().map { (i, obj) in parseStyleRule(obj, index: i) }
    }

    private func parseStyleRule(_ obj: [String: Any], index: Int) -> ElStyleRule {
        let ruleType  = OrbitInspectDecode.string(obj, "ruleType")
        let selector  = OrbitInspectDecode.string(obj, "selector")
        let specArr   = (obj["specificity"] as? [Any])?.compactMap { $0 as? Int } ?? [0, 0, 0]
        let sheetIdx  = OrbitInspectDecode.integer(obj, "sheetIdx")
        let ruleIdx   = OrbitInspectDecode.integer(obj, "ruleIdx")
        let rulePath  = Self.intList(obj, "rulePath")
        let href      = OrbitInspectDecode.optionalString(obj, "sheetHref")
        let mediaQ    = OrbitInspectDecode.optionalString(obj, "mediaQuery")
        let supQ      = OrbitInspectDecode.optionalString(obj, "supportsQuery")
        let pseudoEl  = OrbitInspectDecode.optionalString(obj, "pseudoElement")
        let ancestorL = OrbitInspectDecode.optionalString(obj, "ancestorLabel")
        let declsArr  = OrbitInspectDecode.objects(obj, "declarations")

        let ruleID = "\(ruleType)_\(sheetIdx)_\(ruleIdx)_\(index)"

        func declaration(_ d: [String: Any], id: String) -> ElDeclaration {
            ElDeclaration(
                id:            id,
                property:      OrbitInspectDecode.string(d, "property"),
                value:         OrbitInspectDecode.string(d, "value"),
                priority:      OrbitInspectDecode.string(d, "priority"),
                disabled:      OrbitInspectDecode.bool(d, "disabled"),
                overridden:    OrbitInspectDecode.bool(d, "overridden"),
                computedValue: OrbitInspectDecode.optionalString(d, "computedValue"),
                longhands:     OrbitInspectDecode.objects(d, "longhands").enumerated().map { li, l in
                    declaration(l, id: "\(id)_\(li)")
                }
            )
        }
        let decls: [ElDeclaration] = declsArr.enumerated().map { (di, d) in
            declaration(d, id: "\(ruleID)_\(di)")
        }

        return ElStyleRule(
            id: ruleID, ruleType: ruleType, selector: selector,
            specificity: specArr,
            sheetIdx: sheetIdx, ruleIdx: ruleIdx, rulePath: rulePath,
            sheetHref: href, sourceLine: OrbitInspectDecode.number(obj, "sourceLine").map { Int(clamping: $0) },
            mediaQuery: mediaQ, supportsQuery: supQ,
            groupingRules: OrbitInspectDecode.strings(obj, "groupingRules"),
            isInactive: OrbitInspectDecode.bool(obj, "inactive"),
            declarations: decls, pseudoElement: pseudoEl, ancestorLabel: ancestorL
        )
    }

    private static func intList(_ object: [String: Any], _ key: String) -> [Int] {
        guard let values = object[key] as? [Any] else { return [] }
        return values.compactMap { value in
            switch value {
            case let number as Int: return number
            case let number as Double: return number.isFinite ? Int(clamping: number) : nil
            case let number as NSNumber: return number.intValue
            default: return nil
            }
        }
    }

    private func receiveComputed(_ object: [String: Any]) {
        let nodeID = OrbitInspectDecode.integer(object, "id")
        guard nodeID == selectedID || selectedID == nil else { return }

        let propsArr = OrbitInspectDecode.objects(object, "properties")
        computedProperties = propsArr.map { p in
            ElComputedProperty(
                property:        OrbitInspectDecode.string(p, "property"),
                value:           OrbitInspectDecode.string(p, "value"),
                winningRuleID:   OrbitInspectDecode.optionalString(p, "winningRuleID"),
                winningSelector: OrbitInspectDecode.optionalString(p, "winningSelector"),
                isInherited:     OrbitInspectDecode.bool(p, "isInherited")
            )
        }
    }

    private func receiveBoxModel(_ object: [String: Any]) {
        let nodeID = OrbitInspectDecode.integer(object, "id")
        guard nodeID == selectedID || selectedID == nil else { return }

        boxModel = ElBoxModel(
            width:         OrbitInspectDecode.number(object, "width")  ?? 0,
            height:        OrbitInspectDecode.number(object, "height") ?? 0,
            marginTop:     OrbitInspectDecode.string(object, "marginTop"),
            marginRight:   OrbitInspectDecode.string(object, "marginRight"),
            marginBottom:  OrbitInspectDecode.string(object, "marginBottom"),
            marginLeft:    OrbitInspectDecode.string(object, "marginLeft"),
            borderTop:     OrbitInspectDecode.string(object, "borderTop"),
            borderRight:   OrbitInspectDecode.string(object, "borderRight"),
            borderBottom:  OrbitInspectDecode.string(object, "borderBottom"),
            borderLeft:    OrbitInspectDecode.string(object, "borderLeft"),
            paddingTop:    OrbitInspectDecode.string(object, "paddingTop"),
            paddingRight:  OrbitInspectDecode.string(object, "paddingRight"),
            paddingBottom: OrbitInspectDecode.string(object, "paddingBottom"),
            paddingLeft:   OrbitInspectDecode.string(object, "paddingLeft"),
            position:      OrbitInspectDecode.string(object, "position"),
            top:           OrbitInspectDecode.string(object, "top"),
            right:         OrbitInspectDecode.string(object, "right"),
            bottom:        OrbitInspectDecode.string(object, "bottom"),
            left:          OrbitInspectDecode.string(object, "left"),
            display:       OrbitInspectDecode.string(object, "display"),
            isFlex:        OrbitInspectDecode.bool(object, "flexContainer"),
            isGrid:        OrbitInspectDecode.bool(object, "gridContainer")
        )
    }

    private func receiveListeners(_ object: [String: Any]) {
        let nodeID = OrbitInspectDecode.integer(object, "id")
        guard nodeID == selectedID || selectedID == nil else { return }

        let arr = OrbitInspectDecode.objects(object, "listeners")
        eventListeners = arr.enumerated().map { (i, l) in
            ElEventListener(
                id:            "\(OrbitInspectDecode.integer(l, "nodeId"))_\(OrbitInspectDecode.string(l, "type"))_\(i)",
                nodeID:        OrbitInspectDecode.integer(l, "nodeId"),
                isAncestor:    OrbitInspectDecode.bool(l, "isAncestor"),
                isWindow:      OrbitInspectDecode.bool(l, "isWindow"),
                eventType:     OrbitInspectDecode.string(l, "type"),
                capture:       OrbitInspectDecode.bool(l, "capture"),
                passive:       OrbitInspectDecode.bool(l, "passive"),
                once:          OrbitInspectDecode.bool(l, "once"),
                handlerSource: OrbitInspectDecode.string(l, "handlerSource"),
                sourceURL:     OrbitInspectDecode.optionalString(l, "sourceURL"),
                sourceLine:    OrbitInspectDecode.number(l, "sourceLine").map { Int(clamping: $0) },
                addedBeforeInspector: OrbitInspectDecode.bool(l, "beforeOpen")
            )
        }
    }

    private func receiveA11y(_ object: [String: Any]) {
        let nodeID = OrbitInspectDecode.integer(object, "id")
        guard nodeID == selectedID || selectedID == nil else { return }

        a11y = ElA11y(
            role:         OrbitInspectDecode.string(object, "role"),
            name:         OrbitInspectDecode.string(object, "name"),
            nameFrom:     OrbitInspectDecode.string(object, "nameFrom"),
            ariaAttrs:    OrbitInspectDecode.stringMap(object, "ariaAttrs"),
            focusable:    OrbitInspectDecode.bool(object, "focusable"),
            contrastRatio: OrbitInspectDecode.number(object, "contrastRatio")
        )
    }

    /// An unknown or zero `afterID` means "first", after any leading shadow root the page lists ahead of ordinary children.
    private func insertionIndex(after afterID: Int, in kids: [Int]) -> Int {
        if afterID != 0, let index = kids.firstIndex(of: afterID) { return index + 1 }
        if afterID != 0 { return kids.count }
        return kids.firstIndex { nodes[$0]?.kind != "shadow" } ?? kids.count
    }

    /// Drops the unlinked nodes (and everything below them) that no parent lists any more.
    private func purgeUnlinked(_ ids: [Int]) {
        let parents = OrbitElementsLogic.parentMap(children: childrenMap)
        var doomed: [Int] = ids.filter { parents[$0] == nil && !rootIDs.contains($0) }
        while let id = doomed.popLast() {
            if let kids = childrenMap.removeValue(forKey: id) { doomed.append(contentsOf: kids) }
            nodes.removeValue(forKey: id)
            expanded.remove(id)
            layoutKinds.removeValue(forKey: id)
            layoutOverlays.removeValue(forKey: id)
            showMoreOffsets.removeValue(forKey: id)
        }
    }

    private func receiveMutation(_ object: [String: Any]) {
        let mutations = OrbitInspectDecode.objects(object, "mutations")
        guard !mutations.isEmpty else { return }

        var needsRebuild = false
        // A node unlinked here but linked again by the end of the batch was moved, and keeps its children and expansion.
        var unlinked: [Int] = []

        for mutation in mutations {
            let kind = OrbitInspectDecode.string(mutation, "kind")
            switch kind {
            case "added":
                if let nodeObj = OrbitInspectDecode.object(mutation, "node") {
                    let node   = parseNodeInfo(nodeObj)
                    let pid    = OrbitInspectDecode.integer(mutation, "parentId")
                    let afterID = OrbitInspectDecode.integer(mutation, "afterId")
                    // A node the tree already lists under this parent (late parser insertions) is not a change; one unlinked earlier in the batch and re-added was moved.
                    let alreadyListed = childrenMap[pid]?.contains(node.id) == true && !unlinked.contains(node.id)
                    nodes[node.id] = node
                    if var kids = childrenMap[pid] {
                        kids.removeAll { $0 == node.id }
                        kids.insert(node.id, at: insertionIndex(after: afterID, in: kids))
                        childrenMap[pid] = kids
                    } else if var parent = nodes[pid] {
                        parent.childCount += 1
                        nodes[pid] = parent
                    }
                    if !alreadyListed { flashedNodes.insert(node.id) }
                    needsRebuild = true
                }
            case "removed":
                let nid = OrbitInspectDecode.integer(mutation, "nodeId")
                let pid = OrbitInspectDecode.integer(mutation, "parentId")
                if var kids = childrenMap[pid] { kids.removeAll { $0 == nid }; childrenMap[pid] = kids }
                unlinked.append(nid)
                needsRebuild = true
            case "attrs":
                let nid  = OrbitInspectDecode.integer(mutation, "nodeId")
                let attrs = OrbitInspectDecode.stringMap(mutation, "attrs")
                if var node = nodes[nid] { node.attrs = attrs; nodes[nid] = node }
                flashedNodes.insert(nid)
                needsRebuild = true
            case "text":
                let nid  = OrbitInspectDecode.integer(mutation, "nodeId")
                let text = OrbitInspectDecode.string(mutation, "text")
                if var node = nodes[nid] { node.text = text; nodes[nid] = node }
                flashedNodes.insert(nid)
                needsRebuild = true
            default:
                break
            }
        }

        if needsRebuild {
            if !unlinked.isEmpty { purgeUnlinked(unlinked) }
            rebuildVisibleRows()
            if let id = selectedID {
                if nodes[id] == nil {
                    selectedID = nil
                    selectionPath = []
                } else if let path = pathIDs(to: id) {
                    selectionPath = path
                }
            }
            let flashing = flashedNodes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                for id in flashing { self.flashedNodes.remove(id) }
            }
            if let id = selectedID {
                let affected = mutations.contains {
                    OrbitInspectDecode.integer($0, "nodeId") == id ||
                    OrbitInspectDecode.integer($0, "parentId") == id
                }
                if affected { session?.command(["op": "el.style", "id": id]) }
            }
        }
    }

    private func receiveAttrDone(_ object: [String: Any]) {
        let nodeID   = OrbitInspectDecode.integer(object, "id")
        let newAttrs = OrbitInspectDecode.stringMap(object, "attrs")
        if var node = nodes[nodeID] {
            node.attrs = newAttrs
            nodes[nodeID] = node
            rowsChanged()
        }
    }

    private func receiveOuterHTML(_ object: [String: Any]) {
        let html = OrbitInspectDecode.string(object, "html")
        if outerHTMLNodeID == nil {
            session?.copy(html)
            return
        }
        guard outerHTMLNodeID == OrbitInspectDecode.integer(object, "id") else { return }
        outerHTMLText = html
        outerHTMLOriginal = html
        outerHTMLLoaded = true
    }
}


private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}


extension OrbitElementsModel {
    var cssPropertyList: [String] { commonCSSProperties }
}
