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
        let tabRowRender = render(TabRowView(tab: tab, theme: theme).environment(env), size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight))

        let folder = Folder(name: "Reading")
        let folderRowRender = render(PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(env), size: CGSize(width: width, height: OrbitMetrics.sidebarRowHeight))

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
            TabRowView(tab: tab, theme: theme).environment(env),
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
            PinnedFolderRowView(folder: folder, spaceID: SpaceID(), theme: theme, depth: 0).environment(inactiveEnv),
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
}
