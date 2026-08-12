// Tracks which tabs have their inspector docked and the page rectangle to draw over
// it, keyed by WebContents identity. Dock side is the frontend's own persisted preference, not stored here.

import AppKit
import Foundation

enum DevToolsDockSide: String, Sendable {
    case right, bottom, left, undocked
}

@MainActor
@Observable
final class DevToolsDockState {

    static let shared = DevToolsDockState()

    struct Session {
        var frontend: any WebContents
        /// nil until the frontend has reported one, which is the state Chrome
        /// also draws as "page fills the container".
        var inspectedPageBounds: CGRect?
        var hidesInspectedPage: Bool
    }

    private var sessionsByContents: [ObjectIdentifier: Session] = [:]

    private init() {}

    func session(for contents: any WebContents) -> Session? {
        sessionsByContents[ObjectIdentifier(contents)]
    }

    var dockedContentsCount: Int { sessionsByContents.count }

    func dock(frontend: any WebContents, for contents: any WebContents) {
        let key = ObjectIdentifier(contents)
        guard sessionsByContents[key]?.frontend !== frontend else { return }
        sessionsByContents[key] = Session(
            frontend: frontend,
            inspectedPageBounds: sessionsByContents[key]?.inspectedPageBounds,
            hidesInspectedPage: false
        )
    }

    func setInspectedPageBounds(_ bounds: CGRect?, hidesPage: Bool, for contents: any WebContents) {
        let key = ObjectIdentifier(contents)
        guard var session = sessionsByContents[key] else { return }
        guard session.inspectedPageBounds != bounds || session.hidesInspectedPage != hidesPage else { return }
        session.inspectedPageBounds = bounds
        session.hidesInspectedPage = hidesPage
        sessionsByContents[key] = session
    }

    func undock(_ contents: any WebContents) {
        sessionsByContents.removeValue(forKey: ObjectIdentifier(contents))
    }

    /// Mirrors ApplyDevToolsContentsResizingStrategy: an unset or empty
    /// rectangle means the page fills the container, and everything else is
    /// clamped into it rather than allowed to overhang.
    static func resolvedPageRect(_ bounds: CGRect?, in container: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: container)
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return full }
        return CGRect(
            x: min(max(0, bounds.minX), container.width),
            y: min(max(0, bounds.minY), container.height),
            width: min(bounds.width, container.width),
            height: min(bounds.height, container.height)
        )
    }

    /// The side the reported rectangle describes. The frontend never sends the
    /// side itself; this is the same reading chrome/ takes off the rectangle,
    /// and it exists for diagnostics and tests rather than for layout.
    static func inferredSide(pageBounds: CGRect?, in container: CGSize) -> DevToolsDockSide? {
        guard let pageBounds, container.width > 0, container.height > 0 else { return nil }
        if pageBounds.minX > 0 { return .left }
        if pageBounds.width < container.width { return .right }
        if pageBounds.height < container.height { return .bottom }
        return nil
    }
}
