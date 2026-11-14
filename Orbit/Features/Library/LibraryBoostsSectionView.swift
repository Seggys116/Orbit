import SwiftUI

struct LibraryBoostsSectionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.libraryStyle) private var style
    @State private var editingHost: String?
    private var router: LibraryRouter { env.libraryRouter }
    private var boostsByHost: [(host: String, boosts: [Boost])] {
        let grouped = Dictionary(grouping: env.boostStore.boosts, by: \.host)
        return grouped.map { (host: $0.key, boosts: $0.value) }.sorted { $0.host < $1.host }
    }

    @State private var boostsGloballyEnabled = BoostsGlobalSettings.isEnabled

    var body: some View {
        Group {
            VStack(spacing: LibraryModeMetrics.rowSpacing) {
                if !boostsByHost.isEmpty {
                    globalToggleRow
                }
                boostHostRows
            }
        }
        .onAppear { boostsGloballyEnabled = BoostsGlobalSettings.isEnabled }
        .sheet(item: Binding(
            get: { editingHost.map(HostBox.init) },
            set: { editingHost = $0?.value }
        )) { box in
            BoostsEditorView(host: box.value)
        }
    }

    private var globalToggleRow: some View {
        LibraryRowCard(isSelected: false) {
            Image(systemName: boostsGloballyEnabled ? "paintbrush.fill" : "paintbrush")
                .font(.system(size: OrbitMetrics.iconChrome - 4))
                .foregroundStyle(boostsGloballyEnabled ? style.foreground : style.secondary)
                .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                .accessibilityHidden(true)
            Text(BoostsGlobalSettings.label)
                .font(OrbitFont.sidebarRowActive)
                .foregroundStyle(style.foreground)
                .lineLimit(1)
            Spacer(minLength: OrbitSpacing.sm)
            Toggle("", isOn: $boostsGloballyEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(BoostsGlobalSettings.label)
        }
        .onChange(of: boostsGloballyEnabled) { _, newValue in
            BoostsGlobalSettings.isEnabled = newValue
            BoostRuntime.shared.reapplyAll(env: env)
        }
    }

    @ViewBuilder
    private var boostHostRows: some View {
        Group {
            if !boostsByHost.isEmpty {
                VStack(spacing: LibraryModeMetrics.rowSpacing) {
                    ForEach(boostsByHost, id: \.host) { entry in
                        LibraryRowCard(
                            isSelected: router.selection == .boostHost(entry.host),
                            actions: [LibraryRowAction(title: "Edit Boosts…", symbol: "slider.horizontal.3") {
                                editingHost = entry.host
                            }]
                        ) {
                            Image(systemName: "bolt.circle")
                                .font(.system(size: OrbitMetrics.iconChrome - 4))
                                .foregroundStyle(style.foreground)
                                .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                                Text(entry.host)
                                    .font(OrbitFont.sidebarRowActive)
                                    .foregroundStyle(style.foreground)
                                    .lineLimit(1)
                                Text("\(entry.boosts.count) Boost\(entry.boosts.count == 1 ? "" : "s") · \(entry.boosts.filter(\.isEnabled).count) active")
                                    .font(OrbitFont.commandBarRowSubtitle)
                                    .foregroundStyle(style.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        // Order matters: double-tap must be declared before single-tap.
                        .onTapGesture(count: 2) { editingHost = entry.host }
                        .onTapGesture {
                            withOrbitAnimation(OrbitMotion.standard) { router.select(.boostHost(entry.host)) }
                        }
                    }
                }
            }
        }
    }

    private struct HostBox: Identifiable {
        var value: String
        var id: String { value }
    }
}
