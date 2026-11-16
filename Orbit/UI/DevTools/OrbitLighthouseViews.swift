import AppKit
import SwiftUI

/// Lighthouse bands: 90 to 100 good, 50 to 89 needs improvement, 0 to 49 poor; colour is always paired with a number, word or symbol.
enum LHStyle {
    static func color(score: Int) -> Color {
        switch LHScores.band(for: score) {
        case .good: return OrbitNeutral.good
        case .needsImprovement: return OrbitNeutral.warn
        case .poor: return OrbitNeutral.bad
        }
    }

    static func word(score: Int) -> String {
        switch LHScores.band(for: score) {
        case .good: return "Good"
        case .needsImprovement: return "Needs work"
        case .poor: return "Poor"
        }
    }

    static func color(_ rating: LHRating) -> Color {
        switch rating {
        case .good: return OrbitNeutral.good
        case .needsImprovement: return OrbitNeutral.warn
        case .poor: return OrbitNeutral.bad
        }
    }

    static func word(_ rating: LHRating) -> String {
        switch rating {
        case .good: return "Good"
        case .needsImprovement: return "Needs improvement"
        case .poor: return "Poor"
        }
    }

    /// Matches the wording under the category gauges, and is short enough for the narrowest tile.
    static func shortWord(_ rating: LHRating) -> String {
        switch rating {
        case .good: return "Good"
        case .needsImprovement: return "Needs work"
        case .poor: return "Poor"
        }
    }

    static func symbol(_ rating: LHRating) -> String {
        switch rating {
        case .good: return "checkmark.circle.fill"
        case .needsImprovement: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.circle.fill"
        }
    }

    static func color(_ band: LHAuditBand) -> Color {
        switch band {
        case .passed: return OrbitNeutral.good
        case .warning: return OrbitNeutral.warn
        case .failed: return OrbitNeutral.bad
        case .informative, .notApplicable: return OrbitNeutral.muted
        }
    }

    static func symbol(_ audit: LHAuditResult) -> String {
        switch audit.status {
        case .manual: return "hand.raised"
        case .informative: return "info.circle"
        case .notApplicable: return "minus.circle"
        default:
            switch audit.band {
            case .passed: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.circle.fill"
            case .informative: return "info.circle"
            case .notApplicable: return "minus.circle"
            }
        }
    }

    static func word(_ audit: LHAuditResult) -> String {
        switch audit.status {
        case .manual: return "Manual check"
        case .informative: return "Informational"
        case .notApplicable: return "Not applicable"
        default:
            switch audit.band {
            case .passed: return "Passed"
            case .warning: return "Warning"
            case .failed: return "Failed"
            case .informative: return "Informational"
            case .notApplicable: return "Not applicable"
            }
        }
    }
}

/// Which audits the report shows.
enum LHAuditFilter: String, CaseIterable, Identifiable {
    case all, failed, warnings, passed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .failed: return "Failed"
        case .warnings: return "Warnings"
        case .passed: return "Passed"
        }
    }

    func includes(_ band: LHAuditBand) -> Bool {
        switch self {
        case .all: return true
        case .failed: return band == .failed
        case .warnings: return band == .warning
        case .passed: return band == .passed
        }
    }

    func count(in audits: [LHAuditResult]) -> Int {
        audits.filter { includes($0.band) }.count
    }
}

