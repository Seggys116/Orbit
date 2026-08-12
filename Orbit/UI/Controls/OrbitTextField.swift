import SwiftUI

struct OrbitTextField: View {
    var placeholder: String
    @Binding var text: String
    var systemImage: String? = nil
    var accentColor: Color = .accentColor
    var accessibilityLabel: String? = nil
    // Attaching .focused(_:) to the outside of this view does nothing; FocusState
    // binds to the concrete leaf underneath it, not a container. Pass externalFocus instead.
    var externalFocus: FocusState<Bool>.Binding? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var internalFocus: Bool

    private var isFocused: Bool { externalFocus?.wrappedValue ?? internalFocus }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: OrbitControlMetrics.textFieldIconSize))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
            }
            Group {
                if let externalFocus {
                    TextField(placeholder, text: $text).focused(externalFocus)
                } else {
                    TextField(placeholder, text: $text).focused($internalFocus)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: OrbitControlMetrics.textFieldFontSize))
            .foregroundStyle(OrbitControlColor.primaryForeground(for: colorScheme))
        }
        .padding(.horizontal, OrbitControlMetrics.textFieldHorizontalPadding)
        .frame(height: OrbitControlMetrics.textFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.textFieldCornerRadius, style: .continuous)
                .fill(OrbitControlColor.fill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.textFieldCornerRadius, style: .continuous)
                .strokeBorder(isFocused ? accentColor.opacity(0.9) : OrbitControlColor.border(for: colorScheme), lineWidth: isFocused ? OrbitControlMetrics.textFieldFocusRingWidth : 1)
        )
        .animation(OrbitMotion.quick, value: isFocused)
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .accessibilityValue(text)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        OrbitTextField(placeholder: "Search by command or key combo", text: .constant(""), systemImage: "magnifyingglass")
        OrbitTextField(placeholder: "Name", text: .constant("Work"))
    }
    .padding()
    .frame(width: 280)
}
#endif
