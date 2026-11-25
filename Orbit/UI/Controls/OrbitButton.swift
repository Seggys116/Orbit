import SwiftUI

enum OrbitButtonKind {
    case primary
    case secondary
    case destructive
    case ghost
}

struct OrbitButton: View {
    var title: String
    var systemImage: String? = nil
    var kind: OrbitButtonKind = .secondary
    /// Requires `systemImage` to be non-nil.
    var isIconOnly: Bool = false
    var isCompact: Bool = false
    var titleFont: Font? = nil
    var accentColor: Color = .accentColor
    var keyboardShortcut: KeyboardShortcut? = nil
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var height: CGFloat { isCompact ? OrbitControlMetrics.buttonCompactHeight : OrbitControlMetrics.buttonHeight }
    private var horizontalPadding: CGFloat { isIconOnly ? 0 : (isCompact ? OrbitControlMetrics.buttonCompactHorizontalPadding : OrbitControlMetrics.buttonHorizontalPadding) }

    var body: some View {
        Group {
            if let keyboardShortcut {
                button.keyboardShortcut(keyboardShortcut)
            } else {
                button
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: OrbitControlMetrics.buttonIconSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: OrbitControlMetrics.buttonFontSize, weight: .medium))
                }
                if !isIconOnly {
                    Text(title)
                        .font(titleFont ?? .system(size: OrbitControlMetrics.buttonFontSize, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .frame(minWidth: isIconOnly ? height : nil)
            .background(background)
            .overlay(border)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Self.primaryForeground(onAccent: accentColor)
        case .secondary: return OrbitControlColor.primaryForeground(for: colorScheme)
        case .destructive: return isHovering ? .white : Color.red
        case .ghost: return isHovering ? OrbitControlColor.primaryForeground(for: colorScheme) : OrbitControlColor.secondaryForeground(for: colorScheme)
        }
    }

    // white text on a light accent (a dark theme's near-white accent) is unreadable, so dark text is used past this brightness.
    static let darkTextLuminanceThreshold = 0.5

    static func primaryForeground(onAccent accent: Color) -> Color {
        let c = accent.srgbComponents
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        return luminance > darkTextLuminanceThreshold ? Color.black.opacity(0.85) : .white
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: OrbitControlMetrics.buttonCornerRadius, style: .continuous)
                .fill(accentColor.opacity(isHovering ? 1 : 0.92))
        case .secondary:
            RoundedRectangle(cornerRadius: OrbitControlMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovering ? OrbitControlColor.hoverFill(for: colorScheme) : OrbitControlColor.fill(for: colorScheme))
        case .destructive:
            RoundedRectangle(cornerRadius: OrbitControlMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovering ? Color.red.opacity(0.85) : Color.red.opacity(0.12))
        case .ghost:
            RoundedRectangle(cornerRadius: OrbitControlMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovering ? OrbitControlColor.hoverFill(for: colorScheme) : Color.clear)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .primary, .destructive, .ghost:
            EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: OrbitControlMetrics.buttonCornerRadius, style: .continuous)
                .strokeBorder(OrbitControlColor.border(for: colorScheme))
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 10) {
        OrbitButton(title: "Make Orbit My Default Browser", kind: .primary) {}
        OrbitButton(title: "Cancel", kind: .secondary) {}
        OrbitButton(title: "Remove", kind: .destructive) {}
        OrbitButton(title: "Delete Rule", systemImage: "trash", kind: .ghost, isIconOnly: true) {}
    }
    .padding()
}
#endif