/// A score ring that sweeps to its value. The number is always shown, and the ring is skipped under Reduce Motion.
struct LHGaugeView: View {
    var score: Int?
    var size: CGFloat = 80
    var label: String = ""

    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(OrbitNeutral.chip, lineWidth: lineWidth)
            if let s = score {
                Circle()
                    .trim(from: 0, to: CGFloat(shown))
                    .stroke(LHStyle.color(score: s), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(s)")
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(OrbitNeutral.ink)
                    .monospacedDigit()
            } else {
                Text("n/a")
                    .font(.system(size: size * 0.19))
                    .foregroundStyle(OrbitNeutral.muted)
            }
        }
        .frame(width: size, height: size)
        .onAppear { sweep(to: score) }
        .onChange(of: score) { _, value in sweep(to: value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func sweep(to value: Int?) {
        let target = Double(max(0, min(100, value ?? 0))) / 100
        withOrbitAnimation(OrbitMotion.dramatic) { shown = target }
    }

    private var accessibilityText: String {
        let name = label.isEmpty ? "Score" : "\(label) score"
        guard let score else { return "\(name) not available" }
        return "\(name) \(score) out of 100, \(LHStyle.word(score: score))"
    }

    private var lineWidth: CGFloat { max(4, size / 12) }
}

/// The metric tiles. When `onToggle` is given each tile opens to say what the metric is, why it rated as it did,
/// how to improve it and what evidence the run found; without it the tiles are plain read-outs.
struct LHMetricTilesView: View {
    var metrics: LHMetrics
    var device: LHDevice
    var audits: [LHAuditResult] = []
    var session: OrbitInspectSession? = nil
    var expandedIDs: Set<String> = []
    var onToggle: ((String) -> Void)? = nil

    static func detailID(_ kind: LHMetricKind) -> String { "metric-\(kind.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Core Web Vitals", kinds: LHMetricKind.allCases.filter(\.isCoreWebVital))
            group("Other metrics", kinds: LHMetricKind.allCases.filter { !$0.isCoreWebVital })
        }
    }

    private func group(_ title: String, kinds: [LHMetricKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(OrbitNeutral.muted)
            // Tiles share the row evenly and the last row stretches; rows hold every tile if they fit, then two, then one.
            ViewThatFits(in: .horizontal) {
                rows(kinds, perRow: kinds.count)
                rows(kinds, perRow: 2)
                rows(kinds, perRow: 1)
            }
            ForEach(kinds.filter { expandedIDs.contains(Self.detailID($0)) }) { kind in
                LHMetricDetailView(kind: kind, metrics: metrics,
                                   audit: audits.first { $0.id == kind.auditID }, session: session)
            }
        }
    }

