import SwiftUI
import AppKit

// MARK: - Overview Timeline

struct NetworkOverviewTimeline: View {
    var records: [OrbitNetworkRecord]
    var dclMs: Double?
    var loadMs: Double?
    @Binding var timeRange: ClosedRange<Double>?

    @State private var isDragging = false
    @State private var dragStartFrac: CGFloat = 0
    @State private var dragCurFrac: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                timelineCanvas
                brushOverlay(geo: geo)
            }
            .contentShape(Rectangle())
            .gesture(brushDrag(geo: geo))
            .onTapGesture { timeRange = nil }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var timelineCanvas: some View {
        Canvas { ctx, size in
            let (minT, maxT) = timeSpan()
            guard maxT > minT else { return }
            let span = maxT - minT
            let h = size.height

            // Row height: distribute up to 40 rows max
            let rowH = max(1.0, min(4.0, (h - 16) / CGFloat(max(1, records.count))))

            for (i, rec) in records.enumerated() {
                let y = 8 + CGFloat(i) * rowH
                guard let st = rec.startTime else { continue }
                let x = CGFloat((st - minT) / span) * size.width
                let w = max(2, CGFloat((rec.duration ?? 0) / span) * size.width)
                let color = netBarColor(rec)
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: max(1, rowH - 0.5))),
                         with: .color(color))
            }

            // Marker lines
            func marker(_ ms: Double, _ color: Color) {
                let x = CGFloat((ms - minT) / span) * size.width
                var path = Path(); path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(path, with: .color(color), lineWidth: 1)
            }
            if let d = dclMs { marker(d, Color(nsColor: .systemBlue).opacity(0.8)) }
            if let l = loadMs { marker(l, Color(nsColor: .systemRed).opacity(0.8)) }
        }
    }

    private func brushFractions() -> (CGFloat, CGFloat) {
        if isDragging {
            return (min(dragStartFrac, dragCurFrac), max(dragStartFrac, dragCurFrac))
        }
        guard let range = timeRange else { return (0, 0) }
        let (minT, maxT) = timeSpan()
        let span = maxT - minT
        guard span > 0 else { return (0, 0) }
        return (CGFloat((range.lowerBound - minT) / span), CGFloat((range.upperBound - minT) / span))
    }

    private func brushOverlay(geo: GeometryProxy) -> some View {
        Group {
            if isDragging || timeRange != nil {
                let (f0, f1) = brushFractions()
                let x0 = f0 * geo.size.width
                let x1 = f1 * geo.size.width
                ZStack(alignment: .topLeading) {
                    InspectChrome.accent.opacity(0.18)
                        .frame(width: max(0, x1 - x0), height: geo.size.height)
                        .offset(x: x0)
                    InspectChrome.accent.opacity(0.6)
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: x0)
                    InspectChrome.accent.opacity(0.6)
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: max(x0, x1 - 1))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func brushDrag(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                isDragging = true
                dragStartFrac = min(max(v.startLocation.x / geo.size.width, 0), 1)
                dragCurFrac = min(max(v.location.x / geo.size.width, 0), 1)
            }
            .onEnded { v in
                isDragging = false
                let f1 = min(max(v.startLocation.x / geo.size.width, 0), 1)
                let f2 = min(max(v.location.x / geo.size.width, 0), 1)
                let lo = min(f1, f2); let hi = max(f1, f2)
                if hi - lo < 0.01 { timeRange = nil; return }
                let (minT, maxT) = timeSpan()
                let span = maxT - minT
                if span <= 0 { timeRange = nil; return }
                timeRange = (minT + span * Double(lo))...(minT + span * Double(hi))
            }
    }

    private func timeSpan() -> (Double, Double) {
        let starts = records.compactMap { $0.startTime }
        let ends = records.compactMap { r -> Double? in
            guard let s = r.startTime, let d = r.duration else { return nil }
            return s + d
        }
        guard let minT = starts.min() else { return (0, 1) }
        let maxT = max((ends.max() ?? minT) + 1, minT + 1)
        return (minT, maxT)
    }

    private func netBarColor(_ r: OrbitNetworkRecord) -> Color {
        if r.failed { return InspectChrome.badColor }
        switch OrbitNetworkLogic.canonicalType(resourceType: r.resourceType, mimeType: r.mimeType) {
        case "document": return Color(nsColor: .systemBlue)
        case "script": return Color(nsColor: .systemYellow)
        case "stylesheet": return Color(nsColor: .systemPurple)
        case "image": return Color(nsColor: .systemGreen)
        case "font": return Color(nsColor: .systemTeal)
        case "fetch": return Color(nsColor: .systemOrange)
        case "websocket", "eventsource": return Color(nsColor: .systemPink)
        default: return Color.secondary
        }
    }
}

// MARK: - Column header

enum NetColumn: String, CaseIterable {
    case name = "Name"
    case status = "Status"
    case method = "Method"
    case domain = "Domain"
    case type = "Type"
    case size = "Size"
    case time = "Time"
    case waterfall = "Waterfall"

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 180; case .status: return 54
        case .method: return 54; case .domain: return 100
        case .type: return 72; case .size: return 88
        case .time: return 70; case .waterfall: return 140
        }
    }
    var sortKey: String { rawValue.lowercased() }
    var resizable: Bool { self != .waterfall }
}

struct NetworkColumnHeader: View {
    var model: OrbitNetworkModel

    @AppStorage("orbit.net.hiddenColumns", store: OrbitDefaults.standard) private var hiddenRaw: String = ""

    private var hiddenColumns: Set<String> {
        Set(hiddenRaw.split(separator: ",").map(String.init))
    }

    private func width(_ col: NetColumn) -> CGFloat {
        model.columnWidths[col.rawValue] ?? col.defaultWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NetColumn.allCases, id: \.rawValue) { col in
                if !hiddenColumns.contains(col.rawValue) {
                    columnCell(col).frame(width: width(col))
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: InspectChrome.rowHeight)
        .background(InspectChrome.surface)
        .contextMenu { columnVisibilityMenu }
    }

