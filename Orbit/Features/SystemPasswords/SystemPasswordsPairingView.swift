import AppKit
import SwiftUI

/// The small sheet where the person types the six-digit code macOS shows when Orbit pairs with Passwords.
struct SystemPasswordsPairingView: View {
    let passwords: SystemPasswords
    var onClose: () -> Void

    @State private var code = ""
    @State private var isSubmitting = false
    @FocusState private var isCodeFocused: Bool

    static let codeLength = 6

    static func digits(in text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(codeLength))
    }

    private var canSubmit: Bool {
        passwords.state == .awaitingPIN && !isSubmitting && Self.digits(in: code).count == Self.codeLength
    }

    private var prompt: String {
        switch passwords.state {
        case .notStarted, .starting, .pairing:
            return "Asking macOS for a code."
        case .awaitingPIN:
            return "Type the 6-digit code macOS is showing. macOS shows it only while this Mac is unlocked."
        case .verifyingPIN:
            return "Checking the code."
        case .paired:
            return "Orbit is paired with Passwords."
        default:
            return SystemPasswords.summary(of: passwords.state).detail
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Pair Orbit with Passwords")
                    .font(.system(size: 16, weight: .semibold))
            }

            Text(prompt)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            OrbitTextField(
                placeholder: "6-digit code",
                text: $code,
                systemImage: "number",
                accentColor: SettingsPalette.accent,
                accessibilityLabel: "Code from macOS",
                externalFocus: $isCodeFocused
            )
            .onSubmit(submit)
            .disabled(passwords.state != .awaitingPIN || isSubmitting)

            if let error = passwords.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OrbitButton(title: "Cancel", kind: .secondary, accentColor: SettingsPalette.accent, action: cancel)
                OrbitButton(title: "Pair", kind: .primary, accentColor: SettingsPalette.accent, action: submit)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            isCodeFocused = true
            if passwords.canPair {
                Task { await passwords.beginPairing() }
            }
        }
        .onChange(of: code) { _, newValue in
            let digits = Self.digits(in: newValue)
            if digits != newValue { code = digits }
            if digits.count == Self.codeLength { submit() }
        }
        .onChange(of: passwords.state) { _, newState in
            if newState == .awaitingPIN { isCodeFocused = true }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let pin = Self.digits(in: code)
        isSubmitting = true
        code = ""
        Task {
            let paired = await passwords.submitPIN(pin)
            isSubmitting = false
            if paired { onClose() }
        }
    }

    private func cancel() {
        if passwords.state != .paired { passwords.cancelPairing() }
        onClose()
    }
}

/// Shows the pairing sheet over a browser window, or on its own when there is none. One at a time.
@MainActor
final class SystemPasswordsPairingPresenter {
    static let shared = SystemPasswordsPairingPresenter()

    private var panel: NSPanel?

    func present(over window: NSWindow?, passwords: SystemPasswords) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "Pair with Passwords"
        panel.contentViewController = NSHostingController(rootView: SystemPasswordsPairingView(passwords: passwords) { [weak self] in
            self?.dismiss()
        })
        self.panel = panel
        if let window, window.isVisible, window.attachedSheet == nil {
            window.beginSheet(panel)
        } else {
            panel.level = .floating
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        panel.contentViewController = nil
    }
}
