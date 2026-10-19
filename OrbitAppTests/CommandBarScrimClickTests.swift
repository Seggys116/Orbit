import XCTest
import SwiftUI
@testable import Orbit

// A click on the page behind an open Command Bar must dismiss it; a click inside the bar or on the sidebar must not. The click is delivered to whatever view AppKit's hit test resolves in a window shaped like the production one (OrbitWindowContentView over an NSHostingView): over the page that resolves to the hosting view itself, which SwiftUI taps alone never answered.
@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class CommandBarScrimClickTests: XCTestCase {

    private final class PageStandInView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        var mouseDowns = 0
        override func mouseDown(with event: NSEvent) { mouseDowns += 1 }
    }

    private struct PageStandIn: NSViewRepresentable {
        let view: PageStandInView
        func makeNSView(context: Context) -> NSView {
            let outer = NSView()
            outer.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                view.topAnchor.constraint(equalTo: outer.topAnchor),
                view.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
            ])
            return outer
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private static let size = CGSize(width: 1000, height: 700)
    private static let sidebarWidth: CGFloat = 220

    private var env: AppEnvironment!
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
    }

    override func tearDown() {
        env.isCommandBarPresented = false
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    private func mount(page: PageStandInView) -> NSWindow {
        env.commandBarMode = .newTab
        env.isCommandBarPresented = true

        let content = ZStack {
            PageStandIn(view: page).frame(maxWidth: .infinity, maxHeight: .infinity)
            CommandBarOverlay(anchors: [:], passthroughLeadingWidth: Self.sidebarWidth)
        }
        .environment(env)

        let window = UnconstrainedTestWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: content)
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: Self.size))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump(0.8)
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        let target = window.contentView?.superview?.hitTest(point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { return XCTFail("Could not synthesise a mouse event.") }
            // Delivered to the view the hit test resolved, the way every other click test in this target does it: window.sendEvent is unreliable for SwiftUI gestures under XCTest.
            if type == .leftMouseDown { target?.mouseDown(with: event) } else { target?.mouseUp(with: event) }
            pump(0.1)
        }
        pump(0.3)
    }

    private func chain(_ window: NSWindow, at point: NSPoint) -> String {
        var names: [String] = []
        var node = window.contentView?.superview?.hitTest(point)
        while let current = node {
            names.append("\(type(of: current))")
            node = current.superview
        }
        return names.joined(separator: " < ")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingThePageBehindTheBarDismissesIt

    func test_clickingThePageBehindTheBarDismissesIt() {
        let page = PageStandInView()
        let window = mount(page: page)
        let point = NSPoint(x: Self.size.width - 120, y: 90)

        click(window, at: point)

        XCTAssertTrue(
            chain(window, at: point).contains("CommandBarScrimClickView"),
            "A click on the dimmed page never reaches the scrim's catcher. Hit chain: \(chain(window, at: point))"
        )
        XCTAssertFalse(env.isCommandBarPresented, "Clicking the dimmed page left the Command Bar open. Hit chain: \(chain(window, at: point))")
        XCTAssertEqual(page.mouseDowns, 0, "The dismissing click must not also land in the page.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingTheSidebarStripDoesNotSwallowTheClick

    func test_clickingTheSidebarStripDoesNotSwallowTheClick() {
        let page = PageStandInView()
        let window = mount(page: page)
        let point = NSPoint(x: Self.sidebarWidth / 2, y: 300)

        XCTAssertFalse(
            chain(window, at: point).contains("CommandBarScrimClickView"),
            "The sidebar strip must stay clickable so a tab row can select and dismiss. Chain: \(chain(window, at: point))"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickingInsideTheBarKeepsItOpen

    func test_clickingInsideTheBarKeepsItOpen() {
        let page = PageStandInView()
        let window = mount(page: page)
        let point = NSPoint(x: Self.size.width / 2, y: Self.size.height / 2 + 20)

        click(window, at: point)

        XCTAssertTrue(env.isCommandBarPresented, "A click inside the Command Bar's own panel dismissed it. Hit chain: \(chain(window, at: point))")
    }

    // MARK: - The catcher's own geometry

    func test_catcherClaimsOnlyTheScrimOutsideThePanelAndSidebar() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let panel = CGRect(x: 300, y: 200, width: 400, height: 300)

        func claims(_ x: CGFloat, _ y: CGFloat, panel: CGRect? = panel) -> Bool {
            CommandBarScrimClickView.claims(CGPoint(x: x, y: y), in: bounds, leadingInset: 220, excluding: panel)
        }

        XCTAssertTrue(claims(900, 600), "Page behind the bar.")
        XCTAssertTrue(claims(500, 50), "Above the panel.")
        XCTAssertFalse(claims(500, 300), "Inside the panel.")
        XCTAssertFalse(claims(300, 200), "The panel's own corner belongs to the panel.")
        XCTAssertFalse(claims(100, 300), "The sidebar strip stays clickable.")
        XCTAssertFalse(claims(1200, 300), "Outside the view.")
        XCTAssertFalse(claims(900, 600, panel: nil), "Before the panel has laid out, claiming everything would swallow clicks meant for it.")
        XCTAssertFalse(claims(900, 600, panel: .null))
    }
}
