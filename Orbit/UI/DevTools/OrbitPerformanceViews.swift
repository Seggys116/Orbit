import AppKit
import SwiftUI

// MARK: - Vital card

struct PerfVitalCard: View {
    var name: String
    var value: Double?
    var unit: String
    var rating: PerfRating
    var goodThreshold: String
    var poorThreshold: String
    var decimalPlaces: Int = 0

    private var displayText: String {
        guard let v = value else { return "—" }
        if decimalPlaces == 0 { return "\(Int(clamping: Double(v)))\(unit.isEmpty ? "" : " \(unit)")" }
        return String(format: "%.\(decimalPlaces)f\(unit.isEmpty ? "" : " \(unit)")", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(InspectChrome.muted)
                Spacer()
                Circle().fill(rating.color).frame(width: 8, height: 8)
            }
            Text(displayText)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(value == nil ? InspectChrome.muted : rating.color)
            HStack(spacing: 4) {
                Text("Good: \(goodThreshold)")
                Text("·").foregroundStyle(InspectChrome.muted2)
                Text("Poor: \(poorThreshold)")
            }
            .font(InspectChrome.caption)
            .foregroundStyle(InspectChrome.muted)
            if value != nil {
                Text(rating.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(rating.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(rating.color.opacity(0.12)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InspectChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contextMenu {
            if let v = value {
                Button("Copy value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(v)", forType: .string)
                }
            }
        }
    }
}

// MARK: - Navigation timing waterfall

struct PerfNavTimingWaterfall: View {
    var phases: PerfNavigationPhases

    private struct Bar { var label: String; var value: Double; var color: Color }

    private var bars: [Bar] {
        var out: [Bar] = []
        func add(_ label: String, _ ms: Double?, _ color: Color) {
            guard let ms, ms > 0 else { return }
            out.append(Bar(label: label, value: ms, color: color))
        }
        add("Redirect",   phases.redirectDuration,     .purple)
        add("DNS",        phases.dnsDuration,           .blue)
        add("TCP",        phases.tcpDuration,           .cyan)
        add("TLS",        phases.tlsDuration,           .teal)
        add("Request",    phases.requestDuration,       .orange)
        add("Response",   phases.responseDuration,      .green)
        add("DOM",        phases.domProcessingDuration, .yellow)
        add("Load Event", phases.loadEventDuration,     .red)
        return out
    }

    private var maxMs: Double { max(1, bars.map { $0.value }.max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectSectionHeader("Navigation Timing").padding(.bottom, 8)
            if bars.isEmpty {
                Text("Navigation timing not yet available.")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            } else {
                ForEach(bars, id: \.label) { bar in
                    HStack(spacing: 8) {
                        Text(bar.label)
                            .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                            .frame(width: 72, alignment: .trailing)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                                .fill(bar.color.opacity(0.75))
                                .frame(width: max(2, geo.size.width * CGFloat(bar.value / maxMs)), height: 14)
                        }
                        .frame(height: 14)
                        Text(OrbitDevToolsFormat.milliseconds(bar.value))
                            .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .frame(height: 22)
                    .contextMenu {
                        Button("Copy \(bar.label) duration") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(bar.value)ms", forType: .string)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - LCP breakdown

struct PerfLCPBreakdownView: View {
    var entry: PerfLCPEntry
    var phases: PerfLCPPhases?
    var session: OrbitInspectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !entry.selector.isEmpty {
                    Text(entry.selector).font(InspectChrome.mono).foregroundStyle(InspectChrome.tagColor)
                }
                if !entry.url.isEmpty {
                    Text(entry.url).font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.attributeValueColor).lineLimit(1)
                }
                Spacer()
                if entry.nodeID != 0 {
                    InspectTextButton("Reveal") { session.reveal(nodeID: entry.nodeID) }
                }
            }
            if let phases { lcpPhaseBars(phases: phases) }
            if entry.isLazy {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(InspectChrome.badColor).font(.system(size: 11))
                    Text("loading=\"lazy\" — this delays LCP. Remove it.")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.badColor)
                }
            }
        }
        .padding(10)
        .background(InspectChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
    }

    private func lcpPhaseBars(phases: PerfLCPPhases) -> some View {
        let items: [(String, Double?, Color)] = [
            ("TTFB",            phases.ttfb,                 .blue),
            ("Resource delay",  phases.resourceLoadDelay,    .orange),
            ("Resource load",   phases.resourceLoadDuration, .green),
            ("Render delay",    phases.renderDelay,          .red),
        ]
        let total = items.compactMap { $0.1 }.reduce(0.0, +)
        return VStack(alignment: .leading, spacing: 4) {
            Text("LCP phases (total: \(OrbitDevToolsFormat.milliseconds(total > 0 ? total : nil)))")
                .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            ForEach(items, id: \.0) { (label, ms, color) in
                if let ms, ms > 0 {
                    HStack(spacing: 6) {
                        Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                            .frame(width: 100, alignment: .trailing)
                        GeometryReader { geo in
                            let w = geo.size.width * CGFloat(ms / max(1, total))
                            RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                                .fill(color.opacity(0.75))
                                .frame(width: max(2, w), height: 12)
                        }
                        .frame(height: 12)
                        Text(OrbitDevToolsFormat.milliseconds(ms))
                            .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
            }
        }
    }
}

// MARK: - CLS culprits

struct PerfCLSCulpritsView: View {
    var entries: [PerfLayoutShiftEntry]
    var session: OrbitInspectSession
    @State private var selected: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries.prefix(30)) { entry in
                    clsRow(entry)
                }
                if entries.count > 30 {
                    Text("… \(entries.count - 30) more shifts not shown")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private func clsRow(_ entry: PerfLayoutShiftEntry) -> some View {
        let isSelected = selected == entry.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(String(format: "%.4f", entry.value)).font(InspectChrome.mono)
                    .foregroundStyle(entry.value > 0.1 ? InspectChrome.badColor : InspectChrome.warnColor)
                Text("@ \(OrbitDevToolsFormat.milliseconds(entry.startTime))").font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.muted)
                Spacer()
                Text("\(entry.sources.count) source(s)").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            }
            if isSelected {
                ForEach(entry.sources.prefix(5), id: \.nodeID) { src in
                    HStack(spacing: 6) {
                        if !src.selector.isEmpty {
                            Text(src.selector).font(InspectChrome.mono)
                                .foregroundStyle(InspectChrome.tagColor)
                        }
                        Spacer()
                        if src.nodeID != 0 {
                            InspectTextButton("Reveal") { session.reveal(nodeID: src.nodeID) }
                        }
                    }
                    .padding(.leading, 12)
                    if let pr = src.previousRect, let cr = src.currentRect {
                        Text("Before: (\(Int(clamping: Double(pr.x))),\(Int(clamping: Double(pr.y)))) \(Int(clamping: Double(pr.width)))×\(Int(clamping: Double(pr.height)))  →  After: (\(Int(clamping: Double(cr.x))),\(Int(clamping: Double(cr.y)))) \(Int(clamping: Double(cr.width)))×\(Int(clamping: Double(cr.height)))")
                            .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted2)
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isSelected ? InspectChrome.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { selected = isSelected ? nil : entry.id })
        .contextMenu {
            Button("Copy shift value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.value)", forType: .string)
            }
        }
    }
}

// MARK: - Long tasks list

struct PerfLongTasksView: View {
    var tasks: [PerfLongTask]
    @State private var selected: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tasks.prefix(50)) { task in taskRow(task) }
                if tasks.count > 50 {
                    Text("… \(tasks.count - 50) more tasks not shown")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func taskRow(_ task: PerfLongTask) -> some View {
        let isSelected = selected == task.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(OrbitDevToolsFormat.milliseconds(task.duration)).font(InspectChrome.mono)
                    .foregroundStyle(task.duration > 100 ? InspectChrome.badColor : InspectChrome.warnColor)
                Text("start \(OrbitDevToolsFormat.milliseconds(task.startTime))").font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.muted)
                Spacer()
            }
            if isSelected, let attr = task.attribution {
                if !attr.url.isEmpty {
                    Text(attr.url).font(InspectChrome.mono).foregroundStyle(InspectChrome.attributeValueColor)
                        .lineLimit(2).padding(.leading, 12)
                }
                if !attr.containerType.isEmpty {
                    Text("container: \(attr.containerType) \(attr.containerName)")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2).padding(.leading, 12)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isSelected ? InspectChrome.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { selected = isSelected ? nil : task.id })
        .contextMenu {
            Button("Copy start time") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(task.startTime)ms", forType: .string)
            }
            if let url = task.attribution?.url, !url.isEmpty {
                Button("Copy script URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
    }
}

// MARK: - Interactions (INP candidates)

struct PerfInteractionsView: View {
    var entries: [PerfInteractionEntry]
    var worst: PerfInteractionEntry?
    var session: OrbitInspectSession
    @State private var selected: String? = nil

    private var sorted: [PerfInteractionEntry] {
        entries.filter { $0.interactionID > 0 }.sorted { $0.duration > $1.duration }
            .prefix(30).map { $0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sorted) { entry in interactionRow(entry) }
            }
        }
        .frame(maxHeight: 280)
    }

    private func interactionRow(_ entry: PerfInteractionEntry) -> some View {
        let isSelected = selected == entry.id
        let isWorst = entry.id == worst?.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                if isWorst {
                    Image(systemName: "crown.fill").font(.system(size: 10))
                        .foregroundStyle(InspectChrome.warnColor)
                }
                Text(entry.name).font(InspectChrome.mono).foregroundStyle(InspectChrome.ink)
                Text(OrbitDevToolsFormat.milliseconds(entry.duration)).font(InspectChrome.mono)
                    .foregroundStyle(OrbitPerformanceLogic.ratingForINP(entry.duration).color)
                Spacer()
                if entry.nodeID != 0 {
                    InspectTextButton("Target") { session.reveal(nodeID: entry.nodeID) }
                }
            }
            if isSelected {
                VStack(alignment: .leading, spacing: 2) {
                    phaseRow("Input delay", entry.inputDelay)
                    phaseRow("Processing", entry.processingDuration)
                    phaseRow("Presentation delay", entry.presentationDelay)
                }
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isSelected ? InspectChrome.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { selected = isSelected ? nil : entry.id })
        .contextMenu {
            Button("Copy duration") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.duration)ms", forType: .string)
            }
        }
    }

    private func phaseRow(_ label: String, _ ms: Double?) -> some View {
        HStack {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                .frame(width: 130, alignment: .leading)
            Text(OrbitDevToolsFormat.milliseconds(ms)).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
        }
    }
}

