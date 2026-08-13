import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class ToolbarHeaderHitTestEvidenceTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeTab() -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com")!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func hostInWindow<V: View>(_ view: V, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: view)
        host.safeAreaRegions = []
        host.sizingOptions = []
        let container = OrbitWindowContentView(frame: NSRect(origin: .zero, size: size))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.displayIfNeeded()
        return window
    }

    private func clickCatchers(under root: NSView) -> [(name: String, view: NSView, windowFrame: NSRect)] {
        var found: [(String, NSView, NSRect)] = []
        func walk(_ view: NSView) {
            if OrbitWindowContentView.isClickCatcher(view) {
                found.append(("\(type(of: view))", view, view.convert(view.bounds, to: nil)))
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func hitChain(in window: NSWindow, at point: NSPoint) -> [String] {
        guard let themeFrame = window.contentView?.superview else { return [] }
        var node = themeFrame.hitTest(point)
        var chain: [String] = []
        while let current = node {
            chain.append("\(type(of: current))")
            node = current.superview
        }
        return chain
    }

    private func hostHeaderAtWindowTop(tab: Orbit.Tab, width: CGFloat) -> NSWindow {
        hostInWindow(
            VStack(spacing: 0) {
                Spacer(minLength: 0).frame(height: OrbitMetrics.cardInset)
                ToolbarView(tab: tab).environment(env)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(),
            size: CGSize(width: width, height: 400)
        )
    }

    // MARK: - 1. Every control in the header can be reached by a real click

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyHeaderControlIsReachableByARealClick

    func test_everyHeaderControlIsReachableByARealClick() {
        let tab = makeTab()
        defer { env.state.tabs.removeValue(forKey: tab.id) }
        env.isSidebarVisible = false

        let window = hostHeaderAtWindowTop(tab: tab, width: 900)
        guard let contentView = window.contentView else { return XCTFail("No content view.") }

        let catchers = clickCatchers(under: contentView)
        XCTAssertFalse(catchers.isEmpty, "No click-catchers in the tree — the header's controls were never realised, so this measurement would be meaningless.")

        var unreachable: [String] = []
        for catcher in catchers {
            let centre = NSPoint(x: catcher.windowFrame.midX, y: catcher.windowFrame.midY)
            let chain = hitChain(in: window, at: centre)
            if chain.first != catcher.name {
                unreachable.append("\(catcher.name) at \(catcher.windowFrame) resolved \(chain.first ?? "NOTHING")")
            }
        }

        XCTAssertTrue(
            unreachable.isEmpty,
            """
            A real click cannot reach these controls — AppKit's hit test, started \
            where `NSWindow.sendEvent(_:)` starts it, resolves something else at \
            their exact centre: \(unreachable.joined(separator: "; ")).
            """
        )
    }

    // MARK: - 2. The recovery itself

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_contentViewRecoversAClickSwiftUIWouldHaveSwallowed

    func test_contentViewRecoversAClickSwiftUIWouldHaveSwallowed() throws {
        let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let swiftUIStandIn = NSHostingViewClaimingStandIn(frame: content.bounds)
        content.addSubview(swiftUIStandIn)

        let catcher = OrbitActionButtonClickCatchingView(frame: NSRect(x: 100, y: 80, width: 22, height: 22))
        var fired = false
        catcher.action = { fired = true }
        swiftUIStandIn.addSubview(catcher)

        let onTheButton = NSPoint(x: 111, y: 91)
        XCTAssertTrue(
            content.hitTest(onTheButton) === catcher,
            "The window's content view must hand back the control that is actually under the point, not the SwiftUI container that claimed it."
        )

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: onTheButton,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        catcher.mouseDown(with: click)
        XCTAssertTrue(fired, "The recovered catcher's action must run on mouseDown.")

        XCTAssertTrue(
            content.hitTest(NSPoint(x: 300, y: 20)) === swiftUIStandIn,
            "Off a control, the SwiftUI container must still win — otherwise this override would be stealing clicks rather than recovering them."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_recoveryDoesNotDisturbAClickThatAlreadyWorks

    func test_recoveryDoesNotDisturbAClickThatAlreadyWorks() {
        let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let plain = NSView(frame: content.bounds)
        content.addSubview(plain)
        let catcher = OrbitActionButtonClickCatchingView(frame: NSRect(x: 40, y: 40, width: 22, height: 22))
        plain.addSubview(catcher)

        XCTAssertTrue(content.hitTest(NSPoint(x: 51, y: 51)) === catcher)
        XCTAssertTrue(content.hitTest(NSPoint(x: 300, y: 150)) === plain, "A plain AppKit view keeps every point no control occupies.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_recoverySkipsHiddenAndTransparentControls

    func test_recoverySkipsHiddenAndTransparentControls() {
        let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let swiftUIStandIn = NSHostingViewClaimingStandIn(frame: content.bounds)
        content.addSubview(swiftUIStandIn)

        let hidden = OrbitActionButtonClickCatchingView(frame: NSRect(x: 100, y: 80, width: 22, height: 22))
        hidden.isHidden = true
        swiftUIStandIn.addSubview(hidden)

        let transparent = OrbitActionButtonClickCatchingView(frame: NSRect(x: 200, y: 80, width: 22, height: 22))
        transparent.alphaValue = 0
        swiftUIStandIn.addSubview(transparent)

        XCTAssertTrue(content.hitTest(NSPoint(x: 111, y: 91)) === swiftUIStandIn, "A hidden control must not be recovered.")
        XCTAssertTrue(content.hitTest(NSPoint(x: 211, y: 91)) === swiftUIStandIn, "A fully transparent control must not be recovered.")
    }
}

private final class NSHostingViewClaimingStandIn: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}
