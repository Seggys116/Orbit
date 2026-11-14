import SwiftUI

struct OrbitAnimationsPane: View {
    var session: OrbitInspectSession

    private var model: OrbitAnimationsModel { session.animations }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            InspectDivider()
            tabBar
            InspectDivider()
            content
            footer
        }
    }

    // MARK: - Toolbar

    /// Scrolls horizontally instead of clipping when the dock is narrow.
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pauseResumeButton
                InspectTextButton("Replay all", systemImage: "arrow.counterclockwise") {
                    model.replayAll()
                }
                Rectangle().fill(InspectChrome.hairline).frame(width: 1, height: 18)
                speedControl
                Spacer(minLength: 8)
                InspectTextButton("Clear") {
                    model.clearAll()
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 34)
    }

    private var pauseResumeButton: some View {
        Group {
            if model.globalPaused {
                InspectTextButton("Resume all", systemImage: "play.fill", prominent: true) {
                    model.resumeAll()
                }
            } else {
                InspectTextButton("Pause all", systemImage: "pause.fill") {
                    model.pauseAll()
                }
            }
        }
    }

    private var speedControl: some View {
        HStack(spacing: 4) {
            Text("Speed")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
            OrbitSegmentedControl(
                options: [0.1, 0.25, 0.5, 1.0],
                label: { rate in
                    switch rate {
                    case 0.1:  return "10%"
                    case 0.25: return "25%"
                    case 0.5:  return "50%"
                    default:   return "100%"
                    }
                },
                selection: Binding(
                    get: { model.globalPlaybackRate },
                    set: { model.setGlobalRate($0) }
                ),
                accessibilityLabel: "Animation speed"
            )
            .frame(width: 200)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(AnimTab.allCases, id: \.self) { tab in
                    InspectChip(
                        tab.title,
                        selected: model.activeTab == tab,
                        count: tab == .events ? model.events.count : nil
                    ) {
                        model.activeTab = tab
                    }
                }
                Spacer(minLength: 8)
                if !model.records.isEmpty {
                    Text("\(model.liveRecords.count) active")
                        .font(InspectChrome.caption)
                        .foregroundStyle(InspectChrome.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.activeTab {
        case .timeline:
            if model.records.isEmpty {
                InspectEmptyState(
                    symbol: "play.circle",
                    title: "No animations",
                    message: "Web Animations API animations appear here as they run on the page."
                )
            } else {
                timelineContent
            }
        case .events:
            AnimEventsTab(events: model.events)
        }
    }

    private var timelineContent: some View {
        InspectSplit(key: "anim.detail", defaultFraction: 0.55, minFirst: 220, minSecond: 200, stackBelow: 520) {
            timelineList
        } second: {
            detailsOrEmpty
        }
    }

    // MARK: - Timeline list

    private var timelineList: some View {
        GeometryReader { geo in
            let timelineWidth = max(1, geo.size.width - AnimMetrics.labelWidth)
            VStack(spacing: 0) {
                rulerRow(timelineWidth: timelineWidth)
                InspectDivider()
                rowsArea(timelineWidth: timelineWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func rulerRow(timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: AnimMetrics.labelWidth)
            AnimTimeRuler(
                ticks: OrbitAnimationsLogic.rulerTicks(
                    totalDuration: model.totalDuration,
                    availableWidth: Double(timelineWidth)
                ),
                totalDuration: model.totalDuration,
                scrubTime: model.scrubTime
            )
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let x = value.location.x - AnimMetrics.labelWidth
                    let t = OrbitAnimationsLogic.timeFromScrubberX(
                        Double(max(0, x)), totalDuration: model.totalDuration, width: Double(timelineWidth)
                    )
                    model.scrub(to: t)
                }
                .onEnded { _ in model.endScrub() }
        )
    }

    private func rowsArea(timelineWidth: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.groups) { group in
                    AnimGroupHeader(label: group.elementLabel, count: group.rows.count)
                    ForEach(group.rows) { record in
                        AnimRowView(
                            record: record,
                            totalDuration: model.totalDuration,
                            scrubTime: model.scrubTime,
                            isSelected: model.selectedID == record.id,
                            onSelect: { model.selectAnimation(record.id) },
                            onHover: { hovering in
                                if hovering { model.hoverAnimation(record.id) }
                                else { model.unhoverAnimation() }
                            },
                            onReveal: { model.revealAnimationInElements(record.id) }
                        )
                    }
                    InspectDivider()
                }
            }
        }
    }

    // MARK: - Details / empty right pane

    @ViewBuilder
    private var detailsOrEmpty: some View {
        if let record = model.selectedRecord {
            AnimDetailsPane(record: record, session: session)
        } else {
            InspectEmptyState(
                symbol: "square.and.pencil",
                title: "Select an animation",
                message: "Click a row in the timeline to inspect its timing, keyframes, and easing."
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            InspectDivider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(InspectChrome.muted)
                Text("requestAnimationFrame, SMIL <animate>, canvas, WebGL, and video animations are not Web Animations API and cannot be controlled here. CSS transitions that have already finished cannot be replayed without re-triggering via CSS.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }
}