// MARK: - Resource summary

struct PerfResourceSummaryView: View {
    var buckets: [PerfResourceBucket]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Type").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
                Text("Count").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(width: 50, alignment: .trailing)
                Text("Transferred").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(buckets) { bucket in
                HStack {
                    Text(bucket.type).font(InspectChrome.caption).foregroundStyle(InspectChrome.ink)
                    Spacer()
                    Text("\(bucket.count)").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                        .frame(width: 50, alignment: .trailing)
                    Text(OrbitDevToolsFormat.bytes(bucket.transferBytes)).font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.muted).frame(width: 90, alignment: .trailing)
                }
                .frame(height: InspectChrome.rowHeight).padding(.horizontal, 8)
                .contextMenu {
                    Button("Copy summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "\(bucket.type): \(bucket.count) requests, \(OrbitDevToolsFormat.bytes(bucket.transferBytes))",
                            forType: .string
                        )
                    }
                }
            }
        }
    }
}

// MARK: - User timing

struct PerfUserTimingView: View {
    var timings: [PerfUserTiming]
    @State private var selected: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(timings.prefix(100)) { timing in
                    timingRow(timing)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private func timingRow(_ timing: PerfUserTiming) -> some View {
        let isSelected = selected == timing.id
        return HStack {
            Image(systemName: timing.isMeasure ? "arrow.left.and.right" : "diamond.fill")
                .font(.system(size: 9))
                .foregroundStyle(timing.isMeasure ? InspectChrome.keywordColor : InspectChrome.warnColor)
            Text(timing.name).font(InspectChrome.mono).foregroundStyle(InspectChrome.ink).lineLimit(1)
            Spacer()
            Text(OrbitDevToolsFormat.milliseconds(timing.startTime)).font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
            if timing.isMeasure {
                Text("(\(OrbitDevToolsFormat.milliseconds(timing.duration)))").font(InspectChrome.mono)
                    .foregroundStyle(InspectChrome.muted2)
            }
        }
        .frame(height: InspectChrome.rowHeight).padding(.horizontal, 8)
        .background(isSelected ? InspectChrome.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { selected = isSelected ? nil : timing.id })
        .contextMenu {
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(timing.name, forType: .string)
            }
            Button("Copy start time") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(timing.startTime)ms", forType: .string)
            }
        }
    }
}

