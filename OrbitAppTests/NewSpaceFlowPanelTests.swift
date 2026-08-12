//  Regression guard: the New Space flow is a panel filling the sidebar column, not a
//  centred 400pt modal sheet.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class NewSpaceFlowPanelTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var createdSpaceIDs: [SpaceID] = []

    override func tearDown() {
        for id in createdSpaceIDs where env.space(id) != nil {
            env.deleteSpace(id)
        }
        createdSpaceIDs = []
        super.tearDown()
    }

    // MARK: - 1. The verb still works

    func testCreateSpaceReallyCreatesTheSpaceItWasGiven() {
        let before = env.spaces.count
        let theme = SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.5, blue: 0.5)], grain: 0)

        let id = NewSpaceFlowAction.create(
            name: "  Writing  ",
            icon: "pencil",
            iconIsEmoji: false,
            theme: theme,
            in: env
        )

        XCTAssertNotNil(id, "Create Space returned no Space id for a perfectly valid name.")
        guard let id else { return }
        createdSpaceIDs.append(id)

        let space = env.space(id)
        XCTAssertNotNil(space, "Create Space returned an id that is not in the store.")
        XCTAssertEqual(env.spaces.count, before + 1, "Create Space did not add exactly one Space.")
        XCTAssertEqual(space?.name, "Writing", "The name was not carried through (and surrounding whitespace should be trimmed).")
        XCTAssertEqual(space?.icon, "pencil", "The chosen icon was not carried through.")
        XCTAssertEqual(space?.iconIsEmoji, false)
        XCTAssertEqual(space?.theme, theme, "The theme chosen in the panel was not carried through to the created Space.")
    }

    func testCreateSpaceCarriesAnEmojiIconThrough() {
        let id = NewSpaceFlowAction.create(name: "Fun", icon: "🎈", iconIsEmoji: true, theme: SpaceTheme(), in: env)
        XCTAssertNotNil(id)
        guard let id else { return }
        createdSpaceIDs.append(id)

        XCTAssertEqual(env.space(id)?.icon, "🎈")
        XCTAssertEqual(env.space(id)?.iconIsEmoji, true, "An emoji icon was stored as an SF Symbol name.")
    }

    func testABlankNameCreatesNothing() {
        let before = env.spaces.count

        XCTAssertFalse(NewSpaceFlowAction.canCreate(name: ""))
        XCTAssertFalse(NewSpaceFlowAction.canCreate(name: "   \n\t "))
        XCTAssertTrue(NewSpaceFlowAction.canCreate(name: "x"))

        XCTAssertNil(NewSpaceFlowAction.create(name: "", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), in: env))
        XCTAssertNil(NewSpaceFlowAction.create(name: "   ", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), in: env))

        XCTAssertEqual(env.spaces.count, before, "A blank name created a Space anyway.")
    }

    func testTheCreatedSpaceLandsOnARealPersistentProfile() {
        let id = NewSpaceFlowAction.create(name: "Profileless", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), in: env)
        XCTAssertNotNil(id)
        guard let id, let space = env.space(id) else { return }
        createdSpaceIDs.append(id)

        let profile = env.state.profiles.first { $0.id == space.profileID }
        XCTAssertNotNil(profile, "The created Space points at a Profile that does not exist.")
        XCTAssertTrue(profile?.isPersistent == true, "The created Space landed on a non-persistent (Incognito session) Profile.")
        XCTAssertEqual(space.profileID, NewSpaceProfileDefault.resolve(in: env))
    }

    // MARK: - 2. Arc's ordering, and still no Profile row

    func testPanelRowsAreInArcsOrder() {
        XCTAssertEqual(
            NewSpaceFlowRow.allCases,
            [.nameAndIcon, .chooseTheme],
            "The Create a Space panel's rows are not in the order Arc's captures show (name/icon field, then Choose a Theme)."
        )
    }

    func testNoRowInThePanelIsAProfileRow() {
        let offending = NewSpaceFlowRow.allCases.filter { $0.rawValue.lowercased().contains("profile") }
        XCTAssertTrue(offending.isEmpty, "A Profile row reappeared in the New Space panel: \(offending).")
    }

    // MARK: - 3. A column panel, not a fixed-size modal

    // Probe-based, not boundingBoxOfContent() (misreads a gradient as partly empty).
    func testPanelFillsWhateverColumnItIsGivenRatherThanBeingAFixedSizeModal() {
        for size in [CGSize(width: OrbitMetrics.sidebarMaxWidth, height: 620), CGSize(width: 1000, height: 880)] {
            let uncovered = edgesShowingTheProbe(under: AnyView(NewSpaceFlowView().environment(env)), size: size)
            if !uncovered.isEmpty {
                XCTFail(
                    """
                    The New Space panel left \(uncovered.joined(separator: ", ")) of a \
                    \(Int(size.width))×\(Int(size.height)) column uncovered — the probe colour is still \
                    showing through there. Arc's flow is a panel that FILLS the sidebar column (see \
                    Orbit/UI/Spaces/NewSpaceFlowView.swift's header), not a fixed-size modal sitting \
                    inside it. A diagnostic PNG has been written; open it before changing this assertion.
                    """
                )
            }
        }
    }

    // Positive control: the probe is calibrated by rendering it alone, not a hard-coded RGBA.
    func testTheProbeCanSeeAColumnThatIsNotFilled() {
        let size = CGSize(width: 1000, height: 880)
        let deliberatelySmall = AnyView(NewSpaceFlowView().environment(env).frame(width: 120, height: 120))

        let uncovered = edgesShowingTheProbe(under: deliberatelySmall, size: size)

        XCTAssertFalse(
            uncovered.isEmpty,
            """
            The probe reported a 120×120 view as filling a \(Int(size.width))×\(Int(size.height)) column. \
            It cannot see uncovered area at all, which means \
            testPanelFillsWhateverColumnItIsGivenRatherThanBeingAFixedSizeModal is passing vacuously.
            """
        )
    }

    private func edgesShowingTheProbe(under view: AnyView, size: CGSize) -> [String] {
        let probe = Color(red: 1, green: 0, blue: 1)
        let probeColor = render(probe, size: size).color(atX: 0, y: 0)

        let rendered = render(ZStack { probe; view }, size: size)

        let maxX = Int(size.width) - 1
        let maxY = Int(size.height) - 1
        let midX = Int(size.width) / 2
        let midY = Int(size.height) / 2
        let samples: [(String, Int, Int)] = [
            ("the top-left corner", 0, 0),
            ("the top-right corner", maxX, 0),
            ("the bottom-left corner", 0, maxY),
            ("the bottom-right corner", maxX, maxY),
            ("the leading edge halfway down", 0, midY),
            ("the trailing edge halfway down", maxX, midY),
            ("the top edge centred", midX, 0),
            ("the bottom edge centred", midX, maxY),
            ("the centre", midX, midY),
        ]

        let uncovered = samples
            .filter { rendered.color(atX: $0.1, y: $0.2).isApproximately(probeColor, tolerance: 0.08) }
            .map(\.0)

        if !uncovered.isEmpty {
            rendered.writeDiagnosticPNG(named: "NewSpaceFlowPanel-probe-\(Int(size.width))x\(Int(size.height))")
        }
        return uncovered
    }

    func testTheFlowIsNotPresentedAsASheet() throws {
        let source = try executableLines(of: "UI/Root/BrowserWindowView.swift").joined(separator: "\n")

        XCTAssertFalse(
            source.contains(".sheet(isPresented: $showNewSpaceFlow)"),
            """
            The New Space flow is back on a `.sheet`. Arc presents it as a panel filling the sidebar \
            column — see the four captures listed in Orbit/UI/Spaces/NewSpaceFlowView.swift's header \
            and refs/reference/README.md's "Arc's New Space creation flow".
            """
        )
        XCTAssertTrue(
            source.contains(".overlay { newSpaceFlowPanel }"),
            "The New Space panel is no longer overlaid on the sidebar column in BrowserWindowView."
        )
        XCTAssertTrue(
            source.contains(".frame(width: env.sidebarWidth)"),
            "The view the New Space panel overlays is no longer the sidebar-width column."
        )
    }

    func testThePanelDeclaresNoFixedModalWidth() throws {
        let lines = try executableLines(of: "UI/Spaces/NewSpaceFlowView.swift")
        let offending = lines.enumerated().filter { $0.element.contains(".frame(width: 4") || $0.element.contains(".frame(width: 3") }
        XCTAssertTrue(
            offending.isEmpty,
            "NewSpaceFlowView re-declares a fixed modal width on line(s) \(offending.map { "\($0.offset + 1)" }.joined(separator: ", ")). It takes its width from the sidebar column it fills."
        )
    }

    // MARK: - Helpers

    private static var productionSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    private func executableLines(of relativePath: String) throws -> [String] {
        try String(contentsOf: Self.productionSourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
