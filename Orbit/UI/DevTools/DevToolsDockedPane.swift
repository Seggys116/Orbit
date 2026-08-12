// The docked half of the inspector: the frontend's WebContents fills the pane
// and the page draws on top at the rect the frontend reports (chrome/'s DevToolsContentsResizingStrategy) -- right, bottom and left are the same view hierarchy with a different rect.

import AppKit
import SwiftUI

struct DevToolsDockedPane: View {
    var page: any WebContents
    var session: DevToolsDockState.Session
    var environment: AppEnvironment?
    var hostID: UUID

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DevToolsFrontendHostView(inspected: page, contents: session.frontend)

                if !session.hidesInspectedPage {
                    let rect = DevToolsDockState.resolvedPageRect(session.inspectedPageBounds, in: proxy.size)
                    LiveWebContentsHostView(contents: page, environment: environment, hostID: hostID)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// Deliberately not WebContentsHostView: the frontend is not a tab, so none of the
// page overlays or frozen-frame handover apply, and it moves between this pane and DevToolsWindowController's window rather than between two panes.
struct DevToolsFrontendHostView: NSViewRepresentable {
    var inspected: any WebContents
    var contents: any WebContents

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        embedIfEntitled(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        embedIfEntitled(in: nsView)
    }

    // Read live, never adopt while false: SwiftUI can build a representable's NSView
    // then discard it, running a final update on the removing pane -- without this, undocking let an outgoing container steal the engine view back. Same guard as LiveWebContentsHostView's ownership check.
    private var isEntitled: Bool {
        DevToolsDockState.shared.session(for: inspected)?.frontend === contents
    }

    // No dismantleNSView: a torn-down container that still holds this view releases
    // it along with itself, and the next host re-parents it -- how the view has always moved between panes.
    private func embedIfEntitled(in container: NSView) {
        guard isEntitled else { return }
        let view = contents.view
        guard view.superview !== container else {
            if container.window == nil { contents.setVisible(true) }
            return
        }
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        // After addSubview, for the same reason LiveWebContentsHostView does
        // it there: a container with no window yet answers HIDDEN, and the
        // frontend would come up as an evicted, blank surface.
        contents.setVisible(true)
    }
}