// MARK: - Insights

struct PerfInsightsView: View {
    var insights: [PerfInsight]
    var session: OrbitInspectSession
    @State private var selected: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            ForEach(insights) { insight in insightRow(insight) }
        }
    }

    private func insightRow(_ insight: PerfInsight) -> some View {
        let isSelected = selected == insight.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconFor(insight.severity)).foregroundStyle(insight.severity.color)
                    .font(.system(size: 12, weight: .semibold))
                Text(insight.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(InspectChrome.ink)
                Spacer()
            }
            if isSelected {
                Text(insight.detail).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let url = insight.url {
                        InspectTextButton("Open URL") {
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                    }
                    if let nid = insight.nodeID {
                        InspectTextButton("Reveal Element") { session.reveal(nodeID: nid) }
                    }
                }
            }
        }
        .padding(10)
        .background(InspectChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { selected = isSelected ? nil : insight.id })
        .contextMenu {
            Button("Copy insight") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(insight.title)\n\(insight.detail)", forType: .string)
            }
        }
    }

    private func iconFor(_ rating: PerfRating) -> String {
        switch rating {
        case .good: return "checkmark.circle.fill"
        case .needsImprovement: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.circle.fill"
        case .unknown: return "info.circle.fill"
        }
    }
}

// MARK: - Timeline Canvas view

