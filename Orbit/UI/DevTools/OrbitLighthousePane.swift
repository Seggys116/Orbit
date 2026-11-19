import AppKit
import SwiftUI

struct OrbitLighthousePane: View {
    var session: OrbitInspectSession

    @State private var filter: LHAuditFilter = .all

    private var model: OrbitLighthouseModel { session.lighthouse }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // The option chips scroll sideways rather than clipping when the panel is narrow.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Run mode chips
                    HStack(spacing: 2) {
                        ForEach(LHRunMode.allCases, id: \.self) { mode in
                            InspectChip(mode.title, selected: model.runMode == mode) {
                                model.runMode = mode
                            }
                        }
                    }

                    Divider().frame(height: 16)

                    // Device
                    HStack(spacing: 2) {
                        ForEach(LHDevice.allCases, id: \.self) { dev in
                            InspectChip(dev.title, selected: model.device == dev) {
                                model.device = dev
                            }
                        }
                    }

                    Divider().frame(height: 16)

                    // Runs
                    HStack(spacing: 2) {
                        ForEach([1, 3, 5], id: \.self) { n in
                            InspectChip(n == 1 ? "1×" : "\(n)×", selected: model.runCount == n) {
                                model.runCount = n
                            }
                        }
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }

            // Export / copy
            if model.viewingReport != nil {
                InspectMenuButton(symbol: "square.and.arrow.up", help: "Export or copy") {
                    [
                        InspectMenuItem(title: "Copy Summary") { model.copySummary() },
                        InspectMenuItem(title: "Export as JSON") { model.exportJSON() },
                        InspectMenuItem(title: "Export as HTML") { model.exportHTML() },
                    ]
                }
            }