    private func columnCell(_ col: NetColumn) -> some View {
        HStack(spacing: 2) {
            Text(col.rawValue)
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(InspectChrome.muted)
                .lineLimit(1)
            if model.sortColumn == col.sortKey {
                Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InspectChrome.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if col.resizable {
                InspectResizeHandle(
                    vertical: false, sign: 1,
                    minBreadth: 40, maxBreadth: 400,
                    current: { model.columnWidths[col.rawValue] ?? col.defaultWidth },
                    onChange: { model.columnWidths[col.rawValue] = $0 },
                    onEnd: {}
                )
                .frame(width: 5)
            }
        }
        .overlay(InspectHitTarget {
            if model.sortColumn == col.sortKey {
                model.sortAscending.toggle()
            } else {
                model.sortColumn = col.sortKey
                model.sortAscending = true
            }
        })
    }

    @ViewBuilder private var columnVisibilityMenu: some View {
        ForEach(NetColumn.allCases, id: \.rawValue) { col in
            let hidden = hiddenColumns.contains(col.rawValue)
            Button(action: { toggleColumn(col) }) {
                HStack {
                    if !hidden { Image(systemName: "checkmark") }
                    Text(col.rawValue)
                }
            }
        }
    }

    private func toggleColumn(_ col: NetColumn) {
        var set = hiddenColumns
        if set.contains(col.rawValue) { set.remove(col.rawValue) }
        else { set.insert(col.rawValue) }
        hiddenRaw = set.joined(separator: ",")
    }
}

// MARK: - Network row

struct NetworkRow: View {
    var record: OrbitNetworkRecord
    var model: OrbitNetworkModel

    @AppStorage("orbit.net.hiddenColumns", store: OrbitDefaults.standard) private var hiddenRaw: String = ""
    private var hiddenColumns: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var isSelected: Bool { model.selectedID == record.id }

    private func w(_ col: NetColumn) -> CGFloat {
        model.columnWidths[col.rawValue] ?? col.defaultWidth
    }