private let kTrackHeight: CGFloat = 40
private let kRulerHeight: CGFloat = 22
private let kFilmstripHeight: CGFloat = 66
private let kControlsHeight: CGFloat = 30

struct PerfTimelineCanvasView: View {
    var session: OrbitInspectSession
    private var model: OrbitPerformanceModel { session.performance }

    @State private var canvasWidth: CGFloat = 1
    @State private var hoverTime: Double? = nil
    @State private var selDragStart: Double? = nil

    private var recording: PerfRecording { model.displayRecording }
    private var duration: Double { max(1, recording.duration) }
    private var hasFilmstrip: Bool { !recording.filmstripFrames.isEmpty }

    private var visibleRange: ClosedRange<Double> {
        OrbitPerformanceLogic.visibleRange(
            zoom: model.timelineZoom,
            offset: model.timelineOffset,
            duration: duration
        )
    }

    private var tracks: [PerfTrackDescriptor] {
        PerfTrackDescriptor.tracks(for: recording)
    }

    private var trackAreaHeight: CGFloat {
        CGFloat(tracks.count) * kTrackHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // Time ruler
            rulerCanvas
            InspectDivider()

            // Filmstrip (only during reload-and-record)
            if hasFilmstrip {
                PerfFilmstripRow(frames: recording.filmstripFrames,
                                  range: visibleRange, duration: duration)
                    .frame(height: kFilmstripHeight)
                InspectDivider()
            }

            // Tracks
            trackCanvas
                .frame(height: trackAreaHeight)
                .clipped()
                .overlay {
                    // Scroll/pinch: pan and zoom. DragGesture: create time selection.
                    PerfScrollCapture(
                        onScroll: { dx, dy in model.applyTimelineScroll(deltaX: dx, deltaY: dy) },
                        onMagnify: { mag in model.applyTimelineZoom(factor: 1 + mag) }
                    )
                }
                .gesture(selectionGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverTime = OrbitPerformanceLogic.timeAtX(
                            Double(loc.x), in: visibleRange, width: Double(canvasWidth))
                    case .ended:
                        hoverTime = nil
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { canvasWidth = $0 })

            InspectDivider()

            // Hover readout + controls
            HStack(spacing: 8) {
                if let ht = hoverTime {
                    Text(OrbitDevToolsFormat.milliseconds(ht))
                        .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                }
                if let sel = model.timelineSelection {
                    Text("Selected: \(OrbitDevToolsFormat.milliseconds(sel.lowerBound)) – \(OrbitDevToolsFormat.milliseconds(sel.upperBound))")
                        .font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                    InspectTextButton("Clear") { model.timelineSelection = nil }
                }
                Spacer()
                controlsRow
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .frame(height: kControlsHeight)

            // Selection detail list
            if let sel = model.timelineSelection {
                InspectDivider()
                PerfSelectionDetailList(recording: recording, range: sel, session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Ruler

    private var rulerCanvas: some View {
        Canvas { ctx, size in
            drawRuler(ctx: &ctx, size: size, range: visibleRange)
        }
        .frame(height: kRulerHeight)
    }

    // MARK: Track canvas

    private var trackCanvas: some View {
        let capturedTracks = tracks
        let capturedRange = visibleRange
        let capturedRecording = recording
        let capturedHover = hoverTime
        let capturedSelection = model.timelineSelection
        return Canvas { ctx, size in
            let w = size.width
            for (idx, track) in capturedTracks.enumerated() {
                let yBase = CGFloat(idx) * kTrackHeight
                if idx % 2 == 1 {
                    ctx.fill(Path(CGRect(x: 0, y: yBase, width: w, height: kTrackHeight)),
                             with: .color(InspectChrome.ink.opacity(0.02)))
                }
                var divLine = Path()
                divLine.move(to: CGPoint(x: 0, y: yBase + kTrackHeight - 0.5))
                divLine.addLine(to: CGPoint(x: w, y: yBase + kTrackHeight - 0.5))
                ctx.stroke(divLine, with: .color(InspectChrome.muted.opacity(0.15)), lineWidth: 0.5)
                ctx.draw(
                    Text(track.label).font(.system(size: 9, weight: .medium)).foregroundStyle(InspectChrome.muted),
                    at: CGPoint(x: 4, y: yBase + 4), anchor: .topLeading
                )
                let contentRect = CGRect(x: 0, y: yBase + 14, width: w, height: kTrackHeight - 16)
                track.draw(&ctx, contentRect, capturedRange, Double(w), capturedRecording)
            }
            if let ht = capturedHover {
                let x = CGFloat(OrbitPerformanceLogic.xAtTime(ht, in: capturedRange, width: Double(w)))
                var hoverLine = Path()
                hoverLine.move(to: CGPoint(x: x, y: 0))
                hoverLine.addLine(to: CGPoint(x: x, y: CGFloat(capturedTracks.count) * kTrackHeight))
                ctx.stroke(hoverLine, with: .color(InspectChrome.muted.opacity(0.4)), lineWidth: 1)
            }
            if let sel = capturedSelection {
                let x1 = CGFloat(OrbitPerformanceLogic.xAtTime(sel.lowerBound, in: capturedRange, width: Double(w)))
                let x2 = CGFloat(OrbitPerformanceLogic.xAtTime(sel.upperBound, in: capturedRange, width: Double(w)))
                ctx.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1),
                                     height: CGFloat(capturedTracks.count) * kTrackHeight)),
                         with: .color(.accentColor.opacity(0.12)))
                // Selection edge lines
                var edge1 = Path(); edge1.move(to: CGPoint(x: x1, y: 0)); edge1.addLine(to: CGPoint(x: x1, y: CGFloat(capturedTracks.count) * kTrackHeight))
                var edge2 = Path(); edge2.move(to: CGPoint(x: x2, y: 0)); edge2.addLine(to: CGPoint(x: x2, y: CGFloat(capturedTracks.count) * kTrackHeight))
                ctx.stroke(edge1, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                ctx.stroke(edge2, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    // MARK: Drag-to-select gesture (scroll/pinch pans/zooms via PerfScrollCapture)

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let w = Double(canvasWidth)
                guard w > 0 else { return }
                let startT = OrbitPerformanceLogic.timeAtX(Double(value.startLocation.x), in: visibleRange, width: w)
                let currentT = OrbitPerformanceLogic.timeAtX(Double(value.location.x), in: visibleRange, width: w)
                selDragStart = startT
                let lo = min(startT, currentT)
                let hi = max(startT, currentT)
                if hi > lo { model.timelineSelection = lo...hi }
            }
            .onEnded { value in
                let w = Double(canvasWidth)
                guard w > 0 else { return }
                let startT = selDragStart ?? OrbitPerformanceLogic.timeAtX(Double(value.startLocation.x), in: visibleRange, width: w)
                let endT = OrbitPerformanceLogic.timeAtX(Double(value.location.x), in: visibleRange, width: w)
                let lo = min(startT, endT)
                let hi = max(startT, endT)
                if hi - lo < 2 {
                    model.timelineSelection = nil  // tap, not drag: clear selection
                } else {
                    model.timelineSelection = lo...hi
                }
                selDragStart = nil
            }
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 8) {
            InspectTextButton("−") { model.applyTimelineZoom(factor: 0.75) }
            Text(String(format: "%.0f×", model.timelineZoom)).font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted).frame(width: 28, alignment: .center)
            InspectTextButton("+") { model.applyTimelineZoom(factor: 1.33) }
            InspectTextButton("Reset") { model.timelineZoom = 1; model.timelineOffset = 0 }
            Spacer()
            Text("Duration: \(OrbitDevToolsFormat.milliseconds(duration))").font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
            if let fps = recording.averageFPS {
                Text(String(format: "Avg %.0f fps", fps)).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            }
            if !model.canResolveWebProcess {
                Text("CPU/Memory: web process n/a").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            }
        }
    }

    // MARK: Ruler drawing

    private func drawRuler(ctx: inout GraphicsContext, size: CGSize, range: ClosedRange<Double>) {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let step = niceTickStep(span: span, targetCount: Int(size.width / 80))
        var t = ceil(range.lowerBound / step) * step
        while t <= range.upperBound + step * 0.01 {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(t, in: range, width: Double(size.width)))
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: size.height - 5))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(tick, with: .color(InspectChrome.muted.opacity(0.4)), lineWidth: 1)
            let label = t >= 1000 ? String(format: "%.1fs", t / 1000) : "\(Int(clamping: Double(t)))ms"
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(InspectChrome.muted),
                     at: CGPoint(x: x + 2, y: size.height / 2 - 5), anchor: .topLeading)
            t += step
        }
    }

    private func niceTickStep(span: Double, targetCount: Int) -> Double {
        guard targetCount > 0, span > 0 else { return 100 }
        let raw = span / Double(max(1, targetCount))
        for candidate in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000] {
            if candidate >= raw { return candidate }
        }
        return 10000
    }
}

