import SwiftUI

struct AdBlockerSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @ObservedObject private var controller = ContentBlockingRuntime.shared.controller

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Ad Blocker").font(.system(size: 20, weight: .bold))

            OrbitSettingsSection(title: nil) {
                OrbitSettingsRow(
                    title: "Block Ads & Trackers",
                    description: "Blocks ads, trackers and cookie banners as pages load, using whichever lists below are enabled."
                ) {
                    OrbitToggle(
                        accessibilityLabel: "Block Ads and Trackers",
                        isOn: Binding(
                            get: { controller.isEnabled },
                            set: { newValue in Task { await controller.setEnabled(newValue) } }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }

                OrbitSettingsActionRow {
                    Text(summaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    OrbitButton(
                        title: controller.isUpdating ? "Updating…" : "Update Lists Now",
                        kind: .secondary,
                        isCompact: true,
                        accentColor: SettingsPalette.accent
                    ) {
                        Task { await controller.refresh(force: true) }
                    }
                    .disabled(controller.isUpdating)
                }
            }

            ForEach(FilterListCategory.allCases, id: \.self) { category in
                categorySection(category)
            }
        }
        .task { await controller.awaitInitialCacheLoad() }
    }

    private var summaryText: String {
        if controller.isUpdating { return "Downloading and compiling filter lists…" }
        let listCount = controller.enabledListIDs.count
        var text = "\(controller.compiledRuleCount.formatted()) rules compiled from \(listCount) enabled list\(listCount == 1 ? "" : "s")."
        if let lastUpdatedAt = controller.lastUpdatedAt {
            text += " Last updated \(CommandBarRelativeTime.string(from: lastUpdatedAt))."
        } else {
            text += " Never updated."
        }
        return text
    }

    @ViewBuilder
    private func categorySection(_ category: FilterListCategory) -> some View {
        let lists = FilterListCatalog.lists(in: category).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        if !lists.isEmpty {
            OrbitSettingsSection(title: category.displayName) {
                if let masterTitle = category.settingsRowTitle {
                    OrbitSettingsRow(title: masterTitle, description: category.settingsRowFootnote) {
                        OrbitToggle(
                            accessibilityLabel: masterTitle,
                            isOn: Binding(
                                get: { controller.isCategoryEnabled(category) },
                                set: { newValue in Task { await controller.setCategory(category, enabled: newValue) } }
                            ),
                            accentColor: SettingsPalette.accent
                        )
                    }
                    Divider()
                }
                ForEach(lists) { descriptor in
                    FilterListRow(
                        descriptor: descriptor,
                        isEnabled: controller.enabledListIDs.contains(descriptor.id),
                        statusText: statusText(for: descriptor),
                        isFailed: isFailed(descriptor.id),
                        onToggle: { newValue in
                            Task { await controller.setList(descriptor.id, enabled: newValue) }
                        },
                        onOpenLink: openLink
                    )
                }
            }
        }
    }

    private func isFailed(_ listID: String) -> Bool {
        if case .failed = controller.listStates[listID] { return true }
        return false
    }

    private func statusText(for descriptor: FilterListDescriptor) -> String {
        let isEnabled = controller.enabledListIDs.contains(descriptor.id)
        var parts: [String] = []

        switch controller.listStates[descriptor.id] {
        case .cached(let entry)?, .stale(let entry)?:
            parts.append("Updated \(CommandBarRelativeTime.string(from: entry.fetchedAt))")
        case .failed(let message, _)?:
            parts.append("Update failed: \(message)")
        case .neverFetched?, nil:
            parts.append("Not yet downloaded")
        }

        if isEnabled, let stats = controller.listCompileStats[descriptor.id] {
            parts.append("\(stats.totalCompiledRules.formatted()) rules compiled")
        } else if !isEnabled {
            parts.append("Off")
        }

        return parts.joined(separator: " · ")
    }

    private func openLink(_ url: URL) {
        guard let spaceID = env.activeSpace?.id else { return }
        env.openTab(url: url, in: spaceID)
    }
}

private struct FilterListRow: View {
    var descriptor: FilterListDescriptor
    var isEnabled: Bool
    var statusText: String
    var isFailed: Bool
    var onToggle: (Bool) -> Void
    var onOpenLink: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitControlMetrics.settingsRowLabelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: OrbitControlMetrics.settingsRowContentSpacing) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .medium))
                    if descriptor.isDefaultEnabled {
                        Text("Default")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tertiary.opacity(0.3)))
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: OrbitControlMetrics.settingsRowContentSpacing)
                OrbitToggle(
                    accessibilityLabel: "\(descriptor.displayName) enabled",
                    isOn: Binding(get: { isEnabled }, set: onToggle),
                    accentColor: SettingsPalette.accent,
                    isCompact: true
                )
            }

            HStack(spacing: 8) {
                Text("\(statusText) · \(descriptor.licence)")
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(isFailed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = descriptor.infoURL ?? descriptor.licenceURL {
                    OrbitButton(title: "Info…", kind: .ghost, isCompact: true, accentColor: SettingsPalette.accent) {
                        onOpenLink(link)
                    }
                }
            }
        }
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}
