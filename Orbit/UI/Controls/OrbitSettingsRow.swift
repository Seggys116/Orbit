import SwiftUI

struct OrbitSettingsRow<Control: View>: View {
    var title: String
    var description: String? = nil
    @ViewBuilder var control: () -> Control

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitControlMetrics.settingsRowLabelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: OrbitControlMetrics.settingsRowContentSpacing) {
                Text(title)
                    .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .medium))
                    .foregroundStyle(OrbitControlColor.primaryForeground(for: colorScheme))
                    // Without this, a wide control starves the title's proposed width and it wraps
                    // one character per line instead of eliding.
                    .layoutPriority(1)
                Spacer(minLength: OrbitControlMetrics.settingsRowContentSpacing)
                control()
            }
            if let description {
                Text(description)
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                    // Without this, a multi-line description clips to one ellipsized line.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}

struct OrbitSettingsValueRow<Value: View>: View {
    var title: String
    var description: String? = nil
    @ViewBuilder var value: () -> Value

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitControlMetrics.settingsRowLabelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: OrbitControlMetrics.settingsRowContentSpacing) {
                Text(title)
                    .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .regular))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                    .layoutPriority(1)
                Spacer(minLength: OrbitControlMetrics.settingsRowContentSpacing)
                value()
            }
            if let description {
                Text(description)
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}

struct OrbitSectionHeader: View {
    var title: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.system(size: OrbitControlMetrics.sectionHeaderFontSize, weight: .semibold))
            .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
            .accessibilityAddTraits(.isHeader)
    }
}

struct OrbitSettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitControlMetrics.sectionHeaderSpacing) {
            if let title {
                OrbitSectionHeader(title: title)
            }
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionRowSpacing) {
                content()
            }
            .padding(OrbitControlMetrics.sectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous)
                    .fill(OrbitControlColor.fill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous)
                    .strokeBorder(OrbitControlColor.border(for: colorScheme))
            )
        }
    }
}

#if DEBUG
#Preview {
    OrbitSettingsSection(title: "Browsing") {
        OrbitSettingsRow(title: "Disable Automatic Peek") {
            OrbitToggle(accessibilityLabel: "Disable Automatic Peek", isOn: .constant(false))
        }
        OrbitSettingsRow(title: "Confirm before quitting", description: "Only prompts if multiple tabs are open.") {
            OrbitToggle(accessibilityLabel: "Confirm before quitting", isOn: .constant(true))
        }
        OrbitSettingsValueRow(title: "Engine") {
            Text("Chromium 151.0.7922.72").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 420)
}
#endif