    var body: some View {
        ZStack {
            rowBackground
            rowContent
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { model.selectedID = record.id })
        .contextMenu { rowContextMenu }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                    .fill(InspectChrome.accent.opacity(0.18))
                    .padding(.horizontal, 2)
            } else {
                Color.clear
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            if !hiddenColumns.contains(NetColumn.name.rawValue) {
                nameCell.frame(width: w(.name), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.status.rawValue) {
                statusCell.frame(width: w(.status), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.method.rawValue) {
                methodCell.frame(width: w(.method), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.domain.rawValue) {
                domainCell.frame(width: w(.domain), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.type.rawValue) {
                typeCell.frame(width: w(.type), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.size.rawValue) {
                sizeCell.frame(width: w(.size), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.time.rawValue) {
                timeCell.frame(width: w(.time), alignment: .leading)
            }
            if !hiddenColumns.contains(NetColumn.waterfall.rawValue) {
                waterfallCell.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        // Keep columns on the leading edge: a centred row would be cut off on both sides and drift from the header.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var nameCell: some View {
        HStack(spacing: 4) {
            Image(systemName: typeIcon(record.resourceType))
                .font(.system(size: 9))
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 12)
            Text(rowName)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .foregroundStyle(record.failed ? InspectChrome.badColor : Color.primary)
        }
        .padding(.horizontal, 4)
        .orbitTooltip(record.url)
    }

    private var statusCell: some View {
        Text(record.status > 0 ? "\(record.status)" : (record.failed ? "ERR" : "—"))
            .font(InspectChrome.mono)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var methodCell: some View {
        Text(record.method)
            .font(InspectChrome.monoSmall)
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var domainCell: some View {
        Text(URL(string: record.url)?.host ?? "")
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var typeCell: some View {
        Text(OrbitNetworkLogic.canonicalType(resourceType: record.resourceType, mimeType: record.mimeType))
            .font(InspectChrome.monoSmall)
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var sizeCell: some View {
        let (xfer, _) = OrbitNetworkLogic.sizeLabel(
            transferSize: record.transferSize,
            bodySize: record.bodySize,
            fromCache: record.fromCache)
        return Text(xfer)
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var timeCell: some View {
        Text(OrbitDevToolsFormat.milliseconds(record.duration))
            .font(InspectChrome.mono)
            .foregroundStyle(InspectChrome.muted)
            .padding(.horizontal, 4)
            .lineLimit(1)
    }

    private var waterfallCell: some View {
        NetworkWaterfall(record: record, allRecords: model.records,
                         dclMs: model.navigationTiming?.dclMs,
                         loadMs: model.navigationTiming?.loadMs)
            .frame(height: InspectChrome.rowHeight - 4)
    }

    private var rowName: String {
        guard let url = URL(string: record.url) else { return record.url }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? record.url) : last
    }

    private var statusColor: Color {
        if record.failed || record.status >= 500 { return InspectChrome.badColor }
        if record.status >= 400 { return InspectChrome.warnColor }
        if record.status >= 300 { return Color(nsColor: .systemBlue) }
        if record.status >= 200 { return InspectChrome.goodColor }
        return .secondary
    }

    private func typeIcon(_ type: String) -> String {
        switch OrbitNetworkLogic.canonicalType(resourceType: type, mimeType: "") {
        case "document": return "doc"
        case "script": return "chevron.left.forwardslash.chevron.right"
        case "stylesheet": return "paintbrush"
        case "image": return "photo"
        case "font": return "textformat"
        case "media": return "play.circle"
        case "fetch": return "arrow.up.arrow.down"
        case "websocket": return "antenna.radiowaves.left.and.right"
        default: return "questionmark"
        }
    }

    @ViewBuilder private var rowContextMenu: some View {
        Button("Copy URL") { copyText(record.url) }
        Button("Copy as cURL (bash)") {
            let rich = model.richRecord(id: record.id)
            copyText(OrbitNetworkLogic.curlBash(record, body: OrbitNetworkLogic.exportableBodyText(rich?.requestBody)))
        }
        Button("Copy as cURL (Windows)") {
            let rich = model.richRecord(id: record.id)
            copyText(OrbitNetworkLogic.curlWindows(record, body: OrbitNetworkLogic.exportableBodyText(rich?.requestBody)))
        }
        Button("Copy as fetch") {
            let rich = model.richRecord(id: record.id)
            copyText(OrbitNetworkLogic.fetchExpression(record, body: OrbitNetworkLogic.exportableBodyText(rich?.requestBody)))
        }
        Divider()
        Button("Copy Response") {
            if let body = model.richRecord(id: record.id)?.responseBody {
                copyText(body)
            } else if case .text(let body, _)? = model.fetchedBodies[record.id] {
                copyText(body)
            }
        }
        Button("Open in New Tab") {
            NSWorkspace.shared.open(URL(string: record.url) ?? URL(fileURLWithPath: "/"))
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Per-row waterfall bar

struct NetworkWaterfall: View {
    var record: OrbitNetworkRecord
    var allRecords: [OrbitNetworkRecord]
    var dclMs: Double?
    var loadMs: Double?

    var body: some View {
        Canvas { ctx, size in
            let (minT, maxT) = timeSpan()
            guard maxT > minT else { return }
            let span = maxT - minT

            guard let startT = record.startTime else { return }
            let x0 = CGFloat((startT - minT) / span) * size.width
            let dur = record.duration ?? 0
            let totalW = max(2, CGFloat(dur / span) * size.width)
            let barColor = waterfallColor(record)
            ctx.fill(
                Path(CGRect(x: x0, y: size.height * 0.25, width: totalW, height: size.height * 0.5)),
                with: .color(barColor)
            )

            // Marker lines
            func marker(_ ms: Double?, _ c: Color) {
                guard let ms else { return }
                let x = CGFloat((ms - minT) / span) * size.width
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(c), lineWidth: 0.5)
            }
            marker(dclMs, Color(nsColor: .systemBlue).opacity(0.5))
            marker(loadMs, Color(nsColor: .systemRed).opacity(0.5))
        }
    }

    private func timeSpan() -> (Double, Double) {
        let starts = allRecords.compactMap { $0.startTime }
        let ends = allRecords.compactMap { r -> Double? in
            guard let s = r.startTime, let d = r.duration else { return nil }
            return s + d
        }
        guard let minT = starts.min() else { return (0, 1) }
        return (minT, max((ends.max() ?? minT) + 1, minT + 1))
    }

    private func waterfallColor(_ r: OrbitNetworkRecord) -> Color {
        if r.failed { return InspectChrome.badColor.opacity(0.7) }
        switch OrbitNetworkLogic.canonicalType(resourceType: r.resourceType, mimeType: r.mimeType) {
        case "document": return Color(nsColor: .systemBlue).opacity(0.7)
        case "script": return Color(nsColor: .systemYellow).opacity(0.8)
        case "stylesheet": return Color(nsColor: .systemPurple).opacity(0.7)
        case "image": return Color(nsColor: .systemGreen).opacity(0.7)
        case "font": return Color(nsColor: .systemTeal).opacity(0.7)
        case "fetch": return Color(nsColor: .systemOrange).opacity(0.7)
        case "websocket", "eventsource": return Color(nsColor: .systemPink).opacity(0.7)
        default: return Color.secondary.opacity(0.5)
        }
    }
}

// MARK: - Detail pane

struct NetworkDetailPane: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord
    var model: OrbitNetworkModel
    var session: OrbitInspectSession

    private var availableTabs: [String] {
        var tabs = ["headers", "payload", "response", "initiator", "timing", "cookies"]
        if !rich.wsFrames.isEmpty { tabs.append("ws") }
        if !rich.sseMessages.isEmpty { tabs.append("sse") }
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            detailTabBar
            Divider().foregroundStyle(InspectChrome.hairline)
            detailContent
        }
    }

    private var detailTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(availableTabs, id: \.self) { tab in
                    InspectChip(tabLabel(tab), selected: model.detailTab == tab) {
                        model.detailTab = tab
                    }
                }
                Spacer()
                InspectMenuButton(symbol: "square.and.arrow.up", help: "Export") {
                    exportMenuItems()
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 36)
        .background(InspectChrome.surface)
    }

    private func tabLabel(_ tab: String) -> String {
        switch tab {
        case "headers": return "Headers"
        case "payload": return "Payload"
        case "response": return "Response"
        case "initiator": return "Initiator"
        case "timing": return "Timing"
        case "cookies": return "Cookies"
        case "ws": return "WS Frames (\(rich.wsFrames.count))"
        case "sse": return "EventStream (\(rich.sseMessages.count))"
        default: return tab.capitalized
        }
    }

    @ViewBuilder private var detailContent: some View {
        ScrollView(.vertical) {
            switch model.detailTab {
            case "headers": NetworkHeadersTab(record: record, rich: rich)
            case "payload": NetworkPayloadTab(record: record, rich: rich)
            case "response": NetworkResponseTab(record: record, rich: rich, model: model)
            case "initiator": NetworkInitiatorTab(record: record, rich: rich, session: session)
            case "timing": NetworkTimingTab(record: record, rich: rich, pageURL: session.pageURL, model: model)
            case "cookies": NetworkCookiesTab(record: record, rich: rich, model: model)
            case "ws": NetworkWSTab(rich: rich)
            case "sse": NetworkSSETab(rich: rich)
            default: EmptyView()
            }
        }
    }

    private func exportMenuItems() -> [InspectMenuItem] {
        [
            InspectMenuItem(title: "Copy as cURL (bash)") {
                copyText(OrbitNetworkLogic.curlBash(record, body: OrbitNetworkLogic.exportableBodyText(rich.requestBody)))
            },
            InspectMenuItem(title: "Copy as cURL (Windows)") {
                copyText(OrbitNetworkLogic.curlWindows(record, body: OrbitNetworkLogic.exportableBodyText(rich.requestBody)))
            },
            InspectMenuItem(title: "Copy as fetch") {
                copyText(OrbitNetworkLogic.fetchExpression(record, body: OrbitNetworkLogic.exportableBodyText(rich.requestBody)))
            },
            .separator,
            InspectMenuItem(title: "Copy all as HAR") {
                let har = OrbitNetworkLogic.harJSON(records: model.records,
                                                    pageURL: session.pageURL,
                                                    pageTitle: session.pageTitle)
                copyText(har)
            },
            InspectMenuItem(title: "Save all as HAR…") {
                let har = OrbitNetworkLogic.harJSON(records: model.records,
                                                    pageURL: session.pageURL,
                                                    pageTitle: session.pageTitle)
                saveHAR(har)
            }
        ]
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveHAR(_ har: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "network.har"
        panel.allowedFileTypes = ["har"]  // deprecated but still works; HAR has no official UTType
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? har.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Headers tab

struct NetworkHeadersTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // General
            InspectSectionHeader("General").padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
            headerRows([
                ("Request URL", record.url),
                ("Request Method", record.method),
                ("Status Code", record.status > 0 ? "\(record.status) \(record.statusText)" : "—"),
                ("Remote Address", rich.remoteAddress ?? "n/a (not available in WebKit)"),
                ("Protocol", record.protocolName ?? "—")
            ])

            Divider().padding(.vertical, 6)
            InspectSectionHeader("Response Headers")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            if record.responseHeaders.isEmpty {
                Text("No response headers recorded")
                    .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            } else {
                headerList(record.responseHeaders)
            }

            Divider().padding(.vertical, 6)
            InspectSectionHeader("Request Headers")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            if rich.cookieFromStore {
                Text("ⓘ Cookie header supplemented from cookie store (HttpOnly cookies are not visible to page script)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if record.requestHeaders.isEmpty {
                Text("No request headers recorded")
                    .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            } else {
                headerList(record.requestHeaders)
            }
        }
        .padding(.bottom, 10)
    }

    private func headerRows(_ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pairs, id: \.0) { pair in
                HStack(alignment: .top, spacing: 0) {
                    Text(pair.0 + ": ")
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.muted)
                        .frame(width: 150, alignment: .trailing)
                    Text(pair.1)
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.ink)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func headerList(_ headers: [OrbitHeader]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(headers, id: \.name) { h in
                HStack(alignment: .top, spacing: 4) {
                    Text(h.name + ": ")
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.attributeNameColor)
                    Text(h.value)
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.ink)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 10)
            }
        }
    }


}

// MARK: - Payload tab

/// A caption that explains a limit or a source, shown where data would otherwise be silently missing.
private struct NetworkNote: View {
    var text: String
    var warn = false

    var body: some View {
        Text("ⓘ " + text)
            .font(InspectChrome.caption)
            .foregroundStyle(warn ? InspectChrome.warnColor : InspectChrome.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
    }
}

private struct NetworkPairRow: View {
    var name: String
    var value: String
    var nameColor: Color = InspectChrome.attributeNameColor

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(name + ": ").font(InspectChrome.mono).foregroundStyle(nameColor)
            Text(value).font(InspectChrome.mono).foregroundStyle(InspectChrome.ink).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }
}

/// Body text with a pretty-print switch that appears only when the text is valid JSON.
private struct NetworkTextBody: View {
    var text: String
    var truncated: Bool
    var truncationNote: String
    @State private var prettyPrint = true

    var body: some View {
        let pretty = OrbitNetworkLogic.prettyJSON(text)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if pretty != nil {
                    InspectChip("Pretty-print", selected: prettyPrint) { prettyPrint = true }
                    InspectChip("Raw", selected: !prettyPrint) { prettyPrint = false }
                }
                Spacer()
                Text(OrbitDevToolsFormat.bytes(text.utf8.count)).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                if truncated {
                    Text(truncationNote).font(InspectChrome.caption).foregroundStyle(InspectChrome.warnColor)
                }
            }
            .padding(.horizontal, 10)
            Text(prettyPrint ? (pretty ?? text) : text)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
        }
    }
}

struct NetworkPayloadTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord

    var body: some View {
        let query = OrbitNetworkLogic.queryParameters(of: record.url)
        VStack(alignment: .leading, spacing: 10) {
            if !query.isEmpty {
                InspectSectionHeader("Query String Parameters (\(query.count))").padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(query.indices, id: \.self) { index in
                        NetworkPairRow(name: query[index].name, value: query[index].value)
                    }
                }
            }
            requestBodySection
            requestHeadersSection
        }
        .padding(.vertical, 10)
    }

    private var contentType: (value: String, implied: Bool)? {
        if let header = record.requestHeader("content-type") { return (header, false) }
        if let implied = rich.requestBody?.impliedContentType { return (implied, true) }
        return nil
    }

    private func formFields(of body: NetRequestBody) -> [NetFormField] {
        if !body.fields.isEmpty { return body.fields }
        if let text = body.text, contentType?.value.lowercased().contains("x-www-form-urlencoded") == true {
            return OrbitNetworkLogic.decodeFormEncoded(text)
        }
        return []
    }

    @ViewBuilder private var requestBodySection: some View {
        if let body = rich.requestBody {
            let fields = formFields(of: body)
            InspectSectionHeader(fields.isEmpty ? "Request Payload" : "Form Data", detail: OrbitNetworkLogic.requestBodySummary(body))
                .padding(.horizontal, 10)
            if let contentType {
                NetworkPairRow(name: "Content-Type", value: contentType.value + (contentType.implied ? " (added by the browser)" : ""),
                               nameColor: InspectChrome.muted)
            }
            if !fields.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fields.indices, id: \.self) { index in
                        let field = fields[index]
                        NetworkPairRow(name: field.name, value: field.fileName.map {
                            "(file) \($0)" + (field.fileSize.map { size in ", \(OrbitDevToolsFormat.bytes(size))" } ?? "")
                        } ?? field.value)
                    }
                }
                if let total = body.fieldCount, total > fields.count {
                    NetworkNote(text: "Showing the first \(fields.count) of \(total) fields.")
                }
            } else if let text = body.text, !text.isEmpty {
                NetworkTextBody(text: text, truncated: body.truncated, truncationNote: "Truncated at 64 KB")
            } else {
                NetworkNote(text: body.note ?? emptyBodyNote(body))
            }
        } else {
            InspectSectionHeader("Request Payload").padding(.horizontal, 10)
            NetworkNote(text: noBodyNote)
        }
    }