    private func rows(_ kinds: [LHMetricKind], perRow: Int) -> some View {
        let chunks = stride(from: 0, to: kinds.count, by: max(perRow, 1)).map {
            Array(kinds[$0 ..< min($0 + perRow, kinds.count)])
        }
        return VStack(spacing: 8) {
            ForEach(chunks, id: \.first!.id) { chunk in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(chunk) { kind in
                        LHMetricTile(kind: kind, value: kind.value(in: metrics),
                                     expanded: onToggle == nil ? nil : expandedIDs.contains(Self.detailID(kind))) {
                            onToggle?(Self.detailID(kind))
                        }
                        .frame(minWidth: 150, maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

struct LHMetricTile: View {
    var kind: LHMetricKind
    var value: Double?
    /// Nil when the tile cannot be opened; otherwise whether its detail is showing.
    var expanded: Bool? = nil
    var onToggle: () -> Void = {}

    private var rating: LHRating? { value.map { kind.rating(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let rating {
                    Image(systemName: LHStyle.symbol(rating))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LHStyle.color(rating))
                }
                Text(kind.title)
                    .font(InspectChrome.sectionTitle)
                    .foregroundStyle(OrbitNeutral.muted)
                Spacer(minLength: 0)
                if let expanded {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(OrbitNeutral.muted2)
                }
            }
            if let value {
                Text(kind.format(value))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrbitNeutral.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let rating {
                    Text(LHStyle.shortWord(rating))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LHStyle.color(rating))
                }
            } else {
                Text("n/a")
                    .font(InspectChrome.mono)
                    .foregroundStyle(OrbitNeutral.muted2)
            }
            scale
            Text(kind == .inp && value == nil ? "Measured in Timespan mode." : kind.thresholdText)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous).fill(OrbitNeutral.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
                .strokeBorder(OrbitNeutral.line, lineWidth: 1)
        )
        .overlay {
            if expanded != nil { InspectHitTarget { onToggle() } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(expanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
        .accessibilityAddTraits(expanded != nil ? .isButton : [])
    }

    /// Three zones (good, needs improvement, poor) sized by the thresholds, with a marker where the value falls.
    private var scale: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let ceiling = kind.poorLimit * 1.5
            let goodWidth = width * CGFloat(kind.goodLimit / ceiling)
            let midWidth = width * CGFloat((kind.poorLimit - kind.goodLimit) / ceiling)
            let radius = OrbitRadius.concentric(outer: OrbitRadius.md, inset: 8)
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    Rectangle().fill(OrbitNeutral.good.opacity(0.55)).frame(width: goodWidth)
                    Rectangle().fill(OrbitNeutral.warn.opacity(0.55)).frame(width: midWidth)
                    Rectangle().fill(OrbitNeutral.bad.opacity(0.55))
                }
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                if let value {
                    let position = width * CGFloat(min(max(value / ceiling, 0), 1))
                    Capsule()
                        .fill(OrbitNeutral.ink)
                        .frame(width: 3, height: 10)
                        .offset(x: min(max(position - 1.5, 0), width - 3))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        guard let value, let rating else { return "\(kind.fullName), not available" }
        return "\(kind.fullName), \(kind.format(value)), \(LHStyle.word(rating)). \(kind.thresholdText)"
    }
}

struct LHAuditRowView: View {
    var audit: LHAuditResult
    var expanded: Bool
    var session: OrbitInspectSession
    /// The largest estimated time saving in the list, so every bar shares one scale. Nil hides the bar.
    var savingsScaleMs: Double? = nil
    var onToggle: () -> Void

    private var expandable: Bool {
        !audit.items.isEmpty || audit.docsURL != nil || audit.savingsNote != nil || audit.howToFix != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                auditDetail
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .orbitAnimation(OrbitMotion.quick, value: expanded)
        .background(expanded ? OrbitNeutral.sunk : Color.clear)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: LHStyle.symbol(audit))
                .font(.system(size: 11))
                .foregroundStyle(LHStyle.color(audit.band))
                .frame(width: 16)

            Text(audit.title)
                .font(InspectChrome.label)
                .foregroundStyle(OrbitNeutral.ink)
                .lineLimit(2)

            Spacer(minLength: 0)

            if audit.savingsMs != nil || audit.savingsBytes != nil {
                LHSavingsView(ms: audit.savingsMs, bytes: audit.savingsBytes, scaleMs: savingsScaleMs)
            } else {
                Text(audit.displayValue)
                    .font(InspectChrome.mono)
                    .foregroundStyle(OrbitNeutral.muted)
                    .lineLimit(1)
            }

            if expandable {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(OrbitNeutral.muted2)
            }
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget { if expandable { onToggle() } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(audit.title), \(LHStyle.word(audit)). \(audit.displayValue)")
        .accessibilityValue(expandable ? (expanded ? "Expanded" : "Collapsed") : "")
        .accessibilityAddTraits(expandable ? .isButton : [])
    }

    private var auditDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(audit.description)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if let note = audit.savingsNote {
                Text(note)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fix = audit.howToFix, audit.band == .failed || audit.band == .warning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How to fix")
                        .font(InspectChrome.sectionTitle)
                        .foregroundStyle(OrbitNeutral.muted)
                    Text(fix)
                        .font(InspectChrome.caption)
                        .foregroundStyle(OrbitNeutral.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let docs = audit.docsURL, let url = URL(string: docs) {
                InspectTextButton("Learn more", systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
            }

            if !audit.items.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(audit.items) { item in
                        LHAuditItemRow(item: item, session: session)
                        Divider()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                        .fill(OrbitNeutral.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                                .strokeBorder(OrbitNeutral.line, lineWidth: 1)
                        )
                )
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.bottom, 10)
    }
}

/// One piece of evidence: the element, resource or number that caused an audit result, with Reveal and copy actions.
struct LHAuditItemRow: View {
    var item: LHAuditItem
    var session: OrbitInspectSession

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let label = item.label {
                    Text(label)
                        .font(InspectChrome.mono)
                        .foregroundStyle(OrbitNeutral.ink)
                        .lineLimit(3)
                }
                if let url = item.url, !url.isEmpty {
                    Text(url)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let selector = item.selector, !selector.isEmpty {
                    Text(selector)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let snippet = item.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.muted)
                        .lineLimit(2)
                }
                if let sub = item.subLabel, !sub.isEmpty {
                    Text(sub)
                        .font(InspectChrome.caption)
                        .foregroundStyle(OrbitNeutral.muted2)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if let ms = item.wastedMs, ms > 0 {
                Text(OrbitDevToolsFormat.milliseconds(ms))
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(OrbitNeutral.warn)
            } else if let bytes = item.wastedBytes, bytes > 0 {
                Text(OrbitDevToolsFormat.bytes(bytes))
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(OrbitNeutral.warn)
            }

            // Reveal in Elements: selects the node and switches panels.
            if let nodeID = item.nodeID, nodeID > 0 {
                InspectTextButton("Reveal", systemImage: "scope") { session.reveal(nodeID: nodeID) }
            }
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contextMenu {
            if let label = item.label {
                Button("Copy label") { session.copy(label) }
            }
            if let url = item.url {
                Button("Copy URL") { session.copy(url) }
            }
            if let selector = item.selector, !selector.isEmpty {
                Button("Copy selector") { session.copy(selector) }
            }
        }
    }
}

/// Estimated saving as text and a bar. The text always carries the numbers, the bar only helps compare rows.
struct LHSavingsView: View {
    var ms: Double?
    var bytes: Int?
    var scaleMs: Double?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                if let ms, ms > 0 {
                    Text("~" + OrbitDevToolsFormat.milliseconds(ms))
                        .font(InspectChrome.mono)
                        .foregroundStyle(OrbitNeutral.ink)
                }
                if let bytes, bytes > 0 {
                    Text(OrbitDevToolsFormat.bytes(bytes))
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.muted)
                }
            }
            if let ms, ms > 0, let scaleMs, scaleMs > 0 {
                LHSavingsBar(wastedMs: ms, scaleMs: scaleMs)
            }
        }
        .accessibilityHidden(true)
    }
}

struct LHSavingsBar: View {
    var wastedMs: Double
    /// The saving that fills the bar. Defaults to two seconds when rows are not being compared.
    var scaleMs: Double = 2_000

    private var fraction: CGFloat {
        CGFloat(min(wastedMs / max(scaleMs, 1), 1))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(OrbitNeutral.chip)
                .frame(width: 60, height: 6)
            Capsule()
                .fill(OrbitNeutral.warn)
                .frame(width: max(3, 60 * fraction), height: 6)
        }
        .orbitAnimation(OrbitMotion.standard, value: fraction)
    }
}

// MARK: - Metric detail

/// What a metric means, why it rated as it did, how to improve it, and the evidence behind the number.
struct LHMetricDetailView: View {
    var kind: LHMetricKind
    var metrics: LHMetrics
    var audit: LHAuditResult?
    var session: OrbitInspectSession?

    private var value: Double? { kind.value(in: metrics) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.fullName)
                .font(InspectChrome.labelStrong)
                .foregroundStyle(OrbitNeutral.ink)
            Text(assessment)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
                .fixedSize(horizontal: false, vertical: true)
            block("What it measures", kind.explanation)
            block("How to improve", kind.improvement)
            if let note = kind.measurementNote {
                Text(note)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            evidence
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous).fill(OrbitNeutral.sunk)
        )
    }

