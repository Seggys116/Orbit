import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// A folder row is one click target, the way a tab row is: the name, the empty space to its right and the row's own padding all collapse or expand the folder. Only the folder's name used to answer, so a click anywhere else on the row did nothing.
// Driven through the production container's hit test (OrbitWindowContentView's click recovery), because that is the path a real click takes into a SwiftUI-hosted NSView catcher.
@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class FolderRowClickAreaTests: XCTestCase {

    private static let size = CGSize(width: OrbitMetrics.sidebarDefaultWidth, height: OrbitMetrics.sidebarRowHeight)

    private var window: NSWindow?
    private var env: AppEnvironment!
    private var spaceID: SpaceID!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Folders",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
    }

    override func tearDown() {
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

    private func mount<V: View>(_ row: V) -> NSWindow {
        let content = row.frame(width: Self.size.width, height: Self.size.height).environment(env)
        let window = UnconstrainedTestWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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
        pump(0.6)
        return window
    }

    private func resolved(_ window: NSWindow, x: CGFloat) -> NSView? {
        window.contentView?.superview?.hitTest(NSPoint(x: x, y: Self.size.height / 2))
    }

    private func isClickCatcher(_ view: NSView?) -> Bool {
        view is OrbitActionButtonClickCatchingView
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyPointAlongAPinnedFolderRowReachesAClickCatcher

    func test_everyPointAlongAPinnedFolderRowReachesAClickCatcher() {
        let folder = Folder(name: "Reading", isExpanded: false)
        let window = mount(PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: SpaceTheme(), depth: 0))

        // Inside the pill's own padding, over the name, in the empty space, and just short of the trailing edge, clear of the "+" and the count.
        let insets = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset
        let trailingControlsWidth: CGFloat = 70
        let probes: [(String, CGFloat)] = [
            ("the row's leading padding", OrbitMetrics.sidebarHorizontalPadding + 2),
            ("over the folder's name", insets + OrbitMetrics.sidebarFolderToggleSize + OrbitMetrics.sidebarRowContentSpacing + 12),
            ("the empty space to the right of the name", Self.size.width / 2 + 20),
            ("just before the trailing controls", Self.size.width - insets - trailingControlsWidth),
        ]
        for (label, x) in probes {
            let hit = resolved(window, x: x)
            XCTAssertTrue(
                isClickCatcher(hit),
                "A click \(label) (x=\(x)) must reach a click catcher; it resolved to \(hit.map { "\(type(of: $0))" } ?? "nil"). That is the dead area of the row."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aClickOnTheEmptyPartOfAPinnedFolderRowTogglesIt

    func test_aClickOnTheEmptyPartOfAPinnedFolderRowTogglesIt() throws {
        let folder = Folder(name: "Reading", isExpanded: false)
        env.store.mutateSpace(spaceID) { $0.pinned = [.folder(folder)] }
        let window = mount(PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: SpaceTheme(), depth: 0))

        let catcher = try XCTUnwrap(resolved(window, x: Self.size.width / 2 + 20) as? OrbitActionButtonClickCatchingView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        catcher.mouseDown(with: event)

        // Immediately, not after the double-click interval: only the name waits for a possible second click, since only the name can be renamed.
        pump(0.1)
        let isExpanded = env.store.pinnedNodes(in: spaceID).contains { node in
            if case .folder(let current) = node { return current.id == folder.id && current.isExpanded }
            return false
        }
        XCTAssertTrue(isExpanded, "A click on the empty part of a folder row must open it, as a click on its name does.")
    }
}