    private func emptyBodyNote(_ body: NetRequestBody) -> String {
        switch body.kind {
        case "Blob": return "A Blob body is read only when it is small text; its content is not shown."
        case "string", "URLSearchParams": return "The body is empty."
        default: return "The content of this body is not visible to page script."
        }
    }

    private var noBodyNote: String {
        let method = record.method.uppercased()
        if method == "GET" || method == "HEAD" { return "This \(method) request has no body." }
        switch rich.jsSource {
        case "": return "WebKit does not expose request bodies for loads it starts itself. Bodies are captured only for fetch, XHR, sendBeacon and form posts made from the page, and none was seen for this request."
        default: return "Page script sent no body with this call, or the body could not be read."
        }
    }

    @ViewBuilder private var requestHeadersSection: some View {
        InspectSectionHeader("Request Headers (\(record.requestHeaders.count))").padding(.horizontal, 10)
        if record.requestHeaders.isEmpty {
            NetworkNote(text: "No request headers were recorded.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(record.requestHeaders.indices, id: \.self) { index in
                    NetworkPairRow(name: record.requestHeaders[index].name, value: record.requestHeaders[index].value)
                }
            }
        }
    }
}

// MARK: - Response tab

struct NetworkResponseTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord
    var model: OrbitNetworkModel

    private enum Shown {
        case text(String, truncated: Bool, origin: String)
        case image(Data)
        case loading
        case unavailable(String)
    }

    /// What the pane can show: a body the page hooks captured, one re-read from the page on demand, or the reason there is none.
    private var shown: Shown {
        if let body = rich.responseBody {
            return body.isEmpty
                ? .unavailable("The response body is empty.")
                : .text(body, truncated: rich.responseBodyTruncated, origin: "Captured from the page while DevTools was open.")
        }
        switch model.fetchedBodies[rich.id] {
        case .loading?: return .loading
        case .text(let text, let truncated)?:
            return text.isEmpty
                ? .unavailable("The response body is empty.")
                : .text(text, truncated: truncated,
                        origin: "Re-read from the page with the HTTP cache preferred, so it can differ from what was first received.")
        case .image(let data)?: return .image(data)
        case .unavailable(let reason)?: return .unavailable(reason)
        case nil: break
        }
        if rich.responseBodySkip == "stream" || rich.responseBodySkip == "opaque",
           let reason = OrbitNetworkLogic.captureSkipReason(code: rich.responseBodySkip, mime: rich.mimeType) {
            return .unavailable(reason)
        }
        switch OrbitNetworkLogic.bodyFetchability(
            method: rich.method, status: rich.status, mimeType: rich.mimeType, resourceType: rich.resourceType,
            url: rich.url, pending: rich.pending, failed: rich.failed, cancelled: rich.cancelled
        ) {
        case .refetch:
            return .loading
        case .unavailable(let reason):
            if rich.method.uppercased() != "GET",
               let skip = OrbitNetworkLogic.captureSkipReason(code: rich.responseBodySkip, mime: rich.mimeType) {
                return .unavailable(skip)
            }
            return .unavailable(reason)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryLine
            Divider()
            content
            Divider().padding(.vertical, 8)
            InspectSectionHeader("Response Headers (\(record.responseHeaders.count))")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            if record.responseHeaders.isEmpty {
                NetworkNote(text: headersMissingNote)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(record.responseHeaders.indices, id: \.self) { index in
                        NetworkPairRow(name: record.responseHeaders[index].name, value: record.responseHeaders[index].value)
                    }
                }
            }
        }
        .padding(.bottom, 10)
        .task(id: "\(rich.id)|\(rich.pending)|\(rich.status)|\(rich.responseBody == nil)") {
            model.fetchBodyIfNeeded(id: rich.id)
        }
    }

    private var summaryLine: some View {
        HStack(spacing: 10) {
            Text(record.status > 0 ? "\(record.status) \(record.statusText)" : "No status")
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.ink)
            if !record.mimeType.isEmpty {
                Text(record.mimeType).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            }
            Spacer()
            if let size = record.bodySize {
                Text(OrbitDevToolsFormat.bytes(size)).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .text(let text, let truncated, let origin):
            VStack(alignment: .leading, spacing: 6) {
                NetworkTextBody(text: text, truncated: truncated, truncationNote: "Truncated at 64 KB")
                NetworkNote(text: origin)
            }
            .padding(.vertical, 8)
        case .image(let data):
            VStack(alignment: .leading, spacing: 6) {
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480, maxHeight: 320, alignment: .leading)
                        .padding(.horizontal, 10)
                    NetworkNote(text: "\(Int(image.size.width)) x \(Int(image.size.height)) px, \(OrbitDevToolsFormat.bytes(data.count)). Re-read from the page with the HTTP cache preferred.")
                } else {
                    NetworkNote(text: "The image data could not be decoded for preview.")
                }
            }
            .padding(.vertical, 8)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the response body from the page...")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            .padding(10)
        case .unavailable(let reason):
            VStack(spacing: 4) {
                InspectEmptyState(symbol: "doc.text", title: "Body Not Available", message: reason)
            }
        }
    }

    private var headersMissingNote: String {
        if rich.responseType == "opaque" { return "An opaque response hides its headers from page script." }
        return rich.pending ? "The response has not arrived yet." : "No response headers were recorded."
    }
}

