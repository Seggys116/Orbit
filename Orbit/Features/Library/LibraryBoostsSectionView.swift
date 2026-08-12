import SwiftUI

struct LibraryBoostsSectionView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editingHost: String?
    @State private var router = LibraryRouter.shared
    private var boostsByHost: [(host: String, boosts: [Boost])] {
        let grouped = Dictionary(grouping: env.boostStore.boosts, by: \.host)
        return grouped.map { (host: $0.key, boosts: $0.value) }.sorted { $0.host < $1.host }
    }

    @State private var boostsGloballyEnabled = BoostsGlobalSettings.isEnabled

    var body: some View {
        Group {
            VStack(spacing: LibraryMetrics.rowSpacing) {
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
            HStack(spacing: 10) {
                Image(systemName: boostsGloballyEnabled ? "paintbrush.fill" : "paintbrush")
                    .font(.system(size: 13))
                    .foregroundStyle(boostsGloballyEnabled ? LibraryPalette.accent : LibraryPalette.textTertiary)
                    .frame(width: LibraryMetrics.rowIconSize, height: LibraryMetrics.rowIconSize)
                Text(BoostsGlobalSettings.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LibraryPalette.textPrimary)
                Spacer()
                Toggle("", isOn: $boostsGloballyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
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
                VStack(spacing: LibraryMetrics.rowSpacing) {
                    ForEach(boostsByHost, id: \.host) { entry in
                        LibraryRowCard(isSelected: router.selection == .boostHost(entry.host)) {
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(LibraryPalette.accent)
                                    .frame(width: LibraryMetrics.rowIconSize, height: LibraryMetrics.rowIconSize)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.host)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(LibraryPalette.textPrimary)
                                    Text("\(entry.boosts.count) Boost\(entry.boosts.count == 1 ? "" : "s") · \(entry.boosts.filter(\.isEnabled).count) active")
                                        .font(.system(size: 11))
                                        .foregroundStyle(LibraryPalette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LibraryPalette.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editingHost = entry.host }
                        .onTapGesture { router.select(.boostHost(entry.host)) }
                        .contextMenu {
                            Button("Edit Boosts…") { editingHost = entry.host }
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
