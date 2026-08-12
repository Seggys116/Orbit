import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class EmptyStatePlaceholderTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // MARK: - Site Control's Boosts sheet

    func testUnregisteredBoostsEditorPresentsNothing() {
        let points = UIExtensionPoints()
        XCTAssertNil(points.boostsEditor, "Precondition: a fresh UIExtensionPoints has no registered editor.")

        XCTAssertNil(
            SiteControlPopoverView.makeBoostsEditorSheet(for: "example.com", extensionPoints: points),
            "An unregistered boostsEditor must present nothing at all — not a card explaining Orbit's module layout to the user."
        )
    }

    func testRegisteredBoostsEditorPresentsThatEditorForTheHost() {
        let points = UIExtensionPoints()
        var requestedHosts: [String] = []
        points.boostsEditor = { host in
            requestedHosts.append(host)
            return AnyView(Color.clear)
        }

        let sheet = SiteControlPopoverView.makeBoostsEditorSheet(for: "twitter.com", extensionPoints: points)

        XCTAssertNotNil(sheet, "A registered boostsEditor must be presented.")
        XCTAssertEqual(requestedHosts, ["twitter.com"], "The editor must be built for the host the popover is showing.")
    }

    func testFeatureRegistrationAlwaysRegistersTheBoostsEditor() {
        XCTAssertNil(env.extensionPoints.boostsEditor, "Precondition: a fresh environment has no registered editor.")

        FeatureRegistration.installAll(into: env)

        XCTAssertNotNil(
            env.extensionPoints.boostsEditor,
            "installAll must register boostsEditor, otherwise the Site Control Center's Boosts button silently does nothing."
        )
        XCTAssertNotNil(
            SiteControlPopoverView.makeBoostsEditorSheet(for: "example.com", extensionPoints: env.extensionPoints),
            "After installAll the Boosts button must present a real editor."
        )
    }

    // MARK: - Source guards for empty states that live only in a View body

    func testNoPlaceholderSurfaceViewAnywhereInProductionSource() throws {
        let offenders = try Self.productionSwiftFiles().filter { url in
            let source = try? String(contentsOf: url, encoding: .utf8)
            guard let source else { return false }
            let code = Self.strippingFullLineComments(source)
            return code.contains("struct PlaceholderSurfaceView") || code.contains("PlaceholderSurfaceView(")
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            PlaceholderSurfaceView is back in \(offenders.map(\.lastPathComponent).sorted()). \
            An unregistered UIExtensionPoints hook is a wiring bug, not a user state: render nothing. \
            See ContentCardView.surface(_:) for the same rule.
            """
        )
    }

    func testManageSpacesHasNoEmptyColumnPlaceholderCopy() throws {
        let code = try Self.productionCode(at: "UI/Spaces/ManageSpacesView.swift")

        XCTAssertFalse(
            code.contains(#"Text("No tabs")"#),
            "Arc's empty Space column in Manage Spaces shows nothing at all — no \"No tabs\" line. See arc-manage-spaces-panel-allthingshow.png."
        )
    }

    func testAFreshSpaceHasNoPinnedOrTodayTabsToRender() {
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(
            name: "Writing",
            icon: "sun.max",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )

        XCTAssertTrue(
            env.pinnedNodes(in: spaceID).isEmpty,
            "A newly created Space has no Pinned tabs, so Manage Spaces' empty column is a reachable state and not dead code."
        )
        XCTAssertTrue(
            env.todayTabs(in: spaceID).isEmpty,
            "A newly created Space has no Today tabs, so Manage Spaces' empty column is a reachable state and not dead code."
        )
    }

    func testDownloadsFlyoutHasNoEmptyStateCopy() throws {
        let code = try Self.productionCode(at: "UI/Sidebar/SidebarBottomBar.swift")

        XCTAssertFalse(
            code.contains(#"Text("No downloads yet")"#),
            "The downloads flyout must render an empty list, not placeholder copy — refs/ARC_INTERACTION.md §5, refs/ARC_LIBRARY.md §6."
        )
    }

    func testDownloadsFlyoutListIsEmptyBeforeAnythingIsDownloaded() {
        XCTAssertTrue(
            env.recentDownloads.isEmpty,
            "With no downloads the flyout's list source must be empty, so its empty rendering is a reachable state rather than dead code."
        )
    }

    func testSiteSearchSettingsTableHasNoEmptyStateCopy() throws {
        let code = try Self.productionCode(at: "UI/CommandBar/SiteSearchSettingsWindowController.swift")

        XCTAssertFalse(
            code.contains(#"Text("No sites configured.")"#),
            "The page this reproduces shows nothing when its Site search table is empty — see search_engines_page.ts's showNoResultsMessage_."
        )
    }

    // MARK: - Source access

    private static var productionSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    private static func productionSource(at relativePath: String) throws -> String {
        let url = productionSourceRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Guard is pointed at a file that no longer exists: \(url.path). Re-point it rather than deleting the guard."
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Strips only whole-line `//` comments, so a guarded file's own doc
    /// comment naming the deleted literal cannot make a raw-file match false
    /// positive, and a `//` inside a string literal is left untouched.
    private static func strippingFullLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func productionCode(at relativePath: String) throws -> String {
        strippingFullLineComments(try productionSource(at: relativePath))
    }

    private static func productionSwiftFiles() throws -> [URL] {
        let root = productionSourceRoot
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Could not walk \(root.path) — this guard's own directory walk is broken.")
            return []
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Found no Swift files under \(root.path) — this guard's own directory walk is broken.")
        return files
    }
}
