import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

@MainActor
final class SplitDropZoneOverlayPageInteractionRegressionTests: XCTestCase {

    private final class EngineStandInView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private struct EngineStandInRepresentable: NSViewRepresentable {
        let view: EngineStandInView
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

    private final class StandInWebContents: NSObject, WebContents {
        let id = UUID()
        let session: EngineSession
        weak var delegate: WebContentsDelegate?
        var navigationState: NavigationState = .empty
        var mediaState: MediaState = .idle
        var zoomFactor: Double = 1.0
        var isClosed = false
        let standIn: EngineStandInView

        init(session: EngineSession, standIn: EngineStandInView) {
            self.session = session
            self.standIn = standIn
        }

        func load(_ url: URL) { navigationState.url = url }
        func loadHTML(_ html: String, baseURL: URL?) {}
        func reload(ignoringCache: Bool) {}
        func stopLoading() {}
        func goBack() {}
        func goForward() {}
        func go(offset: Int) {}
        func sessionHistory() -> [SessionHistoryEntry] { [] }
        func currentCertificate() -> SiteCertificate? { nil }
        @discardableResult
        func evaluateJavaScript(_ script: String) async throws -> Any? { nil }
        func injectUserScript(_ script: UserScript) {}
        func find(_ text: String, options: FindOptions) {}
        func stopFinding(clearSelection: Bool) {}
        func cut() {}
        func copy() {}
        func paste() {}
        func selectAll() {}
        func setZoomFactor(_ factor: Double) { zoomFactor = factor }
        func setPreferredColorScheme(_ scheme: ContentColorScheme?) {}
        func setMuted(_ muted: Bool) { mediaState.isMuted = muted }
        func togglePictureInPicture() {}
        func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? { nil }
        func print() {}
        func savePage() {}
        func cancelDownload(id: UUID) {}
        func showDeveloperTools(inspectAt point: CGPoint?) {}
        func closeDeveloperTools() {}
        func focus() {}
        func close() { isClosed = true }
        lazy var view: NSView = standIn
    }

    // MARK: - Harness (mirrors `OrbitWindowController.installContentView(window:)`)

    private func hostLikeProduction<V: View>(_ content: V, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: content)
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

    private func reachedEngine(_ window: NSWindow, at point: NSPoint, engine: NSView) -> Bool {
        guard let themeFrame = window.contentView?.superview else { return false }
        let hit = themeFrame.hitTest(point)
        return hit === engine || (hit.map { $0.isDescendant(of: engine) } ?? false)
    }

    private func anyViewRegistersDraggedTypes(_ view: NSView) -> Bool {
        if !view.registeredDraggedTypes.isEmpty { return true }
        return view.subviews.contains { anyViewRegistersDraggedTypes($0) }
    }

    private static let size = CGSize(width: 900, height: 700)

    // MARK: - 1. The real production tree: page content is reachable everywhere