    private var assessment: String {
        if let value { return kind.assessment(for: value) }
        if let audit, audit.status == .notApplicable, kind == .tbt || kind == .speedIndex { return audit.description }
        return kind == .inp
            ? "Not measured. Start a Timespan recording and interact with the page."
            : "Not measured in this run. A Navigation audit measures it."
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(OrbitNeutral.muted)
            Text(text)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var evidence: some View {
        switch kind {
        case .lcp: lcpEvidence
        case .cls: clsEvidence
        case .tbt:
            if let items = audit?.items, !items.isEmpty {
                evidenceBlock("Longest blocking tasks", items)
            }
        case .ttfb:
            if let parts = metrics.ttfbParts, !parts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where the time went")
                        .font(InspectChrome.sectionTitle)
                        .foregroundStyle(OrbitNeutral.muted)
                    LHPhaseBars(parts: parts, total: metrics.ttfb ?? parts.reduce(0) { $0 + $1.ms })
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var lcpEvidence: some View {
        if let lcp = metrics.lcpDetail {
            let item = LHAuditItem(nodeID: lcp.nodeID, selector: lcp.selector.isEmpty ? nil : lcp.selector,
                                   url: lcp.url, label: "<\(lcp.tag)>", snippet: lcp.snippet)
            evidenceBlock("The LCP element", [item])
            if lcp.isLazyLoaded {
                Label("This image is lazy-loaded, which delays the largest paint.", systemImage: "exclamationmark.triangle.fill")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.warn)
            }
            if !lcp.phases.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where the time went")
                        .font(InspectChrome.sectionTitle)
                        .foregroundStyle(OrbitNeutral.muted)
                    LHPhaseBars(parts: lcp.phases, total: metrics.lcp ?? lcp.phases.reduce(0) { $0 + $1.ms })
                }
            }
        } else if let selector = metrics.lcpElement {
            Text(selector)
                .font(InspectChrome.monoSmall)
                .foregroundStyle(OrbitNeutral.muted)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var clsEvidence: some View {
        if !metrics.clsShifts.isEmpty {
            let total = metrics.clsShifts.reduce(0) { $0 + $1.value }
            VStack(alignment: .leading, spacing: 4) {
                Text(clsSummary(total: total))
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let items = audit?.items, !items.isEmpty {
                    evidenceBlock("Elements that moved, then the largest single shifts", items)
                }
            }
        }
    }

    private func clsSummary(total: Double) -> String {
        var text = "\(metrics.clsShifts.count) layout shift(s) adding up to " + String(format: "%.3f", total) + "."
        if let cls = metrics.cls, total - cls > 0.0005 {
            text += " The figure above counts only the worst burst: shifts less than 1 s apart, within 5 s."
        }
        return text
    }

    @ViewBuilder
    private func evidenceBlock(_ title: String, _ items: [LHAuditItem]) -> some View {
        if let session {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(InspectChrome.sectionTitle)
                    .foregroundStyle(OrbitNeutral.muted)
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        LHAuditItemRow(item: item, session: session)
                        Divider()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                        .fill(OrbitNeutral.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                                .strokeBorder(OrbitNeutral.line, lineWidth: 1)
                        )
                )
            }
        }
    }
}

