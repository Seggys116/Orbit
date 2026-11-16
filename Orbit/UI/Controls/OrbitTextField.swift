import SwiftUI

struct OrbitTextField: View {
    var placeholder: String
    @Binding var text: String
    var systemImage: String? = nil
    var accentColor: Color = .accentColor
    var accessibilityLabel: String? = nil
    // .focused(_:) on the outside of this view does nothing: FocusState binds to the concrete leaf, not a container. Pass externalFocus instead.
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
        .orbitAnimation(OrbitMotion.quick, value: isFocused)
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .accessibilityValue(text)
    }
}

// MARK: - Commit on an outside click

extension View {
    /// An edit-in-place box submits and closes when the user clicks anywhere outside it, instead of staying open.
    /// Active only while `isEditing`; the click itself is still delivered, so clicking another control works as one click.
    func commitsOnOutsideClick(while isEditing: Bool, perform commit: @escaping () -> Void) -> some View {
        background(OutsideClickCatcher(isActive: isEditing, action: commit))
    }
}

private struct OutsideClickCatcher: NSViewRepresentable {
    var isActive: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> OutsideClickCatcherView { OutsideClickCatcherView() }

    func updateNSView(_ view: OutsideClickCatcherView, context: Context) {
        view.action = action
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: OutsideClickCatcherView, coordinator: ()) {
        view.setActive(false)
    }
}

/// Sized to the box it backs, so "outside" is the box's own frame. A local monitor, not a hit-tested view, because
/// SwiftUI areas that take no focus never move AppKit's first responder and would otherwise leave the box open.
final class OutsideClickCatcherView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setActive(_ active: Bool) {
        if active, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        } else if !active, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(point) else { return }
        action?()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
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
