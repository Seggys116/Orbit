import XCTest
import SwiftUI
import AppKit

@MainActor
final class OrbitHoverPopoverDetachedHostingTests: XCTestCase {

    // MARK: - Fixtures

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
    }

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func makeEnvironment(spaceCount: Int = 1) -> AppEnvironment {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        env.state.spaces = (0..<spaceCount).map { Space(name: "Space \($0)", profileID: profile.id) }
        return env
    }

    private func presentThroughRealPopover<Content: View>(
        env: AppEnvironment,
        @ViewBuilder content: @escaping () -> Content
    ) -> NSView? {
        let isPresented = Binding<Bool>(get: { true }, set: { _ in })
        let root = Color.clear
            .frame(width: 220, height: OrbitMetrics.sidebarRowHeight)
            .orbitHoverPopover(isPresented: isPresented, preferredEdge: .maxX, content: content)
            .environment(env)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 20, y: 20, width: 220, height: OrbitMetrics.sidebarRowHeight)
        window.contentView?.addSubview(hostingView)
        hostingView.layoutSubtreeIfNeeded()

        // `_NSPopoverWindow` is an AppKit internal with no public symbol, so it is matched by name.
        guard let popoverWindow = NSApp.windows.first(where: {
            "\(type(of: $0))".contains("Popover") && $0.isVisible
        }) else { return nil }
        popoverWindow.contentView?.layoutSubtreeIfNeeded()
        popoverWindow.contentView?.displayIfNeeded()
        return popoverWindow.contentView
    }

    private func drewAnything(_ view: NSView) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { return true }
            }
        }
        return false
    }

    private func makeFolderPreviewState(itemCount: Int = 2) -> FolderPreviewState {
        FolderPreviewState(
            itemID: FolderID(),
            title: "Q4 Launches",
            allPossibleChildren: (0..<itemCount).map { index in
                FolderPreviewItem(
                    tabID: TabID(),
                    title: "Q4 Roadmap \(index)",
                    url: URL(string: "https://www.figma.com/file/\(index)")!,
                    faviconURL: nil,
                    lastVisitedAt: Date()
                )
            }
        )
    }

    // MARK: - Requirement 1: the reported crash

    /// On the pre-fix source this terminates the whole `xctest` process with
    /// "Fatal error: No Observable object of type AppEnvironment found."
    func test_folderHoverPreview_presentedThroughARealPopover_rendersInsteadOfTrapping() {
        let env = makeEnvironment()
        let state = makeFolderPreviewState()

        guard let contentView = presentThroughRealPopover(env: env, content: {
            FolderHoverPreviewView(state: state) { _ in }
        }) else {
            XCTFail(
                "No popover window appeared for the folder hover preview. Either the preview did not present at " +
                "all (which would mean this test proves nothing about the crash) or presenting it failed."
            )
            return
        }

        XCTAssertTrue(
            drewAnything(contentView),
            "The folder hover preview presented but drew nothing. Surviving the AppEnvironment trap is only half " +
            "the requirement — the preview is a real feature and must still render its rows."
        )
    }

    func test_tabHoverPreview_presentedThroughARealPopover_rendersInsteadOfTrapping() {
        let env = makeEnvironment()
        let tab = Tab(spaceID: env.state.spaces[0].id, url: URL(string: "https://www.figma.com")!, title: "Q4 Roadmap")
        let image = NSImage(size: NSSize(width: 240, height: 150))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 150).fill()
        image.unlockFocus()

        guard let contentView = presentThroughRealPopover(env: env, content: {
            TabHoverPreviewView(tab: tab, image: image)
        }) else {
            XCTFail("No popover window appeared for the tab hover preview.")
            return
        }
        XCTAssertTrue(drewAnything(contentView), "The tab hover preview presented but drew nothing.")
    }

    func test_recentPagesPreview_presentedThroughARealPopover_rendersInsteadOfTrapping() {
        let env = makeEnvironment()
        guard let data = RecentPagesData(
            service: .notion,
            items: [
                RecentPagesItem(
                    url: URL(string: "https://www.notion.so/launch-checklist")!,
                    title: "Launch Checklist",
                    tidyTitle: "Launch Checklist",
                    lastVisitDate: Date(),
                    documentID: nil
                ),
            ]
        ) else {
            XCTFail("RecentPagesData refuses an empty item list; this fixture supplies one item and must succeed.")
            return
        }

        guard let contentView = presentThroughRealPopover(env: env, content: {
            SidebarRecentPagesPreviewView(
                data: data,
                onOpen: { _ in },
                onCreate: nil,
                isPointerInside: .constant(false)
            )
        }) else {
            XCTFail("No popover window appeared for the recent-pages preview.")
            return
        }
        XCTAssertTrue(drewAnything(contentView), "The recent-pages preview presented but drew nothing.")
    }

    // MARK: - Requirement 2: the mechanism, not just the three instances

    func test_hostedContent_carriesThePresentingTreesOwnAppEnvironmentIntoTheDetachedTree() {
        let env = makeEnvironment(spaceCount: 4)

        guard let contentView = presentThroughRealPopover(env: env, content: {
            EnvironmentReadingProbe()
        }) else {
            XCTFail("No popover window appeared for the environment probe.")
            return
        }

        let measured = contentView.bounds.width
        XCTAssertEqual(
            measured, EnvironmentReadingProbe.width(forSpaceCount: 4), accuracy: 2,
            "The popover's detached hosting tree sized itself from a different AppEnvironment than the one the " +
            "presenting tree carries. Expected a bar sized for 4 spaces " +
            "(\(EnvironmentReadingProbe.width(forSpaceCount: 4))pt), measured \(measured)pt. Not crashing is not " +
            "enough — the preview has to see the app's real state, or it will render the wrong content."
        )
    }

    func test_hostedContent_carriesOrdinaryEnvironmentValuesToo_notJustObservableObjects() {
        let env = makeEnvironment()

        guard let contentView = presentThroughRealPopover(env: env, content: {
            ColorSchemeReadingProbe()
        }) else {
            XCTFail("No popover window appeared for the colour-scheme probe.")
            return
        }

        let measured = contentView.bounds.width
        XCTAssertTrue(
            abs(measured - ColorSchemeReadingProbe.width(for: .light)) < 2
                || abs(measured - ColorSchemeReadingProbe.width(for: .dark)) < 2,
            "The colour-scheme probe rendered at \(measured)pt, which matches neither of the two widths it can " +
            "produce — the environment carried into the popover is not the presenting tree's."
        )
    }
}

// MARK: - Test-only probes

private struct EnvironmentReadingProbe: View {
    @Environment(AppEnvironment.self) private var env

    static let unit: CGFloat = 20
    static let base: CGFloat = 40
    static func width(forSpaceCount count: Int) -> CGFloat { base + CGFloat(count) * unit }

    var body: some View {
        Color.black
            .frame(width: Self.width(forSpaceCount: env.state.spaces.count), height: 30)
    }
}

private struct ColorSchemeReadingProbe: View {
    @Environment(\.colorScheme) private var colorScheme

    static func width(for scheme: ColorScheme) -> CGFloat { scheme == .dark ? 120 : 60 }

    var body: some View {
        Color.black.frame(width: Self.width(for: colorScheme), height: 30)
    }
}
