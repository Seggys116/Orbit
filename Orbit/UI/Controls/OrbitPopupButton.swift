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
            OrbitPopupButtonMenuCatcher(menuProvider: buildMenu)
        }
        #else
        OrbitPopupButtonMenuCatcher(menuProvider: buildMenu)
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

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            let item = ClosureMenuItem(title: label(option)) { selection = option }
            item.state = option == selection ? .on : .off
            menu.addItem(item)
        }
        return menu
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

final class OrbitPopupButtonMenuHostView: OrbitMenuButtonClickCatchingView {

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers,
              characters == " " || characters == "\r" || characters == "\n" else {
            super.keyDown(with: event)
            return
        }
        guard let menu = menuProvider?() else { return }
        presentMenu(menu, self)
    }
}

private struct OrbitPopupButtonMenuCatcher: NSViewRepresentable {
    var menuProvider: () -> NSMenu

    func makeNSView(context: Context) -> OrbitPopupButtonMenuHostView {
        let view = OrbitPopupButtonMenuHostView()
        view.menuProvider = menuProvider
        return view
    }

    func updateNSView(_ nsView: OrbitPopupButtonMenuHostView, context: Context) {
        nsView.menuProvider = menuProvider
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
