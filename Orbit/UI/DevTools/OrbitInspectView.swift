// Orbit's inspector shell: toolbar, tab bar, the dock split, and the detached window.

import AppKit
import SwiftUI

struct OrbitInspectView: View {
    var session: OrbitInspectSession

    var body: some View {
        VStack(spacing: 0) {
            if let notice = session.notice, !notice.isEmpty {
                noticeBar(notice)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            toolbar
            if session.device.isActive {
                OrbitDeviceToolbar(model: session.device)
                    .transition(.opacity)
            }
            tabBar
            InspectDivider()
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(InspectChrome.background)
        // Anything a tool view leaves unstyled still reads in the palette's ink and accent.
        .foregroundStyle(InspectChrome.ink)
        .tint(InspectChrome.accent)
        .frame(minWidth: 280, minHeight: 160)
        .orbitAnimation(OrbitMotion.quick, value: session.notice)
        .orbitAnimation(OrbitMotion.quick, value: session.device.isActive)
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(InspectChrome.warnColor)
                .accessibilityHidden(true)
            Text(notice)
                .lineLimit(2)
                .foregroundStyle(InspectChrome.ink)
            Spacer(minLength: 0)
            InspectIconButton(symbol: "xmark", help: "Dismiss notice") { session.notice = nil }
        }
        .font(InspectChrome.caption)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(InspectChrome.warnColor.opacity(0.14))
        .overlay(alignment: .bottom) { InspectDivider() }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            InspectIconButton(symbol: "scope", help: "Select an element on the page", active: session.picking) {
                session.togglePicker()
            }
            InspectIconButton(symbol: "arrow.clockwise", help: "Refresh this panel", active: false) {
                session.refresh(force: true)
            }
            InspectIconButton(symbol: "ipad.and.iphone", help: "Toggle device toolbar", active: session.device.isActive) {
                session.toggleDeviceToolbar()
            }
            Text(session.pageURL.isEmpty ? (session.pageTitle.isEmpty ? "Inspect" : session.pageTitle) : session.pageURL)
                .font(InspectChrome.monoSmall)
                .foregroundStyle(InspectChrome.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
            Spacer(minLength: 8)
            InspectMenuButton(symbol: session.dock.symbol, help: "Dock side") {
                OrbitInspectDock.allCases.map { dock in
                    InspectMenuItem(title: dock.help, checked: session.dock == dock) { session.setDock(dock) }
                }
            }
            InspectMenuButton(symbol: "ellipsis", help: "More") {
                [
                    InspectMenuItem(title: "Preserve log", checked: session.preserveLog) { session.preserveLog.toggle() },
                    InspectMenuItem(title: "Clear console") { session.console.clear() },
                    .separator,
                    InspectMenuItem(title: "Open WebKit Inspector") { session.openWebKitInspector() },
                ]
            }
            InspectIconButton(symbol: "xmark", help: "Close inspector", active: false) {
                session.dismiss()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    /// `ViewThatFits` tries full titles, selected-only title, icons only, then a scrolling strip, so it never clips at any width.
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            tabTrack(.all)
            tabTrack(.selectedOnly)
            tabTrack(.iconsOnly)
            scrollingTabTrack
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private enum LabelMode { case all, selectedOnly, iconsOnly }

    private static let trackInset: CGFloat = 2
    private static let trackRadius = OrbitRadius.md

    private func trackBackground() -> some View {
        RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
            .fill(InspectChrome.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                    .strokeBorder(InspectChrome.hairline, lineWidth: 0.5)
            )
    }

    private func tabTrack(_ mode: LabelMode) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(OrbitInspectPanel.allCases) { panel in
                    tab(panel, showsTitle: mode == .all || (mode == .selectedOnly && session.panel == panel))
                }
            }
            .padding(Self.trackInset)
            .background(trackBackground())
            Spacer(minLength: 0)
        }
    }

    private var scrollingTabTrack: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(OrbitInspectPanel.allCases) { panel in
                        tab(panel, showsTitle: false).id(panel)
                    }
                }
                .padding(Self.trackInset)
            }
            .background(trackBackground())
            .onAppear { proxy.scrollTo(session.panel, anchor: .center) }
            .onChange(of: session.panel) { _, selected in
                withOrbitAnimation(OrbitMotion.quick) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .frame(height: InspectChrome.iconButtonSize + Self.trackInset * 2)
    }

    private func tab(_ panel: OrbitInspectPanel, showsTitle: Bool) -> some View {
        InspectTabItem(
            panel: panel,
            selected: session.panel == panel,
            showsTitle: showsTitle,
            errorCount: panel == .console ? session.console.errorCount : 0,
            frameworkDetected: panel == .frameworks && session.frameworks.primaryName != nil,
            radius: OrbitRadius.concentric(outer: Self.trackRadius, inset: Self.trackInset)
        ) { session.select(panel: panel) }
    }

    @ViewBuilder
    private var panel: some View {
        switch session.panel {
        case .elements: OrbitElementsPane(session: session)
        case .console: OrbitConsolePane(session: session)
        case .sources: OrbitSourcesPane(session: session)
        case .network: OrbitNetworkPane(session: session)
        case .performance: OrbitPerformancePane(session: session)
        case .animations: OrbitAnimationsPane(session: session)
        case .application: OrbitApplicationPane(session: session)
        case .lighthouse: OrbitLighthousePane(session: session)
        case .frameworks: OrbitFrameworksPane(session: session)
        case .security: OrbitSecurityPane(session: session)
        }
    }
}

