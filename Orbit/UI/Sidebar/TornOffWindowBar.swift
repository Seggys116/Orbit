import SwiftUI

struct TornOffWindowBar: View {
    @Environment(AppEnvironment.self) private var env

    var theme: SpaceTheme

    private var focusedTabID: TabID? { env.activeTabID }

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            // Full readable weight, not sidebarSpaceNameOpacity: this is the sole notice of irreversible data loss and must not be the faintest text on screen.
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.readableForeground)
                .accessibilityHidden(true)

            Text("Temporary — closes with this window")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: OrbitMetrics.sidebarRowContentSpacing)

            moveToMainWindowButton
        }
        .padding(.horizontal, OrbitMetrics.sidebarRowContentInset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
                .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
        )
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This window is temporary. Its tabs close with the window.")
    }

    private var moveToMainWindowButton: some View {
        Button {
            guard let focusedTabID else { return }
            env.moveTabToMainWindow(focusedTabID, destinationSpaceID: nil)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: OrbitMetrics.sidebarSpaceIconSize, height: OrbitMetrics.sidebarSpaceIconSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.readableForeground.opacity(focusedTabID == nil ? 0.3 : 0.9))
        .disabled(focusedTabID == nil)
        .orbitTooltip("Move Tab to Main Window")
        .accessibilityLabel("Move tab to main window")
    }
}