    func test_realContentCardTree_pageIsReachableAtEveryPointOverIt() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID, "The demo environment has no active tab.")
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        let points: [(String, NSPoint)] = [
            ("centre", NSPoint(x: 450, y: 335)),
            ("upper-left quadrant", NSPoint(x: 200, y: 500)),
            ("upper-right quadrant", NSPoint(x: 700, y: 500)),
            ("lower-left quadrant", NSPoint(x: 200, y: 150)),
            ("lower-right quadrant", NSPoint(x: 700, y: 150)),
            ("near left edge", NSPoint(x: 20, y: 335)),
            ("near right edge", NSPoint(x: 880, y: 335)),
        ]
        for (label, point) in points {
            XCTAssertTrue(
                reachedEngine(window, at: point, engine: engine),
                "AppKit's hit test at \(label) \(point) did not reach the engine view — a page-interaction regression (see this file's header)."
            )
        }
    }

    func test_realContentCardTree_paneHeaderBand_catchersStillWin_nonCatchersReachTheEngine() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let themeFrame = window.contentView?.superview else {
            return XCTFail("No theme frame.")
        }

        for y in [690.0, 680.0] {
            let point = NSPoint(x: 450, y: y)
            let hit = themeFrame.hitTest(point)
            XCTAssertTrue(
                hit is OrbitActionButtonClickCatchingView,
                "Header click-catcher band regressed at (450, \(y)): resolved \(hit.map { "\(type(of: $0))" } ?? "nil") instead of a click-catcher."
            )
        }

        for y in [670.0, 660.0] {
            let point = NSPoint(x: 450, y: y)
            XCTAssertTrue(
                reachedEngine(window, at: point, engine: engine),
                "Pane header band non-catcher point (450, \(y)) did not reach the engine view — the bonus finding from the diagnosis regressed."
            )
        }
    }

    // MARK: - 2. AppKit's own drag-destination registration survives the fix

    func test_realSplitDropZoneOverlay_stillRegistersAppKitDragDestination() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView else {
            return XCTFail("No content view.")
        }
        XCTAssertTrue(
            anyViewRegistersDraggedTypes(contentView),
            """
            No view in the real ContentCardView tree registers for dragged \
            types with an active tab present. Removing \
            `.contentShape(Rectangle())` from `SplitDropZoneOverlay.dropZone(size:)` \
            must not also remove the AppKit-level drag-destination \
            registration `.sidebarPayloadDropDestination` needs for a real \
            system drag session to ever reach this window's view tree.
            """
        )
    }

    func test_realSplitDropZoneOverlay_noActiveTab_stateIsRecorded() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        env.activeTabID = nil
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                SplitDropZoneOverlay()
            }
            .environment(env),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()

        let registered = window.contentView.map(anyViewRegistersDraggedTypes) ?? false
        print("[SPLIT-DROPZONE-EVIDENCE] draggedTypesRegistered_noActiveTab=\(registered)")
    }

    // MARK: - 3. Driving AppKit's real NSDraggingDestination protocol
    // SwiftUI.DropInfo has no public initialiser, but NSDraggingInfo is a protocol: TestDraggingInfo conforms to it directly and is handed to the real NSDraggingDestination methods on the view SwiftUI created for .sidebarPayloadDropDestination, driving SwiftUI's genuine internal drop routing.

    private final class TestDraggingInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = [.move, .generic, .copy]
        var draggingLocation: NSPoint = .zero
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        let draggingPasteboard: NSPasteboard
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(pasteboard: NSPasteboard, window: NSWindow?) {
            self.draggingPasteboard = pasteboard
            self.draggingDestinationWindow = window
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {
            var stop: ObjCBool = false
            for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
                let draggingItem = NSDraggingItem(pasteboardWriter: item)
                block(draggingItem, index, &stop)
                if stop.boolValue { break }
            }
        }
    }

    // Writes onto the real named system drag pasteboard (NSPasteboard(name: .drag)): SidebarDragPayload.decodeSynchronously() reads that fixed pasteboard directly, so seeding a private one on TestDraggingInfo alone would leave performDrop unable to decode anything.
    @discardableResult
    private func seedDragPasteboard(with payload: SidebarDragPayload) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)
        let data = try JSONEncoder().encode(payload)
        item.setData(data, forType: type)
        pasteboard.writeObjects([item])
        return pasteboard
    }

    // SwiftUI's own internal drag-destination view, located by class-name
    // match since it is a SwiftUI-internal type with no public symbol.
    private func platformDraggingDestinationView(in root: NSView) -> NSView? {
        if "\(type(of: root))" == "_PlatformDraggingDestinationView" { return root }
        for subview in root.subviews {
            if let found = platformDraggingDestinationView(in: subview) { return found }
        }
        return nil
    }

    private func makeDraggableTab(env: AppEnvironment, targetTabID: TabID) throws -> Orbit.Tab {
        let space = try XCTUnwrap(env.tab(targetTabID)?.spaceID, "The active tab has no space.")
        let tab = Orbit.Tab(spaceID: space, section: .today, url: URL(string: "https://example.com/dragged")!, title: "Dragged")
        env.state.tabs[tab.id] = tab
        return tab
    }

    @discardableResult
    private func driveDragSequence(
        destinationView: NSView,
        window: NSWindow,
        pasteboard: NSPasteboard,
        env: AppEnvironment,
        points: [(String, NSPoint)]
    ) -> (edges: [(String, SplitEdge?)], performDragOperationResult: Bool) {
        let info = TestDraggingInfo(pasteboard: pasteboard, window: window)
        guard let destination = destinationView as? NSDraggingDestination else {
            XCTFail("\(type(of: destinationView)) does not conform to NSDraggingDestination — nothing to drive.")
            return ([], false)
        }
        info.draggingLocation = points.first?.1 ?? .zero
        _ = destination.draggingEntered?(info)

        var edges: [(String, SplitEdge?)] = []
        for (label, point) in points {
            info.draggingLocation = point
            _ = destination.draggingUpdated?(info)
            edges.append((label, env.activeSplitDropZone?.edge))
        }

        info.draggingLocation = points.last?.1 ?? .zero
        let result = destination.performDragOperation?(info) ?? false
        destination.draggingEnded?(info)
        return (edges, result)
    }

    // MARK: - 3. DIAGNOSTIC ONLY — locating the real NSDraggingDestination view

    func test_diagnostic_locateDragDestinationViewAndFrame() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)
        defer { env._test_detachWebContents(for: tabID) }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView else { return XCTFail("No content view.") }
        let orbitType = NSPasteboard.PasteboardType(UTType.orbitSidebarNode.identifier)

        func walk(_ view: NSView, depth: Int) {
            if !view.registeredDraggedTypes.isEmpty {
                let frameInWindow = view.convert(view.bounds, to: nil)
                print("[DRAG-DEST-DIAGNOSTIC] \(String(repeating: "  ", count: depth))\(type(of: view)) registers=\(view.registeredDraggedTypes.map(\.rawValue)) containsOrbitType=\(view.registeredDraggedTypes.contains(orbitType)) frameInWindow=\(frameInWindow)")
            }
            for subview in view.subviews { walk(subview, depth: depth + 1) }
        }
        walk(contentView, depth: 0)
    }

    func test_diagnostic_calibrateDraggingLocationToEdgeMapping() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let targetTabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: targetTabID)
        let draggedTab = try makeDraggableTab(env: env, targetTabID: targetTabID)
        defer {
            env._test_detachWebContents(for: targetTabID)
            env.state.tabs.removeValue(forKey: draggedTab.id)
        }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView,
              let destination = platformDraggingDestinationView(in: contentView) else {
            return XCTFail("Could not find the SwiftUI drag-destination view.")
        }

        let pasteboard = try seedDragPasteboard(with: SidebarDragPayload(nodeID: draggedTab.id, kind: .todayTab, spaceID: draggedTab.spaceID))
        let points: [(String, NSPoint)] = [
            ("centre", NSPoint(x: 450, y: 350)),
            ("near left edge", NSPoint(x: 20, y: 350)),
            ("near right edge", NSPoint(x: 880, y: 350)),
            ("near top edge (high window-y)", NSPoint(x: 450, y: 690)),
            ("near bottom edge (low window-y)", NSPoint(x: 450, y: 10)),
        ]
        let (edges, _) = driveDragSequence(destinationView: destination, window: window, pasteboard: pasteboard, env: env, points: points)
        for (label, edge) in edges {
            print("[DRAG-CALIBRATION] \(label) -> activeSplitDropZone.edge=\(edge.map { "\($0)" } ?? "nil")")
        }
    }

    // MARK: - 4. The real regression tests: driving genuine drop routing

    func test_realDragSession_onUpdateSetsTheCorrectEdgeAtEachOfTheFourEdges_andPageStaysReachable() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let targetTabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: targetTabID)
        let draggedTab = try makeDraggableTab(env: env, targetTabID: targetTabID)
        defer {
            env._test_detachWebContents(for: targetTabID)
            env.state.tabs.removeValue(forKey: draggedTab.id)
        }

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView,
              let destination = platformDraggingDestinationView(in: contentView) else {
            return XCTFail("Could not find the SwiftUI drag-destination view — drag-to-split has no destination to route to at all.")
        }

        let pasteboard = try seedDragPasteboard(with: SidebarDragPayload(nodeID: draggedTab.id, kind: .todayTab, spaceID: draggedTab.spaceID))
        let points: [(String, NSPoint, SplitEdge)] = [
            ("left", NSPoint(x: 20, y: 350), .left),
            ("right", NSPoint(x: 880, y: 350), .right),
            ("top", NSPoint(x: 450, y: 690), .top),
            ("bottom", NSPoint(x: 450, y: 10), .bottom),
        ]
        let (edges, _) = driveDragSequence(
            destinationView: destination,
            window: window,
            pasteboard: pasteboard,
            env: env,
            points: points.map { ($0.0, $0.1) }
        )
        XCTAssertEqual(edges.count, points.count)
        for (recorded, expected) in zip(edges, points) {
            XCTAssertEqual(
                recorded.1,
                expected.2,
                "draggingUpdated near the \(expected.0) edge (\(expected.1)) set activeSplitDropZone.edge=\(recorded.1.map { "\($0)" } ?? "nil"), expected .\(expected.2) — real SwiftUI drop routing did not resolve to the correct edge."
            )
        }

        XCTAssertTrue(
            reachedEngine(window, at: NSPoint(x: 450, y: 335), engine: engine),
            "The page stopped being reachable after driving a real drag sequence through the same tree."
        )
    }

    func test_realDragSession_performDragOperation_createsASplitWithTheDraggedTab() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let targetTabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: targetTabID)
        let draggedTab = try makeDraggableTab(env: env, targetTabID: targetTabID)
        defer {
            env._test_detachWebContents(for: targetTabID)
            env.state.tabs.removeValue(forKey: draggedTab.id)
        }
        XCTAssertNil(env.splitGroup(for: targetTabID), "Precondition: not already split.")

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView,
              let destination = platformDraggingDestinationView(in: contentView) else {
            return XCTFail("Could not find the SwiftUI drag-destination view.")
        }

        let pasteboard = try seedDragPasteboard(with: SidebarDragPayload(nodeID: draggedTab.id, kind: .todayTab, spaceID: draggedTab.spaceID))
        let (_, performed) = driveDragSequence(
            destinationView: destination,
            window: window,
            pasteboard: pasteboard,
            env: env,
            points: [("right", NSPoint(x: 880, y: 350))]
        )
        XCTAssertTrue(performed, "performDragOperation returned false — the drop was not accepted.")

        let group = try XCTUnwrap(env.splitGroup(for: targetTabID), "No SplitGroup exists for the target tab after performDragOperation — createSplit was not reached.")
        XCTAssertEqual(Set(group.tabIDs), Set([targetTabID, draggedTab.id]))
        XCTAssertEqual(group.axis, .horizontal, "A .right drop must produce a horizontal split.")
        XCTAssertEqual(group.tabIDs, [targetTabID, draggedTab.id], "A .right drop must keep the existing tab first (SplitEdge.insertsBefore == false for .right).")
    }

    func test_dragSession_withContentShapeRestoredAsControl_behavesIdenticallyToTheFixedTree() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let targetTabID = try XCTUnwrap(env.activeTabID)
        let draggedTab = try makeDraggableTab(env: env, targetTabID: targetTabID)
        defer { env.state.tabs.removeValue(forKey: draggedTab.id) }
        XCTAssertNil(env.splitGroup(for: targetTabID), "Precondition: not already split.")

        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                ControlMirroredDropZone(includeContentShape: true)
            }
            .environment(env),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.displayIfNeeded()

        guard let contentView = window.contentView,
              let destination = platformDraggingDestinationView(in: contentView) else {
            return XCTFail("Could not find the SwiftUI drag-destination view in the WITH-contentShape control tree — nothing to compare against.")
        }

        let pasteboard = try seedDragPasteboard(with: SidebarDragPayload(nodeID: draggedTab.id, kind: .todayTab, spaceID: draggedTab.spaceID))
        let points: [(String, NSPoint, SplitEdge)] = [
            ("left", NSPoint(x: 20, y: 350), .left),
            ("right", NSPoint(x: 880, y: 350), .right),
            ("top", NSPoint(x: 450, y: 690), .top),
            ("bottom", NSPoint(x: 450, y: 10), .bottom),
        ]
        let (edges, _) = driveDragSequence(
            destinationView: destination,
            window: window,
            pasteboard: pasteboard,
            env: env,
            points: points.map { ($0.0, $0.1) }
        )
        for (recorded, expected) in zip(edges, points) {
            XCTAssertEqual(
                recorded.1,
                expected.2,
                "CONTROL (contentShape restored): near the \(expected.0) edge (\(expected.1)) resolved \(recorded.1.map { "\($0)" } ?? "nil"), expected .\(expected.2)."
            )
        }

        let (_, performed) = driveDragSequence(
            destinationView: destination,
            window: window,
            pasteboard: pasteboard,
            env: env,
            points: [("right", NSPoint(x: 880, y: 350))]
        )
        XCTAssertTrue(performed, "CONTROL: performDragOperation returned false.")
        let group = try XCTUnwrap(env.splitGroup(for: targetTabID), "CONTROL: no SplitGroup after performDragOperation — the two arms disagree, which is exactly the risk this control exists to catch.")
        XCTAssertEqual(Set(group.tabIDs), Set([targetTabID, draggedTab.id]))

        XCTAssertFalse(
            reachedEngine(window, at: NSPoint(x: 450, y: 335), engine: engine),
            "CONTROL: the page was reachable even WITH .contentShape(Rectangle()) present — this mirrored tree is not reproducing the original defect, so its agreement with the fixed tree above proves nothing."
        )
    }
}