/// Parts of a duration as bars on one scale, each with its time and share. The numbers carry the meaning; the bars compare.
struct LHPhaseBars: View {
    var parts: [LHTimingPart]
    var total: Double

    var body: some View {
        VStack(spacing: 4) {
            ForEach(parts, id: \.name) { part in
                HStack(spacing: 8) {
                    Text(part.name)
                        .font(InspectChrome.caption)
                        .foregroundStyle(OrbitNeutral.ink2)
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(OrbitNeutral.chip)
                            Capsule()
                                .fill(OrbitNeutral.accent)
                                .frame(width: max(part.ms > 0 ? 2 : 0, geometry.size.width * fraction(part.ms)))
                        }
                    }
                    .frame(height: 6)
                    Text(OrbitDevToolsFormat.milliseconds(part.ms) + " " + share(part.ms))
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.muted)
                        .frame(width: 96, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.name) \(OrbitDevToolsFormat.milliseconds($0.ms))" }.joined(separator: ", "))
    }

    private func fraction(_ ms: Double) -> CGFloat {
        total > 0 ? CGFloat(min(max(ms / total, 0), 1)) : 0
    }

    private func share(_ ms: Double) -> String {
        total > 0 ? "(\(Int((ms / total * 100).rounded()))%)" : ""
    }
}

// MARK: - Score breakdown

/// How each weighted metric adds to a category score: the points it kept out of the points it could give.
struct LHScoreBreakdownView: View {
    var rows: [OrbitLighthouseLogic.ScoreContribution]
    var score: Int

