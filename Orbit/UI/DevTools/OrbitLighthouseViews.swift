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

struct LHMetricTilesView: View {
    var metrics: LHMetrics
    var device: LHDevice

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
                        LHMetricTile(kind: kind, value: kind.value(in: metrics))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

    private var expandable: Bool { !audit.items.isEmpty || audit.docsURL != nil || audit.savingsNote != nil }

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

            if let docs = audit.docsURL, let url = URL(string: docs) {
                InspectTextButton("Learn more", systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
            }

            if !audit.items.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(audit.items) { item in
                        auditItemRow(item)
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

    private func auditItemRow(_ item: LHAuditItem) -> some View {
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
                        .lineLimit(1)
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
