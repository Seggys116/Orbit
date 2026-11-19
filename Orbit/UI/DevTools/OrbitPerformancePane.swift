import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Top-level pane

struct OrbitPerformancePane: View {
    var session: OrbitInspectSession

    private var model: OrbitPerformanceModel { session.performance }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            InspectDivider()
            content
        }
    }

    // MARK: Toolbar

    /// Scrolls horizontally instead of clipping when the dock is narrow.
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                recordingButton
                if model.recordingState != .idle {
                    stopButton
                }
                InspectTextButton("Reload and record", systemImage: "arrow.clockwise.circle",
                                  enabled: model.recordingState == .idle) {
                    model.reloadAndRecord()
                }
                Spacer(minLength: 8)
                recordingMenu
                if !model.recordings.isEmpty {
                    InspectTextButton("Export…", systemImage: "square.and.arrow.up",
                                      enabled: model.selectedRecording != nil) {
                        exportCurrentRecording()
                    }
                    InspectTextButton("Import…", systemImage: "square.and.arrow.down") {
                        importRecording()
                    }
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 40)
    }

    private var recordingButton: some View {
        Group {
            if model.recordingState == .idle {
                InspectTextButton("Record", systemImage: "record.circle") {
                    model.startRecording()
                }
            } else {
                HStack(spacing: 4) {
                    Circle().fill(InspectChrome.badColor).frame(width: 8, height: 8)
                    Text(model.recordingState == .reloadAndRecord ? "Reloading and recording…" : "Recording…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(InspectChrome.badColor)
                }
            }
        }
    }

    private var stopButton: some View {
        InspectTextButton("Stop", systemImage: "stop.circle") {
            model.stopRecording()
        }
    }

    private var recordingMenu: some View {
        Group {
            if model.recordings.isEmpty {
                Text("Live").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            } else {
                InspectMenuButton(symbol: "tray.and.arrow.down", help: "Switch recording") {
                    var items: [InspectMenuItem] = []
                    items.append(InspectMenuItem(
                        title: "Live (current page)",
                        checked: model.selectedRecording == nil
                    ) {
                        // No explicit "live" state to select; just show info
                    })
                    for (idx, rec) in model.recordings.enumerated() {
                        let label = rec.title.isEmpty ? rec.url : rec.title
                        items.append(InspectMenuItem(
                            title: "\(idx + 1). \(String(label.prefix(50)))",
                            checked: model.selectedRecordingIndex == idx
                        ) {
                            model.selectRecording(rec)
                        })
                    }
                    if let rec = model.selectedRecording {
                        items.append(.separator)
                        items.append(InspectMenuItem(title: "Delete this recording") {
                            model.deleteRecording(id: rec.id)
                        })
                    }
                    return items
                }
            }
        }
    }

    private func exportCurrentRecording() {
        guard let data = model.exportCurrentRecording() else { return }
        let panel = NSSavePanel()
        panel.title = "Export Performance Recording"
        panel.allowedContentTypes = [UTType.json]
        let title = model.displayRecording.title.prefix(40)
        panel.nameFieldStringValue = title.isEmpty ? "recording.json" : "\(title).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importRecording() {
        let panel = NSOpenPanel()
        panel.title = "Import Performance Recording"
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        if !model.importRecording(from: data) {
            session.notice = "Could not import: file does not contain a valid performance recording."
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            tabBar
            InspectDivider()
            tabContent
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(OrbitPerformanceModel.PerfTab.allCases) { tab in
                InspectChip(tab.title, selected: model.activeTab == tab) {
                    model.activeTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 4)
        .frame(height: 34)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.activeTab {
        case .live:
            PerfLiveTab(session: session)
        case .summary:
            PerfSummaryTab(session: session)
        case .timeline:
            PerfTimelineTab(session: session)
        }
    }
}

// MARK: - Summary tab

struct PerfSummaryTab: View {
    var session: OrbitInspectSession
    private var model: OrbitPerformanceModel { session.performance }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                vitalsSection
                if model.vitals.navigationPhases != nil { navTimingSection }
                if let lcp = model.vitals.lcpElement { lcpSection(lcp: lcp) }
                if !model.vitals.clsEntries.isEmpty { clsSection }
                if !model.vitals.longTasks.isEmpty { longTasksSection }
                if !model.displayRecording.interactionEntries.isEmpty { interactionsSection }
                resourceSection
                if !model.displayRecording.userTimings.isEmpty { userTimingSection }
                insightsSection
                webkitLimitsFooter
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    // MARK: Core Web Vitals

    private var vitalsSection: some View {
        let v = model.vitals
        return VStack(alignment: .leading, spacing: 12) {
            InspectSectionHeader("Core Web Vitals")
            HStack(spacing: 8) {
                PerfVitalCard(
                    name: "LCP", value: v.lcp, unit: "ms",
                    rating: v.lcp.map { OrbitPerformanceLogic.ratingForLCP($0) } ?? .unknown,
                    goodThreshold: "≤2,500ms", poorThreshold: ">4,000ms"
                )
                PerfVitalCard(
                    name: "INP", value: v.inp, unit: "ms",
                    rating: v.inp.map { OrbitPerformanceLogic.ratingForINP($0) } ?? .unknown,
                    goodThreshold: "≤200ms", poorThreshold: ">500ms"
                )
                PerfVitalCard(
                    name: "CLS", value: v.cls, unit: "",
                    rating: v.cls.map { OrbitPerformanceLogic.ratingForCLS($0) } ?? .unknown,
                    goodThreshold: "≤0.1", poorThreshold: ">0.25", decimalPlaces: 3
                )
            }
            InspectSectionHeader("Other Metrics")
            HStack(spacing: 8) {
                PerfVitalCard(
                    name: "FCP", value: v.fcp, unit: "ms",
                    rating: v.fcp.map { OrbitPerformanceLogic.ratingForFCP($0) } ?? .unknown,
                    goodThreshold: "≤1,800ms", poorThreshold: ">3,000ms"
                )
                PerfVitalCard(
                    name: "TTFB", value: v.ttfb, unit: "ms",
                    rating: v.ttfb.map { OrbitPerformanceLogic.ratingForTTFB($0) } ?? .unknown,
                    goodThreshold: "≤800ms", poorThreshold: ">1,800ms"
                )
                PerfVitalCard(
                    name: "TBT est.", value: v.tbtEstimate, unit: "ms",
                    rating: v.tbtEstimate.map {
                        $0 <= 200 ? .good : ($0 <= 600 ? .needsImprovement : .poor)
                    } ?? .unknown,
                    goodThreshold: "≤200ms", poorThreshold: ">600ms"
                )
            }
        }
        .padding(.bottom, 16)
    }

    private var navTimingSection: some View {
        Group {
            if let phases = model.vitals.navigationPhases {
                PerfNavTimingWaterfall(phases: phases).padding(.bottom, 16)
            }
        }
    }

    private func lcpSection(lcp: PerfLCPEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("LCP Element")
            PerfLCPBreakdownView(entry: lcp, phases: model.vitals.lcpPhases, session: session)
        }
        .padding(.bottom, 16)
    }

    private var clsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Layout Shifts",
                                  detail: "CLS \(String(format: "%.4f", model.vitals.cls ?? 0))")
            PerfCLSCulpritsView(entries: model.vitals.clsEntries, session: session)
        }
        .padding(.bottom, 16)
    }

    private var longTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Long Tasks",
                                  detail: "\(model.vitals.longTasks.count) tasks")
            PerfLongTasksView(tasks: model.vitals.longTasks)
        }
        .padding(.bottom, 16)
    }

    private var interactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Interactions",
                                  detail: "\(model.displayRecording.interactionEntries.count) total")
            PerfInteractionsView(
                entries: model.displayRecording.interactionEntries,
                worst: model.vitals.inpWorstInteraction,
                session: session
            )
        }
        .padding(.bottom, 16)
    }

    private var resourceSection: some View {
        let buckets = model.displayRecording.resourceSummary
        return Group {
            if !buckets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    InspectSectionHeader("Resources by Type")
                    PerfResourceSummaryView(buckets: buckets)
                }
                .padding(.bottom, 16)
            }
        }
    }

    private var userTimingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("User Timing")
            PerfUserTimingView(timings: model.displayRecording.userTimings)
        }
        .padding(.bottom, 16)
    }

    private var insightsSection: some View {
        let insights = OrbitPerformanceLogic.insights(
            recording: model.displayRecording,
            vitals: model.vitals
        )
        return Group {
            if !insights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    InspectSectionHeader("Insights", detail: "\(insights.count)")
                    PerfInsightsView(insights: insights, session: session)
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: WebKit limitations footer

    private var webkitLimitsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            InspectDivider()
            Text("WebKit limitations: no JavaScript CPU flame chart, no JS heap breakdown, no GPU/raster timeline, no Long Animation Frames API (Chrome-only). All measurements come from the W3C PerformanceObserver API and native macOS process metrics.")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted2)
                .padding(.top, 6)
        }
    }
}

// MARK: - Timeline tab

struct PerfTimelineTab: View {
    var session: OrbitInspectSession
    private var model: OrbitPerformanceModel { session.performance }

    var body: some View {
        if model.displayRecording.duration <= 0 && model.recordingState == .idle {
            InspectEmptyState(
                symbol: "waveform",
                title: "No recording",
                message: "Press Record to capture a trace, or use Reload and record to capture a full page load including navigation."
            )
        } else {
            PerfTimelineCanvasView(session: session)
        }
    }
}