// MARK: - Initiator tab

struct NetworkInitiatorTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord
    var session: OrbitInspectSession

    private func shortLocation(_ frame: NetStackFrame) -> String {
        let name: String
        if let url = URL(string: frame.url), !frame.isNative {
            name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? (url.host ?? frame.url) : url.lastPathComponent
        } else {
            name = frame.url
        }
        guard let line = frame.line else { return name }
        return "\(name):\(line)" + (frame.column.map { ":\($0)" } ?? "")
    }

    var body: some View {
        let frames = rich.initiatorFrames
        let kind = OrbitNetworkLogic.initiatorKind(
            jsSource: rich.jsSource, timingInitiatorType: rich.timingInitiatorType, resourceType: rich.resourceType)
        VStack(alignment: .leading, spacing: 0) {
            if let kind {
                InspectSectionHeader("Initiator").padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                NetworkPairRow(name: "Type", value: kind.title)
                NetworkNote(text: kind.detail).padding(.vertical, 2)
                if let source = OrbitNetworkLogic.initiatorLocation(frames) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("Source: ").font(InspectChrome.mono).foregroundStyle(InspectChrome.attributeNameColor)
                        Text(source.url + (source.line.map { ":\($0)" } ?? ""))
                            .font(InspectChrome.mono)
                            .foregroundStyle(InspectChrome.accent)
                            .overlay(InspectHitTarget {
                                session.reveal(sourceURL: source.url, line: source.line, column: source.column)
                            })
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                } else if rich.jsSource.isEmpty, !session.pageURL.isEmpty, rich.isMainFrame, kind.title != "Navigation" {
                    NetworkPairRow(name: "Page", value: session.pageURL)
                    NetworkNote(text: "WebKit does not say which element or rule inside this page asked for the load, so only the page and the type above are known.")
                        .padding(.top, 2)
                }
            }
            if !frames.isEmpty {
                InspectSectionHeader("Call stack").padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                // The stack of a request never reorders, so each frame's position is its identity.
                ForEach(frames.indices, id: \.self) { frameIndex in
                    let frame = frames[frameIndex]
                    HStack(spacing: 6) {
                        Image(systemName: "return").font(.system(size: 9)).foregroundStyle(InspectChrome.muted)
                        Text(frame.function.isEmpty ? "(anonymous)" : frame.function)
                            .font(InspectChrome.mono).foregroundStyle(InspectChrome.ink)
                        Spacer(minLength: 4)
                        Text(shortLocation(frame))
                            .font(InspectChrome.mono)
                            .foregroundStyle(frame.isOpenable ? InspectChrome.accent : InspectChrome.muted)
                            .lineLimit(1)
                            .orbitTooltip(frame.url)
                            .overlay {
                                if frame.isOpenable {
                                    InspectHitTarget {
                                        session.reveal(sourceURL: frame.url, line: frame.line, column: frame.column)
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 1)
                }
            } else if !rich.jsSource.isEmpty {
                NetworkNote(text: "The page's call stack was empty, which happens when the call came from a timer, event handler or native callback with no script frames.")
                    .padding(.top, 10)
            }
            if kind == nil && frames.isEmpty && rich.redirectChain.isEmpty {
                InspectEmptyState(symbol: "arrow.up.right.square", title: "Initiator Unknown",
                    message: "WebKit does not report what started a load. The initiator type comes from PerformanceResourceTiming, which publishes an entry only after the load finishes, so it is not known yet or this load has no entry.")
            }
            if !rich.redirectChain.isEmpty {
                Divider().padding(.vertical, 8)
                InspectSectionHeader("Redirect Chain (\(rich.redirectChain.count))")
                    .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(rich.redirectChain.indices, id: \.self) { hopIndex in
                    let hop = rich.redirectChain[hopIndex]
                    HStack(spacing: 4) {
                        Text("\(hop.status)").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted).frame(width: 34, alignment: .trailing)
                        Text(hop.fromURL).font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(InspectChrome.muted)
                        Text(hop.toURL).font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 10)
    }
}

// MARK: - Timing tab

struct NetworkTimingTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord
    var pageURL: String
    var model: OrbitNetworkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let b = rich.timingBreakdown {
                if b.crossOriginOpaque {
                    NetworkNote(text: opaqueExplanation, warn: true).padding(.top, 10).padding(.bottom, 4)
                    totalOnly(b)
                } else {
                    timingTable(b)
                }
                if let raw = rich.timingRaw, !raw.serverTiming.isEmpty {
                    Divider().padding(.vertical, 8)
                    InspectSectionHeader("Server Timing").padding(.horizontal, 10).padding(.bottom, 4)
                    ForEach(raw.serverTiming.indices, id: \.self) { index in
                        let st = raw.serverTiming[index]
                        HStack {
                            Text(st.name).font(InspectChrome.mono).frame(minWidth: 120, alignment: .leading)
                            if let dur = st.duration { Text(OrbitDevToolsFormat.milliseconds(dur)).font(InspectChrome.mono) }
                            if !st.description.isEmpty { Text(st.description).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted) }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 2)
                    }
                }
            } else {
                NetworkNote(text: missingExplanation, warn: true).padding(.top, 10)
            }
            Divider().padding(.vertical, 8)
            knownDetails
        }
        .padding(.vertical, 10)
        // A finished load with no timing may only be waiting for the page to resend its entries.
        .task(id: "\(rich.id)|\(rich.timingBreakdown == nil)|\(rich.pending)") {
            if rich.timingBreakdown == nil && !rich.pending { model.panelDidAppear(force: true) }
        }
    }

    private var opaqueExplanation: String {
        switch OrbitNetworkLogic.isCrossOrigin(record.url, pageURL: pageURL) {
        case true?:
            return "This is a cross-origin resource and the server did not send Timing-Allow-Origin, so the browser hides the phase breakdown (queueing, DNS, connect, TLS, request, waiting, download). Only the total duration is known."
        case false?:
            return "The browser reported no phase breakdown for this same-origin resource. That usually means it was served from the memory cache without a network request. Only the total duration is known."
        case nil:
            return "The browser reported no phase breakdown for this resource, which happens for cross-origin resources without Timing-Allow-Origin and for cached ones. Only the total duration is known."
        }
    }

    private var missingExplanation: String {
        let canonical = OrbitNetworkLogic.canonicalType(resourceType: rich.resourceType, mimeType: rich.mimeType)
        if canonical == "websocket" || canonical == "eventsource" {
            return "WebSocket and EventSource connections do not produce resource timing entries."
        }
        if rich.pending {
            return "The browser publishes resource timing only after a response has finished, so nothing is available yet."
        }
        if rich.failed || rich.cancelled {
            return "The load did not complete, and the browser publishes no resource timing entry for loads that fail or are cancelled."
        }
        return "PerformanceResourceTiming has not reported this load. It has no entry for loads made inside a worker or a cross-origin frame, or made before DevTools attached. The values below come from WebKit's own callbacks and the page's fetch/XHR hooks."
    }

    private func timingTable(_ b: NetTimingBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            InspectSectionHeader("Phase Breakdown").padding(.horizontal, 10).padding(.bottom, 4)
            phaseRow("Redirect", b.redirectMs, .gray, absent: "No redirect")
            phaseRow("Queued / Blocked", b.queuedMs, .gray, absent: "No wait before the request started")
            phaseRow("DNS Lookup", b.dnsMs, Color(nsColor: .systemGreen), absent: "Not looked up (cached, or connection reused)")
            phaseRow("Initial connection", b.connectMs, Color(nsColor: .systemOrange), absent: "No new connection (reused)")
            phaseRow("TLS negotiation", b.tlsMs, Color(nsColor: .systemPurple), absent: "No TLS handshake (plain HTTP, or connection reused)")
            phaseRow("Waiting (TTFB)", b.waitingMs, Color(nsColor: .systemBlue), absent: "Not reported")
            phaseRow("Content download", b.downloadMs, Color(nsColor: .systemTeal), absent: "Not reported")
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            phaseRow("Total", b.totalMs ?? record.duration, InspectChrome.accent, absent: "Not reported")
            NetworkNote(text: "The browser does not report when the request finished sending, so request upload time is part of Waiting.")
                .padding(.top, 4)
        }
    }

    private func totalOnly(_ b: NetTimingBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            phaseRow("Total", b.totalMs ?? record.duration, InspectChrome.accent, absent: "Not reported")
        }
    }

    private func phaseRow(_ label: String, _ ms: Double?, _ color: Color, absent: String) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(InspectChrome.label)
                .frame(width: 140, alignment: .leading)
            if let ms {
                Text(OrbitDevToolsFormat.milliseconds(ms))
                    .font(InspectChrome.mono)
                    .foregroundStyle(Color.primary)
            } else {
                Text(absent)
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
    }

    private var knownDetails: some View {
        let raw = rich.timingRaw
        return VStack(alignment: .leading, spacing: 2) {
            InspectSectionHeader("Known Details").padding(.horizontal, 10).padding(.bottom, 4)
            NetworkPairRow(name: "Started", value: record.startTime.map { OrbitDevToolsFormat.milliseconds($0) + " after navigation start" } ?? "Not reported",
                           nameColor: InspectChrome.muted)
            NetworkPairRow(name: "Duration", value: record.duration.map { OrbitDevToolsFormat.milliseconds($0) } ?? "Not reported",
                           nameColor: InspectChrome.muted)
            NetworkPairRow(name: "Protocol", value: record.protocolName ?? "Not reported", nameColor: InspectChrome.muted)
            NetworkPairRow(name: "Transferred",
                           value: record.fromCache ? "From cache, no transfer"
                               : (record.transferSize.map { OrbitDevToolsFormat.bytes($0) } ?? "Not reported (hidden for cross-origin without Timing-Allow-Origin)"),
                           nameColor: InspectChrome.muted)
            NetworkPairRow(name: "Encoded size", value: record.bodySize.map { OrbitDevToolsFormat.bytes($0) } ?? "Not reported",
                           nameColor: InspectChrome.muted)
            if let raw, raw.decodedBodySize > 0 {
                NetworkPairRow(name: "Decoded size", value: OrbitDevToolsFormat.bytes(raw.decodedBodySize), nameColor: InspectChrome.muted)
            }
        }
    }
}

