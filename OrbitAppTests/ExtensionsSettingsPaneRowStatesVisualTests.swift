//  Covers row states (installed, disabled, per-row error, empty) via the pure
//  views ExtensionsSettingsPane.swift extracts, since .body reads live singletons.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ExtensionsSettingsPaneRowStatesVisualTests: XCTestCase {

    // MARK: - Fixtures

    private static func makeExtension(
        id: String = "abcdefghijklmnopabcdefghijklmnop",
        name: String = "Fixture Extension",
        version: String = "1.3.0",
        isEnabled: Bool = true,
        manifestVersion: Int = 3
    ) -> LoadedExtension {
        LoadedExtension(
            id: id,
            name: name,
            version: version,
            directory: URL(fileURLWithPath: "/tmp/orbit-fixture-extensions/\(id)", isDirectory: true),
            iconURL: nil,
            hasToolbarAction: true,
            manifestVersion: manifestVersion,
            isEnabled: isEnabled,
            isActivated: true
        )
    }

    private static let sampleWarning = ExtensionPermissionWarning(
        id: "host.all", text: "Read and change all your data on all websites", severity: .critical, isGrantedAtInstall: true
    )

    // MARK: - Empty state

    func test_installedSection_withNoExtensions_rendersTheEmptyStateText() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                Self.installedSection(extensions: []),
                size: CGSize(width: SettingsMetrics.contentMaxWidth, height: 80),
                appearance: appearance
            )
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue): the empty-state text painted nothing.")
        }
    }

    func test_installedSection_withExtensions_rendersVisiblyDifferentlyFromTheEmptyState() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 120)
        let empty = render(Self.installedSection(extensions: []), size: size, appearance: .darkAqua)
        let populated = render(
            Self.installedSection(extensions: [Self.makeExtension()]),
            size: size,
            appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(empty, populated, size: size),
            "A section with one real installed extension rendered pixel-identical to the empty state — the row is not actually drawing."
        )
    }

    // MARK: - Installed / disabled: the toggle actually reflects isEnabled

    func test_extensionRow_enabledAndDisabled_renderVisiblyDifferentToggles() {
        let size = CGSize(width: 420, height: 80)
        let enabled = render(Self.row(ext: Self.makeExtension(isEnabled: true)), size: size, appearance: .darkAqua)
        let disabled = render(Self.row(ext: Self.makeExtension(isEnabled: false)), size: size, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(enabled, disabled, size: size),
            "An enabled row and a disabled row (only isEnabled differs) rendered pixel-identical — the toggle is not reflecting the extension's real state."
        )
    }

    func test_extensionRow_paintsNonBlankContent_inBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(Self.row(ext: Self.makeExtension()), size: CGSize(width: 420, height: 60), appearance: appearance)
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    // MARK: - Error: a row whose manifest.json could not be read

    func test_extensionRow_expandedWithNoDetail_showsTheUnreadableManifestMessage() {
        let size = CGSize(width: 420, height: 140)
        let withoutDetail = render(Self.row(ext: Self.makeExtension(), isExpanded: true, detail: nil), size: size, appearance: .darkAqua)
        let withDetail = render(
            Self.row(
                ext: Self.makeExtension(),
                isExpanded: true,
                detail: ExtensionsSettingsPane.ExtensionRowDetail(warnings: [], requestsTabs: false, isPathDerived: false, optionsURL: nil)
            ),
            size: size,
            appearance: .darkAqua
        )
        XCTAssertNotNil(withoutDetail.boundingBoxOfContent(), "The unreadable-manifest error state painted nothing.")
        XCTAssertTrue(
            Self.rendersDiffer(withoutDetail, withDetail, size: size),
            "A row with an unreadable manifest (detail: nil) rendered identically to one with a real, empty detail — the error branch is not reachable."
        )
    }

    func test_extensionRow_collapsedVsExpanded_renderDifferently() {
        let size = CGSize(width: 420, height: 140)
        let ext = Self.makeExtension()
        let detail = ExtensionsSettingsPane.ExtensionRowDetail(warnings: [Self.sampleWarning], requestsTabs: true, isPathDerived: false, optionsURL: nil)

        let collapsed = render(Self.row(ext: ext, isExpanded: false, detail: detail), size: size, appearance: .darkAqua)
        let expanded = render(Self.row(ext: ext, isExpanded: true, detail: detail), size: size, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(collapsed, expanded, size: size),
            "Expanding a row with warnings and a tabs-permission notice did not change anything rendered — Show Details is decorative."
        )
    }

    func test_extensionRow_pathDerivedVsWebStoreSourced_renderDifferently() {
        let size = CGSize(width: 420, height: 140)
        let pathDerived = render(
            Self.row(
                ext: Self.makeExtension(),
                isExpanded: true,
                detail: ExtensionsSettingsPane.ExtensionRowDetail(warnings: [], requestsTabs: false, isPathDerived: true, optionsURL: nil)
            ),
            size: size, appearance: .darkAqua
        )
        let webStoreSourced = render(
            Self.row(
                ext: Self.makeExtension(),
                isExpanded: true,
                detail: ExtensionsSettingsPane.ExtensionRowDetail(warnings: [], requestsTabs: false, isPathDerived: false, optionsURL: nil)
            ),
            size: size, appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(pathDerived, webStoreSourced, size: size),
            "A locally loaded (path-derived) extension and a Chrome Web Store one rendered identically — the two must show different source copy and controls (Check for Update only applies to the latter)."
        )
    }

    // MARK: - Pending-changes / activation-error banner

    func test_pendingChangesBanner_paintsNonBlankContent_inBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionPendingChangesBanner(lastError: nil, onRestart: {}),
                size: CGSize(width: 460, height: 60),
                appearance: appearance
            )
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    func test_pendingChangesBanner_activationErrorRendersDifferentlyFromTheNeutralMessage() {
        let size = CGSize(width: 460, height: 60)
        let neutral = render(ExtensionPendingChangesBanner(lastError: nil, onRestart: {}), size: size, appearance: .darkAqua)
        let failed = render(
            ExtensionPendingChangesBanner(lastError: "some-extension-id: engine unavailable", onRestart: {}),
            size: size,
            appearance: .darkAqua
        )
        XCTAssertTrue(
            Self.rendersDiffer(neutral, failed, size: size),
            "Chromium's own load failure (lastError set) rendered identically to the plain 'not running yet' message — the banner is not showing the real error."
        )
    }

    // MARK: - No engine yet

    func test_engineStartingNotice_paintsNonBlankContent_inBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                ExtensionsEngineStartingNotice(),
                size: CGSize(width: SettingsMetrics.contentMaxWidth, height: 60),
                appearance: appearance
            )
            XCTAssertNotNil(
                rendered.boundingBoxOfContent(),
                "appearance \(appearance.rawValue): the no-engine notice painted nothing, so the pane's only pre-engine state is blank."
            )
        }
    }

    func test_engineStartingNotice_rendersDifferentlyFromTheEmptyInstalledList() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 60)
        let notice = render(ExtensionsEngineStartingNotice(), size: size, appearance: .darkAqua)
        let emptyList = render(Self.installedSection(extensions: []), size: size, appearance: .darkAqua)
        XCTAssertTrue(
            Self.rendersDiffer(notice, emptyList, size: size),
            "\"Chromium isn't running yet\" rendered identically to \"No extensions installed.\" — the two states must not be confusable, since only one of them means the user has nothing installed."
        )
    }

    // MARK: - Architecture: the DI seam must not regress back onto the shared singletons

    func test_extractedPureRowViews_neverReferenceTheSharedExtensionSingletons() throws {
        let source = try Self.productionSource(named: "ExtensionsSettingsPane.swift")
        for typeName in ["ExtensionRowView", "ExtensionsInstalledSectionView", "ExtensionPendingChangesBanner"] {
            let body = try Self.bodyOfType(typeName, in: source)
            XCTAssertFalse(
                body.contains("env.extensionStore"),
                "\(typeName) reads env.extensionStore directly — that reintroduces the machine-state dependency this DI seam exists to remove."
            )
            XCTAssertFalse(
                body.contains("ExtensionRuntime.shared"),
                "\(typeName) reads ExtensionRuntime.shared directly — that reintroduces the machine-state dependency this DI seam exists to remove."
            )
        }
    }

    // MARK: - Harness

    private static func installedSection(extensions: [LoadedExtension]) -> some View {
        ExtensionsInstalledSectionView(
            extensions: extensions,
            expandedExtensionIDs: [],
            updateRowStates: [:],
            isCheckingForUpdateDisabled: false,
            rowDetail: { _ in nil },
            onSetEnabled: { _, _ in },
            onRemove: { _ in },
            onToggleExpanded: { _ in },
            onOpenOptionsPage: { _ in },
            onOpenWebStoreListing: { _ in },
            onCheckForUpdate: { _ in }
        )
    }

    private static func row(
        ext: LoadedExtension,
        isExpanded: Bool = false,
        detail: ExtensionsSettingsPane.ExtensionRowDetail? = nil,
        updateState: ExtensionUpdateRowState? = nil
    ) -> some View {
        ExtensionRowView(
            ext: ext,
            isExpanded: isExpanded,
            detail: detail,
            updateState: updateState,
            isCheckingForUpdateDisabled: false,
            onSetEnabled: { _ in },
            onRemove: {},
            onToggleExpanded: {},
            onOpenOptionsPage: { _ in },
            onOpenWebStoreListing: {},
            onCheckForUpdate: {}
        )
    }

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 6
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }

    // MARK: - Source lookup

    private static func productionSource(named fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OrbitAppTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Orbit", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(root.path).")
            return ""
        }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTFail("Could not find \(fileName) under Orbit/.")
        return ""
    }

    /// The declaration of `struct <typeName>` up to the next top-level type.
    /// Strips `//` comments first, since the next type's header comment names the singletons this file forbids reading.
    private static func bodyOfType(_ typeName: String, in source: String) throws -> String {
        guard let declRange = source.range(of: "struct \(typeName): View {") ?? source.range(of: "struct \(typeName) {") else {
            XCTFail("Could not find `struct \(typeName)` in the source.")
            return ""
        }
        let rest = source[declRange.upperBound...]
        let nextTopLevelMarkers = ["\nstruct ", "\nenum ", "\nextension ", "\nclass ", "\nprivate struct ", "\nprivate enum "]
        var end = rest.endIndex
        for marker in nextTopLevelMarkers {
            if let range = rest.range(of: marker), range.lowerBound < end {
                end = range.lowerBound
            }
        }
        return rest[rest.startIndex..<end]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentRange = line.range(of: "//") else { return line }
                return line[line.startIndex..<commentRange.lowerBound]
            }
            .joined(separator: "\n")
    }
}
