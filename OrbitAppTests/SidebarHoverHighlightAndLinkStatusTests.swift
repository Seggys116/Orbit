import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SidebarHoverHighlightAndLinkStatusTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // MARK: - The sidebar's collapse toggle

    private static let topRowCanvas = CGSize(width: 220, height: OrbitMetrics.sidebarTopRowHeight)

    private func renderTopRow(hovered: Bool) -> RenderedImage {
        render(
            SidebarTopRow(theme: SpaceTheme())
                .environment(env)
                .environment(\.orbitScreenshotModeDragDisabled, true)
                .environment(\.orbitForcedHoverHighlight, hovered),
            size: Self.topRowCanvas
        )
    }

    func test_theSidebarCollapseToggleShadesOnHover() {
        let rest = renderTopRow(hovered: false)
        let hovered = renderTopRow(hovered: true)

        let box = Self.toggleBox()
        XCTAssertTrue(
            Self.anyPixelDiffers(rest, hovered, in: box),
            "The collapse toggle painted identically hovered and unhovered — the exact complaint this fixes"
        )
    }

    func test_theSidebarCollapseToggleShadingStaysInsideItsOwnTapTarget() {
        let rest = renderTopRow(hovered: false)
        let hovered = renderTopRow(hovered: true)
        let box = Self.toggleBox()

        let besideTheControl = CGRect(x: box.maxX + 4, y: box.minY, width: 10, height: box.height)
        XCTAssertFalse(
            Self.anyPixelDiffers(rest, hovered, in: besideTheControl),
            "The hover fill paints past the toggle's own tap target, so the shading no longer traces the region that accepts the click"
        )

        let beforeTheControl = CGRect(x: box.minX - 6, y: box.minY, width: 4, height: box.height)
        XCTAssertFalse(
            Self.anyPixelDiffers(rest, hovered, in: beforeTheControl),
            "The hover fill reaches back into the traffic-light reservation"
        )
    }

    private static func toggleBox() -> CGRect {
        let clusterWidth = OrbitMetrics.trafficLightDiameter * 3 + OrbitMetrics.trafficLightSpacing * 2
        let size = OrbitMetrics.sidebarTopRowIconSize
        return CGRect(
            x: OrbitMetrics.trafficLightLeadingInset + clusterWidth + OrbitMetrics.trafficLightSpacing,
            y: (OrbitMetrics.sidebarTopRowHeight - size) / 2,
            width: size,
            height: size
        )
    }

    // MARK: - The Space icons

    func test_bothSpacePagersApplyTheHoverHighlightToTheirDots() throws {
        for file in ["Orbit/UI/Spaces/SpaceSwitcherPagerView.swift", "Orbit/UI/Sidebar/SpacePagerView.swift"] {
            let source = try Self.source(file)
            XCTAssertTrue(
                source.contains("orbitHoverHighlight("),
                "\(file) has no hover shading on its Space icons — the user asked for this on both pagers"
            )
            XCTAssertTrue(
                source.contains("OrbitMetrics.sidebarActiveRowOpacity"),
                "\(file) must use the sidebar's own hover pill opacity so all three sidebar icon buttons agree"
            )
            XCTAssertTrue(
                source.contains("OrbitMetrics.sidebarFaviconCornerRadius"),
                "\(file) must use the sidebar's own hover pill radius"
            )
        }
    }

    func test_theSidebarToggleUsesTheSidebarsOwnHoverPillNotThePaneHeaders() throws {
        let source = try Self.source("Orbit/UI/Sidebar/SidebarTopRow.swift")
        XCTAssertTrue(source.contains("orbitHoverHighlight("))
        XCTAssertTrue(
            source.contains("OrbitMetrics.sidebarActiveRowOpacity"),
            "The sidebar's established hover pill is readableForeground at sidebarActiveRowOpacity — see SidebarBottomBar's Library button"
        )
        XCTAssertTrue(
            source.contains("OrbitMetrics.sidebarFaviconCornerRadius"),
            "…in a sidebarFaviconCornerRadius rounded square, matching the Library button's pill"
        )
    }

    // MARK: - The hyperlink status readout

    func test_hoveringAWebLinkReportsTheFullURL() {
        XCTAssertEqual(
            LinkHoverStatusText.text(for: URL(string: "https://example.com/guide/oaxaca")),
            "https://example.com/guide/oaxaca",
            "The scheme is part of the full URL"
        )
        XCTAssertEqual(
            LinkHoverStatusText.text(for: URL(string: "http://example.com")),
            "http://example.com",
            "An insecure link must be visibly insecure here"
        )
        XCTAssertEqual(
            LinkHoverStatusText.text(for: URL(string: "https://example.com/search?q=oaxaca#top")),
            "https://example.com/search?q=oaxaca#top",
            "Query and fragment are part of where the link goes"
        )
    }

    func test_nothingIsReportedWhenThereIsNoLinkOrNoWebDestination() {
        XCTAssertNil(LinkHoverStatusText.text(for: nil), "Pointer is not over a link")

        for href in [
            "javascript:void(0)",
            "mailto:hello@example.com",
            "tel:+441234567890",
            "data:text/html,<h1>hi</h1>",
            "file:///etc/passwd"
        ] {
            XCTAssertNil(
                LinkHoverStatusText.text(for: URL(string: href)),
                "\(href) is not a web destination and must report nothing"
            )
        }
    }

    func test_theStatusReadoutNeverTakesAClick() throws {
        let source = try Self.source("Orbit/UI/Content/LinkHoverStatusView.swift")
        XCTAssertTrue(
            source.contains("allowsHitTesting(false)"),
            "A status readout that swallowed a click on the link it describes would be worse than not having one"
        )
    }

    func test_theStatusReadoutIsMountedAboveThePageRatherThanInASwiftUILayer() throws {
        let host = try Self.source("Orbit/UI/Content/WebContentsHostView.swift")
        XCTAssertTrue(
            host.contains("LinkHoverStatusView(contentsID:"),
            "WebContentsHostView must host the readout, or hovering a link still shows nothing"
        )
        XCTAssertTrue(
            host.contains("positioned: .above"),
            "The overlay must be ordered explicitly above the engine view; being added later is not enough once the page is re-embedded"
        )

        let card = try Self.source("Orbit/UI/Content/ContentCardView.swift")
        XCTAssertFalse(
            card.contains("LinkHoverStatusView("),
            "The readout is back in ContentCardView's ZStack, where the page draws over it and the user sees nothing"
        )
    }

    // MARK: - Helpers

    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitAppTests/
            .deletingLastPathComponent()   // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func luminance(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    private static func anyPixelDiffers(_ a: RenderedImage, _ b: RenderedImage, in rect: CGRect) -> Bool {
        for x in Int(rect.minX.rounded(.down))..<Int(rect.maxX.rounded(.up)) {
            for y in Int(rect.minY.rounded(.down))..<Int(rect.maxY.rounded(.up)) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                if abs(lhs.r - rhs.r) > 0.004 || abs(lhs.g - rhs.g) > 0.004 || abs(lhs.b - rhs.b) > 0.004 {
                    return true
                }
            }
        }
        return false
    }
}