// MARK: - Filmstrip row

struct PerfFilmstripRow: View {
    var frames: [PerfFilmstripFrame]
    var range: ClosedRange<Double>
    var duration: Double

    private let thumbWidth: CGFloat = 80
    private let thumbHeight: CGFloat = kFilmstripHeight - 4

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.05)
                ForEach(frames.filter { ts in ts.timestamp >= range.lowerBound && ts.timestamp <= range.upperBound }) { frame in
                    if let img = frame.nsImage {
                        let x = CGFloat(OrbitPerformanceLogic.xAtTime(frame.timestamp, in: range, width: w))
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: thumbHeight)
                            .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous))
                            .offset(x: max(0, x - thumbWidth / 2), y: 2)
                    }
                }
            }
        }
    }
}

// MARK: - Selection detail list

struct PerfSelectionDetailList: View {
    var recording: PerfRecording
    var range: ClosedRange<Double>
    var session: OrbitInspectSession

    private struct EventRow: Identifiable {
        var id: String
        var kind: String
        var label: String
        var startTime: Double
        var duration: Double
        var nodeID: Int
        var url: String
    }

    private var eventsInRange: [EventRow] {
        var out: [EventRow] = []
        for task in recording.longTaskEntries
            where task.startTime <= range.upperBound && task.startTime + task.duration >= range.lowerBound {
            out.append(EventRow(id: task.id, kind: "Long Task",
                                label: task.attribution?.url.isEmpty == false ? task.attribution!.url : "Long Task",
                                startTime: task.startTime, duration: task.duration,
                                nodeID: 0, url: task.attribution?.url ?? ""))
        }
        for entry in recording.interactionEntries
            where entry.startTime >= range.lowerBound && entry.startTime <= range.upperBound {
            out.append(EventRow(id: entry.id, kind: "Interaction",
                                label: entry.name,
                                startTime: entry.startTime, duration: entry.duration,
                                nodeID: entry.nodeID, url: ""))
        }
        for entry in recording.layoutShiftEntries
            where entry.startTime >= range.lowerBound && entry.startTime <= range.upperBound {
            out.append(EventRow(id: entry.id, kind: "Layout Shift",
                                label: String(format: "CLS %.4f", entry.value),
                                startTime: entry.startTime, duration: 0,
                                nodeID: entry.sources.first?.nodeID ?? 0, url: ""))
        }
        let allTimings = recording.markEntries + recording.measureEntries
        for timing in allTimings
            where timing.startTime >= range.lowerBound && timing.startTime <= range.upperBound {
            out.append(EventRow(id: timing.id, kind: timing.isMeasure ? "Measure" : "Mark",
                                label: timing.name, startTime: timing.startTime, duration: timing.duration,
                                nodeID: 0, url: ""))
        }
        return out.sorted { $0.startTime < $1.startTime }.prefix(200).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Events in selection (\(eventsInRange.count))")
                    .font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 5)
            .background(InspectChrome.surface)
            if eventsInRange.isEmpty {
                Text("No events in the selected range.")
                    .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(eventsInRange) { event in
                            eventRow(event)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func eventRow(_ event: EventRow) -> some View {
        HStack(spacing: 8) {
            Text(event.kind).font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted).frame(width: 80, alignment: .leading)
            Text(event.label).font(InspectChrome.mono).foregroundStyle(InspectChrome.ink).lineLimit(1)
            Spacer()
            Text(OrbitDevToolsFormat.milliseconds(event.startTime)).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
            if event.duration > 0 {
                Text("(\(OrbitDevToolsFormat.milliseconds(event.duration)))").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted2)
            }
            if event.nodeID != 0 {
                InspectTextButton("→") { session.reveal(nodeID: event.nodeID) }
            }
        }
        .frame(height: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
        .contextMenu {
            Button("Copy label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.label, forType: .string)
            }
            Button("Copy start time") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(event.startTime)ms", forType: .string)
            }
        }
    }
}

