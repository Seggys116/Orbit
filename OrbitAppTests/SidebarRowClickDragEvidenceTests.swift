import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class SidebarRowClickDragEvidenceTests: XCTestCase {

    private final class RecordingView: NSView {}

    private struct RecordingRepresentable: NSViewRepresentable {
        let view: RecordingView
        func makeNSView(context: Context) -> RecordingView { view }
        func updateNSView(_ nsView: RecordingView, context: Context) {}
    }

    @MainActor
    private func host<V: View>(_ content: V, size: CGSize) -> (window: NSWindow, hostView: NSHostingView<V>) {
        let hostView = NSHostingView(rootView: content)
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostView
        window.orderFront(nil)
        hostView.layoutSubtreeIfNeeded()
        return (window, hostView)
    }

    @MainActor
    private func makeRow(recording: RecordingView, isFolder: Bool = false) -> some View {
        SidebarDropTarget(
            payload: SidebarDragPayload(nodeID: UUID(), kind: .pinnedNode, spaceID: SpaceID()),
            rowID: UUID(),
            isFolder: isFolder,
            accentColor: .blue,
            onDrop: { _, _ in }
        ) {
            RecordingRepresentable(view: recording)
                .frame(width: 220, height: OrbitMetrics.sidebarRowHeight)
        }
        .frame(width: 220, height: OrbitMetrics.sidebarRowHeight)
    }

    // MARK: - 1. Geometric claim, measured against the real `SidebarDropTarget`

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_hitTestInsideNominalTopStripBand_resolvesToContent
    func test_atRest_hitTestInsideNominalTopStripBand_resolvesToContent() {
        assertResolvesToContent(atFractionOfRowHeightFromTop: 0.15, label: "top strip band (0.15 * rowHeight)")
    }

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_hitTestInMiddleGapBetweenStrips_resolvesToContent
    func test_atRest_hitTestInMiddleGapBetweenStrips_resolvesToContent() {
        assertResolvesToContent(atFractionOfRowHeightFromTop: 0.5, label: "middle gap (0.5 * rowHeight)")
    }

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_atRest_hitTestInsideNominalBottomStripBand_resolvesToContent
    func test_atRest_hitTestInsideNominalBottomStripBand_resolvesToContent() {
        assertResolvesToContent(atFractionOfRowHeightFromTop: 0.85, label: "bottom strip band (0.85 * rowHeight)")
    }

    /// AppKit views are unflipped, so "fraction from the top" is converted to a bottom-left-origin y.
    @MainActor
    private func assertResolvesToContent(atFractionOfRowHeightFromTop fraction: CGFloat, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let recording = RecordingView()
        let width: CGFloat = 220
        let height = OrbitMetrics.sidebarRowHeight
        let row = makeRow(recording: recording)
        let (window, _) = host(row, size: CGSize(width: width, height: height))
        defer { window.orderOut(nil) }

        let yFromTop = height * fraction
        let point = NSPoint(x: width / 2, y: height - yFromTop)
        guard let hit = window.contentView?.hitTest(point) else {
            XCTFail("hitTest(\(point)) returned nil at \(label) — nothing in the real SidebarDropTarget tree claims this point at rest, which is itself a (different) bug.", file: file, line: line)
            return
        }
        let resolvedToContent = hit === recording || recording.isDescendant(of: hit)
        XCTContext.runActivity(named: "click-reliability evidence: at rest, does \(label) resolve to the row's real content?") { _ in
            XCTContext.runActivity(named: resolvedToContent
                ? "ANSWER: YES — hitTest resolved to the RecordingView (or an ancestor forwarding to it). An ordinary click at \(label) is not geometrically claimed by the drop strips or the bootstrap full-row dropDestination."
                : "ANSWER: NO — hitTest resolved to \(type(of: hit)) instead of the row's own content at \(label). Something in SidebarDropTarget's ZStack is still geometrically eating this click at rest.",
                block: { _ in })
        }
        print("[CLICK-EVIDENCE] atRest.\(label.split(separator: " ").first ?? "").resolvesToContent=\(resolvedToContent)")
        XCTAssertTrue(
            resolvedToContent,
            "At rest (no drag in progress), a plain click at \(label) must reach the row's real content, not one of SidebarDropTarget's drop zones — hitTest resolved to \(type(of: hit)) instead.",
            file: file, line: line
        )
    }

    /// Strips generics off an `NSView`'s dynamic type name so two trees can be compared on
    /// which real AppKit classes are present, not SwiftUI's internal generic type spelling.
    private func baseClassSignature(_ view: NSView) -> [String] {
        func baseName(_ type: Any.Type) -> String {
            let full = String(describing: type)
            return full.split(separator: "<", maxSplits: 1).first.map(String.init) ?? full
        }
        return [baseName(type(of: view))] + view.subviews.flatMap(baseClassSignature)
    }

    // MARK: - 2. Does `.draggable(_:)` alone add a new, distinct `NSView`?

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_draggablePresenceAddsNoDistinctNSView
    func test_draggablePresenceAddsNoDistinctNSView() {
        let size = CGSize(width: 120, height: 120)

        let withoutDraggable = RecordingView()
        let plainContent = RecordingRepresentable(view: withoutDraggable).frame(width: size.width, height: size.height)
        let (plainWindow, plainHost) = host(plainContent, size: size)
        defer { plainWindow.orderOut(nil) }

        let withDraggable = RecordingView()
        let draggableContent = RecordingRepresentable(view: withDraggable)
            .frame(width: size.width, height: size.height)
            .draggable(SidebarDragPayload(nodeID: UUID(), kind: .pinnedNode, spaceID: SpaceID()))
        let (draggableWindow, draggableHost) = host(draggableContent, size: size)
        defer { draggableWindow.orderOut(nil) }

        let plainSignature = baseClassSignature(plainHost)
        let draggableSignature = baseClassSignature(draggableHost)

        XCTContext.runActivity(named: "click-reliability evidence: does .draggable(_:) add a distinct NSView to the tree?") { _ in
            XCTContext.runActivity(named: "without .draggable, base classes: \(plainSignature)") { _ in }
            XCTContext.runActivity(named: "with .draggable, base classes: \(draggableSignature)") { _ in }
            XCTContext.runActivity(named: draggableSignature == plainSignature
                ? "ANSWER: NO — identical real-NSView-class tree with and without .draggable(_:). The drag-vs-tap race with content()'s own .onTapGesture is invisible to hitTest by construction (no second NSView boundary exists between them), and can only be reasoned about, not proven, in this harness."
                : "ANSWER: YES — .draggable(_:) added a distinct NSView class. That is new since this file's header was written; re-investigate with the new subview as a direct hitTest target.",
                block: { _ in })
        }
        print("[CLICK-EVIDENCE] draggableAddsDistinctNSView=\(draggableSignature != plainSignature)")
        XCTAssertEqual(
            draggableSignature, plainSignature,
            "If this ever fails, `.draggable(_:)` has started adding a distinct NSView class to the tree — update this file's own header, because the drag-vs-tap race would then be directly testable with hitTest rather than only reasoned about."
        )
    }

    // MARK: - 3. Does the full `SidebarDropTarget` apparatus add real `NSView`s?

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_fullSidebarDropTargetApparatus_addsRealDraggingDestinationViews
    func test_fullSidebarDropTargetApparatus_addsRealDraggingDestinationViews() {
        let size = CGSize(width: 220, height: OrbitMetrics.sidebarRowHeight)

        let plainRecording = RecordingView()
        let plainContent = RecordingRepresentable(view: plainRecording).frame(width: size.width, height: size.height)
        let (plainWindow, plainHost) = host(plainContent, size: size)
        defer { plainWindow.orderOut(nil) }

        let rowRecording = RecordingView()
        let (rowWindow, rowHost) = host(makeRow(recording: rowRecording), size: size)
        defer { rowWindow.orderOut(nil) }

        let plainSignature = baseClassSignature(plainHost)
        let rowSignature = baseClassSignature(rowHost)

        func count(_ className: String, in signature: [String]) -> Int {
            signature.filter { $0 == className }.count
        }
        let draggingDestinationViewCount = count("_PlatformDraggingDestinationView", in: rowSignature)

        XCTContext.runActivity(named: "click-reliability evidence: does the full SidebarDropTarget apparatus add real dragging-destination NSViews?") { _ in
            XCTContext.runActivity(named: "plain content, base classes: \(plainSignature)") { _ in }
            XCTContext.runActivity(named: "SidebarDropTarget-wrapped content, base classes: \(rowSignature)") { _ in }
            XCTContext.runActivity(named: "ANSWER: the real row tree carries \(draggingDestinationViewCount) real _PlatformDraggingDestinationView instance(s) beyond the plain baseline's 0 — one per .dropDestination call in SidebarDropTarget.realBody (content()'s own bootstrap target, the top strip, the bottom strip). .dropDestination is real NSView-level machinery, not purely gesture-arena state the way .draggable is (contrast test_draggablePresenceAddsNoDistinctNSView above).") { _ in }
        }
        print("[CLICK-EVIDENCE] fullApparatusDraggingDestinationViewCount=\(draggingDestinationViewCount)")
        print("[CLICK-EVIDENCE] fullApparatusAddsRealNSViews=\(rowSignature != plainSignature)")
        XCTAssertEqual(
            draggingDestinationViewCount, 3,
            "SidebarDropTarget.realBody declares exactly three `.dropDestination` calls (content()'s own bootstrap target, the top strip, the bottom strip). If this count ever changes, either a drop zone was added/removed or SwiftUI stopped giving each one its own real NSView — either way this comment and this file's own header need updating to match."
        )
        XCTAssertNotEqual(
            rowSignature, plainSignature,
            "The real SidebarDropTarget apparatus should add real NSViews beyond the plain baseline (three .dropDestination-backed _PlatformDraggingDestinationViews at minimum) — if this ever passes as equal, the apparatus has been simplified and this section's own evidence is stale."
        )
    }

}
