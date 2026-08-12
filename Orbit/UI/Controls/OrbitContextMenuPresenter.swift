//  Presents via OrbitMenuPanelController, a borderless custom panel: not NSPopover (no
//  system chrome), not NSMenu.popUp/runModal (returns immediately, safe on any test path).

import AppKit
import SwiftUI

@MainActor
final class OrbitContextMenuPresenter {
    static let shared = OrbitContextMenuPresenter()

    /// Set only by tests: replaces the real panel presentation with a
    /// recorder, so a test can assert what would have been shown without ever
    /// creating a real AppKit window.
    var presentForTesting: ((_ entries: [OrbitContextMenuEntry], _ point: CGPoint) -> Void)?

    private let controller = OrbitMenuPanelController()

    var isPresented: Bool { controller.isPresented }

    /// The right-click menu is always arrow-less: the beak is the one piece of
    /// popover chrome a context menu must never grow.
    static let showsArrow = false

    func present(entries: [OrbitContextMenuEntry], anchorView: NSView, at point: CGPoint) {
        if let presentForTesting {
            presentForTesting(entries, point)
            return
        }
        dismiss()
        guard let window = anchorView.window else { return }

        let pointInWindow = anchorView.convert(point, to: nil)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)

        controller.present(
            entries: entries,
            anchorRect: CGRect(origin: pointOnScreen, size: .zero),
            anchorView: anchorView,
            ownerWindow: window,
            mode: .pointCorner,
            preferredDirection: .down,
            showsArrow: Self.showsArrow
        )
    }

    func dismiss() {
        controller.dismiss()
    }

    /// Where the right-click menu would land, without presenting anything --
    /// the arrow-less, flip-and-clamp contract its tests assert against.
    static func geometry(contentSize: CGSize, at point: CGPoint, visibleFrame: CGRect) -> OrbitMenuGeometry {
        OrbitMenuPlacement.geometry(
            contentSize: contentSize,
            anchor: CGRect(origin: point, size: .zero),
            mode: .pointCorner,
            preferredDirection: .down,
            showsArrow: showsArrow,
            visibleFrame: visibleFrame
        )
    }
}
