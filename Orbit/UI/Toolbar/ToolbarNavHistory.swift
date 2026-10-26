//  This header sits inside the window's invisible 32pt titlebar band, so every interactive control here needs mouseDownCanMoveWindow overridden to false or AppKit consumes the mouseDown for a window drag before it ever reaches this view.

import AppKit
import SwiftUI

enum ToolbarNavDirection {
    case back
    case forward

    var immediateOffset: Int { self == .back ? -1 : 1 }
}

struct ToolbarHistoryItem: Identifiable, Equatable {
    var id: Int { offset }
    var offset: Int
    var title: String
}

enum ToolbarNavHistory {

    static func entries(from history: [SessionHistoryEntry], direction: ToolbarNavDirection) -> [ToolbarHistoryItem] {
        let matching = history.filter { direction == .back ? $0.offset < 0 : $0.offset > 0 }
        let ordered = matching.sorted { abs($0.offset) < abs($1.offset) }
        return ordered.map { entry in
            let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = ToolbarAddressText.text(for: entry.url, showsFullURL: true) ?? entry.url.absoluteString
            return ToolbarHistoryItem(offset: entry.offset, title: trimmed.isEmpty ? fallback : trimmed)
        }
    }

    static func immediateURL(from history: [SessionHistoryEntry], direction: ToolbarNavDirection) -> URL? {
        history.first { $0.offset == direction.immediateOffset }?.url
    }

    static func menuEntries(items: [ToolbarHistoryItem], onSelect: @escaping (Int) -> Void) -> [OrbitContextMenuEntry] {
        items.map { item in
            .item(OrbitContextMenuItem(title: item.title) { onSelect(item.offset) })
        }
    }
}

@MainActor
final class ToolbarNavButtonClickCatchingView: NSView, OrbitClickCatching, OrbitHandlesRightClick {
    var isEnabled: () -> Bool = { true }

    var onNavigate: (() -> Void)?
    var immediateURL: (() -> URL?)?
    var onNavigateInNewTab: ((URL) -> Void)?

    var historyMenu: (() -> [OrbitContextMenuEntry]?)?

    var presentMenu: (([OrbitContextMenuEntry]) -> Void)?

    private var holdTimer: Timer?

    private(set) var isPressPending = false

    // MARK: - Never a window-drag handle

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Hit testing

    // point arrives in the superview's coordinate space, not this view's own bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        orbitContainsHitTestPoint(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Plain click / Cmd-click / press-and-hold (all left-button)

    override func mouseDown(with event: NSEvent) {
        holdTimer?.invalidate()
        isPressPending = true
        holdTimer = Timer.scheduledTimer(withTimeInterval: ToolbarNavButton.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTimerFired() }
        }
    }

    func holdTimerFired() {
        guard isPressPending else { return }
        isPressPending = false
        holdTimer?.invalidate()
        holdTimer = nil
        presentHistory()
    }

    private func presentHistory() {
        guard let entries = historyMenu?() else { return }
        if let presentMenu {
            presentMenu(entries)
        } else {
            ToolbarNavButton.presentAtCursor(entries, from: self)
        }
    }

    // If the hold already fired, isPressPending is already false and this mouseUp is the second half of that same press — it must do nothing more.
    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard isPressPending else { return }
        isPressPending = false
        guard isEnabled() else { return }
        if event.modifierFlags.contains(.command), let url = immediateURL?() {
            onNavigateInNewTab?(url)
        } else {
            onNavigate?()
        }
    }

    // MARK: - Right-click (RN2023 Aug 31)

    // rightMouseDown is a separate responder-chain callback from mouseDown and is never subject to mouseDownCanMoveWindow (window dragging is left-button-only).
    override func rightMouseDown(with event: NSEvent) {
        presentHistory()
    }
}

private struct ToolbarNavButtonCatcher: NSViewRepresentable {
    var isEnabled: () -> Bool
    var onNavigate: () -> Void
    var immediateURL: () -> URL?
    var onNavigateInNewTab: (URL) -> Void
    var historyMenu: () -> [OrbitContextMenuEntry]?
    var presentMenu: (([OrbitContextMenuEntry]) -> Void)?

    func makeNSView(context: Context) -> ToolbarNavButtonClickCatchingView {
        let view = ToolbarNavButtonClickCatchingView()
        applyState(to: view)
        return view
    }

    func updateNSView(_ nsView: ToolbarNavButtonClickCatchingView, context: Context) {
        applyState(to: nsView)
    }

    private func applyState(to view: ToolbarNavButtonClickCatchingView) {
        view.isEnabled = isEnabled
        view.onNavigate = onNavigate
        view.immediateURL = immediateURL
        view.onNavigateInNewTab = onNavigateInNewTab
        view.historyMenu = historyMenu
        view.presentMenu = presentMenu
    }
}

struct ToolbarNavButton: View {
    var symbol: String
    var direction: ToolbarNavDirection
    var isEnabled: Bool
    var foreground: Color
    var dimmedForeground: Color

    // Reads live session history at the moment a menu opens, not cached: a cached copy is how a menu ends up offering a page the tab has already left.
    var history: () -> [SessionHistoryEntry]

    var onNavigate: () -> Void
    var onNavigateInNewTab: (URL) -> Void
    var onSelectHistory: (Int) -> Void

    var presentHoldMenu: (([OrbitContextMenuEntry]) -> Void)?

    static let holdDuration: Double = 0.35

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: OrbitToolbarMetrics.navGlyphSize, weight: .medium))
            .frame(width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
            .overlay(clickCatcher)
            .foregroundStyle(isEnabled ? foreground : dimmedForeground)
    }

    @ViewBuilder
    private var clickCatcher: some View {
        #if DEBUG
        if !screenshotModeRepresentableDisabled {
            catcher
        }
        #else
        catcher
        #endif
    }

    private var catcher: some View {
        ToolbarNavButtonCatcher(
            isEnabled: { isEnabled },
            onNavigate: onNavigate,
            immediateURL: { ToolbarNavHistory.immediateURL(from: history(), direction: direction) },
            onNavigateInNewTab: onNavigateInNewTab,
            historyMenu: historyMenuOrNil,
            presentMenu: presentHoldMenu
        )
    }

    private func historyMenuOrNil() -> [OrbitContextMenuEntry]? {
        let items = ToolbarNavHistory.entries(from: history(), direction: direction)
        guard !items.isEmpty else { return nil }
        return ToolbarNavHistory.menuEntries(items: items, onSelect: onSelectHistory)
    }

    @MainActor
    static func presentAtCursor(_ entries: [OrbitContextMenuEntry], from view: NSView) {
        guard let window = view.window else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        OrbitContextMenuPresenter.shared.present(entries: entries, anchorView: view, at: point)
    }
}