    private var earned: Double { rows.reduce(0) { $0 + $1.points } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The score is 100 points shared out by weight. Each metric keeps the share its own score earns; the largest losses are first.")
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { row in
                rowView(row)
            }
            HStack {
                Text("Total")
                    .font(InspectChrome.labelStrong)
                    .foregroundStyle(OrbitNeutral.ink)
                Spacer()
                Text(String(format: "%.1f points, shown as ", earned) + "\(score)")
                    .font(InspectChrome.mono)
                    .foregroundStyle(OrbitNeutral.ink)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func rowView(_ row: OrbitLighthouseLogic.ScoreContribution) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(InspectChrome.label)
                    .foregroundStyle(OrbitNeutral.ink)
                    .lineLimit(1)
                Text(row.displayValue)
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(OrbitNeutral.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if row.measured {
                    Text(String(format: "%.1f of %.1f", row.points, row.maxPoints))
                        .font(InspectChrome.mono)
                        .foregroundStyle(OrbitNeutral.ink)
                } else {
                    Text("not measured")
                        .font(InspectChrome.caption)
                        .foregroundStyle(OrbitNeutral.muted2)
                }
            }
            if row.measured, let score = row.score {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(OrbitNeutral.chip)
                        Capsule()
                            .fill(LHStyle.color(score: Int((score * 100).rounded())))
                            .frame(width: max(score > 0 ? 3 : 0, geometry.size.width * CGFloat(min(max(score, 0), 1))))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            } else {
                Text("Weight \(Int(row.weight)) is shared among the metrics that were measured.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(row))
    }

    private func accessibilityText(_ row: OrbitLighthouseLogic.ScoreContribution) -> String {
        guard row.measured else { return "\(row.title), not measured" }
        return String(format: "%@, %@, %.1f of %.1f points", row.title, row.displayValue, row.points, row.maxPoints)
    }
}

// MARK: - Visual evidence

/// The page as it was when the audit ran: a screenshot with the LCP element and the elements that shifted outlined,
/// and a filmstrip of the load.
struct LHVisualEvidenceView: View {
    var visuals: LHVisuals
    var metrics: LHMetrics
    var session: OrbitInspectSession

    @State private var showMarks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shot = visuals.screenshot {
                screenshot(shot)
            } else if let note = visuals.note {
                Text(note)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !visuals.filmstrip.isEmpty {
                filmstrip
            }
        }
    }

    private func screenshot(_ shot: LHScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Screenshot at the end of the run")
                    .font(InspectChrome.sectionTitle)
                    .foregroundStyle(OrbitNeutral.muted)
                Spacer()
                if !visuals.drawnMarks.isEmpty {
                    InspectChip("Outlines", selected: showMarks) { showMarks.toggle() }
                }
            }
            LHAnnotatedScreenshot(screenshot: shot, marks: showMarks ? visuals.drawnMarks : [])
                .frame(maxWidth: 560)
            if !visuals.marks.isEmpty {
                legend
            }
        }
    }

    private var legend: some View {
        let drawn = Set(visuals.drawnMarks.map(\.id))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(visuals.marks) { mark in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(LHMarkStyle.color(mark.kind), style: LHMarkStyle.stroke(mark.kind))
                        .frame(width: 14, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mark.label)
                            .font(InspectChrome.label)
                            .foregroundStyle(OrbitNeutral.ink)
                        Text(mark.selector)
                            .font(InspectChrome.monoSmall)
                            .foregroundStyle(OrbitNeutral.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = mark.detail {
                            Text(detail)
                                .font(InspectChrome.caption)
                                .foregroundStyle(OrbitNeutral.muted2)
                        }
                        if !drawn.contains(mark.id) {
                            Text("Outside the captured area, so it is listed but not outlined.")
                                .font(InspectChrome.caption)
                                .foregroundStyle(OrbitNeutral.muted2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let nodeID = mark.nodeID, nodeID > 0 {
                        InspectTextButton("Reveal", systemImage: "scope") { session.reveal(nodeID: nodeID) }
                    }
                }
            }
        }
    }

    private var filmstrip: some View {
        let tags = OrbitLighthouseLogic.filmstripMilestones(frameMs: visuals.filmstrip.map(\.ms), fcpMs: metrics.fcp, lcpMs: metrics.lcp)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Filmstrip, time since the reload")
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(OrbitNeutral.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(visuals.filmstrip.enumerated()), id: \.offset) { index, frame in
                        LHFilmstripFrameView(frame: frame, milestones: tags[index])
                    }
                }
            }
        }
    }
}