// MARK: - Cookies tab

struct NetworkCookiesTab: View {
    var record: OrbitNetworkRecord
    var rich: NetRecord
    var model: OrbitNetworkModel

    var body: some View {
        let reqCookies = rich.requestCookies
        let respCookies = rich.responseCookies
        VStack(alignment: .leading, spacing: 0) {
            requestSection(reqCookies)
            Divider().padding(.vertical, 8)
            responseSection(respCookies)
            Divider().padding(.vertical, 8)
            NetworkNote(text: "Cookie and Set-Cookie are forbidden header names that page script (fetch, XHR) can never read. Request cookies come from WebKit's native request callback or from the cookie store, and response cookies from WebKit's native response headers; each list says which.")
        }
        .padding(.vertical, 10)
        .task(id: "\(rich.id)|\(reqCookies.isEmpty)") {
            if reqCookies.isEmpty { await model.loadStoreCookies(id: rich.id) }
        }
    }

    @ViewBuilder private func requestSection(_ cookies: [NetCookieParsed]) -> some View {
        if !cookies.isEmpty {
            InspectSectionHeader("Request Cookies (\(cookies.count))")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            NetworkNote(text: rich.cookieFromStore
                ? "Not seen on the wire: these are the cookies in the cookie store that matched this URL when the request was sent, HttpOnly ones included. WebKit does not expose the Cookie header it actually sends, and SameSite and third-party blocking are not applied."
                : "Read from the request's Cookie header.")
                .padding(.bottom, 4)
            cookieTable(cookies)
        } else if let stored = model.storeCookies[rich.id] {
            InspectSectionHeader("Cookies Matching This URL (\(stored.count))")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            if stored.isEmpty {
                NetworkNote(text: "No Cookie header was observed for this request, and the cookie store holds no unexpired cookie that matches its URL.")
            } else {
                NetworkNote(text: "No Cookie header was observed, so this lists what the cookie store holds for this URL right now, HttpOnly ones included. It is not a record of what was sent: SameSite and third-party blocking are not applied, and the store may have changed since the request.")
                    .padding(.bottom, 4)
                storeCookieTable(stored)
            }
        } else {
            InspectSectionHeader("Request Cookies").padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            NetworkNote(text: "No Cookie header was observed. Looking up the cookie store for cookies that match this URL...")
        }
    }

