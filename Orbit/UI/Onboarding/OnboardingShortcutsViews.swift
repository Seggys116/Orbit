import AppKit
import SwiftUI

/// Keycaps are read from ShortcutRegistry and depress as the user presses the real keys; the first press of each ticks it off.
struct OnboardingShortcutsStep: View {
    @Binding var primer: OnboardingShortcutPrimer

    @State private var heldModifiers: UInt = 0
    @State private var pressedCommand: ShortcutCommandID?
    @State private var isStepActive = true

    private let registry = ShortcutRegistry.shared

    private struct ShortcutEntry: Identifiable {
        let command: ShortcutCommandID
        let binding: KeyBinding
        var id: ShortcutCommandID { command }
    }

    // A command the user has unbound has nothing to teach, so it is left out.
    private var rows: [ShortcutEntry] {
        primer.commands.compactMap { command in
            registry.binding(for: command).map { ShortcutEntry(command: command, binding: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeading(
                title: "A few keys do most of it.",
                subtitle: "Try them now. Each key presses down as you hit it, and you can change any of them later in Settings."
            )
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    shortcutRow(row)
                }
            }
        }
        .background(OnboardingKeyEventCapture(isActive: isStepActive, handler: handle))
        .onAppear { isStepActive = true }
        .onDisappear {
            isStepActive = false
            pressedCommand = nil
            heldModifiers = 0
        }
    }


    private func shortcutRow(_ row: ShortcutEntry) -> some View {
        let caps = OnboardingKeycaps.caps(for: row.binding)
        let didTry = primer.hasTried(row.command)
        let outer = OrbitRadius.lg
        return Button {
            tryShortcut(row.command)
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(caps, id: \.self) { cap in
                        OnboardingKeycapView(cap: cap, isPressed: isPressed(cap, in: row))
                    }
                }
                Text(Self.purpose(of: row.command))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OrbitNeutral.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: didTry ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(didTry ? OrbitNeutral.good : OrbitNeutral.muted2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: outer, style: .continuous).fill(OrbitNeutral.chip))
            .overlay(RoundedRectangle(cornerRadius: outer, style: .continuous).strokeBorder(OrbitNeutral.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: outer, style: .continuous))
        }
        .buttonStyle(.plain)
        .orbitAnimation(OrbitMotion.quick, value: didTry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.purpose(of: row.command)), \(row.binding.displayString)")
        .accessibilityValue(didTry ? "Tried" : "Not tried yet")
        .accessibilityHint("Press the shortcut, or activate this to try it")
    }

    static func purpose(of command: ShortcutCommandID) -> String {
        switch command {
        case .newTabCommandBar: "Search or open anything"
        case .toggleSidebar: "Show or hide the sidebar"
        case .jumpToSpace1: "Jump to your first Space"
        case .findOnPage: "Find or ask on the page"
        default: ShortcutRegistry.shared.command(for: command)?.title ?? command.rawValue
        }
    }

    private func isPressed(_ cap: OnboardingKeycap, in row: ShortcutEntry) -> Bool {
        switch cap.kind {
        case .modifier(let rawFlag):
            return heldModifiers & rawFlag != 0
        case .key:
            return pressedCommand == row.command
        }
    }


    private func tryShortcut(_ command: ShortcutCommandID) {
        pressedCommand = command
        primer.record(command)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            if pressedCommand == command { pressedCommand = nil }
        }
    }

    /// Returns true to swallow the event, so a taught chord does not also run its menu command (a new window, say) while practising.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyBinding.significantModifiers).rawValue
        switch event.type {
        case .flagsChanged:
            heldModifiers = modifiers
            return false
        case .keyDown:
            heldModifiers = modifiers
            guard let command = registry.command(matching: event), primer.commands.contains(command) else {
                return false
            }
            pressedCommand = command
            if !event.isARepeat { primer.record(command) }
            return true
        case .keyUp:
            guard let command = pressedCommand, isKeyUp(event, forCommand: command) else { return false }
            pressedCommand = nil
            return true
        default:
            return false
        }
    }

    // Modifiers may already be released on key-up, so only the key itself is compared.
    private func isKeyUp(_ event: NSEvent, forCommand command: ShortcutCommandID) -> Bool {
        guard let bound = registry.binding(for: command)?.key else { return false }
        if let symbolic = ShortcutRegistry.symbolicKey(for: event) { return symbolic == bound }
        if event.charactersIgnoringModifiers?.lowercased() == bound { return true }
        return ShortcutRegistry.asciiCapableCharacter(forKeyCode: event.keyCode, modifiers: event.modifierFlags) == bound
    }
}


/// A local key monitor scoped to the window hosting this view, alive only while the view is in a window.
private struct OnboardingKeyEventCapture: NSViewRepresentable {
    var isActive: Bool
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> OnboardingKeyCaptureView {
        let view = OnboardingKeyCaptureView()
        view.handler = handler
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: OnboardingKeyCaptureView, context: Context) {
        nsView.handler = handler
        nsView.isActive = isActive
    }
}

private final class OnboardingKeyCaptureView: NSView {
    var handler: (NSEvent) -> Bool = { _ in false }
    private var monitor: Any?

    // Cleared when the step starts leaving, so its chords stop being swallowed during the transition.
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { installMonitor() } else { removeMonitor() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    private func installMonitor() {
        removeMonitor()
        guard window != nil, isActive else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return MainActor.assumeIsolated { self.handler(event) ? nil : event }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
