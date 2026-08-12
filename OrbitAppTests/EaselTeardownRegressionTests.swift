import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class EaselTeardownRegressionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?
    private var scratchSpaceID: SpaceID!

    override func setUp() {
        super.setUp()
        FeatureRegistration.installAll(into: env)
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Easel Teardown Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        scratchSpaceID = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A live `NSHostingView`, not `RenderHarness.render` — a fresh
    /// `ImageRenderer` call has no view identity to carry state across snapshots.
    private func hostLikeProduction<V: View>(_ content: V, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
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
        self.window = window
        return window
    }

    private func allDescendants<T: NSView>(of view: NSView?, ofType type: T.Type, into result: inout [T]) {
        guard let view else { return }
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { allDescendants(of: subview, ofType: type, into: &result) }
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        var result: [NSTextField] = []
        allDescendants(of: window.contentView, ofType: NSTextField.self, into: &result)
        return result
    }

    // MARK: - Fixtures

    private struct EaselFixture {
        let id: UUID
        let title: String
    }

    @discardableResult
    private func makeEasel(title: String) -> EaselFixture {
        let easel = env.easelStore.createEasel(title: title)
        return EaselFixture(id: easel.id, title: title)
    }

    private func openEaselTab(_ fixture: EaselFixture) -> TabID {
        env.openTab(
            url: URL(string: "orbit://easel/\(fixture.id.uuidString)")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )
    }

    // MARK: - Disk verification

    private func reflectedURL(of object: AnyObject, propertyNamed name: String) -> URL? {
        Mirror(reflecting: object).children.first(where: { $0.label == name })?.value as? URL
    }

    /// Forces a real disk write then opens a brand-new `EaselStore` at the
    /// same directory, bypassing `env.easelStore`'s in-memory cache.
    private func easelStoreReadFromDisk() -> EaselStore? {
        do {
            try env.easelStore.saveNow()
        } catch {
            XCTFail("env.easelStore.saveNow() threw: \(error)")
            return nil
        }
        guard let directory = reflectedURL(of: env.easelStore, propertyNamed: "directory") else {
            XCTFail("Could not reflect EaselStore's private `directory` property — EaselStore's internal storage layout changed.")
            return nil
        }
        return EaselStore(directory: directory)
    }

    // MARK: - Render carryover (structural half)

    func test_theTitleFieldReloadsAfterSwitchingToADifferentEaselTab() {
        let easelA = makeEasel(title: "Easel A — must close cleanly")
        let easelB = makeEasel(title: "Easel B — the one being opened")
        let tabA = openEaselTab(easelA)
        let tabB = openEaselTab(easelB)

        env.activateTab(tabA)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        XCTAssertTrue(
            textFields(in: window).contains(where: { $0.stringValue == easelA.title }),
            "Fixture check: Easel A's title never rendered at all — nothing below is testing the reported defect."
        )

        env.activateTab(tabB)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let visibleTitles = textFields(in: window).map(\.stringValue)
        XCTAssertTrue(
            visibleTitles.contains(easelB.title),
            "Switching to Easel B's tab must show Easel B's own title; found titles: \(visibleTitles)."
        )
        XCTAssertFalse(
            visibleTitles.contains(easelA.title),
            "Easel A's stale title (\"\(easelA.title)\") is still on screen after switching to Easel B's tab — " +
            "the canvas did not rebuild for Easel B; found titles: \(visibleTitles)."
        )
    }

    // MARK: - Save correctness (disk half)

    func test_editingTheTitleWhileEaselBsTabIsActive_writesTheEditToEaselBsOwnFile() throws {
        let easelA = makeEasel(title: "Easel A — must stay untouched")
        let easelB = makeEasel(title: "Easel B — being edited")
        let tabA = openEaselTab(easelA)
        let tabB = openEaselTab(easelB)

        env.activateTab(tabA)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)
        guard textFields(in: window).contains(where: { $0.stringValue == easelA.title }) else {
            XCTFail("Fixture check: Easel A's title never rendered at all.")
            return
        }

        env.activateTab(tabB)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let titleField = textFields(in: window).first(where: { $0.stringValue == easelB.title }) else {
            XCTFail(
                "Fixture check: expected to find Easel B's own title on screen after switching to its tab so " +
                "this test can edit that exact field; found titles: \(textFields(in: window).map(\.stringValue))."
            )
            return
        }

        let typedTitle = "RENAMED WHILE THE PANE SHOWED EASEL B"
        window.makeFirstResponder(titleField)
        pump(seconds: 0.15)
        guard let editor = window.firstResponder as? NSTextView else {
            XCTFail("The title field never became first responder through its real field editor; first responder: \(String(describing: window.firstResponder)).")
            return
        }
        editor.insertText(typedTitle, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        window.makeFirstResponder(nil)
        // `EaselCanvasModel.titlePersistDebounce` is 400ms; this pump clears it with margin.
        pump(seconds: 0.6)

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let easelATitle = diskStore.easel(easelA.id)?.title
        let easelBTitle = diskStore.easel(easelB.id)?.title

        XCTAssertEqual(
            easelBTitle, typedTitle,
            """
            The rename typed while Easel B's tab was on screen must land in Easel B's own file (found \
            "\(String(describing: easelBTitle))", expected "\(typedTitle)"). Every field the user actually typed \
            into belonged to Easel B — `EaselCanvasModel.setTitle(_:)` writing through `self.easelID` is only \
            correct if `self` is genuinely Easel B's own model.
            """
        )
        XCTAssertEqual(
            easelATitle, easelA.title,
            """
            Easel A's file on disk changed (now "\(String(describing: easelATitle))", was "\(easelA.title)") from \
            an edit made while Easel A's tab was not even open. Easel A must come back exactly as it was left.
            """
        )
    }

    // MARK: - Rebuild mid-gesture

    func test_rebuildingModelForADifferentEasel_commitsTheOutgoingModelsInFlightStrokeAndFlushesItsViewport() throws {
        let easelA = makeEasel(title: "Rebuild Source")
        let easelB = makeEasel(title: "Rebuild Destination")

        let modelA = EaselCanvasModel(easelID: easelA.id, store: env.easelStore)
        modelA.strokeColorIndex = try markerBlueIndex()
        modelA.viewportOrigin = CGPoint(x: 42, y: -17)
        XCTAssertTrue(modelA.items.isEmpty, "fixture check: Easel A must start with no items")

        let strokePoints: [CGPoint] = [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 130), CGPoint(x: 180, y: 90)]
        let minX = try XCTUnwrap(strokePoints.map(\.x).min())
        let minY = try XCTUnwrap(strokePoints.map(\.y).min())
        let maxX = try XCTUnwrap(strokePoints.map(\.x).max())
        let maxY = try XCTUnwrap(strokePoints.map(\.y).max())
        let strokeFrame = CGRect(x: minX - 6, y: minY - 6, width: (maxX - minX) + 12, height: (maxY - minY) + 12)
        let relativePoints = strokePoints.map { CGPoint(x: $0.x - strokeFrame.origin.x, y: $0.y - strokeFrame.origin.y) }
        let strokeID = modelA.addItem(
            .drawing(points: relativePoints, color: modelA.strokeColor, width: EaselCanvasModel.defaultStrokeWidth),
            frame: strokeFrame
        )
        modelA.persistViewport()

        let modelB = EaselCanvasModel(easelID: easelB.id, store: env.easelStore)

        XCTAssertTrue(
            modelB.items.isEmpty,
            "the stroke committed against Easel A must never reach Easel B's model — this is exactly the " +
            "wrong-document write F3 describes: a drag that completes after the swap must not be able to land here."
        )

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let onDiskA = try XCTUnwrap(diskStore.easel(easelA.id))
        XCTAssertEqual(onDiskA.items.count, 1, "the in-flight stroke must be committed to Easel A's own document, not discarded")
        let persistedStroke = try XCTUnwrap(onDiskA.items.first { $0.id == strokeID })
        guard case .drawing(let points, _, _) = persistedStroke.content else {
            return XCTFail("the persisted item is \(persistedStroke.content), not the committed stroke")
        }
        XCTAssertEqual(points.count, strokePoints.count)
        XCTAssertEqual(
            onDiskA.viewportOrigin, CGPoint(x: 42, y: -17),
            "the pan made just before the rebuild must reach disk — a rebuild must not silently discard the last " +
            "150ms of panning along with the model that held it"
        )

        let onDiskB = try XCTUnwrap(diskStore.easel(easelB.id))
        XCTAssertTrue(onDiskB.items.isEmpty, "Easel B's own document must not contain Easel A's stroke")
    }

    // MARK: - Single-easel persistence across an unrelated tab switch

    private func markerBlueIndex() throws -> Int {
        try XCTUnwrap(
            EaselPalette.colors.firstIndex { $0.blue > 0.9 && $0.red < 0.3 && $0.green < 0.3 },
            "no sufficiently saturated blue swatch in EaselPalette to use as an unambiguous on-screen marker"
        )
    }

    func test_singleEasel_itemsSurviveSwitchingThePaneAwayToAWebTabAndBack() throws {
        let easel = makeEasel(title: "Single Easel")

        let seedModel = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        seedModel.strokeColorIndex = try markerBlueIndex()
        seedModel.activeTool = .rectangle
        let start = CGPoint(x: 260, y: 260)
        let end = CGPoint(x: 460, y: 420)
        let itemID = try XCTUnwrap(
            seedModel.addShape(kind: .rectangle, from: start, to: end),
            "seed shape was rejected as too small a drag"
        )
        let expectedGeometry = try XCTUnwrap(
            EaselCanvasModel.shapeGeometry(from: start, to: end, lineWidth: EaselCanvasModel.defaultStrokeWidth)
        )

        let easelTab = openEaselTab(easel)
        let webTab = env.openTab(
            url: URL(string: "https://example.com/")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )

        env.activateTab(easelTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        guard let canvasOrigin = canvasPixelFrame(in: window)?.origin else {
            XCTFail("Fixture check: could not locate the Easel canvas's own drawable area (KeyCaptureView) in the hosted window.")
            return
        }
        let expectedPixelFrame = localizedPixelFrame(
            forCanvasFrame: expectedGeometry.frame,
            canvasOrigin: canvasOrigin,
            scale: window.backingScaleFactor
        )

        let beforeSwitch = try XCTUnwrap(captureBitmap(of: window), "could not capture the hosted window's own pixels")
        XCTAssertGreaterThan(
            blueDominantPixelCount(in: beforeSwitch, within: expectedPixelFrame),
            Self.minimumBlueDominantPixelsForFixtureCheck,
            "Fixture check: the seeded rectangle never painted a single recognisably blue pixel inside its own " +
            "frame on the first mount — nothing below is testing the reported defect."
        )

        env.activateTab(webTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let duringWebTab = try XCTUnwrap(captureBitmap(of: window), "could not capture the hosted window's own pixels while the web tab is showing")
        XCTAssertLessThanOrEqual(
            blueDominantPixelCount(in: duringWebTab, within: expectedPixelFrame),
            Self.minimumBlueDominantPixelsForFixtureCheck,
            "Self-check: the rectangle's own window-space rectangle reads as blue-dominant even while a completely " +
            "unrelated web tab is showing — the localisation is not discriminating enough for the assertions below " +
            "to mean anything."
        )

        env.activateTab(easelTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let afterReturn = try XCTUnwrap(captureBitmap(of: window))
        XCTAssertGreaterThan(
            blueDominantPixelCount(in: afterReturn, within: expectedPixelFrame),
            Self.minimumBlueDominantPixelsForFixtureCheck,
            """
            User, verbatim: "As soon as I click off and click back on, the easel gets completely erased." The \
            rectangle drawn before switching away is no longer visible on screen after switching back to this \
            easel's own tab.
            """
        )

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let reloadedEasel = try XCTUnwrap(diskStore.easel(easel.id), "the easel itself vanished from the store's index")
        XCTAssertEqual(reloadedEasel.items.count, 1, "the seeded item must be the only item, still present, on disk")
        let reloadedItem = try XCTUnwrap(reloadedEasel.items.first { $0.id == itemID })
        guard case .shape(let kind, let color, _, _, _) = reloadedItem.content else {
            return XCTFail("the persisted item is \(reloadedItem.content), not the seeded rectangle")
        }
        XCTAssertEqual(kind, .rectangle)
        XCTAssertEqual(color, EaselPalette.themeColor(at: try markerBlueIndex()))
        XCTAssertEqual(reloadedItem.frame, expectedGeometry.frame, "the persisted frame must be exactly what the seeding drag produced")
    }

    // MARK: - Rendering: real pixels, not just a green assertion

    func test_easelCanvasView_actuallyPaintsARealItemAtItsRealFrame() throws {
        let easel = makeEasel(title: "Render Check")
        let model = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        model.strokeColorIndex = try markerBlueIndex()
        model.activeTool = .rectangle
        let start = CGPoint(x: 40, y: 40)
        let end = CGPoint(x: 200, y: 160)
        XCTAssertNotNil(model.addShape(kind: .rectangle, from: start, to: end))
        let geometry = try XCTUnwrap(
            EaselCanvasModel.shapeGeometry(from: start, to: end, lineWidth: EaselCanvasModel.defaultStrokeWidth)
        )

        let rendered = render(EaselCanvasView(easelID: easel.id).environment(env), size: CGSize(width: 400, height: 300))

        var blueDominantPixels = 0
        var y = Int(geometry.frame.minY)
        while y < Int(geometry.frame.maxY) {
            var x = Int(geometry.frame.minX)
            while x < Int(geometry.frame.maxX) {
                let color = rendered.color(atX: x, y: y)
                if color.b > color.r + 0.2, color.b > color.g + 0.2 {
                    blueDominantPixels += 1
                }
                x += 1
            }
            y += 1
        }
        XCTAssertGreaterThan(
            blueDominantPixels, 0,
            "EaselCanvasView rendered no recognisably blue pixel anywhere inside the seeded rectangle's own " +
            "frame \(geometry.frame) — real content did not reach the screen, only the model's array changed."
        )
    }

    // MARK: - Drag / resize / rotate commit paths

    func test_moveGesture_commitPathWritesTheDraggedFrameToTheStoreAndToDisk() throws {
        let easel = makeEasel(title: "Move Test")
        let model = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        let startingFrame = CGRect(x: 50, y: 50, width: 100, height: 40)
        let itemID = model.addItem(.text("move me"), frame: startingFrame)

        model.beginDrag()
        model.dragOriginFrame[itemID] = startingFrame
        let translation = CGSize(width: 120, height: -30)
        let zoom = model.viewportZoom
        let delta = CGSize(width: translation.width / zoom, height: translation.height / zoom)
        let origin = try XCTUnwrap(model.dragOriginFrame[itemID])
        let proposed = CGRect(
            origin: CGPoint(x: origin.origin.x + delta.width, y: origin.origin.y + delta.height),
            size: origin.size
        )
        let snapped = model.snappedFrame(proposed, movingItemID: itemID, threshold: 6 / zoom)
        model.updateDuringDrag(itemID) { $0.frame = snapped }
        model.dragOriginFrame.removeValue(forKey: itemID)
        model.commitDrag()

        XCTAssertTrue(model.canUndo, "commitDrag() must push an undo step, exactly like every other structural edit")
        let persisted = try XCTUnwrap(env.easelStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(persisted.frame.origin.x, 170, accuracy: 0.01)
        XCTAssertEqual(persisted.frame.origin.y, 20, accuracy: 0.01)
        XCTAssertEqual(persisted.frame.size, startingFrame.size, "a plain move must not resize the item")

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let onDisk = try XCTUnwrap(diskStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(onDisk.frame, persisted.frame, "the moved frame must reach the file on disk, not only the in-memory store cache")
    }

    func test_resizeGesture_bottomRightHandle_commitPathWritesTheResizedFrameToTheStoreAndToDisk() throws {
        let easel = makeEasel(title: "Resize Test")
        let model = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        let startingFrame = CGRect(x: 20, y: 20, width: 80, height: 60)
        let itemID = model.addItem(.text("resize me"), frame: startingFrame)

        model.beginDrag()
        model.dragOriginFrame[itemID] = startingFrame
        let translation = CGSize(width: 40, height: 25)
        let zoom = model.viewportZoom
        let dx = translation.width / zoom
        let dy = translation.height / zoom
        var frame = try XCTUnwrap(model.dragOriginFrame[itemID])
        frame.size.width += dx
        frame.size.height += dy
        frame.size.width = max(24, frame.size.width)
        frame.size.height = max(24, frame.size.height)
        model.updateDuringDrag(itemID) { $0.frame = frame }
        model.dragOriginFrame.removeValue(forKey: itemID)
        model.commitDrag()

        let persisted = try XCTUnwrap(env.easelStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(persisted.frame.origin.x, 20, accuracy: 0.01, "the bottom-right handle must not move the origin")
        XCTAssertEqual(persisted.frame.origin.y, 20, accuracy: 0.01)
        XCTAssertEqual(persisted.frame.width, 120, accuracy: 0.01)
        XCTAssertEqual(persisted.frame.height, 85, accuracy: 0.01)

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let onDisk = try XCTUnwrap(diskStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(onDisk.frame, persisted.frame, "the resized frame must reach the file on disk, not only the in-memory store cache")
    }

    /// Regression: `rotateGesture` never called `beginDrag()`, so
    /// `commitDrag()` skipped `persist()` and the rotation never reached disk.
    func test_rotateGesture_commitPathWritesTheRotationToTheStoreAndToDisk() throws {
        let easel = makeEasel(title: "Rotate Test")
        let model = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        let frame = CGRect(x: 100, y: 100, width: 80, height: 40)
        let itemID = model.addItem(.text("rotate me"), frame: frame)
        XCTAssertEqual(model.items.first { $0.id == itemID }?.rotation, 0)

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let zoom = model.viewportZoom
        let origin = model.viewportOrigin

        func angle(at location: CGPoint) -> Double {
            let vector = CGPoint(
                x: location.x - center.x * zoom - origin.x,
                y: location.y - center.y * zoom - origin.y
            )
            return atan2(vector.y, vector.x) * 180 / .pi + 90
        }

        // Two changes, as a real drag would deliver: the committed rotation must equal the second.
        if model.dragOriginFrame[itemID] == nil {
            model.beginDrag()
            model.dragOriginFrame[itemID] = frame
        }
        model.updateDuringDrag(itemID) { $0.rotation = angle(at: CGPoint(x: center.x + 40, y: center.y)) }
        let finalAngle = angle(at: CGPoint(x: center.x, y: center.y - 40))
        model.updateDuringDrag(itemID) { $0.rotation = finalAngle }
        model.dragOriginFrame.removeValue(forKey: itemID)
        model.commitDrag()

        XCTAssertTrue(model.canUndo, "commitDrag() must push an undo step for a rotate exactly like any other edit")
        let persisted = try XCTUnwrap(env.easelStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(persisted.rotation, finalAngle, accuracy: 0.01)

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let onDisk = try XCTUnwrap(diskStore.easel(easel.id)?.items.first { $0.id == itemID })
        XCTAssertEqual(
            onDisk.rotation, finalAngle, accuracy: 0.01,
            "the rotation must reach the file on disk — this is exactly the assertion the pre-fix `rotateGesture` failed"
        )
    }

    // MARK: - Undo after deleting a mid-edit item

    func test_undoingAfterDeletingAMidEditTextItem_restoresItOnTheFirstUndo() throws {
        let easel = makeEasel(title: "Undo After Delete")
        let model = EaselCanvasModel(easelID: easel.id, store: env.easelStore)
        let originalText = "half-typed before the delete"
        let frame = CGRect(x: 40, y: 40, width: 160, height: 32)
        let itemID = model.addItem(.text(originalText), frame: frame)

        model.selection = [itemID]
        model.deleteSelected()
        XCTAssertTrue(model.items.isEmpty, "fixture check: the item must actually be gone after deleteSelected()")

        model.updateItem(itemID) { current in
            guard case .text = current.content else { return }
            current.content = .text("draft the guarded no-op must never write")
        }

        model.undo()

        XCTAssertEqual(
            model.items.count, 1,
            "one Cmd+Z after deleting a mid-edit item must restore it on the FIRST undo — a stray no-op frame " +
            "from the guarded `updateItem` call above would instead make this undo a no-op and require a second press"
        )
        let restored = try XCTUnwrap(model.items.first { $0.id == itemID })
        guard case .text(let text) = restored.content else {
            return XCTFail("the restored item is \(restored.content), not the original text item")
        }
        XCTAssertEqual(
            text, originalText,
            "the restored item must carry its original text, not the draft the guarded no-op must never have written"
        )
    }

    // MARK: - Quit-time flush (`DocumentEditorFlushRegistry`)

    func test_easelCanvas_registersWithFlushRegistryOnMountAndDeregistersOnUnmount() {
        let easel = makeEasel(title: "Registry Lifecycle")
        let easelTab = openEaselTab(easel)
        let webTab = env.openTab(
            url: URL(string: "https://example.com/")!,
            in: scratchSpaceID,
            section: .pinned,
            activate: false
        )

        let baseline = DocumentEditorFlushRegistry.shared.registeredCount

        env.activateTab(easelTab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        XCTAssertEqual(
            DocumentEditorFlushRegistry.shared.registeredCount, baseline + 1,
            "mounting the Easel canvas must register exactly one flush closure with DocumentEditorFlushRegistry"
        )

        env.activateTab(webTab)
        pump(seconds: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(
            DocumentEditorFlushRegistry.shared.registeredCount, baseline,
            "switching away from the Easel tab must deregister its flush closure, or a later quit-time " +
            "flushAll() would call into a torn-down view's state"
        )
    }

    func test_quitTimeFlush_commitsAPendingTitleEditBeforeItsOwnDebounceWindowElapses() throws {
        let easel = makeEasel(title: "Pending Title Edit")
        let tab = openEaselTab(easel)
        env.activateTab(tab)
        let window = hostLikeProduction(ContentCardView().environment(env), size: CGSize(width: 900, height: 700))
        pump(seconds: 0.3)

        guard let titleField = textFields(in: window).first(where: { $0.stringValue == easel.title }) else {
            XCTFail("Fixture check: the easel's own title never rendered.")
            return
        }

        let typedTitle = "TYPED JUST BEFORE QUIT"
        window.makeFirstResponder(titleField)
        pump(seconds: 0.05)
        guard let editor = window.firstResponder as? NSTextView else {
            XCTFail("The title field never became first responder through its real field editor; first responder: \(String(describing: window.firstResponder)).")
            return
        }
        editor.insertText(typedTitle, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))

        // Well inside the 400ms titlePersistDebounce, so a pass here is evidence flushAll() forced the write.
        pump(seconds: 0.1)

        DocumentEditorFlushRegistry.shared.flushAll()

        guard let diskStore = easelStoreReadFromDisk() else { return }
        let persistedTitle = diskStore.easel(easel.id)?.title
        XCTAssertEqual(
            persistedTitle, typedTitle,
            """
            A title typed just before quit must reach disk once `DocumentEditorFlushRegistry.shared.flushAll()` \
            runs (the app delegate's quit-time hook), even though it was still well inside \
            `EaselCanvasModel.titlePersistDebounce` and would otherwise not have been written for roughly another \
            300ms (found "\(String(describing: persistedTitle))", expected "\(typedTitle)").
            """
        )
    }

    // MARK: - Real-window pixel capture

    private static let minimumBlueDominantPixelsForFixtureCheck = 30

    /// Must use dlsym for `CGWindowListCreateImage`, not a direct call: it is obsoleted in the macOS 15 SDK but the symbol is still live, and a process may capture its own windows with it under no Screen Recording grant.
    private func captureBitmap(of window: NSWindow) -> NSBitmapImageRep? {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    /// The Easel canvas's own drawable area, converted into the same
    /// top-left-origin pixel space `captureBitmap(of:)`'s bitmap reads.
    private func canvasPixelFrame(in window: NSWindow) -> CGRect? {
        var keyCaptureViews: [KeyCaptureView.KeyCaptureNSView] = []
        allDescendants(of: window.contentView, ofType: KeyCaptureView.KeyCaptureNSView.self, into: &keyCaptureViews)
        guard let keyCaptureView = keyCaptureViews.first, let contentView = window.contentView else { return nil }
        let pointFrame = keyCaptureView.convert(keyCaptureView.bounds, to: contentView)
        let scale = window.backingScaleFactor
        let topLeftYInPoints = contentView.bounds.height - pointFrame.maxY
        return CGRect(
            x: pointFrame.minX * scale,
            y: topLeftYInPoints * scale,
            width: pointFrame.width * scale,
            height: pointFrame.height * scale
        )
    }

    /// Valid only while `viewportOrigin == .zero` and `viewportZoom == 1`,
    /// true for every test that calls this.
    private func localizedPixelFrame(forCanvasFrame canvasFrame: CGRect, canvasOrigin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: canvasOrigin.x + canvasFrame.minX * scale,
            y: canvasOrigin.y + canvasFrame.minY * scale,
            width: canvasFrame.width * scale,
            height: canvasFrame.height * scale
        )
    }

    /// Sampled on a 2pt stride rather than every physical pixel. `pixelRect`
    /// restricts the scan to that rectangle instead of the whole window.
    private func blueDominantPixelCount(in bitmap: NSBitmapImageRep, within pixelRect: CGRect? = nil) -> Int {
        let minX = max(0, Int((pixelRect?.minX ?? 0).rounded(.down)))
        let minY = max(0, Int((pixelRect?.minY ?? 0).rounded(.down)))
        let maxX = min(bitmap.pixelsWide, Int((pixelRect?.maxX ?? CGFloat(bitmap.pixelsWide)).rounded(.up)))
        let maxY = min(bitmap.pixelsHigh, Int((pixelRect?.maxY ?? CGFloat(bitmap.pixelsHigh)).rounded(.up)))
        var count = 0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.blueComponent > color.redComponent + 0.2,
                   color.blueComponent > color.greenComponent + 0.2 {
                    count += 1
                }
                x += 2
            }
            y += 2
        }
        return count
    }
}
