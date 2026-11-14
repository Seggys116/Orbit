import AppKit
import SwiftUI

struct OrbitFrameworksPane: View {
    var session: OrbitInspectSession

    private var model: OrbitFrameworksModel { session.frameworks }

    var body: some View {
        InspectSplit(key: "fw.main", defaultFraction: 0.26, minFirst: 160, minSecond: 320, stackBelow: 600) {
            sidebarList
        } second: {
            mainArea
        }
    }

    // MARK: - Sidebar

    private var sidebarList: some View {
        VStack(spacing: 0) {
            sidebarHeader
            InspectDivider()
            if model.detections.isEmpty && !model.isScanning {
                InspectEmptyState(
                    symbol: "questionmark.circle",
                    title: "No technologies detected",
                    message: "Navigate to a page and press Refresh. Detection requires JavaScript to execute in the page."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.filteredDetections) { d in
                            FWTechRow(detection: d, selected: false)
                                .padding(.vertical, 1)
                                .padding(.horizontal, InspectChrome.panelPadding)
                        }
                        if model.isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Scanning…").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                            }
                            .padding(.horizontal, InspectChrome.panelPadding)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Technologies").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                    .padding(.leading, InspectChrome.panelPadding)
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.refresh()
                }
                .padding(.trailing, 4)
            }
            .frame(height: 32)
            InspectSearchField(placeholder: "Filter", text: Binding(
                get: { model.techFilter },
                set: { model.techFilter = $0 }
            ))
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Main area

    private var mainArea: some View {
        VStack(spacing: 0) {
            tabBar
            InspectDivider()
            tabContent
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(FWTab.allCases) { tab in
                    InspectChip(tab.rawValue, selected: model.tab == tab) {
                        model.selectTab(tab)
                    }
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .components:
            FWComponentsTab(model: model, session: session)
        case .data:
            FWDataTab(model: model, session: session)
        case .routes:
            FWRoutesTab(model: model)
        case .devServer:
            FWDevServerTab(model: model, session: session)
        case .technologies:
            FWTechnologiesTab(model: model, session: session)
        }
    }
}
