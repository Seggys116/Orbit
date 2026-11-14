import SwiftUI
import AppKit

struct OrbitNetworkPane: View {
    var session: OrbitInspectSession

    private var model: OrbitNetworkModel { session.network }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            InspectDivider()
            overviewTimeline
            InspectDivider()
            mainContent
            InspectDivider()
            footerBar
        }
        .background(InspectChrome.panel)
    }

    /// The row scrolls horizontally rather than clipping when the dock is narrow, and the field keeps a usable minimum width.
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            toolbarRow
                .padding(.horizontal, 8)
                .frame(minWidth: 0, maxHeight: .infinity)
        }
        .frame(height: 36)
        .background(InspectChrome.surface)
    }

    private var toolbarRow: some View {
        HStack(spacing: 6) {
            InspectIconButton(
                symbol: model.isRecording ? "record.circle.fill" : "record.circle",
                help: model.isRecording ? "Stop recording" : "Start recording",
                active: model.isRecording
            ) { model.isRecording.toggle() }

            InspectIconButton(symbol: "trash", help: "Clear") {
                model.pageDidReset(preservingLog: false)
            }

            InspectIconButton(
                symbol: "clock.arrow.circlepath",
                help: "Preserve log across navigations",
                active: session.preserveLog
            ) { session.preserveLog.toggle() }

            InspectIconButton(
                symbol: "bolt.horizontal",
                help: "Hard reload (bypass cache)"
            ) { session.reloadPage(ignoringCache: true) }

            InspectSearchField(placeholder: "Filter", text: Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 }))
                .frame(width: 160)

            typeChips
            filterMenuButton
        }
    }

    private var typeChips: some View {
        HStack(spacing: 2) {
            ForEach(NetTypeChip.allCases, id: \.rawValue) { chip in
                let count = chip == .all ? model.filteredRecords.count : countForChip(chip)
                InspectChip(chip.label, selected: model.typeFilter == chip.filter,
                            count: chip == .all ? nil : (count > 0 ? count : nil)) {
                    model.typeFilter = chip.filter
                }
            }
        }
    }

    private func countForChip(_ chip: NetTypeChip) -> Int {
        guard chip != .all else { return model.filteredRecords.count }
        let f = chip.filter
        return model.typeCounts[f] ?? 0
    }

    private var filterMenuButton: some View {
        InspectMenuButton(symbol: "line.3.horizontal.decrease.circle", help: "Filter options") {
            [InspectMenuItem(title: "Hide data: URLs", checked: model.hideDataURLs) { model.hideDataURLs.toggle() },
             InspectMenuItem(title: "Only failed", checked: model.showOnlyFailed) { model.showOnlyFailed.toggle() },
             InspectMenuItem(title: "Third-party only", checked: model.showThirdPartyOnly) { model.showThirdPartyOnly.toggle() },
             InspectMenuItem(title: "Invert filter", checked: model.invertFilter) { model.invertFilter.toggle() }]
        }
    }

    @ViewBuilder
    private var overviewTimeline: some View {
        if model.records.isEmpty {
            InspectChrome.panel.frame(height: 44)
        } else {
            NetworkOverviewTimeline(
                records: model.records,
                dclMs: model.navigationTiming?.dclMs,
                loadMs: model.navigationTiming?.loadMs,
                timeRange: Binding(get: { model.timeRange }, set: { model.timeRange = $0 })
            )
            .frame(height: 44)
        }
    }

    private var mainContent: some View {
        InspectSplit(key: "net.main", defaultFraction: 0.52, stackBelow: 600) {
            networkList
        } second: {
            networkDetail
        }
    }

    /// The table scrolls sideways as one piece, header included, so columns stay under their titles and Time and Waterfall stay reachable.
    private var networkList: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    NetworkColumnHeader(model: model)
                    InspectDivider()
                    networkRows
                }
                .frame(width: max(proxy.size.width, tableWidth), height: proxy.size.height)
            }
        }
    }

    @AppStorage("orbit.net.hiddenColumns", store: OrbitDefaults.standard) private var hiddenColumnsRaw: String = ""

    /// Width the visible columns need: every fixed column, the waterfall at its default width, and row padding.
    private var tableWidth: CGFloat {
        let hidden = Set(hiddenColumnsRaw.split(separator: ",").map(String.init))
        let columns = NetColumn.allCases.filter { !hidden.contains($0.rawValue) }
        return columns.reduce(8) { $0 + (model.columnWidths[$1.rawValue] ?? $1.defaultWidth) }
    }

    private var networkRows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredRecords) { record in
                        NetworkRow(record: record, model: model)
                            .id(record.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var networkDetail: some View {
        if let id = model.selectedID,
           let record = model.filteredRecords.first(where: { $0.id == id }),
           let rich = model.richRecord(id: id) {
            NetworkDetailPane(record: record, rich: rich, model: model, session: session)
        } else {
            InspectEmptyState(
                symbol: "doc.text.magnifyingglass",
                title: "No request selected",
                message: "Click a request in the list to inspect its headers, timing, payload, and more."
            )
        }
    }

    private var footerBar: some View {
        NetworkSummaryFooter(summary: model.summary)
    }
}

// MARK: - Type chip model

private enum NetTypeChip: String, CaseIterable {
    case all, fetchXHR = "fetch", doc = "document", css = "stylesheet",
         js = "script", font, img = "image", media, ws = "websocket", other

    var label: String {
        switch self {
        case .all: return "All"
        case .fetchXHR: return "Fetch/XHR"
        case .doc: return "Doc"
        case .css: return "CSS"
        case .js: return "JS"
        case .font: return "Font"
        case .img: return "Img"
        case .media: return "Media"
        case .ws: return "WS"
        case .other: return "Other"
        }
    }

    var filter: String {
        switch self {
        case .all: return "all"
        default: return rawValue
        }
    }
}