enum LHMarkStyle {
    static func color(_ kind: LHShotMark.Kind) -> Color {
        kind == .lcp ? OrbitNeutral.accent : OrbitNeutral.bad
    }

    /// LCP is solid and shifts are dashed, so the two read apart without relying on colour.
    static func stroke(_ kind: LHShotMark.Kind) -> StrokeStyle {
        kind == .lcp ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 2, dash: [4, 3])
    }
}

struct LHAnnotatedScreenshot: View {
    var screenshot: LHScreenshot
    var marks: [LHShotMark]

    var body: some View {
        if let image = NSImage(data: screenshot.jpeg) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .overlay { outlines }
                .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                        .strokeBorder(OrbitNeutral.line, lineWidth: 1)
                )
                .accessibilityLabel("Screenshot of the page when the audit ran")
                .accessibilityValue(marks.isEmpty ? "" : marks.map(\.label).joined(separator: ", ") + " outlined")
        } else {
            Text("The screenshot could not be displayed.")
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
        }
    }

    private var outlines: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(marks) { mark in
                    if let fraction = OrbitLighthouseLogic.fractionalRect(mark.rect, in: screenshot.viewport) {
                        let width = geometry.size.width * fraction.width
                        let height = geometry.size.height * fraction.height
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(LHMarkStyle.color(mark.kind).opacity(0.12))
                            Rectangle().strokeBorder(LHMarkStyle.color(mark.kind), style: LHMarkStyle.stroke(mark.kind))
                            Text(mark.kind == .lcp ? "LCP" : "CLS")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 3)
                                .background(LHMarkStyle.color(mark.kind))
                        }
                        .frame(width: width, height: height)
                        .offset(x: geometry.size.width * fraction.x, y: geometry.size.height * fraction.y)
                    }
                }
            }
        }
    }
}

struct LHFilmstripFrameView: View {
    var frame: LHFilmstripFrame
    var milestones: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let image = NSImage(data: frame.jpeg) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 116)
                    .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                            .strokeBorder(OrbitNeutral.line, lineWidth: 1)
                    )
            }
            Text(OrbitDevToolsFormat.milliseconds(frame.ms))
                .font(InspectChrome.mono)
                .foregroundStyle(OrbitNeutral.ink)
            if let completeness = frame.completeness {
                Text("\(Int((completeness * 100).rounded()))% of final")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
            }
            if !milestones.isEmpty {
                Text(milestones.joined(separator: ", ") + " by here")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.accent)
            }
        }
        .frame(width: 116, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Page at \(OrbitDevToolsFormat.milliseconds(frame.ms))"]
        if let completeness = frame.completeness { parts.append("\(Int((completeness * 100).rounded())) percent of the final picture") }
        if !milestones.isEmpty { parts.append(milestones.joined(separator: " and ") + " reached") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - History chip

struct LHHistoryChip: View {
    var report: LHReport
    var isSelected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ForEach(LHCategory.allCases) { cat in
                    if report.enabledCategories.contains(cat) {
                        LHGaugeView(score: report.scores[cat], size: 32, label: cat.title)
                    }
                }
            }
            Text(DateFormatter.localizedString(from: report.timestamp, dateStyle: .none, timeStyle: .short))
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
            Text(report.mode.title)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
                .fill(isSelected ? OrbitNeutral.chipStrong : OrbitNeutral.chip)
        )
        .overlay(InspectHitTarget(action: onSelect))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Run at \(DateFormatter.localizedString(from: report.timestamp, dateStyle: .none, timeStyle: .short)), \(report.mode.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Delete") { onDelete() }
        }
    }
}
