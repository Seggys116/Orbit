import XCTest
import SwiftUI
import AppKit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class SpaceSwipeGestureCatcherTests: XCTestCase {

    // MARK: - 1. Direct hitTest proof

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_passThroughHitTestView_neverClaimsAnyPoint

    func test_passThroughHitTestView_neverClaimsAnyPoint() {
        let view = SpaceSwipeGestureCatcher.PassThroughHitTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))

        let candidatePoints: [NSPoint] = [
            NSPoint(x: 0, y: 0),           // origin corner
            NSPoint(x: 100, y: 300),       // dead centre
            NSPoint(x: 199, y: 599),       // far corner, still inside bounds
            NSPoint(x: 0, y: 300),         // left edge
            NSPoint(x: 199, y: 300),       // right edge (exactly where SidebarResizeHandle begins in production — see SidebarResizeHandleTests)
            NSPoint(x: 100, y: 0),         // top edge
            NSPoint(x: 100, y: 599),       // bottom edge
        ]

        for point in candidatePoints {
            XCTAssertNil(
                view.hitTest(point),
                "refs/DEFECTS.md R10: PassThroughHitTestView.hitTest(\(point)) must return nil — a " +
                "non-nil result here means this view is back to claiming clicks/drags meant for " +
                "whatever SwiftUI content SpaceSwitchingSidebarContainer draws on top of it, which " +
                "is the exact mechanism that made every .onTapGesture-based sidebar row " +
                "(TabRowView row activation, FavoritesGridView taps, PinnedFolderRowView rename) " +
                "silently dead."
            )
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_negativeControl_plainNSViewDoesClaimPointsInsideItsBounds

    func test_negativeControl_plainNSViewDoesClaimPointsInsideItsBounds() {
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertNotNil(
            plainView.hitTest(NSPoint(x: 100, y: 300)),
            "A plain, non-hidden NSView is expected to claim a point inside its own bounds by " +
            "default — this is the exact AppKit behaviour that made the un-fixed " +
            "SpaceSwipeGestureCatcher (a bare NSView(frame: .zero)) swallow sidebar clicks."
        )
    }

    // MARK: - 3. Real composition: the catcher's real installed frame, sized exactly like production

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_realCatcherEmbeddedInProductionShape_neverClaimsAnyPoint

    func test_realCatcherEmbeddedInProductionShape_neverClaimsAnyPoint() {
        struct ProbeSidebarShape: View {
            var body: some View {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Text("Row")
                            .frame(width: geo.size.width, height: 26, alignment: .leading)
                    }
                    .clipped()
                    .background(
                        SpaceSwipeGestureCatcher(onBegin: {}, onChange: { _ in }, onEnd: { _, _ in })
                            .frame(width: geo.size.width, height: geo.size.height)
                    )
                }
            }
        }

        let hosting = NSHostingView(rootView: ProbeSidebarShape().frame(width: 200, height: 600))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        hosting.layoutSubtreeIfNeeded()

        guard let catcherView = firstDescendant(of: hosting, matching: SpaceSwipeGestureCatcher.PassThroughHitTestView.self) else {
            XCTFail("Expected a SpaceSwipeGestureCatcher.PassThroughHitTestView subview somewhere in the hosted view hierarchy — SpaceSwitchingSidebarContainer's real .background() composition installs exactly one for the whole sidebar.")
            return
        }

        for point in [NSPoint(x: 5, y: 5), NSPoint(x: 100, y: 300), NSPoint(x: 195, y: 595)] {
            XCTAssertNil(
                catcherView.hitTest(point),
                "refs/DEFECTS.md R10: the real SpaceSwipeGestureCatcher's underlying NSView, once " +
                "embedded exactly the way SpaceSwitchingSidebarContainer installs it for the whole " +
                "docked sidebar, must still never claim a point (\(point)) via hitTest."
            )
        }
    }
}

// MARK: - Test-only AppKit helpers

@MainActor
private func firstDescendant<V: NSView>(of view: NSView, matching type: V.Type) -> V? {
    if let match = view as? V { return match }
    for subview in view.subviews {
        if let found = firstDescendant(of: subview, matching: type) { return found }
    }
    return nil
}
