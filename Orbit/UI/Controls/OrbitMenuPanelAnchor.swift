//  SwiftUI entry point onto the same OrbitMenuPanelController the right-click menu uses,
//  for menus hung off a real control; only difference is `showsArrow` (button menus may beak back).

import AppKit
import SwiftUI

struct OrbitMenuPanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    var entries: [OrbitContextMenuEntry]
    var preferredDirection: OrbitMenuDirection
    var showsArrow: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> OrbitHoverPopoverAnchorView {
        let anchor = OrbitHoverPopoverAnchorView()
        anchor.onWindowChange = { [weak coordinator = context.coordinator] anchor in
            coordinator?.anchorWindowDidChange(anchor)
        }
        return anchor
    }

    func updateNSView(_ nsView: OrbitHoverPopoverAnchorView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            anchor: nsView,
            entries: entries,
            preferredDirection: preferredDirection,
            showsArrow: showsArrow
        )
    }

    static func dismantleNSView(_ nsView: OrbitHoverPopoverAnchorView, coordinator: Coordinator) {
        // anchor.window stays non-nil for at least one more run-loop turn after this returns.
        nsView.isDismantled = true
        nsView.onWindowChange = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private let controller = OrbitMenuPanelController()
        private let isPresented: Binding<Bool>
        private var isTearingDown = false
        private var pending: (entries: [OrbitContextMenuEntry], direction: OrbitMenuDirection, showsArrow: Bool)?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(
            isPresented: Bool,
            anchor: OrbitHoverPopoverAnchorView,
            entries: [OrbitContextMenuEntry],
            preferredDirection: OrbitMenuDirection,
            showsArrow: Bool
        ) {
            guard isPresented else {
                tearDown()
                return
            }
            guard !controller.isPresented else {
                controller.updateRootEntries(entries)
                return
            }
            present(from: anchor, entries: entries, preferredDirection: preferredDirection, showsArrow: showsArrow)
        }

        func anchorWindowDidChange(_ anchor: OrbitHoverPopoverAnchorView) {
            guard anchor.window != nil else {
                tearDown()
                return
            }
            guard let pending, !controller.isPresented, isPresented.wrappedValue else {
                self.pending = nil
                return
            }
            self.pending = nil
            present(
                from: anchor, entries: pending.entries,
                preferredDirection: pending.direction, showsArrow: pending.showsArrow
            )
        }

        func tearDown() {
            pending = nil
            guard controller.isPresented else { return }
            isTearingDown = true
            controller.dismiss()
            isTearingDown = false
        }

        private func present(
            from anchor: OrbitHoverPopoverAnchorView,
            entries: [OrbitContextMenuEntry],
            preferredDirection: OrbitMenuDirection,
            showsArrow: Bool
        ) {
            guard !anchor.isDismantled else {
                pending = nil
                return
            }
            guard let window = anchor.window else {
                pending = (entries, preferredDirection, showsArrow)
                return
            }
            let rectInWindow = anchor.convert(anchor.bounds, to: nil)
            controller.present(
                entries: entries,
                anchorRect: window.convertToScreen(rectInWindow),
                anchorView: anchor,
                ownerWindow: window,
                mode: .anchored,
                preferredDirection: preferredDirection,
                showsArrow: showsArrow,
                onDismiss: { [weak self] in
                    guard let self, !self.isTearingDown else { return }
                    self.isPresented.wrappedValue = false
                }
            )
        }
    }
}

extension View {
    /// Gated on `isPresented`: an unconditional background(OrbitMenuPanelAnchor(...))
    /// breaks ImageRenderer-based render tests on views that are never opened.
    func orbitMenuPanel(
        isPresented: Binding<Bool>,
        entries: [OrbitContextMenuEntry],
        preferredDirection: OrbitMenuDirection = .up,
        showsArrow: Bool = true
    ) -> some View {
        background {
            if isPresented.wrappedValue {
                OrbitMenuPanelAnchor(
                    isPresented: isPresented,
                    entries: entries,
                    preferredDirection: preferredDirection,
                    showsArrow: showsArrow
                )
            }
        }
    }
}
