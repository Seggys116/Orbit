//  The "Save to Passwords?" and "Update in Passwords?" prompt. Non-modal: a borderless panel pinned to the top-trailing corner of the page,
//  where the address bar's own prompts sit, that leaves the page usable. It goes away when the tab does (the page view leaves its window),
//  when its window closes, or when the user answers it.

import AppKit
import SwiftUI

struct PasswordSavePromptModel: Equatable {
    enum Kind: Equatable {
        case save
        case update
    }

    var kind: Kind
    /// The origin as shown to the user, such as `accounts.example.com` or `localhost:3000` (`PasswordAutofillPolicy.displayOrigin`).
    var site: String
    var username: String

    var title: String {
        switch kind {
        case .save: return "Save password for \(site) to Passwords?"
        case .update: return "Update password for \(site) in Passwords?"
        }
    }

    /// Never the password.
    var detail: String {
        switch kind {
        case .save: return username
        case .update: return "\(username) on \(site)"
        }
    }

    var primaryTitle: String { kind == .save ? "Save to Passwords" : "Update" }
}

struct PasswordSavePromptView: View {
    var model: PasswordSavePromptModel
    var onPrimary: () -> Void
    var onNotNow: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.orbitSpaceTheme) private var environmentTheme

    private var chrome: SpaceThemeChrome? {
        (environmentTheme ?? OrbitMenuThemeSource.shared.theme).map {
            SpaceThemeChrome(theme: $0, colorScheme: colorScheme)
        }
    }

    private var surface: OrbitMenuSurfaceShape {
        OrbitMenuSurfaceShape(cornerRadius: OrbitMetrics.popoverCornerRadius)
    }

    var body: some View {
        let chrome = self.chrome
        let accent = chrome?.accent ?? Color.accentColor
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(chrome?.secondaryForeground ?? OrbitControlColor.secondaryForeground(for: colorScheme))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(chrome?.foreground ?? OrbitControlColor.primaryForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(chrome?.secondaryForeground ?? OrbitControlColor.secondaryForeground(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                OrbitButton(title: model.primaryTitle, kind: .primary, isCompact: true, accentColor: accent, action: onPrimary)
                OrbitButton(title: "Not Now", kind: .secondary, isCompact: true, accentColor: accent, action: onNotNow)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: PasswordSavePromptPresenter.contentWidth)
        .background(surface.fill(chrome?.surface ?? OrbitColor.menuSurface(for: colorScheme)))
        .overlay(
            surface.strokeBorder(
                chrome?.border ?? OrbitControlColor.border(for: colorScheme),
                lineWidth: OrbitAcrylic.panelEdgeHighlightWidth
            )
        )
        .compositingGroup()
        .shadow(
            color: .black.opacity(OrbitMetrics.contextMenuShadowOpacity),
            radius: OrbitMetrics.contextMenuShadowRadius,
            y: OrbitMetrics.contextMenuShadowYOffset
        )
        .padding(OrbitMetrics.contextMenuShadowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }
}

final class OrbitPasswordPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PasswordSavePromptPresenter {

    static let contentWidth: CGFloat = 340
    private static let edgeInset: CGFloat = 12

    /// Set only by tests: replaces the real panel with a recorder of what would have been shown and of what its primary button would do.
    var presentForTesting: ((_ model: PasswordSavePromptModel, _ onPrimary: @escaping () -> Void) -> Void)?

    private(set) var presentedModel: PasswordSavePromptModel?
    var isPresented: Bool { panel != nil }

    private var panel: OrbitPasswordPromptPanel?
    private var sentinel: OrbitMenuAnchorSentinel?
    private var closeObserver: NSObjectProtocol?

    /// `anchorView` is the page the sign-in happened on. Each callback runs once, after the prompt is gone.
    func present(
        _ model: PasswordSavePromptModel,
        anchorView: NSView,
        onPrimary: @escaping () -> Void,
        onNotNow: @escaping () -> Void = {}
    ) {
        if let presentForTesting {
            presentedModel = model
            presentForTesting(model, onPrimary)
            return
        }
        dismiss()
        guard let window = anchorView.window else { return }

        let view = PasswordSavePromptView(
            model: model,
            onPrimary: { [weak self] in
                self?.dismiss()
                onPrimary()
            },
            onNotNow: { [weak self] in
                self?.dismiss()
                onNotNow()
            }
        )
        let hosting = OrbitFirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = OrbitPasswordPromptPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityLabel(model.title)
        panel.appearance = window.effectiveAppearance

        let pageOnScreen = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let padding = OrbitMetrics.contextMenuShadowPadding
        let origin = CGPoint(
            x: pageOnScreen.maxX - size.width + padding - Self.edgeInset,
            y: pageOnScreen.maxY - size.height + padding - Self.edgeInset
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        self.presentedModel = model
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        // The page view leaves its window when another tab takes over.
        let sentinel = OrbitMenuAnchorSentinel(frame: .zero)
        sentinel.onWindowLost = { [weak self] in self?.dismiss() }
        anchorView.addSubview(sentinel)
        self.sentinel = sentinel

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        sentinel?.onWindowLost = nil
        sentinel?.removeFromSuperview()
        sentinel = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let panel {
            // A button click makes the panel key; the browser window takes that back so the page keeps the keyboard.
            let owner = panel.parent
            let wasKey = panel.isKeyWindow
            owner?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            if wasKey, let owner, owner.isVisible { owner.makeKey() }
        }
        panel = nil
        presentedModel = nil
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