    @ViewBuilder private func responseSection(_ cookies: [NetSetCookieParsed]) -> some View {
        if !cookies.isEmpty {
            InspectSectionHeader("Response Set-Cookie (\(cookies.count))")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            setCookieTable(cookies)
        } else {
            InspectSectionHeader("Response Set-Cookie").padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            if rich.nativeResponseSeen {
                NetworkNote(text: "WebKit reported the response headers for this request and none was a Set-Cookie.")
            } else if rich.pending {
                NetworkNote(text: "The response has not arrived yet.")
            } else {
                NetworkNote(text: "Set-Cookie is invisible to page script, and WebKit's own response headers were not matched to this request, so any cookies it set are unavailable.", warn: true)
            }
        }
    }

    private func storeCookieTable(_ cookies: [NetStoreCookie]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(cookies.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(c.name).font(InspectChrome.mono).foregroundStyle(InspectChrome.attributeNameColor)
                        Text("=")
                        Text(c.value).font(InspectChrome.mono).textSelection(.enabled)
                        Spacer()
                    }
                    let attrs: [String] = ["Domain: \(c.domain)", "Path: \(c.path)",
                                 c.expires.map { "Expires: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Session",
                                 c.secure ? "Secure" : nil,
                                 c.httpOnly ? "HttpOnly" : nil,
                                 c.sameSite.map { "SameSite=\($0)" }].compactMap { $0 }
                    Text(attrs.joined(separator: "; ")).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func cookieTable(_ cookies: [NetCookieParsed]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(cookies.indices, id: \.self) { index in
                let c = cookies[index]
                HStack(spacing: 4) {
                    Text(c.name).font(InspectChrome.mono).foregroundStyle(InspectChrome.attributeNameColor)
                    Text("=")
                    Text(c.value).font(InspectChrome.mono).textSelection(.enabled)
                    Spacer()
                }.padding(.horizontal, 10)
            }
        }
    }

    private func setCookieTable(_ cookies: [NetSetCookieParsed]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(cookies.indices, id: \.self) { cookieIndex in
                let c = cookies[cookieIndex]
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.name).font(InspectChrome.mono).bold()
                        Text("=")
                        Text(c.value).font(InspectChrome.mono).textSelection(.enabled)
                        Spacer()
                    }
                    let attrs = [c.domain.map { "Domain: \($0)" },
                                 c.path.map { "Path: \($0)" },
                                 c.expiresRaw.map { "Expires: \($0)" },
                                 c.maxAge.map { "Max-Age: \($0)" },
                                 c.secure ? Optional("Secure") : nil,
                                 c.httpOnly ? Optional("HttpOnly") : nil,
                                 c.sameSite.map { "SameSite=\($0)" }].compactMap { $0 }
                    Text(attrs.joined(separator: "; ")).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    ForEach(c.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(InspectChrome.caption)
                            .foregroundStyle(InspectChrome.warnColor)
                    }
                }
                .padding(.horizontal, 10)
                Divider().padding(.leading, 10)
            }
        }
    }
}

