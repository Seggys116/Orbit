import XCTest
@testable import Orbit

@MainActor
final class EaselShapeToolAndExportTests: XCTestCase {

    private var scratchRoot: URL!
    private var store: EaselStore!
    private var savedStrokeColorIndex: Int = EaselPalette.defaultIndex

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedStrokeColorIndex = EaselPalette.loadPreferredIndex()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitEaselShapeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        store = EaselStore(directory: scratchRoot)
    }

    override func tearDownWithError() throws {
        EaselPalette.savePreferredIndex(savedStrokeColorIndex)
        store = nil
        if let scratchRoot {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    private func newModel() -> EaselCanvasModel {
        let easel = store.createEasel(title: "Test Easel")
        return EaselCanvasModel(easelID: easel.id, store: store)
    }

    private func persistedItems(_ model: EaselCanvasModel) throws -> [EaselItem] {
        try XCTUnwrap(store.easel(model.easelID)).items
    }

    // MARK: - The palette roster

    func test_toolPaletteIsArcsRosterInArcsOrder() {
        XCTAssertEqual(
            EaselTool.allCases,
            [.select, .image, .text, .ellipse, .rectangle, .arrow, .draw, .webCapture],
            "the palette strip is rendered straight from allCases; this is Arc's order plus Orbit's capture tool last"
        )
        XCTAssertEqual(EaselTool.allCases.last, .webCapture, "Orbit's own tool must never displace one of Arc's")
    }

    func test_onlyTheThreeArcShapeToolsMapToAShapeKind() {
        XCTAssertEqual(EaselTool.ellipse.shapeKind, .ellipse)
        XCTAssertEqual(EaselTool.rectangle.shapeKind, .rectangle)
        XCTAssertEqual(EaselTool.arrow.shapeKind, .arrow)

        for tool in [EaselTool.select, .image, .text, .draw, .webCapture] {
            XCTAssertNil(tool.shapeKind, "\(tool) is not one of Arc's three shape tools")
        }
        XCTAssertEqual(
            EaselTool.allCases.compactMap(\.shapeKind).count,
            3,
            "Arc's palette offers a circle, a square and an arrow and nothing else"
        )

        for tool in EaselTool.allCases {
            XCTAssertEqual(
                tool.usesStrokeColor,
                tool.shapeKind != nil || tool == .draw,
                "\(tool) disagrees about whether the colour picker applies to it"
            )
        }
    }

    func test_colourPaletteSplitsIntoArcsTwoRows() {
        XCTAssertEqual(EaselPalette.colors.count, 11)
        XCTAssertEqual(EaselPalette.topRowCount, 6)
        XCTAssertEqual(EaselPalette.colors.count - EaselPalette.topRowCount, 5)
        XCTAssertTrue(EaselPalette.colors.indices.contains(EaselPalette.defaultIndex))
        XCTAssertEqual(
            Set(EaselPalette.colors).count, EaselPalette.colors.count,
            "two identical swatches would be an unpickable duplicate in the picker"
        )
    }

    // MARK: - Drawing a shape

    func test_draggingWithEachShapeTool_persistsAShapeItemAtTheDraggedFrame() throws {
        let model = newModel()
        let cases: [(tool: EaselTool, kind: EaselItem.ShapeKind, start: CGPoint, end: CGPoint)] = [
            (.ellipse, .ellipse, CGPoint(x: 40, y: 60), CGPoint(x: 180, y: 150)),
            (.rectangle, .rectangle, CGPoint(x: 300, y: 40), CGPoint(x: 380, y: 200)),
            (.arrow, .arrow, CGPoint(x: 500, y: 300), CGPoint(x: 620, y: 180))
        ]

        for (index, testCase) in cases.enumerated() {
            model.activeTool = testCase.tool
            let kind = try XCTUnwrap(model.activeTool.shapeKind)
            let newID = try XCTUnwrap(
                model.addShape(kind: kind, from: testCase.start, to: testCase.end),
                "dragging \(testCase.start) -> \(testCase.end) with the \(testCase.tool) tool produced no item"
            )

            let items = try persistedItems(model)
            XCTAssertEqual(items.count, index + 1, "each drag must add exactly one item to the persisted easel")

            let item = try XCTUnwrap(items.first { $0.id == newID })
            guard case .shape(let storedKind, let color, let lineWidth, let unitStart, let unitEnd) = item.content else {
                return XCTFail("the \(testCase.tool) tool produced \(item.content) rather than a shape")
            }

            XCTAssertEqual(storedKind, testCase.kind, "the \(testCase.tool) tool drew a \(storedKind)")
            XCTAssertEqual(color, model.strokeColor, "a new shape takes the currently selected stroke colour")
            XCTAssertEqual(lineWidth, EaselCanvasModel.defaultStrokeWidth, accuracy: 0.0001)

            let pad = CGFloat(lineWidth) / 2 + 1
            XCTAssertEqual(item.frame.minX, min(testCase.start.x, testCase.end.x) - pad, accuracy: 0.0001)
            XCTAssertEqual(item.frame.minY, min(testCase.start.y, testCase.end.y) - pad, accuracy: 0.0001)
            XCTAssertEqual(item.frame.width, abs(testCase.end.x - testCase.start.x) + pad * 2, accuracy: 0.0001)
            XCTAssertEqual(item.frame.height, abs(testCase.end.y - testCase.start.y) + pad * 2, accuracy: 0.0001)

            let mapped = EaselShapeGeometry.endpoints(unitStart: unitStart, unitEnd: unitEnd, in: item.frame)
            XCTAssertEqual(mapped.start.x, testCase.start.x, accuracy: 0.0001)
            XCTAssertEqual(mapped.start.y, testCase.start.y, accuracy: 0.0001)
            XCTAssertEqual(mapped.end.x, testCase.end.x, accuracy: 0.0001)
            XCTAssertEqual(mapped.end.y, testCase.end.y, accuracy: 0.0001)

            XCTAssertEqual(model.selection, [newID], "a freshly drawn shape is the selection, so it can be moved or deleted at once")
            XCTAssertEqual(item.zIndex, index, "each new shape lands on top of what was already there")
        }
    }

    func test_changingTheSwatchColoursTheNextShapeAndLeavesTheLastOneAlone() throws {
        let model = newModel()
        model.strokeColorIndex = 4                                   // blue
        model.activeTool = .rectangle
        let firstID = try XCTUnwrap(model.addShape(kind: .rectangle, from: .zero, to: CGPoint(x: 60, y: 60)))

        model.strokeColorIndex = 6                                   // black
        let secondID = try XCTUnwrap(model.addShape(kind: .rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 160)))

        let items = try persistedItems(model)
        let first = try XCTUnwrap(items.first { $0.id == firstID })
        let second = try XCTUnwrap(items.first { $0.id == secondID })

        guard case .shape(_, let firstColor, _, _, _) = first.content,
              case .shape(_, let secondColor, _, _, _) = second.content else {
            return XCTFail("expected two shapes, got \(first.content) and \(second.content)")
        }
        XCTAssertEqual(firstColor, EaselPalette.themeColor(at: 4))
        XCTAssertEqual(secondColor, EaselPalette.themeColor(at: 6))
        XCTAssertNotEqual(firstColor, secondColor, "recolouring the tool must not retroactively recolour finished work")
    }

    func test_aDragTooShortToBeAShapeAddsNothing() throws {
        let model = newModel()
        model.activeTool = .ellipse

        let tiny = EaselCanvasModel.minimumShapeDragSpan / 2
        XCTAssertNil(model.addShape(kind: .ellipse, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10 + tiny, y: 10)))
        XCTAssertTrue(try persistedItems(model).isEmpty, "a mis-click must not leave a speck on the canvas")

        let enough = EaselCanvasModel.minimumShapeDragSpan
        XCTAssertNotNil(model.addShape(kind: .ellipse, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10 + enough, y: 10)))
        XCTAssertEqual(try persistedItems(model).count, 1, "a deliberate drag at the threshold must draw")
    }

    func test_oppositeDiagonalDragsShareABoxButPointOppositeWays() throws {
        let model = newModel()
        model.activeTool = .arrow
        let a = CGPoint(x: 100, y: 100)
        let b = CGPoint(x: 220, y: 220)

        let downRight = try XCTUnwrap(model.addShape(kind: .arrow, from: a, to: b))
        let upLeft = try XCTUnwrap(model.addShape(kind: .arrow, from: b, to: a))

        let items = try persistedItems(model)
        let first = try XCTUnwrap(items.first { $0.id == downRight })
        let second = try XCTUnwrap(items.first { $0.id == upLeft })
        XCTAssertEqual(first.frame, second.frame, "the two drags cover the same box")

        guard case .shape(_, _, let lineWidth, let startA, let endA) = first.content,
              case .shape(_, _, _, let startB, let endB) = second.content else {
            return XCTFail("expected two arrows")
        }
        XCTAssertEqual(startA.x, endB.x, accuracy: 0.0001, "one arrow's start is the other's end")
        XCTAssertEqual(endA.x, startB.x, accuracy: 0.0001)
        XCTAssertLessThan(startA.x, endA.x, "the first arrow was dragged rightwards")
        XCTAssertGreaterThan(startB.x, endB.x, "the second was dragged leftwards")

        let headA = EaselShapeGeometry.arrowHead(
            start: EaselShapeGeometry.endpoints(unitStart: startA, unitEnd: endA, in: first.frame).start,
            end: EaselShapeGeometry.endpoints(unitStart: startA, unitEnd: endA, in: first.frame).end,
            lineWidth: CGFloat(lineWidth)
        )
        let headB = EaselShapeGeometry.arrowHead(
            start: EaselShapeGeometry.endpoints(unitStart: startB, unitEnd: endB, in: second.frame).start,
            end: EaselShapeGeometry.endpoints(unitStart: startB, unitEnd: endB, in: second.frame).end,
            lineWidth: CGFloat(lineWidth)
        )
        XCTAssertGreaterThan(headA.left.x, headB.left.x, "the arrowheads are at opposite ends of the box")
    }

    func test_thePreviewGeometryIsTheGeometryThatGetsCommitted() throws {
        let model = newModel()
        let start = CGPoint(x: 12, y: 34)
        let end = CGPoint(x: 210, y: 96)

        let preview = try XCTUnwrap(
            EaselCanvasModel.shapeGeometry(from: start, to: end, lineWidth: EaselCanvasModel.defaultStrokeWidth)
        )
        let committedID = try XCTUnwrap(model.addShape(kind: .ellipse, from: start, to: end))
        let committed = try XCTUnwrap(try persistedItems(model).first { $0.id == committedID })

        XCTAssertEqual(committed.frame, preview.frame, "the shape must not move or resize the instant the mouse comes up")
        guard case .shape(_, _, _, let unitStart, let unitEnd) = committed.content else {
            return XCTFail("expected a shape, got \(committed.content)")
        }
        XCTAssertEqual(unitStart, preview.unitStart)
        XCTAssertEqual(unitEnd, preview.unitEnd)

        XCTAssertNil(EaselCanvasModel.shapeGeometry(from: start, to: start, lineWidth: EaselCanvasModel.defaultStrokeWidth))
        XCTAssertNil(model.addShape(kind: .ellipse, from: start, to: start))
    }

    func test_undoRemovesADrawnShapeFromThePersistedEasel() throws {
        let model = newModel()
        model.activeTool = .rectangle
        XCTAssertNotNil(model.addShape(kind: .rectangle, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90)))
        XCTAssertEqual(try persistedItems(model).count, 1)

        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(try persistedItems(model).isEmpty, "undoing a shape must take it out of the saved document too")

        model.redo()
        XCTAssertEqual(try persistedItems(model).count, 1, "redo must put it back")
    }

    // MARK: - Persistence through EaselStore's own documents

    func test_aShapeSurvivesBeingWrittenAndReloadedFromDisk() throws {
        let model = newModel()
        model.strokeColorIndex = 3
        let id = try XCTUnwrap(model.addShape(kind: .arrow, from: CGPoint(x: 44, y: 400), to: CGPoint(x: 260, y: 120)))
        let original = try XCTUnwrap(try persistedItems(model).first { $0.id == id })
        try store.saveNow()

        let documentURL = scratchRoot.appendingPathComponent("\(model.easelID.uuidString).json", isDirectory: false)
        let onDisk = try String(contentsOf: documentURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("\"shape\""), "the shape must actually be in the file, not only in memory")

        let reopened = EaselStore(directory: scratchRoot)
        let reloaded = try XCTUnwrap(reopened.easel(model.easelID))
        let reloadedItem = try XCTUnwrap(reloaded.items.first { $0.id == id })
        XCTAssertEqual(reloadedItem.content, original.content, "the shape came back different from how it was drawn")
        XCTAssertEqual(reloadedItem.frame, original.frame)
    }

    // MARK: - PNG export

    func test_exportProducesRealPNGBytesSizedFromTheCanvasContent() throws {
        let model = newModel()
        model.activeTool = .rectangle
        XCTAssertNotNil(model.addShape(kind: .rectangle, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 240, y: 160)))
        let easel = try XCTUnwrap(store.easel(model.easelID))

        let data = try XCTUnwrap(EaselExporter.pngData(for: easel, store: store), "the exporter returned no bytes at all")
        let header = try Self.pngHeader(data)

        let bounds = EaselExporter.contentBounds(of: easel)
        XCTAssertEqual(header.width, Int((bounds.width * EaselExporter.scale).rounded()))
        XCTAssertEqual(header.height, Int((bounds.height * EaselExporter.scale).rounded()))
        XCTAssertGreaterThan(header.width, Int(EaselExporter.margin), "an easel with content must be bigger than its own margin")
        XCTAssertGreaterThan(header.height, Int(EaselExporter.margin))
        XCTAssertGreaterThan(data.count, 100, "a PNG that small is a header with nothing behind it")

        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, header.width)
        XCTAssertEqual(rep.pixelsHigh, header.height)
    }

    func test_exportGrowsWithTheContentItIsGiven() throws {
        let model = newModel()
        model.activeTool = .rectangle
        XCTAssertNotNil(model.addShape(kind: .rectangle, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 140)))
        let smallData = try XCTUnwrap(EaselExporter.pngData(for: try XCTUnwrap(store.easel(model.easelID)), store: store))
        let small = try Self.pngHeader(smallData)

        let farRight: CGFloat = 900
        XCTAssertNotNil(model.addShape(kind: .ellipse, from: CGPoint(x: farRight, y: 40), to: CGPoint(x: farRight + 100, y: 140)))
        let largeData = try XCTUnwrap(EaselExporter.pngData(for: try XCTUnwrap(store.easel(model.easelID)), store: store))
        let large = try Self.pngHeader(largeData)

        XCTAssertGreaterThan(large.width, small.width, "an item placed 900pt to the right must widen the export")
        XCTAssertEqual(
            large.height, small.height,
            "the second item was placed at the same vertical extent, so the export must not have grown taller"
        )
    }

    func test_exportActuallyDrawsTheShapeAndInTheRightPlace() throws {
        let model = newModel()
        model.addItem(.text("anchor"), frame: CGRect(x: 40, y: 600, width: 200, height: 60))

        let blueIndex = try XCTUnwrap(EaselPalette.colors.firstIndex { $0.blue > 0.9 && $0.red < 0.3 && $0.green < 0.3 })
        model.strokeColorIndex = blueIndex
        model.activeTool = .rectangle
        let shapeID = try XCTUnwrap(model.addShape(kind: .rectangle, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 300, y: 200)))

        let easel = try XCTUnwrap(store.easel(model.easelID))
        let data = try XCTUnwrap(EaselExporter.pngData(for: easel, store: store))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))

        let bounds = EaselExporter.contentBounds(of: easel)
        let shapeFrame = try XCTUnwrap(easel.items.first { $0.id == shapeID }).frame
        let scale = EaselExporter.scale

        var blueDominantPixels = 0
        var outsideTheShape = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                guard color.blueComponent > color.redComponent + 0.2,
                      color.blueComponent > color.greenComponent + 0.2 else { continue }
                blueDominantPixels += 1

                let canvasX = bounds.minX + CGFloat(x) / scale
                let canvasY = bounds.minY + CGFloat(y) / scale
                let allowance = CGFloat(EaselCanvasModel.defaultStrokeWidth)
                if !shapeFrame.insetBy(dx: -allowance, dy: -allowance).contains(CGPoint(x: canvasX, y: canvasY)) {
                    outsideTheShape += 1
                }
            }
        }

        XCTAssertGreaterThan(
            blueDominantPixels, 0,
            "the exported PNG contains no pixel of the stroke colour — the shape was not rasterised at all"
        )
        XCTAssertEqual(
            outsideTheShape, 0,
            "\(outsideTheShape) of \(blueDominantPixels) stroke pixels landed outside the rectangle's own frame — "
            + "the export is drawing the shape in the wrong place, most likely a vertical flip"
        )

        let framePixelArea = Double(shapeFrame.width * scale) * Double(shapeFrame.height * scale)
        XCTAssertLessThan(
            Double(blueDominantPixels), framePixelArea * 0.5,
            "Arc's square tool draws a hollow square; this one filled it in"
        )
    }

    func test_anEmptyEaselStillExportsAValidImage() throws {
        let easel = store.createEasel(title: "Empty")
        let data = try XCTUnwrap(EaselExporter.pngData(for: easel, store: store))
        let header = try Self.pngHeader(data)
        XCTAssertGreaterThan(header.width, 0)
        XCTAssertGreaterThan(header.height, 0)
        XCTAssertNotNil(NSBitmapImageRep(data: data))
    }

    func test_suggestedFileNameIsUsableOnDiskAndKeepsTheTitle() {
        let named = Easel(title: "Q3 / Planning: draft")
        let suggested = EaselExporter.suggestedFileName(for: named)
        XCTAssertTrue(suggested.hasSuffix(".png"))
        XCTAssertFalse(suggested.contains("/"))
        XCTAssertFalse(suggested.contains(":"))
        XCTAssertTrue(suggested.contains("Planning"), "the user must still recognise their easel in the save panel")

        let untitled = EaselExporter.suggestedFileName(for: Easel(title: "   "))
        XCTAssertFalse(untitled.hasPrefix("."), "a blank title must not produce a hidden file called \".png\"")
    }

    // MARK: - PNG structure

    private static func pngHeader(_ data: Data) throws -> (width: Int, height: Int) {
        let bytes = [UInt8](data)
        XCTAssertGreaterThan(bytes.count, 24, "too few bytes to even contain a PNG header")

        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(bytes.prefix(8)), signature, "the exported bytes do not start with the PNG signature")
        XCTAssertEqual(
            String(decoding: bytes[12..<16], as: UTF8.self), "IHDR",
            "the first chunk of a PNG must be IHDR"
        )

        func bigEndian32(at offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        return (bigEndian32(at: 16), bigEndian32(at: 20))
    }
}