private struct ControlMirroredDropZone: View {
    @Environment(AppEnvironment.self) private var env
    var includeContentShape: Bool

    var body: some View {
        GeometryReader { proxy in
            zone(size: proxy.size)
        }
    }

    @ViewBuilder
    private func zone(size: CGSize) -> some View {
        if includeContentShape {
            Color.clear
                .contentShape(Rectangle())
                .sidebarPayloadDropDestination(action: { drop(items: $0, location: $1, size: size) }) { targeted in
                    if !targeted { env.activeSplitDropZone = nil }
                } onUpdate: { update(location: $0, size: size) }
        } else {
            Color.clear
                .sidebarPayloadDropDestination(action: { drop(items: $0, location: $1, size: size) }) { targeted in
                    if !targeted { env.activeSplitDropZone = nil }
                } onUpdate: { update(location: $0, size: size) }
        }
    }

    private func drop(items: [SidebarDragPayload], location: CGPoint, size: CGSize) -> Bool {
        defer { env.activeSplitDropZone = nil }
        guard let item = items.first, let targetTabID = env.activeTabID, item.nodeID != targetTabID else { return false }
        let edge = SplitDropZoneGeometry.edge(at: location, in: size, allowedOrientation: env.activeSplitGroup?.axis)
        env.createSplit(existingTabID: targetTabID, newTabID: item.nodeID, edge: edge)
        return true
    }

    private func update(location: CGPoint, size: CGSize) {
        guard let targetTabID = env.activeTabID else {
            env.activeSplitDropZone = nil
            return
        }
        let edge = SplitDropZoneGeometry.edge(at: location, in: size, allowedOrientation: env.activeSplitGroup?.axis)
        env.activeSplitDropZone = SplitDropZone(edge: edge, targetTabID: targetTabID)
    }
}
