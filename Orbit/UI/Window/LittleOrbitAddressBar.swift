import Observation
import SwiftUI

// Window-scoped, not routed through the shared Command Bar: a Little Orbit tab is
// deliberately never AppEnvironment.activeTabID, so the shared bar would silently
// edit whatever tab the main window is showing instead of this window's own tab.
@MainActor
@Observable
final class LittleOrbitAddressBarModel {
    var isPresented = false
    var text = ""
}

struct LittleOrbitAddressBarOverlay: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LittleOrbitAddressBarModel
    var tabID: TabID
    @FocusState private var isFocused: Bool

    var body: some View {
        CommandBarOverlayLayout(
            targetRect: nil,
            onScrimTap: dismiss
        ) { width in
            editor(width: width)
        }
        // .task(id:) against the flag, not .onAppear: this view stays mounted for
        // the window's whole life once shown, so onAppear would never refire on a
        // second edit in the same window.
        .task(id: model.isPresented) {
            guard model.isPresented else { return }
            await CommandBarFieldFocus.claim(
                showing: { model.text },
                isFocused: { isFocused },
                requestFocus: { isFocused = true }
            )
        }
    }

    private func editor(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or Enter URL", text: $model.text)
                .textFieldStyle(.plain)
                .font(OrbitFont.commandBarInput)
                .focused($isFocused)
                .onSubmit(commit)
            if !model.text.isEmpty {
                Button(action: { model.text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OrbitMetrics.commandBarCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitMetrics.commandBarCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(OrbitMetrics.cardBorderOpacity), lineWidth: OrbitMetrics.cardBorderWidth)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .overlay {
            Button("", action: dismiss)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func commit() {
        guard let url = env.resolveTypedInput(model.text) else { return }
        env.loadInTab(tabID, url: url)
        model.isPresented = false
    }

    private func dismiss() {
        model.isPresented = false
    }
}