// MARK: - WebSocket frames tab

struct NetworkWSTab: View {
    var rich: NetRecord
    @State private var filterDir: String = "all"

    private var frames: [NetWSFrame] {
        if filterDir == "all" { return rich.wsFrames }
        return rich.wsFrames.filter { $0.direction == filterDir }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                InspectChip("All", selected: filterDir == "all") { filterDir = "all" }
                InspectChip("↓ Received", selected: filterDir == "in") { filterDir = "in" }
                InspectChip("↑ Sent", selected: filterDir == "out") { filterDir = "out" }
                Spacer()
                Text("\(rich.wsFrames.count) frames").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(frames) { frame in
                    HStack(spacing: 6) {
                        Image(systemName: frame.direction == "in" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(frame.direction == "in" ? Color(nsColor: .systemBlue) : Color(nsColor: .systemOrange))
                        Text(OrbitDevToolsFormat.milliseconds(frame.time)).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 60)
                        Text("\(frame.length) B").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 50)
                        Text(frame.binary ? "Binary" : "Text").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 40)
                        Text(frame.data).font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 8).frame(minHeight: InspectChrome.rowHeight)
                    Divider().padding(.leading, 8)
                }
            }
        }
    }
}

// MARK: - SSE tab

struct NetworkSSETab: View {
    var rich: NetRecord

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(rich.sseMessages.count) messages").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rich.sseMessages) { msg in
                    HStack(spacing: 6) {
                        Text(OrbitDevToolsFormat.milliseconds(msg.time)).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 60)
                        Text(msg.event).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.attributeNameColor).frame(width: 80)
                        Text(msg.data).font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 8).frame(minHeight: InspectChrome.rowHeight)
                    Divider().padding(.leading, 8)
                }
            }
        }
    }
}

// MARK: - Summary footer

struct NetworkSummaryFooter: View {
    var summary: NetSummary

    var body: some View {
        HStack(spacing: 12) {
            Text("\(summary.filteredRequests)/\(summary.totalRequests) requests")
                .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)

            if summary.transferredBytes > 0 {
                Text("\(OrbitDevToolsFormat.bytes(summary.transferredBytes)) transferred")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            if summary.resourceBytes > 0 {
                Text("\(OrbitDevToolsFormat.bytes(summary.resourceBytes)) resources")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            if let finish = summary.finishMs {
                Text("Finish: \(OrbitDevToolsFormat.milliseconds(finish))")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            if let dcl = summary.dclMs {
                Text("DOMContentLoaded: \(OrbitDevToolsFormat.milliseconds(dcl))")
                    .font(InspectChrome.caption).foregroundStyle(Color(nsColor: .systemBlue))
            }
            if let load = summary.loadMs {
                Text("Load: \(OrbitDevToolsFormat.milliseconds(load))")
                    .font(InspectChrome.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(InspectChrome.surface)
    }
}
