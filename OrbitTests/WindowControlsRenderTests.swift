import XCTest
import SwiftUI
import AppKit

@MainActor
final class WindowControlsRenderTests: XCTestCase {

    // MARK: - 1. Cluster renders at its declared size

    func test_clusterRendersAtDeclaredSize() {
        let size = CGSize(width: OrbitWindowControlMetrics.clusterWidth, height: OrbitWindowControlMetrics.diameter)
        let rendered = render(WindowControlsCluster(isKey: true, isHovering: false), size: size)

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "WindowControls-declaredSize-FAILED-empty")
            XCTFail("Expected WindowControlsCluster to draw three visible dots; rendered image was entirely background.")
            return
        }

        if abs(box.width - size.width) > 1.5 || abs(box.height - size.height) > 1.5 {
            rendered.writeDiagnosticPNG(named: "WindowControls-declaredSize-FAILED")
        }
        XCTAssertEqual(
            box.width, size.width, accuracy: 1.5,
            "refs/DEFECTS.md R7/R9: expected the drawn cluster's width to match OrbitWindowControlMetrics.clusterWidth (\(OrbitWindowControlMetrics.clusterWidth)pt = 3 * diameter(\(OrbitWindowControlMetrics.diameter)) + 2 * spacing(\(OrbitWindowControlMetrics.spacing))), found \(box.width)pt. See the diagnostic PNG path RenderHarness printed to the console."
        )
        XCTAssertEqual(
            box.height, size.height, accuracy: 1.5,
            "Expected the drawn cluster's height to match OrbitWindowControlMetrics.diameter (\(OrbitWindowControlMetrics.diameter)pt), found \(box.height)pt."
        )
    }

    func test_R9_diameterMatchesTrafficLightDiameter_whichIsThePlatformStandardNotTheIconLadder() {
        XCTAssertEqual(
            OrbitWindowControlMetrics.diameter, OrbitMetrics.trafficLightDiameter,
            "Window-control diameter (\(OrbitWindowControlMetrics.diameter)pt) must equal OrbitMetrics.trafficLightDiameter (\(OrbitMetrics.trafficLightDiameter)pt) — the reserved space in SidebarTopRow and the dots actually drawn here must never drift apart."
        )
        XCTAssertEqual(
            OrbitMetrics.trafficLightDiameter, 12,
            "OrbitMetrics.trafficLightDiameter must stay pinned to macOS's own fixed 12pt traffic-light diameter — this is a platform constant, not a value Orbit tunes, and is deliberately *not* a rung of the icon ladder (see that token's own comment for the regression this fixes)."
        )
    }

    // MARK: - 2. Each action closure invokes the right window selector

    func test_closeAction_invokesPerformClose() {
        let window = RecordingWindow()
        let actions = WindowControlActions(windowProvider: { window })
        actions.close()
        XCTAssertEqual(window.calls, [.close])
    }

    func test_miniaturizeAction_invokesPerformMiniaturize() {
        let window = RecordingWindow()
        let actions = WindowControlActions(windowProvider: { window })
        actions.miniaturize()
        XCTAssertEqual(window.calls, [.miniaturize])
    }

    func test_zoomAction_invokesPerformZoom() {
        let window = RecordingWindow()
        let actions = WindowControlActions(windowProvider: { window })
        actions.zoom()
        XCTAssertEqual(window.calls, [.zoom])
    }

    func test_actions_resolveWindowProviderAtCallTimeNotConstructionTime() {
        let first = RecordingWindow()
        let second = RecordingWindow()
        var current: RecordingWindow = first
        let actions = WindowControlActions(windowProvider: { current })

        actions.close()
        current = second
        actions.zoom()

        XCTAssertEqual(first.calls, [.close])
        XCTAssertEqual(second.calls, [.zoom])
    }

    func test_actions_toleratesNoWindow() {
        let actions = WindowControlActions(windowProvider: { nil })
        actions.close()
        actions.miniaturize()
        actions.zoom()
    }

    // MARK: - 3. Hover reveals glyphs together, over the whole cluster

    func test_hover_revealsGlyphsAcrossAllThreeDots() {
        let size = CGSize(width: OrbitWindowControlMetrics.clusterWidth, height: OrbitWindowControlMetrics.diameter)
        let restRender = render(WindowControlsCluster(isKey: true, isHovering: false), size: size)
        let hoverRender = render(WindowControlsCluster(isKey: true, isHovering: true), size: size)

        let dotCenters: [CGFloat] = (0..<3).map { index in
            OrbitWindowControlMetrics.diameter / 2 + CGFloat(index) * (OrbitWindowControlMetrics.diameter + OrbitWindowControlMetrics.spacing)
        }
        let centerY = OrbitWindowControlMetrics.diameter / 2

        var mismatchedDots: [Int] = []
        for (index, centerX) in dotCenters.enumerated() {
            let atRest = restRender.color(atX: Int(centerX), y: Int(centerY))
            let hovering = hoverRender.color(atX: Int(centerX), y: Int(centerY))
            if atRest.isApproximately(hovering, tolerance: 0.05) {
                mismatchedDots.append(index)
            }
        }

        if !mismatchedDots.isEmpty {
            restRender.writeDiagnosticPNG(named: "WindowControls-hover-rest-FAILED")
            hoverRender.writeDiagnosticPNG(named: "WindowControls-hover-hovering-FAILED")
        }
        XCTAssertTrue(
            mismatchedDots.isEmpty,
            "refs/DEFECTS.md R7: expected hovering the cluster to reveal a glyph on every dot (indices 0=close, 1=minimize, 2=zoom), matching macOS's whole-cluster hover behaviour — dot(s) at index \(mismatchedDots) showed no measurable pixel change between rest and hover. See the diagnostic PNG paths RenderHarness printed to the console."
        )
    }

    // MARK: - Desaturation when not key

    func test_isKeyFalse_rendersDesaturatedRatherThanColoured() {
        let size = CGSize(width: OrbitWindowControlMetrics.clusterWidth, height: OrbitWindowControlMetrics.diameter)
        let keyRender = render(WindowControlsCluster(isKey: true, isHovering: false), size: size)
        let inactiveRender = render(WindowControlsCluster(isKey: false, isHovering: false), size: size)

        let closeDotCenterX = Int(OrbitWindowControlMetrics.diameter / 2)
        let centerY = Int(OrbitWindowControlMetrics.diameter / 2)

        let keyColor = keyRender.color(atX: closeDotCenterX, y: centerY)
        let inactiveColor = inactiveRender.color(atX: closeDotCenterX, y: centerY)

        if inactiveColor.isApproximately(keyColor, tolerance: 0.05) {
            keyRender.writeDiagnosticPNG(named: "WindowControls-key-FAILED")
            inactiveRender.writeDiagnosticPNG(named: "WindowControls-inactive-FAILED")
        }
        XCTAssertFalse(
            inactiveColor.isApproximately(keyColor, tolerance: 0.05),
            "refs/DEFECTS.md R7: expected the close dot to render a visibly different (desaturated grey) colour when isKey=false versus the coloured #FF5F57 fill when isKey=true — found the same colour \(inactiveColor) in both. See the diagnostic PNG paths RenderHarness printed to the console."
        )
    }
}

// MARK: - Recording window (test double)

private final class RecordingWindow: NSWindow {
    enum Call: Equatable { case close, miniaturize, zoom }
    private(set) var calls: [Call] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override func performClose(_ sender: Any?) { calls.append(.close) }
    override func performMiniaturize(_ sender: Any?) { calls.append(.miniaturize) }
    override func performZoom(_ sender: Any?) { calls.append(.zoom) }
}
