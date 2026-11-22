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

    // MARK: - Pixel helpers

    private func assertDimensions(_ image: RenderedImage, _ size: CGSize, _ label: String) {
        XCTAssertEqual(image.bitmap.pixelsWide, Int(size.width) * 2, "\(label): rendered at the requested width @2x")
        XCTAssertEqual(image.bitmap.pixelsHigh, Int(size.height) * 2, "\(label): rendered at the requested height @2x")
    }

    /// Mean of (r + g + b) / 3 over the pixels in `rect` that are at least 30% opaque; nil when none are.
    private func inkBrightness(_ image: RenderedImage, in rect: CGRect) -> Double? {
        var total = 0.0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let color = image.color(atX: x, y: y)
                guard color.a >= 0.3 else { continue }
                total += (color.r + color.g + color.b) / 3
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    private func hasInk(_ image: RenderedImage, in rect: CGRect) -> Bool {
        image.containsNonBackgroundPixels(in: rect, background: .clear, tolerance: 0.1)
    }

    /// An opaque, orange-hued pixel: SwiftUI's `.orange` is roughly (1.0, 0.58, 0.0) in light and (1.0, 0.62, 0.04) in dark.
    private func hasOrangePixel(_ image: RenderedImage, in rect: CGRect) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let color = image.color(atX: x, y: y)
                if color.a > 0.8, color.r > 0.85, color.g > 0.4, color.g < 0.75, color.b < 0.3 { return true }
            }
        }
        return false
    }

    // MARK: - Empty state

    func test_installedSection_withNoExtensions_rendersTheEmptyStateText() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 80)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = "appearance \(appearance.rawValue)"
            let rendered = render(Self.installedSection(extensions: []), size: size, appearance: appearance)
            assertDimensions(rendered, size, label)

            // "No extensions installed." at 12pt is one line, about 140pt wide, at the top left of the canvas
            guard let box = rendered.boundingBoxOfContent() else {
                XCTFail("\(label): the empty-state text painted nothing.")
                continue
            }
            XCTAssertLessThanOrEqual(box.minX, 2, "\(label): text starts at the left edge, got \(box)")
            XCTAssertLessThanOrEqual(box.minY, 4, "\(label): text starts at the top, got \(box)")
            XCTAssertLessThanOrEqual(box.height, 20, "\(label): a single line of 12pt text, got \(box)")
            XCTAssertGreaterThan(box.width, 100, "\(label): the sentence is wider than a stray glyph, got \(box)")
            XCTAssertLessThan(box.width, 200, "\(label): the sentence is not wider than its 24 characters, got \(box)")

            // secondary text is light on dark and dark on light
            let brightness = inkBrightness(rendered, in: box)
            if appearance == .darkAqua {
                XCTAssertGreaterThan(brightness ?? -1, 0.6, "\(label): secondary text reads light in the dark appearance")
            } else {
                XCTAssertLessThan(brightness ?? 2, 0.4, "\(label): secondary text reads dark in the light appearance")
            }
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
        let size = CGSize(width: 420, height: 60)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = "appearance \(appearance.rawValue)"
            let rendered = render(Self.row(ext: Self.makeExtension()), size: size, appearance: appearance)
            assertDimensions(rendered, size, label)

            // the row is a 28pt icon at the left, the name and version beside it, then a toggle and a Remove button against the right edge
            guard let box = rendered.boundingBoxOfContent() else {
                XCTFail("\(label): the row painted nothing")
                continue
            }
            XCTAssertLessThanOrEqual(box.minX, 10, "\(label): the icon sits at the left edge, got \(box)")
            XCTAssertGreaterThanOrEqual(box.maxX, 410, "\(label): the Remove button sits against the right edge, got \(box)")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 0, y: 4, width: 30, height: 28)), "\(label): the extension icon is drawn")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 38, y: 4, width: 100, height: 15)), "\(label): the name is drawn beside the icon")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 38, y: 20, width: 60, height: 12)), "\(label): the version line is drawn under the name")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 370, y: 4, width: 45, height: 28)), "\(label): the Remove button is drawn")
            XCTAssertFalse(hasInk(rendered, in: CGRect(x: 200, y: 4, width: 90, height: 28)), "\(label): the Spacer leaves the middle of the row empty")
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
        let size = CGSize(width: 460, height: 60)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = "appearance \(appearance.rawValue)"
            let rendered = render(ExtensionPendingChangesBanner(lastError: nil, onRestart: {}), size: size, appearance: appearance)
            assertDimensions(rendered, size, label)

            // an orange icon at the left, one line of message, a Spacer, then the Restart Orbit button against the right edge
            guard let box = rendered.boundingBoxOfContent() else {
                XCTFail("\(label): the banner painted nothing")
                continue
            }
            XCTAssertTrue(hasOrangePixel(rendered, in: CGRect(x: 0, y: 0, width: 24, height: size.height)), "\(label): the icon is drawn in orange")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 30, y: 0, width: 200, height: size.height)), "\(label): the message is drawn")
            XCTAssertFalse(hasInk(rendered, in: CGRect(x: 280, y: 0, width: 40, height: size.height)), "\(label): the Spacer leaves the middle empty")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 380, y: 0, width: 75, height: size.height)), "\(label): the Restart Orbit button is drawn")
            XCTAssertGreaterThanOrEqual(box.maxX, 450, "\(label): the button sits against the right edge, got \(box)")
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
            "WebKit's own load failure (lastError set) rendered identically to the plain 'not running yet' message — the banner is not showing the real error."
        )
    }

    // MARK: - No engine yet

    func test_engineStartingNotice_paintsNonBlankContent_inBothAppearances() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 60)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = "appearance \(appearance.rawValue)"
            let rendered = render(ExtensionsEngineStartingNotice(), size: size, appearance: appearance)
            assertDimensions(rendered, size, label)

            // a small spinner at the left, then one line of sentence, then a Spacer to the right edge
            guard let box = rendered.boundingBoxOfContent() else {
                XCTFail("\(label): the no-engine notice painted nothing, so the pane's only pre-engine state is blank.")
                continue
            }
            XCTAssertLessThanOrEqual(box.minX, 4, "\(label): the spinner sits at the left edge, got \(box)")
            XCTAssertLessThan(box.maxX, size.width - 40, "\(label): the sentence does not run to the right edge, got \(box)")
            XCTAssertGreaterThan(box.width, 200, "\(label): spinner plus the full sentence, got \(box)")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 0, y: 0, width: 16, height: size.height)), "\(label): the spinner is drawn")
            XCTAssertTrue(hasInk(rendered, in: CGRect(x: 30, y: 0, width: 200, height: size.height)), "\(label): the sentence is drawn")
            XCTAssertFalse(hasInk(rendered, in: CGRect(x: size.width - 40, y: 0, width: 40, height: size.height)), "\(label): nothing is drawn at the right edge")
        }
    }

    func test_engineStartingNotice_rendersDifferentlyFromTheEmptyInstalledList() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 60)
        let notice = render(ExtensionsEngineStartingNotice(), size: size, appearance: .darkAqua)
        let emptyList = render(Self.installedSection(extensions: []), size: size, appearance: .darkAqua)
        XCTAssertTrue(
            Self.rendersDiffer(notice, emptyList, size: size),
            "\"WebKit isn't running yet\" rendered identically to \"No extensions installed.\" — the two states must not be confusable, since only one of them means the user has nothing installed."
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
