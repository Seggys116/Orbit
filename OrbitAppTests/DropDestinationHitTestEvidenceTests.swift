//  Uses AppKit's real hitTest(_:); synthesized NSEvent clicks don't wake SwiftUI's gesture arena here.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class DropDestinationHitTestEvidenceTests: XCTestCase {

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

    // MARK: - 1. Baseline: no .dropDestination

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_baseline_noDropDestination_hitTestResolvesToTheRepresentableItself
    func test_baseline_noDropDestination_hitTestResolvesToTheRepresentableItself() {
        let recording = RecordingView()
        let size = CGSize(width: 120, height: 120)
        let content = RecordingRepresentable(view: recording).frame(width: size.width, height: size.height)
        let (window, _) = host(content, size: size)
        defer { window.orderOut(nil) }

        guard let hit = window.contentView?.hitTest(NSPoint(x: 60, y: 60)) else {
            XCTFail("hitTest returned nil for the baseline (no `.dropDestination`) case — the harness itself isn't reaching AppKit's real view tree.")
            return
        }
        XCTAssertTrue(
            hit === recording || recording.isDescendant(of: hit),
            "Baseline sanity check failed: with nothing but the representable in this ZStack, hitTest should resolve to it (or an ancestor that forwards to it), not to \(type(of: hit))."
        )
    }

    // MARK: - 2. Does a gesture-less .dropDestination change what hitTest resolves to?

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_dropDestinationWithNoGesture_changesWhatHitTestResolvesTo
    func test_dropDestinationWithNoGesture_changesWhatHitTestResolvesTo() {
        let recording = RecordingView()
        let size = CGSize(width: 120, height: 120)
        let content = ZStack {
            RecordingRepresentable(view: recording)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
                .dropDestination(for: SidebarDragPayload.self) { _, _ in false } isTargeted: { _ in }
        }
        .frame(width: size.width, height: size.height)
        let (window, _) = host(content, size: size)
        defer { window.orderOut(nil) }

        guard let hit = window.contentView?.hitTest(NSPoint(x: 60, y: 60)) else {
            XCTFail("hitTest returned nil with a `.dropDestination` present — that alone is evidence the point is claimed by *something* other than plain pass-through.")
            return
        }

        let resolvedToRepresentable = hit === recording || recording.isDescendant(of: hit)
        XCTContext.runActivity(named: "RANK 4 evidence: does a gesture-less .dropDestination consume a plain click?") { _ in
            if resolvedToRepresentable {
                XCTContext.runActivity(named: "ANSWER: NO — hitTest still resolved to the representable (\(type(of: hit))). A plain .dropDestination with no gesture does NOT intercept an ordinary click in this configuration.", block: { _ in })
            } else {
                XCTContext.runActivity(named: "ANSWER: YES — hitTest resolved to \(type(of: hit)), not the representable. A plain .dropDestination DOES intercept an ordinary click here.", block: { _ in })
            }
        }
        addEvidence(key: "dropDestinationConsumesClick", value: !resolvedToRepresentable)
    }

    // MARK: - 3. Does .allowsHitTesting(false) restore pass-through?

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_allowsHitTestingFalse_onDropDestination_restoresPassThroughToTheRepresentable
    func test_allowsHitTestingFalse_onDropDestination_restoresPassThroughToTheRepresentable() {
        let recording = RecordingView()
        let size = CGSize(width: 120, height: 120)
        let content = ZStack {
            RecordingRepresentable(view: recording)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
                .dropDestination(for: SidebarDragPayload.self) { _, _ in false } isTargeted: { _ in }
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        let (window, _) = host(content, size: size)
        defer { window.orderOut(nil) }

        guard let hit = window.contentView?.hitTest(NSPoint(x: 60, y: 60)) else {
            XCTFail("hitTest returned nil even with `.allowsHitTesting(false)` on the drop zone — nothing in this tree claims the point at all, which would itself be a (different) bug.")
            return
        }
        let resolvedToRepresentable = hit === recording || recording.isDescendant(of: hit)
        XCTContext.runActivity(named: "RANK 4 evidence: does .allowsHitTesting(false) restore click pass-through through a .dropDestination?") { _ in
            XCTContext.runActivity(named: resolvedToRepresentable
                ? "ANSWER: YES — with .allowsHitTesting(false) applied, hitTest resolves to the representable again. This is the clean fix."
                : "ANSWER: NO — hitTest still resolves to \(type(of: hit)) even under .allowsHitTesting(false). Need a different mechanism.",
                block: { _ in })
        }
        addEvidence(key: "allowsHitTestingFalseRestoresPassThrough", value: resolvedToRepresentable)
        XCTAssertTrue(
            resolvedToRepresentable,
            "`.allowsHitTesting(false)` on a `.dropDestination`-decorated view must restore plain-click pass-through to the view beneath it in the same ZStack — hitTest resolved to \(type(of: hit)) instead of the representable underneath."
        )
    }

    // MARK: - 4. Does AppKit drag-destination registration survive allowsHitTesting(false)?

    @MainActor
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_registeredDraggedTypes_withAndWithoutAllowsHitTestingFalse
    func test_registeredDraggedTypes_withAndWithoutAllowsHitTestingFalse() {
        func draggedTypesRegisteredSomewhere(allowsHitTesting: Bool) -> Bool {
            let recording = RecordingView()
            let size = CGSize(width: 120, height: 120)
            let zone = Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
                .dropDestination(for: SidebarDragPayload.self) { _, _ in false } isTargeted: { _ in }
            let content = ZStack {
                RecordingRepresentable(view: recording)
                if allowsHitTesting {
                    zone
                } else {
                    zone.allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            let (window, hostView) = host(content, size: size)
            defer { window.orderOut(nil) }

            func anyViewRegistersDraggedTypes(_ view: NSView) -> Bool {
                if !view.registeredDraggedTypes.isEmpty { return true }
                return view.subviews.contains { anyViewRegistersDraggedTypes($0) }
            }
            return anyViewRegistersDraggedTypes(hostView)
        }

        let registeredWhenHitTestable = draggedTypesRegisteredSomewhere(allowsHitTesting: true)
        let registeredWhenNotHitTestable = draggedTypesRegisteredSomewhere(allowsHitTesting: false)

        XCTContext.runActivity(named: "RANK 4 supporting evidence: registeredDraggedTypes with allowsHitTesting=true: \(registeredWhenHitTestable), with allowsHitTesting=false: \(registeredWhenNotHitTestable)") { _ in }
        addEvidence(key: "draggedTypesRegistered_hitTestable", value: registeredWhenHitTestable)
        addEvidence(key: "draggedTypesRegistered_notHitTestable", value: registeredWhenNotHitTestable)
    }

    private func addEvidence(key: String, value: Bool) {
        print("[RANK4-EVIDENCE] \(key)=\(value)")
    }
}
