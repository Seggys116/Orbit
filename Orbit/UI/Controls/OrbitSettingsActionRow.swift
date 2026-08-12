import SwiftUI

struct OrbitSettingsActionRow<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = OrbitControlMetrics.settingsRowContentSpacing
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            leading()
            Spacer(minLength: spacing)
            trailing()
        }
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}

extension OrbitSettingsActionRow where Leading == EmptyView {
    init(spacing: CGFloat = OrbitControlMetrics.settingsRowContentSpacing, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.spacing = spacing
        self.leading = { EmptyView() }
        self.trailing = trailing
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 4) {
        OrbitSettingsActionRow {
            HStack(spacing: 10) {
                Text("Connected.").font(.system(size: 11)).foregroundStyle(.secondary)
                OrbitButton(title: "Test Provider", kind: .secondary) {}
            }
        }
        Divider()
        OrbitSettingsActionRow {
            Text("Remove this Profile from every Space before deleting it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } trailing: {
            OrbitButton(title: "Delete Profile", kind: .destructive, isCompact: true) {}
        }
    }
    .padding()
    .frame(width: 420)
}
#endif
