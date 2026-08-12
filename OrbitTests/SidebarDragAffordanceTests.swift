import XCTest
import SwiftUI

@MainActor
final class SidebarDragAffordanceTests: XCTestCase {

    // MARK: - The green `+`

    func test_everySidebarDropZoneProposesMoveSoAppKitDrawsNoPlusBadge() {
        XCTAssertEqual(
            SidebarPayloadDropDelegate.proposedOperation, .move,
            "A `.copy` proposal is exactly what puts the green + on the drag image the user reported. " +
            "It is also untrue: dragging a row in this sidebar moves it, and no sidebar drop handler duplicates anything."
        )
    }

    func test_noShippingSourceUsesTheBadgeDrawingDropDestinationForASidebarPayload() throws {
        let sources = try swiftFiles(under: productionRoot())
        XCTAssertGreaterThan(
            sources.count, 100,
            "Walked \(sources.count) files under Orbit/. Far too few — the path resolution below is wrong and this test is looking at nothing."
        )

        var offences: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard code.contains("dropDestination(for: SidebarDragPayload.self") else { continue }
                offences.append("\(relative):\(number + 1): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            "These drop zones would put the green + back on the drag image. Use `.sidebarPayloadDropDestination(action:isTargeted:)` " +
            "(Orbit/UI/Sidebar/SidebarDragDrop.swift), which proposes `.move`:\n" + offences.joined(separator: "\n")
        )
    }

    // MARK: - "a circle on the left with a line coming out"

    func test_insertionIndicator_isARingAtTheLeadingEndWithALineRunningOutOfIt() throws {
        let width: CGFloat = 200
        let height = InsertionIndicatorLine.height
        let image = try render(
            InsertionIndicatorLine(color: .white)
                .frame(width: width, height: height)
                .background(Color.black),
            size: CGSize(width: width, height: height)
        )

        let inkColumns = (0..<image.width).map { x in
            (0..<image.height).filter { image.isInk(x: x, y: $0) }
        }
        let firstInkColumn = try XCTUnwrap(inkColumns.firstIndex { !$0.isEmpty }, "The indicator rendered no ink at all.")

        let tallestColumn = try XCTUnwrap(inkColumns.indices.max(by: { inkColumns[$0].count < inkColumns[$1].count }))
        XCTAssertLessThan(
            tallestColumn - firstInkColumn, image.width / 4,
            "The tallest part of the mark must be at its leading end — that is the knob. Found it at x=\(tallestColumn) " +
            "with the mark starting at x=\(firstInkColumn) of \(image.width)."
        )

        let knobWidth = max(inkColumns[tallestColumn].count, 2)
        let knobColumns = firstInkColumn..<min(firstInkColumn + knobWidth, image.width)
        let hasHollowColumn = knobColumns.contains { x in
            let rows = inkColumns[x]
            guard let top = rows.first, let bottom = rows.last, bottom > top else { return false }
            return (top...bottom).contains { !image.isInk(x: x, y: $0) }
        }
        XCTAssertTrue(
            hasHollowColumn,
            "The leading end must read as a ring, not a filled dot — no column across it had a gap between its top and bottom ink."
        )

        let centreRow = image.height / 2
        let lastInkColumn = try XCTUnwrap(inkColumns.lastIndex { !$0.isEmpty })
        XCTAssertGreaterThan(
            lastInkColumn, image.width * 3 / 4,
            "The line must run out of the knob to the trailing edge; it stopped at x=\(lastInkColumn) of \(image.width)."
        )
        XCTAssertTrue(
            image.isInk(x: image.width / 2, y: centreRow),
            "The line must run along the knob's own vertical centre, so the mark reads as one continuous caret."
        )
    }

    // MARK: - Minus vs X on a bookmarked row

    func test_trailingAction_isMinusOnAnOpenBookmarkAndXOnEverythingElse() {
        XCTAssertEqual(
            TabRowTrailingAction.resolve(section: .pinned, isOpen: true), .closeTabKeepingBookmark,
            "An open bookmark's control closes the tab and keeps the bookmark."
        )
        XCTAssertEqual(
            TabRowTrailingAction.resolve(section: .pinned, isOpen: false), .removeBookmark,
            "A bookmark with nothing open behind it is just a bookmark, so its control removes the bookmark."
        )
        for section in [TabSection.today, .favorite, .archived] {
            XCTAssertEqual(
                TabRowTrailingAction.resolve(section: section, isOpen: true), .closeTab,
                "Only a Pinned row is a bookmark; \(section) must keep the plain close it has always had."
            )
            XCTAssertEqual(TabRowTrailingAction.resolve(section: section, isOpen: false), .closeTab)
        }
    }

    func test_trailingAction_glyphs() {
        XCTAssertEqual(TabRowTrailingAction.closeTabKeepingBookmark.systemImage, "minus")
        XCTAssertEqual(TabRowTrailingAction.removeBookmark.systemImage, "xmark")
        XCTAssertEqual(TabRowTrailingAction.closeTab.systemImage, "xmark")
    }

    // MARK: - Reaching the "drop one row onto another" gesture

    func test_rowBodyDropBand_isTheLargestOfARowsThreeDropZones() {
        let strip = OrbitMetrics.sidebarRowEdgeDropZoneFraction
        let body = 1 - 2 * strip
        XCTAssertGreaterThan(
            body, strip,
            "The row-body band (\(body) of the row) carries the folder/split gesture and must be the easiest of the three zones to hit, " +
            "not the leftover between two strips of \(strip) each."
        )
        XCTAssertGreaterThan(
            strip * OrbitMetrics.sidebarRowHeight, OrbitMetrics.sidebarInsertionIndicatorKnobDiameter,
            "Each insertion strip must still be comfortably taller than the caret it draws, or reordering becomes the hard gesture instead."
        )
    }

    // MARK: - Helpers

    private struct Raster {
        let bitmap: NSBitmapImageRep
        var width: Int { bitmap.pixelsWide }
        var height: Int { bitmap.pixelsHigh }

        func isInk(x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height,
                  let colour = bitmap.colorAt(x: x, y: y) else { return false }
            return colour.brightnessComponent > 0.5 && colour.alphaComponent > 0.5
        }
    }

    private func render(_ view: some View, size: CGSize) throws -> Raster {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image.")
        let data = try XCTUnwrap(image.tiffRepresentation)
        return Raster(bitmap: try XCTUnwrap(NSBitmapImageRep(data: data)))
    }

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