/// One tab in the strip. The selected tab is raised on the track with a hairline and a small neutral shadow.
private struct InspectTabItem: View {
    var panel: OrbitInspectPanel
    var selected: Bool
    var showsTitle: Bool
    var errorCount: Int
    var frameworkDetected: Bool
    var radius: CGFloat
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: panel.symbol)
                .font(.system(size: 11.5))
            if showsTitle {
                Text(panel.title).lineLimit(1).fixedSize()
            }
            if errorCount > 0 {
                Text("\(errorCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OrbitNeutral.onAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(InspectChrome.badColor))
            }
            if frameworkDetected {
                Circle().fill(InspectChrome.goodColor).frame(width: 6, height: 6)
            }
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? InspectChrome.ink : InspectChrome.muted)
        .padding(.horizontal, 9)
        .frame(minWidth: 32, minHeight: InspectChrome.iconButtonSize)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? OrbitNeutral.raised : (hovering ? InspectChrome.hover : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(selected ? InspectChrome.hairline : Color.clear, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1, x: 0, y: 1)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(focusable: true, action: action))
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .orbitAnimation(OrbitMotion.quick, value: selected)
        .orbitTooltip(panel.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(errorCount > 0 ? "\(panel.title), \(errorCount) errors" : panel.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct OrbitInspectSplit<Page: View>: View {
    var session: OrbitInspectSession
    @ViewBuilder var page: () -> Page

    var body: some View {
        GeometryReader { geo in
            let vertical = session.dock == .bottom
            let limit = vertical ? geo.size.height : geo.size.width
            let tools = min(max(session.breadth, 280), max(280, limit - 180))
            let handle = InspectResizeHandle(
                vertical: vertical,
                sign: session.dock == .left ? 1 : (vertical ? 1 : -1),
                minBreadth: 280,
                maxBreadth: max(280, limit - 180),
                current: { session.breadth },
                onChange: { session.breadth = $0 },
                onEnd: { session.setBreadth(session.breadth) }
            )
            .frame(width: vertical ? nil : 7, height: vertical ? 7 : nil)
            .background(InspectChrome.hairline.frame(width: vertical ? nil : 1, height: vertical ? 1 : nil))
            .accessibilityLabel("Resize inspector")
            if vertical {
                VStack(spacing: 0) {
                    page().frame(maxWidth: .infinity, maxHeight: .infinity)
                    handle
                    OrbitInspectView(session: session).frame(height: tools)
                }
            } else if session.dock == .left {
                HStack(spacing: 0) {
                    OrbitInspectView(session: session).frame(width: tools)
                    handle
                    page().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    page().frame(maxWidth: .infinity, maxHeight: .infinity)
                    handle
                    OrbitInspectView(session: session).frame(width: tools)
                }
            }
        }
    }
}

@MainActor
final class OrbitInspectWindowController: NSWindowController, NSWindowDelegate {
    private var session: OrbitInspectSession?
    private var relinquishing = false

    static func present(_ session: OrbitInspectSession) {
        if let existing = session.windowController {
            existing.updateTitle()
            existing.show()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.windowTitle
        window.setFrameAutosaveName("OrbitInspectWindow")
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        let controller = OrbitInspectWindowController(window: window)
        controller.session = session
        session.windowController = controller
        let hosting = NSHostingView(rootView: OrbitInspectView(session: session))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = controller
        controller.show()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateTitle() {
        window?.title = session?.windowTitle ?? "Inspect"
    }

    /// The inspector is docking back into the page. The window goes away and the session stays.
    func relinquish() {
        relinquishing = true
        session?.windowController = nil
        session = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !relinquishing else { return }
        let closing = session
        session = nil
        closing?.closeFromWindow()
    }
}
