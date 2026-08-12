import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class OrbitScrollerLiveRetrofitTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // Held for the lifetime of the test method: a hosting view whose window
    // has been released mid-measurement stops laying out.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - The mechanism

    func test_aSwiftUIScrollViewIsRetrofittedWithNoCallSiteOfItsOwn() {
        OrbitScrollerInstaller.start()

        let hosting = host(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<400, id: \.self) { index in
                        Text("Row \(index)").frame(height: 24)
                    }
                }
            }
        )

        pumpMainQueue()

        let scrollViews = scrollViews(under: hosting).filter(\.hasVerticalScroller)
        guard !scrollViews.isEmpty else {
            return XCTFail("SwiftUI's ScrollView produced no NSScrollView with a vertical scroller, so this test measured nothing. Re-check the harness before trusting a pass.")
        }

        for scrollView in scrollViews {
            guard let scroller = scrollView.verticalScroller else { continue }
            XCTAssertTrue(
                scroller is OrbitScroller,
                "A SwiftUI ScrollView must be retrofitted by the installed observers alone, with no call site of its own. It still has \(type(of: scroller))."
            )
            XCTAssertEqual(
                scroller.frame.width, OrbitScrollerMetrics.thickness, accuracy: 0.01,
                "SwiftUI must lay the retrofitted scroller out at Orbit's width; it came out \(scroller.frame.width)pt."
            )
        }
    }

    func test_theLibrarysSpacesSectionGetsThinScrollers() {
        OrbitScrollerInstaller.start()

        let hosting = host(
            LibrarySpacesView(searchQuery: "")
                .environment(env)
                .frame(width: 900, height: 500)
        )
        pumpMainQueue()

        let horizontals = scrollViews(under: hosting).filter(\.hasHorizontalScroller)
        guard !horizontals.isEmpty else {
            return XCTFail("The Spaces section drew no horizontally scrolling NSScrollView, so the bar from the user's capture was not under test.")
        }

        for scrollView in horizontals {
            guard let scroller = scrollView.horizontalScroller else { continue }
            XCTAssertTrue(
                scroller is OrbitScroller,
                "The scroller under the Manage Spaces columns — the bar in the report — must be Orbit's, not \(type(of: scroller))."
            )
            XCTAssertEqual(
                scroller.frame.height, OrbitScrollerMetrics.thickness, accuracy: 0.01,
                "The Spaces section's horizontal scroller came out \(scroller.frame.height)pt tall."
            )
        }
    }

    // .scrollIndicators(.hidden) still has a live NSScroller in the tree (only visually suppressed); .never produces none at all.
    func test_anIndicatorOptOutSurvivesTheRetrofitAndAHiddenOneIsStillThin() {
        OrbitScrollerInstaller.start()

        let rows = ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<400, id: \.self) { index in
                    Text("Row \(index)").frame(height: 24)
                }
            }
        }

        let never = host(rows.scrollIndicators(.never))
        pumpMainQueue()
        let neverScrollViews = scrollViews(under: never)
        XCTAssertFalse(neverScrollViews.isEmpty, "`.never` must still produce an NSScrollView, or this test measured nothing.")
        for scrollView in neverScrollViews {
            XCTAssertFalse(
                scrollView.hasVerticalScroller,
                "The retrofit must never switch an indicator back on for a surface that opted out with `.scrollIndicators(.never)`."
            )
            XCTAssertNil(
                scrollView.verticalScroller,
                "A `.never` scroll view must come out of the retrofit with no scroller at all; it has \(String(describing: scrollView.verticalScroller))."
            )
        }

        let hidden = host(rows.scrollIndicators(.hidden))
        pumpMainQueue()
        let hiddenScrollers = scrollViews(under: hidden).compactMap(\.verticalScroller)
        XCTAssertFalse(hiddenScrollers.isEmpty, "`.hidden` is expected to leave a live scroller in place — if that stops being true, the comment above this test is stale and needs remeasuring.")
        for scroller in hiddenScrollers {
            XCTAssertTrue(
                scroller is OrbitScroller,
                "A `.hidden` surface keeps a real scroller and shows it while scrolling, so it must be Orbit's, not \(type(of: scroller))."
            )
            XCTAssertEqual(
                scroller.frame.width, OrbitScrollerMetrics.thickness, accuracy: 0.01,
                "The scroller behind `.scrollIndicators(.hidden)` came out \(scroller.frame.width)pt wide."
            )
        }
    }

    // MARK: - Harness

    private func host<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    private func pumpMainQueue() {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func scrollViews(under view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found.append(contentsOf: scrollViews(under: subview)) }
        return found
    }
}
