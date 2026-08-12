//  Every composition here asserts `reachedEngine` (whether AppKit's hit test resolves to the
//  engine view), never just resolved != nil. Negative cases are deliberate unclickable-page controls.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class PageClipShapeHitTestEvidenceTests: XCTestCase {

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

    // MARK: - Harness

    private struct Probe {
        let resolved: NSView?
        let chain: [String]
        let reachedEngine: Bool
    }

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

    private func probe(_ window: NSWindow, at point: NSPoint, engine: NSView) -> Probe {
        guard let themeFrame = window.contentView?.superview else {
            return Probe(resolved: nil, chain: [], reachedEngine: false)
        }
        let hit = themeFrame.hitTest(point)
        var chain: [String] = []
        var node = hit
        while let current = node {
            chain.append("\(type(of: current))")
            node = current.superview
        }
        let reached = hit === engine || (hit.map { $0.isDescendant(of: engine) } ?? false)
        return Probe(resolved: hit, chain: chain, reachedEngine: reached)
    }

    private func report(_ label: String, _ probe: Probe) {
        print("[PAGE-HIT-EVIDENCE] \(label): resolved=\(probe.resolved.map { "\(type(of: $0))" } ?? "nil") reachedEngine=\(probe.reachedEngine) chain=\(probe.chain.joined(separator: " < "))")
    }

    // Reports and asserts together: the printed chain makes a failure diagnosable.
    @discardableResult
    private func expectReachesEngine(_ label: String, _ probe: Probe, file: StaticString = #filePath, line: UInt = #line) -> Probe {
        report(label, probe)
        XCTAssertTrue(
            probe.reachedEngine,
            """
            \(label): the hit test resolved to \(probe.resolved.map { "\(type(of: $0))" } ?? "nil") \
            instead of the engine view, so a click at this point never reaches the \
            page. Chain: \(probe.chain.joined(separator: " < "))
            """,
            file: file, line: line
        )
        return probe
    }

    @discardableResult
    private func expectBlocked(_ label: String, _ probe: Probe, file: StaticString = #filePath, line: UInt = #line) -> Probe {
        report(label, probe)
        XCTAssertFalse(
            probe.reachedEngine,
            """
            \(label): this arm is a CONTROL -- it exists to reproduce the original \
            defect, and it reached the engine instead. Its sibling's agreement with \
            the fixed tree now proves nothing. Chain: \(probe.chain.joined(separator: " < "))
            """,
            file: file, line: line
        )
        return probe
    }

    private static let size = CGSize(width: 900, height: 700)

    private static let centre = NSPoint(x: 450, y: 350)

    // MARK: - 1. Baseline

    func test_1_baseline_representableAlone() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        let result = probe(window, at: Self.centre, engine: engine)
        XCTAssertNotNil(result.resolved, "The harness never reached AppKit's view tree at all, so nothing below can mean anything.")
        expectReachesEngine("1 baseline (representable alone)", result)
    }

    // MARK: - 2. The clip alone

    func test_2_clipShapeAlone() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("2 clipShape(RoundedRectangle) only", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - 3. The border overlay alone

    func test_3_strokeBorderOverlayAlone() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .center) {
                    RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(OrbitMetrics.cardBorderOpacity), lineWidth: OrbitMetrics.cardBorderWidth)
                        .allowsHitTesting(false)
                },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("3 strokeBorder overlay only", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - 4. The real modifier, unchanged

    func test_4_realPaneCardChrome() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paneCardChrome(isFocused: false),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("4 .paneCardChrome(isFocused: false) [the real modifier]", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - 5. The real modifier plus the real drop-zone sibling

    func test_5_paneCardChromePlusSplitDropZoneOverlay() {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
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
        expectReachesEngine(
            "5 .paneCardChrome + SplitDropZoneOverlay (activeTabID=\(String(describing: env.activeTabID)))",
            probe(window, at: Self.centre, engine: engine)
        )
    }

    // MARK: - 6. Nested exactly as production nests it

    func test_6_vStackWithHeaderThenChrome() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            VStack(spacing: 0) {
                Color.gray.frame(height: 44)
                ZStack {
                    EngineStandInRepresentable(view: engine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .paneCardChrome(isFocused: false),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("6 VStack{header, web}.paneCardChrome", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - 7. The overlay sibling the page really carries

    func test_7_fullPageSiblingHostingViewAboveTheEngineView() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paneCardChrome(isFocused: false),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        guard let container = engine.superview else {
            return XCTFail("The stand-in was never embedded.")
        }
        // Production's WebContentsHostView.PageOverlayHostingView pins over the whole engine
        // view and overrides hitTest to return nil; a plain sibling is the contrast case.
        let plain = NSHostingView(rootView: Color.clear)
        pin(plain, over: container)
        report("7a plain NSHostingView sibling above the engine view", probe(window, at: Self.centre, engine: engine))
        plain.removeFromSuperview()

        let productionShaped = NilHitTestHostingView(rootView: Color.clear)
        pin(productionShaped, over: container)
        expectReachesEngine(
            "7b hitTest-nil hosting sibling [the production overlay's own shape]",
            probe(window, at: Self.centre, engine: engine)
        )
    }

    // Mirrors WebContentsHostView's private PageOverlayHostingView.
    private final class NilHitTestHostingView<Content: View>: NSHostingView<Content> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        required init(rootView: Content) { super.init(rootView: rootView) }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    private func pin(_ overlay: NSView, over container: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
    }

    // MARK: - 8. What each level of the descent answers

    func test_8_perLevelHitTestWalk() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            EngineStandInRepresentable(view: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paneCardChrome(isFocused: false),
            size: Self.size
        )
        defer { window.orderOut(nil) }

        var ancestry: [NSView] = []
        var node: NSView? = engine
        while let current = node {
            ancestry.append(current)
            node = current.superview
        }
        ancestry.reverse()

        print("[PAGE-HIT-EVIDENCE] 8 per-level walk for point \(Self.centre) in window space (paneCardChrome, no drop-zone sibling):")
        for view in ancestry {
            let local = view.superview.map { $0.convert(Self.centre, from: nil) } ?? Self.centre
            let answer = view.hitTest(local)
            let verdict: String
            if answer == nil {
                verdict = "nil (declines)"
            } else if answer === view {
                verdict = "ITSELF (stops the descent)"
            } else {
                verdict = "\(type(of: answer!))"
            }
            print("[PAGE-HIT-EVIDENCE]   \(type(of: view)) frameInWindow=\(view.convert(view.bounds, to: nil)) -> \(verdict)")
        }
        XCTAssertFalse(ancestry.isEmpty, "No ancestry — the stand-in was never realised.")
        expectReachesEngine("8 descent from the theme frame", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - ROUND 2: decomposing `SplitDropZoneOverlay`

    private func geometryReaderShell<Content: View>(@ViewBuilder _ content: @escaping (CGSize) -> Content) -> some View {
        GeometryReader { proxy in
            ZStack { content(proxy.size) }
        }
    }

    func test_9_geometryReaderPlusContentShapeOnly_noDropModifier() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                geometryReaderShell { _ in
                    Color.clear.contentShape(Rectangle())
                }
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectBlocked("9 GeometryReader + Color.clear.contentShape, NO drop modifier", probe(window, at: Self.centre, engine: engine))
    }

    func test_10_sameShellWithDropDestinationFor() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                geometryReaderShell { _ in
                    Color.clear
                        .contentShape(Rectangle())
                        .dropDestination(for: SidebarDragPayload.self) { _, _ in false } isTargeted: { _ in }
                }
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectBlocked("10 same shell + .dropDestination(for:) [contentShape control]", probe(window, at: Self.centre, engine: engine))
    }

    func test_11_sameShellWithSidebarPayloadDropDestination() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                geometryReaderShell { _ in
                    Color.clear
                        .contentShape(Rectangle())
                        .sidebarPayloadDropDestination { _, _ in false } isTargeted: { _ in } onUpdate: { _ in }
                }
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectBlocked("11 same shell + .sidebarPayloadDropDestination [contentShape control]", probe(window, at: Self.centre, engine: engine))
    }

    func test_12_realOverlayWithNoActiveTab() {
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
        expectReachesEngine("12 real SplitDropZoneOverlay, activeTabID=nil (allowsHitTesting false)", probe(window, at: Self.centre, engine: engine))
    }

    func test_13_realOverlayWithActiveTab_atManyPoints() {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
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
        let points: [(String, NSPoint)] = [
            ("centre", NSPoint(x: 450, y: 350)),
            ("near left edge", NSPoint(x: 20, y: 350)),
            ("near right edge", NSPoint(x: 880, y: 350)),
            ("near top edge", NSPoint(x: 450, y: 680)),
            ("near bottom edge", NSPoint(x: 450, y: 20)),
            ("upper-left quadrant", NSPoint(x: 200, y: 500)),
        ]
        for (label, point) in points {
            expectReachesEngine("13 real overlay + active tab @ \(label) \(point)", probe(window, at: point, engine: engine))
        }
    }

    // MARK: - ROUND 2b: which line of the drop zone claims the point

    func test_15_colorClearAloneInsideGeometryReader() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                geometryReaderShell { _ in Color.clear }
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("15 GeometryReader + bare Color.clear (no contentShape, no drop)", probe(window, at: Self.centre, engine: engine))
    }

    func test_16_contentShapeWithoutGeometryReader() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                Color.clear.contentShape(Rectangle())
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectBlocked("16 Color.clear.contentShape(Rectangle()), no GeometryReader", probe(window, at: Self.centre, engine: engine))
    }

    func test_17_geometryReaderAloneWithEmptyContent() {
        let engine = EngineStandInView()
        let window = hostLikeProduction(
            ZStack {
                EngineStandInRepresentable(view: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCardChrome(isFocused: false)
                GeometryReader { _ in EmptyView() }
            },
            size: Self.size
        )
        defer { window.orderOut(nil) }
        expectReachesEngine("17 GeometryReader with EmptyView content (no Color at all)", probe(window, at: Self.centre, engine: engine))
    }

    // MARK: - ROUND 3: the real `ContentCardView`, unmodified

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

    func test_14_realContentCardView_wholeTree() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID, "The demo environment has no active tab, so ContentCardView would render the no-tab placeholder instead of a pane.")
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)
        let tab = try XCTUnwrap(env.tab(tabID))
        print("[PAGE-HIT-EVIDENCE] 14 tab url=\(tab.url) scheme=\(OrbitScheme.parse(tab.url))")

        let window = hostLikeProduction(ContentCardView().environment(env), size: Self.size)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.contentView?.displayIfNeeded()

        print("[PAGE-HIT-EVIDENCE] 14 engine stand-in inWindow=\(engine.window != nil) frameInWindow=\(engine.convert(engine.bounds, to: nil)) superview=\(engine.superview.map { "\(type(of: $0))" } ?? "nil")")

        let points: [(String, NSPoint)] = [
            ("centre", NSPoint(x: 450, y: 300)),
            ("upper-left quadrant", NSPoint(x: 200, y: 450)),
            ("lower-right quadrant", NSPoint(x: 700, y: 150)),
        ]
        for (label, point) in points {
            expectReachesEngine("14 REAL ContentCardView @ \(label) \(point)", probe(window, at: point, engine: engine))
        }

        var ancestry: [NSView] = []
        var node: NSView? = engine
        while let current = node {
            ancestry.append(current)
            node = current.superview
        }
        ancestry.reverse()
        print("[PAGE-HIT-EVIDENCE] 14 per-level walk, real ContentCardView, point (450, 300):")
        for view in ancestry {
            let point = NSPoint(x: 450, y: 300)
            let local = view.superview.map { $0.convert(point, from: nil) } ?? point
            let answer = view.hitTest(local)
            let verdict: String
            if answer == nil {
                verdict = "nil (declines)"
            } else if answer === view {
                verdict = "ITSELF (stops the descent)"
            } else {
                verdict = "\(type(of: answer!))"
            }
            print("[PAGE-HIT-EVIDENCE]   \(type(of: view)) frameInWindow=\(view.convert(view.bounds, to: nil)) -> \(verdict)")
        }

        // 690/680 are the pane header's own click-catcher band; 670/660 are page and must reach it.
        for y in [690.0, 680.0] {
            expectBlocked("14 pane header click-catcher band @ (450, \(y))", probe(window, at: NSPoint(x: 450, y: y), engine: engine))
        }
        for y in [670.0, 660.0] {
            expectReachesEngine("14 pane header band, below the catchers @ (450, \(y))", probe(window, at: NSPoint(x: 450, y: y), engine: engine))
        }

        let live = engine.superview != nil && engine.window != nil
        print("[PAGE-HIT-EVIDENCE] 14 FROZEN-FRAME CHECK: engine view mounted in the window = \(live). A frozen pane would leave it unparented.")
        XCTAssertTrue(live, "The engine view is not in the window at all -- a frozen pane, which no hit test above can mean anything for.")

        env._test_detachWebContents(for: tabID)
    }

    func test_18_realContentCardView_withTheDropZoneNeutralised() throws {
        let engine = EngineStandInView()
        let env = AppEnvironment.demo
        let tabID = try XCTUnwrap(env.activeTabID)
        let contents = StandInWebContents(session: MockEngineSession(), standIn: engine)
        env._test_attachWebContents(contents, for: tabID)

        let window = hostLikeProduction(
            ContentCardView()
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true),
            size: Self.size
        )
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.contentView?.displayIfNeeded()

        for (label, point) in [("centre", NSPoint(x: 450, y: 300)), ("upper-left", NSPoint(x: 200, y: 450))] {
            expectReachesEngine("18 REAL ContentCardView, drop zone neutralised @ \(label)", probe(window, at: point, engine: engine))
        }
        env._test_detachWebContents(for: tabID)
    }
}
