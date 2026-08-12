import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Orbit

// MARK: - Capability probes (shared by every suite that needs a real window-server session or GPU)

private final class CommitProbeMarkerView: NSView {
    var committed = false
}

private struct CommitProbeRepresentable: NSViewRepresentable {
    var committed: Bool
    func makeNSView(context: Context) -> CommitProbeMarkerView { CommitProbeMarkerView() }
    func updateNSView(_ nsView: CommitProbeMarkerView, context: Context) { nsView.committed = committed }
}

private struct CommitProbeView: View {
    @State private var committed = false
    var body: some View {
        CommitProbeRepresentable(committed: committed).task { committed = true }
    }
}

private func probeFirstDescendant<T: NSView>(of view: NSView?, ofType type: T.Type) -> T? {
    guard let view else { return nil }
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let match = probeFirstDescendant(of: subview, ofType: type) { return match }
    }
    return nil
}

// Mounts a real NSWindow, writes @State from inside .task, and polls whether that reaches a
// custom NSViewRepresentable's updateNSView — the exact mechanism these suites depend on.
@MainActor
private func probeWindowServerCommitsAreAvailable(timeout: TimeInterval = 3) -> Bool {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: CommitProbeView())
    host.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    func committed() -> Bool {
        probeFirstDescendant(of: window.contentView, ofType: CommitProbeMarkerView.self)?.committed ?? false
    }
    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    settle()
    let deadline = Date().addingTimeInterval(timeout)
    while !committed(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        settle()
    }
    let result = committed()
    window.orderOut(nil)
    return result
}

// Renders a tiny MeshGradient twice, off any real window, and only reports unavailable if BOTH
// attempts miss the budget — one slow attempt reads as local contention, not a missing capability.
@MainActor
private func probeMetalMeshGradientRenderingIsAvailable(timeout: TimeInterval = 3) -> Bool {
    let theme = SpaceTheme(style: .mesh, colors: SpaceTheme.defaultPalette)
    for _ in 0..<2 {
        let start = Date()
        _ = render(ThemeBackgroundView(theme: theme), size: CGSize(width: 4, height: 4))
        if Date().timeIntervalSince(start) <= timeout { return true }
    }
    return false
}

// Each static let is computed at most once per process, the first time it is read.
enum CapabilityProbe {
    @MainActor static let windowServerCommitsAreAvailable = probeWindowServerCommitsAreAvailable()
    @MainActor static let metalMeshGradientRenderingIsAvailable = probeMetalMeshGradientRenderingIsAvailable()
}
