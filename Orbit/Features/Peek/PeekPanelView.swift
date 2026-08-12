//  Built but not wired up: nothing calls `extensionPoints.peekPanel` and no
//  host view observes `PeekState.shared.activePreview`.

import SwiftUI

enum PeekSettings {
    #if DEBUG
    static var defaults: UserDefaults = .standard
    #else
    static let defaults: UserDefaults = .standard
    #endif

    private static let key = "OrbitAutomaticPeekEnabled"
    private static let shiftKey = "OrbitShiftClickPeekEnabled"

    // Legacy key, also written by SiteControlPopoverView's "Open Links in Modal" row (inverted).
    private static let legacyDisableKey = "OrbitDisableAutoPeek"

    // Setter mirrors into the legacy key so SiteControlPopoverView's row (which reads it directly)
    // can't disagree with this one; the legacy key is only ever a seed for the first read here.
    static var isAutomaticPeekEnabled: Bool {
        get {
            if let stored = defaults.object(forKey: key) as? Bool { return stored }
            return !defaults.bool(forKey: legacyDisableKey)
        }
        set {
            defaults.set(newValue, forKey: key)
            defaults.set(!newValue, forKey: legacyDisableKey)
        }
    }

    static var isShiftClickPeekEnabled: Bool {
        get { defaults.object(forKey: shiftKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: shiftKey) }
    }
}

struct PeekPanelView: View {
    @Environment(AppEnvironment.self) private var env
    var sourceTabID: TabID
    var url: URL

    private var previewTabID: TabID? { PeekState.shared.previewTabID }

    @State private var isLoading = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            panel
            controls
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .onExitCommand { dismiss() }
    }

    private var panel: some View {
        content
        .frame(maxWidth: 980, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: peekCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: peekCornerRadius).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .onAppear(perform: materialize)
        .onDisappear(perform: teardown)
    }

    private var peekCornerRadius: CGFloat { 18 }

    private var controls: some View {
        VStack(spacing: 10) {
            peekControl(
                systemName: "xmark",
                help: "Dismiss (⌘W)",
                action: dismiss
            )
            .keyboardShortcut("w", modifiers: .command)

            peekControl(
                systemName: "arrow.up.left.and.arrow.down.right",
                help: "Open as Tab (⌘O)",
                action: promoteToTab
            )
            .keyboardShortcut("o", modifiers: .command)

            peekControl(
                systemName: "rectangle.split.2x1",
                help: "Split View",
                action: promoteToSplitView
            )
        }
    }

    private func peekControl(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .orbitTooltip(help)
    }

    @ViewBuilder
    private var content: some View {
        if let previewTabID, let contents = env.webContents[previewTabID] {
            WebContentsHostView(contents: contents, environment: env)
                .clipShape(RoundedRectangle(cornerRadius: 0))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // A throwaway WebContents: must never navigate the source (Pinned/Favorited) tab itself.
    private func materialize() {
        guard env.activeSpace != nil else { return }
        PeekState.shared.previewTabID = env.makeDetachedTab(url: url)
    }

    private func teardown() {
        guard let previewTabID else { return }
        PeekState.shared.previewTabID = nil
        env.closeDetachedTab(previewTabID)
    }

    private func promoteToTab() {
        guard let previewTabID else { return }
        PeekState.shared.previewTabID = nil // ownership moved; don't close it on disappear
        env.promoteDetachedTabToMainWindow(previewTabID)
        PeekState.shared.dismiss()
    }

    private func promoteToSplitView() {
        guard let previewTabID else { return }
        PeekState.shared.previewTabID = nil
        env.promoteDetachedTabToMainWindow(previewTabID)
        if let current = env.activeTabID, current != previewTabID {
            env.createSplit(existingTabID: sourceTabID, newTabID: previewTabID, edge: .right)
        }
        PeekState.shared.dismiss()
    }

    private func dismiss() {
        PeekState.shared.dismiss()
    }
}