// MARK: - Track descriptor (pure data + draw closure)

struct PerfTrackDescriptor {
    var label: String
    var draw: (inout GraphicsContext, CGRect, ClosedRange<Double>, Double, PerfRecording) -> Void

    static func tracks(for recording: PerfRecording) -> [PerfTrackDescriptor] {
        var out: [PerfTrackDescriptor] = []
        if !recording.frameSamples.isEmpty {
            out.append(.init(label: "FPS / Frames") { ctx, rect, range, w, rec in
                drawFrameTrack(&ctx, rect: rect, range: range, w: w, samples: rec.frameSamples)
            })
        }
        if recording.nativeSamples.contains(where: { $0.resolved }) {
            out.append(.init(label: "CPU %") { ctx, rect, range, w, rec in
                drawCPUTrack(&ctx, rect: rect, range: range, w: w, samples: rec.nativeSamples)
            })
            out.append(.init(label: "Memory") { ctx, rect, range, w, rec in
                drawMemoryTrack(&ctx, rect: rect, range: range, w: w, samples: rec.nativeSamples)
            })
        }
        if !recording.networkRecords.isEmpty {
            out.append(.init(label: "Network") { ctx, rect, range, w, rec in
                drawNetworkTrack(&ctx, rect: rect, range: range, w: w, records: rec.networkRecords)
            })
        }
        if !recording.longTaskEntries.isEmpty {
            out.append(.init(label: "Main Thread") { ctx, rect, range, w, rec in
                drawLongTaskTrack(&ctx, rect: rect, range: range, w: w, tasks: rec.longTaskEntries)
            })
        }
        if !recording.layoutShiftEntries.isEmpty {
            out.append(.init(label: "Layout Shifts") { ctx, rect, range, w, rec in
                drawShiftTrack(&ctx, rect: rect, range: range, w: w, entries: rec.layoutShiftEntries)
            })
        }
        out.append(.init(label: "Markers") { ctx, rect, range, w, rec in
            drawMarkerTrack(&ctx, rect: rect, range: range, w: w, recording: rec)
        })
        if !recording.interactionEntries.isEmpty {
            out.append(.init(label: "Interactions") { ctx, rect, range, w, rec in
                drawInteractionTrack(&ctx, rect: rect, range: range, w: w, entries: rec.interactionEntries)
            })
        }
        if !recording.userTimings.isEmpty {
            out.append(.init(label: "User Timing") { ctx, rect, range, w, rec in
                drawUserTimingTrack(&ctx, rect: rect, range: range, w: w, timings: rec.userTimings)
            })
        }
        return out
    }

