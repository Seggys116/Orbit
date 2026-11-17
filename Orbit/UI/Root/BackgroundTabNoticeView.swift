import SwiftUI

/// The small card at the top right of the window that says a link opened in a new tab behind the current one.
/// Pressing it goes to that tab.
@MainActor
struct BackgroundTabNoticeView: View {
    @Environment(AppEnvironment.self) private var env

    static let title = "New Tab"
    static let width: CGFloat = 260

    var body: some View {
        Group {
            if let notice = env.visibleBackgroundTabNotice, let tab = env.tab(notice.tabID) {
                card(for: tab)
                    .id(notice.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .orbitAnimation(OrbitMotion.standard, value: env.visibleBackgroundTabNotice)
    }

    private func card(for tab: Tab) -> some View {
        let theme = env.activeSpace?.theme
        let foreground = theme?.readableForeground ?? .primary
        let secondary = theme?.readableSecondaryForeground ?? .secondary
        let shape = RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
        return Button {
            env.openBackgroundTabFromNotice()
        } label: {
            HStack(spacing: OrbitMetrics.cardInset) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize + 4, weight: .medium))
                    .foregroundStyle(foreground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title)
                        .font(OrbitFont.sidebarRowActive)
                        .foregroundStyle(foreground)
                    Text(tab.displayTitle)
                        .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(OrbitMetrics.cardInset)
            .frame(width: Self.width, alignment: .leading)
            .background(
                shape
                    .fill(Color(theme?.primary.nsColor ?? .windowBackgroundColor))
                    .overlay(shape.fill(foreground.opacity(OrbitMetrics.sidebarActiveRowOpacity)))
                    .overlay(shape.strokeBorder(foreground.opacity(OrbitMetrics.cardBorderOpacity), lineWidth: OrbitMetrics.cardBorderWidth))
            )
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 3)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .padding(.top, OrbitMetrics.cardInset)
        .padding(.trailing, OrbitMetrics.cardInset)
        .accessibilityLabel("\(Self.title). \(tab.displayTitle)")
        .accessibilityHint("Goes to the new tab")
    }
}
