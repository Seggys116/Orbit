import XCTest
import AppKit
import SwiftUI

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class PinnedFolderRowClickBehaviorTests: XCTestCase {

    // MARK: - Pure arbitration (PinnedFolderNameLabelClick.resolve)

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_singleClick_schedulesDeferredToggle

    func test_resolve_singleClick_schedulesDeferredToggle() {
        XCTAssertEqual(PinnedFolderNameLabelClick.resolve(clickCount: 1), .scheduleDeferredToggle)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_doubleClick_cancelsPendingToggleAndBeginsRename

    func test_resolve_doubleClick_cancelsPendingToggleAndBeginsRename() {
        XCTAssertEqual(PinnedFolderNameLabelClick.resolve(clickCount: 2), .cancelPendingToggleAndBeginRename)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_resolve_tripleClickAndBeyond_stillResolvesToCancelAndRename

    func test_resolve_tripleClickAndBeyond_stillResolvesToCancelAndRename() {
        XCTAssertEqual(PinnedFolderNameLabelClick.resolve(clickCount: 3), .cancelPendingToggleAndBeginRename)
        XCTAssertEqual(PinnedFolderNameLabelClick.resolve(clickCount: 4), .cancelPendingToggleAndBeginRename)
    }

    // MARK: - OrbitActionButtonClickCatchingView: the clickCountAction mechanism

    private func mouseDownEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickCatcher_withClickCountActionSet_deliversRealClickCountsAndNeverRunsAction

    func test_clickCatcher_withClickCountActionSet_deliversRealClickCountsAndNeverRunsAction() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        var delivered: [Int] = []
        var actionCalled = false
        view.action = { actionCalled = true }
        view.clickCountAction = { delivered.append($0) }

        view.mouseDown(with: mouseDownEvent(clickCount: 1))
        view.mouseDown(with: mouseDownEvent(clickCount: 2))

        XCTAssertEqual(delivered, [1, 2], "clickCountAction must be called with the real NSEvent.clickCount for each mouseDown, in order.")
        XCTAssertFalse(actionCalled, "When clickCountAction is set, the plain action must never also run.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clickCatcher_withNoClickCountAction_stillRunsThePlainActionOnEveryMouseDown

    func test_clickCatcher_withNoClickCountAction_stillRunsThePlainActionOnEveryMouseDown() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        var callCount = 0
        view.action = { callCount += 1 }

        view.mouseDown(with: mouseDownEvent(clickCount: 1))
        view.mouseDown(with: mouseDownEvent(clickCount: 2))

        XCTAssertEqual(callCount, 2, "With no clickCountAction set, action must still fire unconditionally on every mouseDown — this is what every existing OrbitNSActionButton(action:) caller depends on.")
    }

    // MARK: - Live, real-mouseDown end-to-end behaviour

    private func makeSpace(pinned: [SidebarNode]) -> (env: AppEnvironment, spaceID: SpaceID) {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        let space = Space(name: "Personal", profileID: profile.id, pinned: pinned)
        env.state.profiles = [profile]
        env.state.spaces = [space]
        return (env, space.id)
    }

    private func collectClickCatchersLeadingToTrailing(in root: NSView) -> [(frame: CGRect, view: OrbitActionButtonClickCatchingView)] {
        var results: [(CGRect, OrbitActionButtonClickCatchingView)] = []
        func walk(_ view: NSView) {
            if let catcher = view as? OrbitActionButtonClickCatchingView {
                results.append((view.convert(view.bounds, to: root), catcher))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return results.sorted { $0.0.minX < $1.0.minX }
    }

    private struct LiveFolderRowHost: View {
        @Environment(AppEnvironment.self) private var env
        var folderID: FolderID
        var spaceID: SpaceID
        var theme: SpaceTheme

        private var folder: Folder? {
            for node in env.pinnedNodes(in: spaceID) {
                if case .folder(let folder) = node, folder.id == folderID { return folder }
            }
            return nil
        }

        var body: some View {
            if let folder {
                PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: theme, depth: 0)
            }
        }
    }

    private func hostLiveRow(folder: Folder, env: AppEnvironment, spaceID: SpaceID) -> NSHostingView<some View> {
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)
        let hosted = LiveFolderRowHost(folderID: folder.id, spaceID: spaceID, theme: SpaceTheme())
            .environment(env)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: hosted)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }

    private func isExpanded(_ folderID: FolderID, env: AppEnvironment, spaceID: SpaceID) -> Bool? {
        for node in env.pinnedNodes(in: spaceID) {
            if case .folder(let folder) = node, folder.id == folderID { return folder.isExpanded }
        }
        return nil
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_liveRow_exposesExactlyFourClickCatchersInLeadingToTrailingOrder

    func test_liveRow_exposesExactlyFourClickCatchersInLeadingToTrailingOrder() {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)

        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)

        XCTAssertEqual(
            catchers.count, 4,
            "Expected exactly 4 click catchers (glyph, name label, empty space, trailing +) on a non-renaming folder row; found \(catchers.count)."
        )
        for index in 1..<catchers.count {
            XCTAssertGreaterThan(
                catchers[index].frame.minX, catchers[index - 1].frame.minX,
                "Click catcher \(index) must sit strictly to the right of catcher \(index - 1) — this test's own leading-to-trailing sort/index assumption must hold before any test below can trust which catcher is 'the name label'."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_liveRow_clickCatchersLeaveARealUncoveredMarginAboveAndBelowForDragging

    func test_liveRow_clickCatchersLeaveARealUncoveredMarginAboveAndBelowForDragging() {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)

        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)
        XCTAssertFalse(catchers.isEmpty, "Expected at least one click catcher to measure against.")

        let minY = catchers.map(\.frame.minY).min()!
        let maxY = catchers.map(\.frame.maxY).max()!
        let coveredHeight = maxY - minY
        let uncoveredMargin = OrbitMetrics.sidebarRowHeight - coveredHeight

        XCTAssertLessThan(
            coveredHeight, OrbitMetrics.sidebarRowHeight,
            "Every click catcher together must not cover the row's full height (\(OrbitMetrics.sidebarRowHeight)pt) " +
            "— a real margin above and/or below must remain for SwiftUI's own .onDrag to still recognise a drag " +
            "start. Measured covered band: \(coveredHeight)pt (y \(minY)..\(maxY))."
        )
        XCTAssertGreaterThan(
            uncoveredMargin, 4,
            "The uncovered drag margin above/below the row's content must be a real, comfortably sized band, not " +
            "a sub-pixel sliver — measured only \(uncoveredMargin)pt."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_singleClickOnNameLabel_toggleCollapsedFolderToExpanded

    func test_singleClickOnNameLabel_toggleCollapsedFolderToExpanded() async throws {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)
        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)
        let nameLabelCatcher = try XCTUnwrap(catchers[safe: 1]?.view, "Could not find the name label's own click catcher (expected at leading-to-trailing index 1).")

        XCTAssertEqual(isExpanded(folder.id, env: env, spaceID: spaceID), false, "Precondition: the folder starts collapsed.")

        nameLabelCatcher.mouseDown(with: mouseDownEvent(clickCount: 1))

        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.3) * 1_000_000_000))

        XCTAssertEqual(
            isExpanded(folder.id, env: env, spaceID: spaceID), true,
            "A single click on the folder's name label must collapse/expand it, same as the glyph — the user's own report: 'Clicking just always collapses and uncollapses it', now true everywhere on the row, not nowhere on the label."
        )
        XCTAssertTrue(env.recordedActions.contains("toggleFolderExpanded"), "The single click must have reached the real toggleFolderExpanded action.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_singleClickOnEmptySpace_togglesCollapsedFolderToExpandedImmediately

    func test_singleClickOnEmptySpace_togglesCollapsedFolderToExpandedImmediately() throws {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)
        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)
        let emptySpaceCatcher = try XCTUnwrap(catchers[safe: 2]?.view, "Could not find the empty-space click catcher (expected at leading-to-trailing index 2).")

        emptySpaceCatcher.mouseDown(with: mouseDownEvent(clickCount: 1))

        XCTAssertEqual(
            isExpanded(folder.id, env: env, spaceID: spaceID), true,
            "A single click on the empty space between the name and the trailing controls must collapse/expand the folder, immediately — this region previously had no handler of any kind."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_doubleClickOnNameLabel_neverTogglesTheFolder_evenAfterWaitingPastTheDoubleClickInterval

    func test_doubleClickOnNameLabel_neverTogglesTheFolder_evenAfterWaitingPastTheDoubleClickInterval() async throws {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)
        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)
        let nameLabelCatcher = try XCTUnwrap(catchers[safe: 1]?.view, "Could not find the name label's own click catcher (expected at leading-to-trailing index 1).")

        XCTAssertEqual(isExpanded(folder.id, env: env, spaceID: spaceID), false, "Precondition: the folder starts collapsed.")

        nameLabelCatcher.mouseDown(with: mouseDownEvent(clickCount: 1))
        nameLabelCatcher.mouseDown(with: mouseDownEvent(clickCount: 2))

        XCTAssertFalse(
            env.recordedActions.contains("toggleFolderExpanded"),
            "Immediately after a double click on the name, toggleFolderExpanded must never have been called — the second click must cancel the first's deferred toggle before it runs, not merely revert its effect."
        )

        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.3) * 1_000_000_000))

        XCTAssertFalse(
            env.recordedActions.contains("toggleFolderExpanded"),
            "Even after waiting past NSEvent.doubleClickInterval — long enough for a wrongly-still-pending deferred toggle to have fired — toggleFolderExpanded must still never have been called."
        )
        XCTAssertEqual(
            isExpanded(folder.id, env: env, spaceID: spaceID), false,
            "A double click on the folder's name must never leave it in a different collapsed/expanded state than before either click — the CRITICAL requirement: no flip, not even transiently reverted."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_doubleClickOnNameLabel_beginsARealRenameTextField

    func test_doubleClickOnNameLabel_beginsARealRenameTextField() throws {
        let folder = Folder(name: "Reading", isExpanded: false)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
        let hostingView = hostLiveRow(folder: folder, env: env, spaceID: spaceID)

        XCTAssertFalse(
            containsTextField(hostingView),
            "Precondition: no rename field exists before either click."
        )

        let catchers = collectClickCatchersLeadingToTrailing(in: hostingView)
        let nameLabelCatcher = try XCTUnwrap(catchers[safe: 1]?.view, "Could not find the name label's own click catcher (expected at leading-to-trailing index 1).")

        nameLabelCatcher.mouseDown(with: mouseDownEvent(clickCount: 1))
        nameLabelCatcher.mouseDown(with: mouseDownEvent(clickCount: 2))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            containsTextField(hostingView),
            "A double click on the folder's name must begin a real inline rename — expected a genuine NSTextField to appear in the live view tree once PinnedFolderRowView.body swaps its Text label for a TextField."
        )
    }

    private func containsTextField(_ view: NSView) -> Bool {
        if view is NSTextField { return true }
        return view.subviews.contains { containsTextField($0) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