    // MARK: - Drawing functions

    static func drawFrameTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                range: ClosedRange<Double>, w: Double, samples: [PerfFrameSample]) {
        for sample in samples where sample.timestamp >= range.lowerBound && sample.timestamp <= range.upperBound {
            let cls = OrbitPerformanceLogic.classifyFrame(sample.duration)
            guard cls != .smooth else { continue }
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(sample.timestamp, in: range, width: w))
            let frac = min(1.0, sample.duration / 50.0)
            let barH = max(3, rect.height * CGFloat(frac))
            let color: Color = cls == .slightDrop ? .orange : .red
            ctx.fill(Path(CGRect(x: x - 1, y: rect.maxY - barH, width: 2, height: barH)),
                     with: .color(color.opacity(0.85)))
        }
    }

    static func drawCPUTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                              range: ClosedRange<Double>, w: Double, samples: [PerfNativeSample]) {
        let visible = samples.filter { $0.timestamp >= range.lowerBound && $0.timestamp <= range.upperBound && $0.resolved }
        guard visible.count >= 2 else { return }
        var path = Path()
        for (i, s) in visible.enumerated() {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(s.timestamp, in: range, width: w))
            let y = rect.minY + rect.height * CGFloat(1 - min(1, s.cpuPercent / 100))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(.orange.opacity(0.8)), lineWidth: 1.5)
    }

    static func drawMemoryTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                 range: ClosedRange<Double>, w: Double, samples: [PerfNativeSample]) {
        let visible = samples.filter { $0.timestamp >= range.lowerBound && $0.timestamp <= range.upperBound && $0.resolved }
        guard visible.count >= 2 else { return }
        let maxMem = max(1.0, visible.map { Double($0.memoryBytes) }.max() ?? 1)
        var path = Path()
        for (i, s) in visible.enumerated() {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(s.timestamp, in: range, width: w))
            let y = rect.minY + rect.height * CGFloat(1 - Double(s.memoryBytes) / maxMem)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(.blue.opacity(0.7)), lineWidth: 1.5)
    }

    static func drawNetworkTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                  range: ClosedRange<Double>, w: Double, records: [PerfNetworkRecord]) {
        let visible = records.filter { r in
            guard let st = r.startTime else { return false }
            return st + (r.duration ?? 0) >= range.lowerBound && st <= range.upperBound
        }
        let rowH: CGFloat = min(8, visible.isEmpty ? 8 : rect.height / CGFloat(visible.count + 1))
        for (i, record) in visible.enumerated() {
            guard let st = record.startTime else { continue }
            let x1 = CGFloat(OrbitPerformanceLogic.xAtTime(st, in: range, width: w))
            let x2 = CGFloat(OrbitPerformanceLogic.xAtTime(st + (record.duration ?? 0), in: range, width: w))
            let y = rect.minY + CGFloat(i) * (rowH + 1)
            let barRect = CGRect(x: x1, y: y, width: max(2, x2 - x1), height: rowH)
            ctx.fill(Path(roundedRect: barRect, cornerRadius: 2), with: .color(networkBarColor(record.resourceType).opacity(0.7)))
        }
    }

    static func drawLongTaskTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                   range: ClosedRange<Double>, w: Double, tasks: [PerfLongTask]) {
        for task in tasks {
            let endTime = task.startTime + task.duration
            guard endTime >= range.lowerBound && task.startTime <= range.upperBound else { continue }
            let x1 = CGFloat(OrbitPerformanceLogic.xAtTime(task.startTime, in: range, width: w))
            let x2 = CGFloat(OrbitPerformanceLogic.xAtTime(endTime, in: range, width: w))
            let barRect = CGRect(x: x1, y: rect.minY, width: max(2, x2 - x1), height: rect.height)
            ctx.fill(Path(roundedRect: barRect, cornerRadius: 2), with: .color(InspectChrome.badColor.opacity(0.55)))
        }
    }

    static func drawShiftTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                range: ClosedRange<Double>, w: Double, entries: [PerfLayoutShiftEntry]) {
        for entry in entries where !entry.hadRecentInput && entry.startTime >= range.lowerBound && entry.startTime <= range.upperBound {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(entry.startTime, in: range, width: w))
            let barH = max(3, min(rect.height, CGFloat(entry.value / 0.25) * rect.height))
            ctx.fill(Path(CGRect(x: x - 1, y: rect.maxY - barH, width: 3, height: barH)),
                     with: .color(.orange.opacity(0.8)))
        }
    }

    static func drawMarkerTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                 range: ClosedRange<Double>, w: Double, recording: PerfRecording) {
        let markers: [(String, Double?, Color)] = [
            ("FP",   recording.paintEntries.first { $0.name == "first-paint" }?.startTime,                      .gray),
            ("FCP",  recording.paintEntries.first { $0.name == "first-contentful-paint" }?.startTime,           .green),
            ("LCP",  recording.lcpEntries.last.map { $0.renderTime ?? $0.loadTime ?? $0.startTime },            .blue),
            ("DCL",  recording.navigationEntry?.domContentLoadedEventEnd,                                        .orange),
            ("Load", recording.navigationEntry?.loadEventEnd,                                                    .red),
        ]
        for (label, ts, color) in markers {
            guard let ts, ts >= range.lowerBound && ts <= range.upperBound else { continue }
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(ts, in: range, width: w))
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.5)
            ctx.draw(Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(color),
                     at: CGPoint(x: x + 2, y: rect.minY + 1), anchor: .topLeading)
        }
    }

    static func drawInteractionTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                      range: ClosedRange<Double>, w: Double,
                                      entries: [PerfInteractionEntry]) {
        for entry in entries where entry.interactionID > 0 && entry.startTime >= range.lowerBound && entry.startTime <= range.upperBound {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(entry.startTime, in: range, width: w))
            let barH = max(4, min(rect.height, CGFloat(entry.duration / 500) * rect.height + 4))
            let color: Color = OrbitPerformanceLogic.ratingForINP(entry.duration) == .good ? .green : .orange
            ctx.fill(Path(CGRect(x: x - 1, y: rect.maxY - barH, width: 3, height: barH)),
                     with: .color(color.opacity(0.8)))
        }
    }

    static func drawUserTimingTrack(_ ctx: inout GraphicsContext, rect: CGRect,
                                     range: ClosedRange<Double>, w: Double,
                                     timings: [PerfUserTiming]) {
        var measRow: CGFloat = 0
        let rowH: CGFloat = min(10, rect.height / 2)
        for timing in timings where timing.startTime >= range.lowerBound && timing.startTime <= range.upperBound {
            let x = CGFloat(OrbitPerformanceLogic.xAtTime(timing.startTime, in: range, width: w))
            if timing.isMeasure {
                let x2 = CGFloat(OrbitPerformanceLogic.xAtTime(timing.startTime + timing.duration, in: range, width: w))
                let barRect = CGRect(x: x, y: rect.minY + measRow, width: max(2, x2 - x), height: rowH)
                ctx.fill(Path(roundedRect: barRect, cornerRadius: 2), with: .color(InspectChrome.keywordColor.opacity(0.5)))
                measRow = (measRow + rowH + 1).truncatingRemainder(dividingBy: rect.height)
            } else {
                var mark = Path()
                mark.move(to: CGPoint(x: x, y: rect.minY))
                mark.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.stroke(mark, with: .color(.orange.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    private static func networkBarColor(_ type: String) -> Color {
        switch type {
        case "document": return .blue
        case "script": return .yellow
        case "stylesheet": return .purple
        case "image": return .green
        case "font": return .orange
        case "fetch", "xhr": return .cyan
        default: return .gray
        }
    }
}
