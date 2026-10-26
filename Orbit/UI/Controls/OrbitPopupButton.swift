import AppKit
import SwiftUI

// Not a SwiftUI Menu: Menu(...).menuStyle(.borderlessButton) does not open reliably
// in this app's NSHostingView configuration.
struct OrbitPopupButton<Option: Hashable>: View {
    var options: [Option]
    var label: (Option) -> String
    @Binding var selection: Option
    var accessibilityLabel: String
    var accentColor: Color = .accentColor
    var expands: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    var body: some View {
        controlLabel
            .overlay(menuCatcher)
            .modifier(OrbitPopupSizing(isFixed: !expands))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(label(selection))
    }

    @ViewBuilder
    private var menuCatcher: some View {
        #if DEBUG
        if !screenshotModeRepresentableDisabled {
            OrbitPopupButtonMenuCatcher(entriesProvider: buildEntries)
        }
        #else
        OrbitPopupButtonMenuCatcher(entriesProvider: buildEntries)
        #endif
    }

    private var controlLabel: some View {
        HStack(spacing: 6) {
            Text(label(selection))
                .font(.system(size: OrbitControlMetrics.popupFontSize))
                .foregroundStyle(OrbitControlColor.primaryForeground(for: colorScheme))
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: OrbitControlMetrics.popupChevronSize, weight: .semibold))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
        }
        .padding(.horizontal, OrbitControlMetrics.popupHorizontalPadding)
        .frame(height: OrbitControlMetrics.popupHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.popupCornerRadius, style: .continuous)
                .fill(OrbitControlColor.fill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.popupCornerRadius, style: .continuous)
                .strokeBorder(OrbitControlColor.border(for: colorScheme))
        )
        .contentShape(RoundedRectangle(cornerRadius: OrbitControlMetrics.popupCornerRadius, style: .continuous))
    }

    func buildEntries() -> [OrbitContextMenuEntry] {
        options.map { option -> OrbitContextMenuEntry in
            .item(OrbitContextMenuItem(
                title: label(option),
                isChecked: option == selection,
                action: { selection = option }
            ))
        }
    }
}

private struct OrbitPopupSizing: ViewModifier {
    var isFixed: Bool

    func body(content: Content) -> some View {
        if isFixed {
            content.fixedSize()
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

@MainActor
final class OrbitPopupButtonMenuHostView: NSView, OrbitClickCatching {
    var entriesProvider: (() -> [OrbitContextMenuEntry])?
    var presentEntries: (([OrbitContextMenuEntry], NSView) -> Void)?

    private let controller = OrbitMenuPanelController()

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if OrbitMenuClickGuard.wasDismissedThisTurn { return }
        presentMenu()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers,
              characters == " " || characters == "\r" || characters == "\n" else {
            super.keyDown(with: event)
            return
        }
        presentMenu()
    }

    private func presentMenu() {
        guard let entries = entriesProvider?() else { return }
        if let presentEntries {
            presentEntries(entries, self)
            return
        }
        guard let window else { return }
        controller.present(
            entries: entries,
            anchorRect: window.convertToScreen(convert(bounds, to: nil)),
            anchorView: self,
            ownerWindow: window,
            mode: .anchored,
            preferredDirection: .down,
            showsArrow: false
        )
    }

    // Otherwise the transparent titlebar band turns the click into a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }
}

private struct OrbitPopupButtonMenuCatcher: NSViewRepresentable {
    var entriesProvider: () -> [OrbitContextMenuEntry]

    func makeNSView(context: Context) -> OrbitPopupButtonMenuHostView {
        let view = OrbitPopupButtonMenuHostView()
        view.entriesProvider = entriesProvider
        return view
    }

    func updateNSView(_ nsView: OrbitPopupButtonMenuHostView, context: Context) {
        nsView.entriesProvider = entriesProvider
    }
}

#if DEBUG
#Preview {
    OrbitPopupButton(
        options: ["Never", "After 12 Hours", "After 24 Hours"],
        label: { $0 },
        selection: .constant("After 12 Hours"),
        accessibilityLabel: "Archive tabs after"
    )
    .padding()
    .frame(width: 260)
}
#endif
