import XCTest
import SwiftUI

@MainActor
final class SidebarRowPaddingConsistencyTests: XCTestCase {

    func test_R13_tabRowAndFolderRowShareTheSameLeadingInset() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let width: CGFloat = 200

        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://example.com")!)
        env.activeTabID = tab.id
        // ImageRenderer paints OrbitNSActionButton's click catcher as an opaque block.
        let tabRowRender = render(TabRowView(tab: tab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true), size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight))

        let folder = Folder(name: "Reading")
        let folderRowRender = render(PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(env).environment(\.orbitScreenshotModeDragDisabled, true), size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight))

        var leadingXs: [String: CGFloat] = [:]
        let renders: [(String, RenderedImage)] = [
            ("TabRowView (active)", tabRowRender),
            ("PinnedFolderRowView", folderRowRender),
        ]
        let expectedLeading: [String: CGFloat] = [
            "TabRowView (active)": OrbitMetrics.sidebarHorizontalPadding,
            "PinnedFolderRowView": OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset,
        ]
        for (name, rendered) in renders {
            guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
                rendered.writeDiagnosticPNG(named: "R13-\(name)-FAILED-empty")
                XCTFail("Expected \(name) to draw visible content; rendered image was entirely background.")
                continue
            }
            let expected = expectedLeading[name]!
            leadingXs[name] = box.minX - expected
            if abs(box.minX - expected) > 3 {
                rendered.writeDiagnosticPNG(named: "R13-\(name)-FAILED")
            }
            XCTAssertEqual(
                box.minX, expected, accuracy: 3,
                "refs/DEFECTS.md R13: \(name)'s leading content starts at \(box.minX)pt, expected " +
                "\(expected)pt — every sidebar row kind must share the same leading inset for the same " +
                "*kind* of thing (pill at sidebarHorizontalPadding = \(OrbitMetrics.sidebarHorizontalPadding)pt, " +
                "content at + sidebarRowContentInset = \(OrbitMetrics.sidebarRowContentInset)pt), none touching " +
                "the edge, none floating at some other distance from it."
            )
        }

        let measuredValues = Array(leadingXs.values)
        if let maxValue = measuredValues.max(), let minValue = measuredValues.min() {
            XCTAssertLessThanOrEqual(
                maxValue - minValue, 3,
                "refs/DEFECTS.md R13: every sidebar row kind must miss its own expected leading inset by " +
                "close to the same amount; found per-kind errors \(leadingXs)."
            )
        }
    }

    func test_R23_rowPillHasRealInternalPaddingBeforeItsFavicon() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let width: CGFloat = 240

        XCTAssertGreaterThan(
            OrbitMetrics.sidebarRowContentInset, 0,
            "OrbitMetrics.sidebarRowContentInset must be positive — at zero, a row's favicon sits flush " +
            "against its own highlight pill, which is exactly what refs/reference/user-reports/" +
            "orbit-pinned-row-padding.png shows and what this token exists to prevent."
        )

        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://example.com")!)
        env.activeTabID = tab.id
        let rendered = render(
            TabRowView(tab: tab, theme: theme).environment(env).environment(\.orbitScreenshotModeDragDisabled, true),
            size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "R23-rowPillInternalPadding-FAILED-empty")
            XCTFail("Expected the active TabRowView to draw its highlight pill; the rendered image was entirely background.")
            return
        }

        XCTAssertEqual(
            box.minX, OrbitMetrics.sidebarHorizontalPadding, accuracy: 3,
            "The active row's highlight pill must start at OrbitMetrics.sidebarHorizontalPadding " +
            "(\(OrbitMetrics.sidebarHorizontalPadding)pt); measured \(box.minX)pt."
        )

        let inactiveEnv = AppEnvironment()
        let inactiveTab = Tab(spaceID: SpaceID(), url: URL(string: "https://example.com")!)
        let folder = Folder(name: "Reading")
        let contentRender = render(
            PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(inactiveEnv).environment(\.orbitScreenshotModeDragDisabled, true),
            size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight)
        )
        _ = inactiveTab

        guard let contentBox = contentRender.boundingBoxOfContent(tolerance: 0.03) else {
            contentRender.writeDiagnosticPNG(named: "R23-rowContentInset-FAILED-empty")
            XCTFail("Expected an unhighlighted row to draw its own content; the rendered image was entirely background.")
            return
        }

        let measuredInternalPadding = contentBox.minX - box.minX
        if abs(measuredInternalPadding - OrbitMetrics.sidebarRowContentInset) > 3 {
            rendered.writeDiagnosticPNG(named: "R23-rowPillInternalPadding-FAILED-pill")
            contentRender.writeDiagnosticPNG(named: "R23-rowPillInternalPadding-FAILED-content")
        }
        XCTAssertEqual(
            measuredInternalPadding, OrbitMetrics.sidebarRowContentInset, accuracy: 3,
            "A sidebar row's content must sit OrbitMetrics.sidebarRowContentInset " +
            "(\(OrbitMetrics.sidebarRowContentInset)pt) inside its own highlight pill; measured " +
            "\(measuredInternalPadding)pt between the pill's leading edge (\(box.minX)pt) and the content's " +
            "(\(contentBox.minX)pt). Zero here is the defect in refs/reference/user-reports/" +
            "orbit-pinned-row-padding.png — favicon flush against the highlight."
        )
    }

    func test_R13_horizontalPaddingTokenIsSharedAcrossRowKinds() {
        XCTAssertEqual(OrbitMetrics.sidebarBottomBarHorizontalPadding, OrbitMetrics.sidebarHorizontalPadding, "SidebarBottomBar's horizontal padding token must stay aliased to the same constant every other sidebar row uses.")
        XCTAssertEqual(OrbitMetrics.trafficLightLeadingInset, OrbitMetrics.sidebarHorizontalPadding, "SidebarTopRow's leading inset happens to be a distinct token (trafficLightLeadingInset) for a distinct reason (traffic-light cluster alignment), but must still resolve to the same 16pt every other row's leading inset uses, so the top row's toggle lines up with every row beneath it.")
    }

    func test_R14_tabRowBackgroundStaysInsetFromBothSidebarEdges() {
        let env = AppEnvironment()
        let theme = SpaceTheme()
        let rowWidth: CGFloat = 260
        let canvasWidth: CGFloat = 400

        let tab = Tab(spaceID: SpaceID(), url: URL(string: "https://example.com")!)
        env.activeTabID = tab.id
        let rendered = render(
            HStack(spacing: 0) {
                TabRowView(tab: tab, theme: theme)
                    .environment(env)
                    .environment(\.orbitScreenshotModeDragDisabled, true)
                    .frame(width: rowWidth)
                Color.clear
            },
            size: CGSize(width: canvasWidth, height: OrbitMetrics.sidebarRowHeight)
        )

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.03) else {
            rendered.writeDiagnosticPNG(named: "R14-tabRowTrailingInset-FAILED-empty")
            XCTFail("Expected the active TabRowView to draw visible content; rendered image was entirely background.")
            return
        }

        let expectedTrailingX = rowWidth - OrbitMetrics.sidebarHorizontalPadding
        if abs(box.maxX - expectedTrailingX) > 3 {
            rendered.writeDiagnosticPNG(named: "R14-tabRowTrailingInset-FAILED")
        }
        XCTAssertEqual(
            box.maxX, expectedTrailingX, accuracy: 3,
            "R14/refs/DEFECTS.md: TabRowView's active-state background must stay inset from the " +
            "row's own trailing edge by OrbitMetrics.sidebarHorizontalPadding (\(OrbitMetrics.sidebarHorizontalPadding)pt) " +
            "— found drawn content extending to x=\(box.maxX)pt inside a \(rowWidth)pt-wide row " +
            "(expected \(expectedTrailingX)pt). An edge-to-edge highlight pill would measure " +
            "\(rowWidth)pt here instead."
        )
    }

    // The activation catcher is the content box. The drawn pill hangs past it; the row pitch hangs past the pill.
    func test_tabRowHitTargetMatchesTheDrawnPillNotTheTextLineOrTheRowPitch() {
        let contentHeight = OrbitMetrics.faviconSize
        let contentWidth: CGFloat = 180
        let content = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let leading = OrbitMetrics.sidebarRowContentInset
        let trailing = OrbitMetrics.sidebarRowContentInset
        let pill = SidebarRowPillHitTarget.rect(
            contentBounds: content,
            leadingOutset: leading,
            trailingOutset: trailing
        )

        let rowSlack = (OrbitMetrics.sidebarRowHeight - contentHeight) / 2
        let pillOutset = rowSlack - OrbitMetrics.sidebarRowPillVerticalInset
        XCTAssertGreaterThan(pillOutset, 0, "The pill must extend past a favicon-tall content line, or this fixture no longer describes the miss.")
        XCTAssertEqual(
            pill.height,
            OrbitMetrics.sidebarRowHeight - 2 * OrbitMetrics.sidebarRowPillVerticalInset,
            accuracy: 0.001
        )
        XCTAssertLessThan(pill.height, OrbitMetrics.sidebarRowHeight, "The gap between pills is not part of the hit target.")
        XCTAssertEqual(pill.minY, -pillOutset, accuracy: 0.001)
        XCTAssertEqual(pill.maxY, contentHeight + pillOutset, accuracy: 0.001)
        XCTAssertEqual(pill.minX, -leading, accuracy: 0.001)
        XCTAssertEqual(pill.width, contentWidth + leading + trailing, accuracy: 0.001)

        let midX = contentWidth / 2
        let midY = contentHeight / 2
        XCTAssertTrue(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: midX, y: midY), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "The title line is part of the pill."
        )
        XCTAssertTrue(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: midX, y: contentHeight + pillOutset / 2), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "The band between the text line and the pill's top edge must activate."
        )
        XCTAssertFalse(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: midX, y: contentHeight + pillOutset + 0.5), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "The gap above the pill, still inside the row pitch, must not activate."
        )
        XCTAssertFalse(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: midX, y: -pillOutset - 0.5), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "The gap below the pill must not activate."
        )
        XCTAssertTrue(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: -leading / 2, y: midY), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "The pill's internal margin, sidebarRowContentInset past the content box, must activate."
        )
        XCTAssertFalse(
            SidebarRowPillHitTarget.tabRowContains(CGPoint(x: -leading - 0.5, y: midY), contentBounds: content, leadingOutset: leading, trailingOutset: trailing),
            "Past the pill's leading edge is the sidebar gutter, not the tab."
        )

        let corner = CGPoint(x: pill.minX, y: pill.maxY)
        XCTAssertFalse(
            SidebarRowPillHitTarget.contains(corner, in: pill, cornerRadius: OrbitMetrics.sidebarRowCornerRadius),
            "The pill's square bounding corner is outside the drawn rounded rect."
        )
        XCTAssertTrue(
            SidebarRowPillHitTarget.contains(
                CGPoint(x: pill.minX + OrbitMetrics.sidebarRowCornerRadius, y: pill.maxY - OrbitMetrics.sidebarRowCornerRadius),
                in: pill,
                cornerRadius: OrbitMetrics.sidebarRowCornerRadius
            ),
            "The center of the corner curve is on the pill."
        )

        let indentedLeading = leading + OrbitMetrics.sidebarIndentPerDepth
        let indented = SidebarRowPillHitTarget.rect(
            contentBounds: content,
            leadingOutset: indentedLeading,
            trailingOutset: trailing
        )
        XCTAssertEqual(indented.minX, -indentedLeading, accuracy: 0.001)
        XCTAssertEqual(indented.maxX, pill.maxX, accuracy: 0.001, "Indent grows the leading side of the pill only.")
    }
}
