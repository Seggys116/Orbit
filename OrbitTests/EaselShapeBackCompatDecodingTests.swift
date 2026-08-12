import XCTest

@MainActor
final class EaselShapeBackCompatDecodingTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-EaselShapeBackCompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private static let shapeOnlyKeys = ["shape", "kind", "lineWidth", "unitStart", "unitEnd"]

    private static let legacyEaselJSON = """
    {
      "id": "1E9C0F62-9C1C-4D6B-9E52-30C8B4A21F01",
      "title": "Trip Planning",
      "items": [
        {
          "id": "2A0B1C2D-3E4F-4A5B-8C7D-9E0F1A2B3C4D",
          "frame": [[40, 60], [220, 120]],
          "rotation": 0,
          "zIndex": 0,
          "content": { "text": { "_0": "Book the flights" } }
        },
        {
          "id": "3B1C2D3E-4F5A-4B6C-9D8E-0F1A2B3C4D5E",
          "frame": [[300, 80], [160, 90]],
          "rotation": 12,
          "zIndex": 1,
          "content": {
            "drawing": {
              "points": [[0, 0], [40, 30], [80, 10]],
              "color": { "red": 0.85, "green": 0.28, "blue": 0.02, "alpha": 1 },
              "width": 3
            }
          }
        },
        {
          "id": "4C2D3E4F-5A6B-4C7D-8E9F-1A2B3C4D5E6F",
          "frame": [[40, 220], [220, 145]],
          "rotation": 0,
          "zIndex": 2,
          "content": { "image": { "fileName": "boarding-pass.png" } }
        }
      ],
      "createdAt": 726000000,
      "updatedAt": 726000000,
      "viewportOrigin": [0, 0],
      "viewportZoom": 1
    }
    """

    // MARK: - Direction 1: an old document decodes under the new model

    func test_easelWrittenBeforeShapesExisted_stillDecodes() throws {
        for key in Self.shapeOnlyKeys {
            XCTAssertFalse(
                Self.legacyEaselJSON.contains("\"\(key)\""),
                "\(key) is in the legacy fixture — it is no longer a fixture of the pre-shape format and proves nothing"
            )
        }

        let easel = try JSONDecoder().decode(Easel.self, from: Data(Self.legacyEaselJSON.utf8))

        XCTAssertEqual(easel.title, "Trip Planning")
        XCTAssertEqual(easel.items.count, 3, "every item in a pre-shape document must survive, not just the first")

        guard case .text(let text) = easel.items[0].content else {
            return XCTFail("item 0 decoded as \(easel.items[0].content) rather than .text")
        }
        XCTAssertEqual(text, "Book the flights")

        guard case .drawing(let points, let color, let width) = easel.items[1].content else {
            return XCTFail("item 1 decoded as \(easel.items[1].content) rather than .drawing")
        }
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.last?.x ?? 0, 80, accuracy: 0.0001)
        XCTAssertEqual(color.red, 0.85, accuracy: 0.0001)
        XCTAssertEqual(width, 3, accuracy: 0.0001)
        XCTAssertEqual(easel.items[1].rotation, 12, accuracy: 0.0001, "rotation is not a shape field and must be untouched")

        guard case .image(let fileName) = easel.items[2].content else {
            return XCTFail("item 2 decoded as \(easel.items[2].content) rather than .image")
        }
        XCTAssertEqual(fileName, "boarding-pass.png")
    }

    func test_stateJSONWithoutAnyShapeItems_stillLoads() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        let space = Space(name: "Work", profileID: profile.id)
        let tab = Tab(spaceID: space.id, url: URL(string: "https://arc.net/")!)
        let legacyEasel = try JSONDecoder().decode(Easel.self, from: Data(Self.legacyEaselJSON.utf8))

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.easels = [legacyEasel]
        document.activeSpaceID = space.id
        _ = try store.saveNow(document)

        let stateURL = scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
        let writtenText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in Self.shapeOnlyKeys {
            XCTAssertFalse(
                writtenText.contains("\"\(key)\""),
                "\(key) is in the written state.json — this fixture is not the pre-shape format"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.easels.count, 1,
            """
            A state.json written before EaselItem.Content.shape existed failed to load. \
            Adding a case to a persisted Codable enum must stay additive — see this file's header.
            """
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "the rest of the document must come back too, not just the easel")
        XCTAssertEqual(reloaded.tabs.count, 1)
        XCTAssertEqual(reloaded.profiles.count, 1)

        let reloadedEasel = try XCTUnwrap(reloaded.easels.first)
        XCTAssertEqual(reloadedEasel.items.count, 3)
        XCTAssertEqual(reloadedEasel.title, "Trip Planning")
        XCTAssertFalse(
            reloadedEasel.items.contains { if case .shape = $0.content { return true } else { return false } },
            "nothing in a pre-shape document may come back as a shape"
        )
    }

    // MARK: - Direction 2: a document containing a shape round-trips

    func test_stateJSONWithAShapeItem_roundTripsThroughTheRealLoadPath() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let arrowColor = ThemeColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        let arrow = EaselItem(
            frame: CGRect(x: 120, y: 240, width: 180, height: 90),
            rotation: 0,
            content: .shape(
                kind: .arrow,
                color: arrowColor,
                lineWidth: 3,
                unitStart: CGPoint(x: 0.02, y: 0.97),
                unitEnd: CGPoint(x: 0.98, y: 0.03)
            ),
            zIndex: 4
        )
        let circle = EaselItem(
            frame: CGRect(x: 10, y: 10, width: 60, height: 60),
            content: .shape(
                kind: .ellipse,
                color: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
                lineWidth: 3,
                unitStart: .zero,
                unitEnd: CGPoint(x: 1, y: 1)
            ),
            zIndex: 5
        )

        var document = OrbitState()
        document.easels = [Easel(title: "Shapes", items: [arrow, circle])]
        _ = try store.saveNow(document)

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()
        let reloadedEasel = try XCTUnwrap(reloaded.easels.first)
        XCTAssertEqual(reloadedEasel.items.count, 2)

        let reloadedArrow = try XCTUnwrap(reloadedEasel.items.first { $0.id == arrow.id })
        guard case .shape(let kind, let color, let lineWidth, let unitStart, let unitEnd) = reloadedArrow.content else {
            return XCTFail("the arrow came back as \(reloadedArrow.content) rather than .shape")
        }
        XCTAssertEqual(kind, .arrow, "an arrow that reloads as a circle is a silently rewritten drawing")
        XCTAssertEqual(color, arrowColor, "the stroke colour is part of the shape, not a render-time default")
        XCTAssertEqual(lineWidth, 3, accuracy: 0.0001)

        XCTAssertEqual(unitStart.x, 0.02, accuracy: 0.0001)
        XCTAssertEqual(unitStart.y, 0.97, accuracy: 0.0001)
        XCTAssertEqual(unitEnd.x, 0.98, accuracy: 0.0001)
        XCTAssertEqual(unitEnd.y, 0.03, accuracy: 0.0001)
        XCTAssertGreaterThan(
            unitStart.y, unitEnd.y,
            "the arrow was drawn pointing up-right; it must still point up-right after a reload"
        )

        XCTAssertEqual(reloadedArrow.frame, arrow.frame)
        XCTAssertEqual(reloadedArrow.zIndex, 4, "z-order decides what an arrow is drawn over")

        let reloadedCircle = try XCTUnwrap(reloadedEasel.items.first { $0.id == circle.id })
        guard case .shape(let circleKind, _, _, _, _) = reloadedCircle.content else {
            return XCTFail("the circle came back as \(reloadedCircle.content) rather than .shape")
        }
        XCTAssertEqual(circleKind, .ellipse)
    }

    func test_easelMixingPreShapeItemsWithANewShape_roundTrips() throws {
        let store = StateStore(rootDirectory: scratchDirectory)
        var easel = try JSONDecoder().decode(Easel.self, from: Data(Self.legacyEaselJSON.utf8))
        easel.items.append(
            EaselItem(
                frame: CGRect(x: 500, y: 500, width: 40, height: 40),
                content: .shape(
                    kind: .rectangle,
                    color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1),
                    lineWidth: 3,
                    unitStart: .zero,
                    unitEnd: CGPoint(x: 1, y: 1)
                ),
                zIndex: 3
            )
        )

        var document = OrbitState()
        document.easels = [easel]
        _ = try store.saveNow(document)

        let reloadedEasel = try XCTUnwrap(try StateStore(rootDirectory: scratchDirectory).load().easels.first)
        XCTAssertEqual(reloadedEasel.items.count, 4, "adding a shape must not cost the three items that were already there")

        let shapeCount = reloadedEasel.items.filter { if case .shape = $0.content { return true } else { return false } }.count
        XCTAssertEqual(shapeCount, 1)
        guard case .text(let text) = reloadedEasel.items[0].content else {
            return XCTFail("the pre-existing text item came back as \(reloadedEasel.items[0].content)")
        }
        XCTAssertEqual(text, "Book the flights")
    }

    // MARK: - The roster itself

    func test_shapeKindRawValues_areTheArcRosterAndAreStable() throws {
        XCTAssertEqual(EaselItem.ShapeKind.ellipse.rawValue, "ellipse")
        XCTAssertEqual(EaselItem.ShapeKind.rectangle.rawValue, "rectangle")
        XCTAssertEqual(EaselItem.ShapeKind.arrow.rawValue, "arrow")

        let starJSON = """
        {"shape":{"kind":"star","color":{"red":0,"green":0,"blue":0,"alpha":1},"lineWidth":3,"unitStart":[0,0],"unitEnd":[1,1]}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(EaselItem.Content.self, from: Data(starJSON.utf8)))
    }
}
