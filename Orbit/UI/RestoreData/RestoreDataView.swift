import SwiftUI

struct RestoreDataView: View {

    @Bindable var model: RestoreDataModel

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            OrbitPopupButton(
                options: RestoreDataScope.allCases,
                label: { $0.displayName },
                selection: $model.scope,
                accessibilityLabel: "Data to restore"
            )

            OrbitPopupButton(
                options: model.backups.map { Optional($0) },
                label: { RestoreDataModel.label(for: $0) },
                selection: $model.selectedBackup,
                accessibilityLabel: "Backup"
            )

            Spacer(minLength: 0)

            // No .defaultAction shortcut: a stray Return must not replace someone's Spaces and tabs.
            HStack(spacing: 0) {
                OrbitButton(title: "Restore", kind: .secondary) { model.restore() }
                    .disabled(!model.canRestore)
                    .orbitTooltip(restoreDisabledHelp)
                Spacer(minLength: 0)
            }
        }
        .padding(Layout.windowPadding)
        .frame(minWidth: Layout.minimumWidth, minHeight: Layout.minimumHeight, alignment: .topLeading)
    }

    private var restoreDisabledHelp: String {
        if model.backups.isEmpty {
            return "No backups have been saved yet. Orbit writes one each time it saves your Spaces and tabs."
        }
        if model.selectedBackup == nil {
            return "Choose a backup to restore."
        }
        return "Replaces your Spaces, tabs and split views with the ones saved at this time."
    }

    private enum Layout {
        static let windowPadding: CGFloat = 20
        static let rowSpacing: CGFloat = 12
        static let minimumWidth: CGFloat = 280
        static let minimumHeight: CGFloat = 160
    }
}