            // Cancel / Analyze
            if model.isRunning {
                InspectTextButton("Cancel", action: { model.cancelRun() })
            } else if model.isTimespanActive {
                InspectTextButton("Stop Recording", systemImage: "stop.circle", prominent: true) {
                    model.stopTimespan()
                }
            } else if model.runMode == .timespan {
                InspectTextButton("Start Recording", systemImage: "record.circle", prominent: true) {
                    model.startTimespan()
                }
            } else {
                InspectTextButton("Analyze", systemImage: "play.fill", prominent: true) {
                    model.startRun()
                }
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: 36)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.runState {
        case .idle:
            if let report = model.viewingReport {
                reportView(report)
            } else {
                idleState
            }
        case .running(let step, let progress):
            progressView(step: step, progress: progress)
        case .timespanActive(let start):
            timespanView(startDate: start)
        case .done:
            if let report = model.viewingReport {
                reportView(report)
            } else {
                idleState
            }
        case .failed(let msg):
            VStack(spacing: 12) {
                if let report = model.viewingReport { reportView(report) }
                InspectEmptyState(symbol: "exclamationmark.triangle",
                                  title: "Run failed",
                                  message: msg)
            }
        }
    }

    private var idleState: some View {
        InspectEmptyState(
            symbol: "lightbulb.max",
            title: "Lighthouse",
            message: model.runMode == .timespan
                ? "Press Start Recording, interact with the page, then press Stop."
                : "Press Analyze to run a \(model.runMode.title) audit."
        )
    }

    private func progressView(step: String, progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)
            Text(step)
                .font(InspectChrome.label)
                .foregroundStyle(OrbitNeutral.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timespanView(startDate: Date) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 32))
                .foregroundStyle(OrbitNeutral.bad)
            Text("Recording…")
                .font(.system(size: 14, weight: .semibold))
            Text("Interact with the page, then press Stop.")
                .font(InspectChrome.label)
                .foregroundStyle(OrbitNeutral.muted)
            Text("Measuring CLS, INP, and TBT during the interaction.")
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportView(_ report: LHReport) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                reportHeader(report)
                gaugeRow(report)
                throttlingNote(report)
                comparisonSection(report)
                if report.enabledCategories.contains(.performance) {
                    metricsSection(report)
                    mainThreadSection(report)
                }
                visualEvidenceSection(report)
                if report.enabledCategories.contains(.performance) {
                    scoreBreakdownSection(report)
                }
                filterBar(report)
                opportunitiesSection(report)
                diagnosticsSection(report)
                ForEach(LHCategory.allCases) { cat in
                    if report.enabledCategories.contains(cat) {
                        categorySection(report, category: cat)
                    }
                }
                historyStrip
                Spacer().frame(height: 24)
            }
        }
    }

    // MARK: Report sections

    private func reportHeader(_ report: LHReport) -> some View {
        let when = DateFormatter.localizedString(from: report.timestamp, dateStyle: .short, timeStyle: .short)
        var detail = "\(when) · \(report.mode.title) · \(OrbitLighthouseLogic.deviceLine(report))"
        if report.runCount > 1 { detail += " · median of \(report.runCount)" }
        return VStack(alignment: .leading, spacing: 2) {
            Text(report.pageTitle.isEmpty ? report.url : report.pageTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OrbitNeutral.ink)
                .lineLimit(1)
            Text(report.url)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 10)
    }

    private func gaugeRow(_ report: LHReport) -> some View {
        // Gauges wrap onto more rows instead of squeezing or clipping in a narrow panel.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8, alignment: .top)], spacing: 10) {
            ForEach(LHCategory.allCases) { cat in
                if report.enabledCategories.contains(cat) {
                    VStack(spacing: 4) {
                        LHGaugeView(score: report.scores[cat], size: 72, label: cat.title)
                        Text(cat.title)
                            .font(InspectChrome.caption)
                            .foregroundStyle(OrbitNeutral.ink2)
                            .multilineTextAlignment(.center)
                        if let score = report.scores[cat] {
                            Text(LHStyle.word(score: score))
                                .font(InspectChrome.caption)
                                .foregroundStyle(OrbitNeutral.muted)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(gaugeAccessibility(report, cat))
                }
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 8)
    }

    private func gaugeAccessibility(_ report: LHReport, _ cat: LHCategory) -> String {
        guard let score = report.scores[cat] else { return "\(cat.title) score not available" }
        return "\(cat.title) score \(score) out of 100, \(LHStyle.word(score: score))"
    }

    private func throttlingNote(_ report: LHReport) -> some View {
        Group {
            ForEach(OrbitLighthouseLogic.emulationProblems(report), id: \.self) { problem in
                Label(problem, systemImage: "iphone.slash")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 2)
            }
            if let note = report.redistributionNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.warn)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 2)
            }
            if let emulation = report.emulation {
                Text(emulation.coverage)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 2)
            }
            Text(report.throttlingNote)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.bottom, 8)
        }
    }

    /// What changed since an earlier run: by default the previous run of the same page and device, or any run picked from the menu.
    private func comparisonSection(_ report: LHReport) -> some View {
        let candidates = model.comparisonCandidates
        return Group {
            if !candidates.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    let base = model.comparison.flatMap { c in candidates.first { $0.id == c.baseID } }
                    InspectSectionHeader("Compared with", detail: base.map(LHStyle.runLabel) ?? "no other run")
                    Spacer(minLength: 0)
                    InspectMenuButton(symbol: "arrow.left.arrow.right", help: "Compare with another run") {
                        [InspectMenuItem(title: "No comparison", checked: model.comparison == nil) { model.compare(withID: nil) }]
                            + candidates.map { other in
                                InspectMenuItem(title: LHStyle.runLabel(other), checked: other.id == model.comparisonBaseID) {
                                    model.compare(withID: other.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
                if let comparison = model.comparison {
                    LHComparisonView(comparison: comparison)
                        .padding(.horizontal, InspectChrome.panelPadding)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func metricsSection(_ report: LHReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            InspectSectionHeader("Performance metrics")
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)
            LHMetricTilesView(metrics: report.metrics, device: report.device, audits: report.audits, session: session,
                              expandedIDs: model.expandedAuditIDs) { model.toggleExpanded(auditID: $0) }
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.bottom, 4)
            Text(report.runCount > 1
                 ? "Select a metric for what it means and the evidence behind it. The LCP element, layout shifts and filmstrip come from the run closest to the median."
                 : "Select a metric for what it means and the evidence behind it.")
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.bottom, 8)
        }
    }

    private func mainThreadSection(_ report: LHReport) -> some View {
        Group {
            if let thread = report.mainThread {
                Divider()
                InspectSectionHeader("Main thread", detail: OrbitLighthouseLogic.formatMs(thread.totalMs))
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                LHMainThreadView(thread: thread, tti: report.tti, session: session)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 10)
            } else if let note = report.tti?.note, report.tti?.valueMs == nil {
                Text("Time to Interactive not measured: " + note)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 8)
            }
        }
    }

    private func visualEvidenceSection(_ report: LHReport) -> some View {
        Group {
            if let visuals = report.visuals {
                Divider()
                InspectSectionHeader("Visual evidence")
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                LHVisualEvidenceView(visuals: visuals, metrics: report.metrics, session: session)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 10)
            }
        }
    }

    private func scoreBreakdownSection(_ report: LHReport) -> some View {
        let rows = OrbitLighthouseLogic.scoreBreakdown(report.audits, category: .performance)
        return Group {
            if let score = report.scores.performance, !rows.isEmpty {
                Divider()
                InspectSectionHeader("Performance score breakdown", detail: "\(score)/100")
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                LHScoreBreakdownView(rows: rows, score: score)
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: Filter

    private func filterBar(_ report: LHReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(LHAuditFilter.allCases) { option in
                        InspectChip(option.title, selected: filter == option,
                                    count: option == .all ? nil : option.count(in: report.audits)) {
                            withOrbitAnimation(OrbitMotion.quick) { filter = option }
                        }
                    }
                }
                .padding(.horizontal, InspectChrome.panelPadding)
            }
            .frame(height: 32)
        }
    }

    private func opportunitiesSection(_ report: LHReport) -> some View {
        let opps = OrbitLighthouseLogic.rankedOpportunities(report.audits).filter { filter.includes($0.band) }
        let scale = opps.compactMap(\.savingsMs).max()
        return Group {
            if !opps.isEmpty {
                Divider()
                InspectSectionHeader("Opportunities", detail: "\(opps.count), largest saving first")
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                ForEach(opps) { audit in
                    LHAuditRowView(audit: audit,
                                   expanded: model.expandedAuditIDs.contains(audit.id),
                                   session: session,
                                   savingsScaleMs: scale) {
                        model.toggleExpanded(auditID: audit.id)
                    }
                }
            }
        }
    }

    private func diagnosticsSection(_ report: LHReport) -> some View {
        let diags = report.audits.filter {
            ($0.status == .informative || ($0.weight == 0 && $0.status != .fail)) && filter.includes($0.band)
        }
        return Group {
            if !diags.isEmpty {
                Divider()
                InspectSectionHeader("Diagnostics", detail: "\(diags.count)")
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                ForEach(diags) { audit in
                    LHAuditRowView(audit: audit,
                                   expanded: model.expandedAuditIDs.contains(audit.id),
                                   session: session) {
                        model.toggleExpanded(auditID: audit.id)
                    }
                }
            }
        }
    }

    private func categorySection(_ report: LHReport, category: LHCategory) -> some View {
        let audits = report.audits.filter { $0.category == category && $0.weight > 0 }
        let failing = audits.filter { $0.band == .failed && filter.includes(.failed) }
        let warnings = audits.filter { $0.band == .warning && filter.includes(.warning) }
        let passing = audits.filter { $0.band == .passed && filter.includes(.passed) }
        let manual  = audits.filter { $0.status == .manual && filter == .all }
        let na      = audits.filter { $0.status == .notApplicable && filter == .all }
        let hasRows = !failing.isEmpty || !warnings.isEmpty || !passing.isEmpty || !manual.isEmpty || !na.isEmpty
        return Group {
            if !audits.isEmpty && hasRows {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: category.symbol).foregroundStyle(OrbitNeutral.muted)
                    InspectSectionHeader(category.title, detail: report.scores[category].map { "\($0)/100" })
                }
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)

                ForEach(failing + warnings) { audit in
                    LHAuditRowView(audit: audit,
                                   expanded: model.expandedAuditIDs.contains(audit.id),
                                   session: session) {
                        model.toggleExpanded(auditID: audit.id)
                    }
                }

                if !passing.isEmpty {
                    // Under the Passed filter the user asked to see them, so they are not tucked away.
                    if filter == .passed {
                        ForEach(passing) { audit in
                            LHAuditRowView(audit: audit,
                                           expanded: model.expandedAuditIDs.contains(audit.id),
                                           session: session) {
                                model.toggleExpanded(auditID: audit.id)
                            }
                        }
                    } else {
                        collapsedGroup(label: "Passed audits (\(passing.count))",
                                       audits: passing, symbol: "checkmark.circle.fill", color: OrbitNeutral.good)
                    }
                }
                if !manual.isEmpty {
                    collapsedGroup(label: "Manual checks (\(manual.count))",
                                   audits: manual, symbol: "hand.raised", color: OrbitNeutral.muted)
                }
                if !na.isEmpty {
                    collapsedGroup(label: "Not applicable (\(na.count))",
                                   audits: na, symbol: "minus.circle", color: OrbitNeutral.muted)
                }
            }
        }
    }

    private func collapsedGroup(label: String, audits: [LHAuditResult], symbol: String, color: Color) -> some View {
        let groupID = label
        let isExpanded = model.expandedAuditIDs.contains(groupID)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(OrbitNeutral.muted2)
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(label)
                    .font(InspectChrome.label)
                    .foregroundStyle(OrbitNeutral.muted)
                Spacer()
            }
            .frame(minHeight: InspectChrome.rowHeight)
            .padding(.horizontal, InspectChrome.panelPadding)
            .contentShape(Rectangle())
            .overlay(InspectHitTarget { model.toggleExpanded(auditID: groupID) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                ForEach(audits) { audit in
                    LHAuditRowView(audit: audit,
                                   expanded: model.expandedAuditIDs.contains(audit.id),
                                   session: session) {
                        model.toggleExpanded(auditID: audit.id)
                    }
                }
            }
        }
    }

    // MARK: History strip

    private var historyStrip: some View {
        Group {
            if !model.history.isEmpty {
                Divider()
                InspectSectionHeader("Run history", detail: "\(model.history.count)")
                    .padding(.horizontal, InspectChrome.panelPadding)
                    .padding(.vertical, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.history) { report in
                            LHHistoryChip(
                                report: report,
                                isSelected: model.selectedHistoryID == report.id
                            ) {
                                model.selectHistoryItem(id:
                                    model.selectedHistoryID == report.id ? nil : report.id)
                            } onDelete: {
                                model.deleteHistoryItem(id: report.id)
                            }
                        }
                    }
                    .padding(.horizontal, InspectChrome.panelPadding)
                }
                .padding(.bottom, 8)
            }
        }
    }
}


