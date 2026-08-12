// Regression guard: a live, mounted PinnedFolderRowView must survive repeated real
// clicks without crashing or blanking ("CLICKING THE FOLDER TOGGLE CRASHES THE APP").

import XCTest
import SwiftUI
import AppKit

@MainActor
final class FolderToggleGlyphRegressionGuardTests: XCTestCase {

    // MARK: - Guard 1: the toggle stays an OrbitNSActionButton

    func test_pinnedFolderRowToggle_staysAnOrbitNSActionButton_neverAPlainButton() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/UI/Sidebar/TabRowView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)

        guard let structIndex = lines.firstIndex(where: { $0.contains("struct PinnedFolderRowView") }) else {
            XCTFail("Could not find `struct PinnedFolderRowView` in \(url.path) — has it moved or been renamed? Update this guard if so.")
            return
        }
        let searchLines = lines[structIndex...]
        guard let glyphCallSiteOffset = searchLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "folderGlyph" }) else {
            XCTFail("Could not find the bare `folderGlyph` call site inside `PinnedFolderRowView`.")
            return
        }
        var wrapperLine: String?
        var index = glyphCallSiteOffset
        while index > structIndex {
            let line = lines[index]
            if line.contains("OrbitNSActionButton(action:") {
                wrapperLine = line
                break
            }
            if line.contains("Button(action:") {
                wrapperLine = line
                break
            }
            index -= 1
        }

        guard let wrapperLine else {
            XCTFail("Could not find the control wrapping PinnedFolderRowView's folderGlyph toggle in \(url.path).")
            return
        }
        XCTAssertTrue(
            wrapperLine.contains("OrbitNSActionButton(action:"),
            "PinnedFolderRowView's folder-glyph toggle must be wrapped in OrbitNSActionButton (a real, frontmost " +
            "AppKit NSView), never a plain SwiftUI Button — a plain Button here has repeatedly shipped dead in " +
            "this app's hosting configuration (see OrbitNSActionButton.swift's own header). Found: \"\(wrapperLine.trimmingCharacters(in: .whitespaces))\"."
        )
    }

    // MARK: - Guard 2: the glyph column is the same width in every configuration

    private func makeEnv() -> AppEnvironment { AppEnvironment() }

    private func makeSpace(pinned: [SidebarNode]) -> (env: AppEnvironment, spaceID: SpaceID) {
        let env = makeEnv()
        let profile = Profile(name: "Personal")
        let space = Space(name: "Personal", profileID: profile.id, pinned: pinned)
        env.state.profiles = [profile]
        env.state.spaces = [space]
        return (env, space.id)
    }

    func test_folderRowLabel_startsAtTheSameXRegardlessOfGlyphKind() {
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)
        let theme = SpaceTheme()

        func labelLeadingX(icon: String?, isEmoji: Bool) -> CGFloat? {
            let folder = Folder(name: "ZZZZZ", icon: icon, iconIsEmoji: isEmoji)
            let (env, spaceID) = makeSpace(pinned: [.folder(folder)])
            guard let rendered = hostedRender(
                PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: theme, depth: 0).environment(env),
                size: size
            ) else { return nil }
            let glyphColumnRight = OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset + OrbitMetrics.sidebarFolderToggleSize
            let scanStart = Int(glyphColumnRight.rounded(.up))
            for x in scanStart..<Int(size.width) {
                for y in 0..<Int(size.height) {
                    if !rendered.color(atX: x, y: y).isApproximately(RGBA.clear, tolerance: 0.06) {
                        return CGFloat(x)
                    }
                }
            }
            return nil
        }

        guard let defaultX = labelLeadingX(icon: nil, isEmoji: false) else {
            XCTFail("Could not find the label's leading edge for the default (no custom icon) folder glyph.")
            return
        }
        guard let emojiX = labelLeadingX(icon: "🔥", isEmoji: true) else {
            XCTFail("Could not find the label's leading edge for a custom emoji folder icon.")
            return
        }
        guard let symbolX = labelLeadingX(icon: "tray.full", isEmoji: false) else {
            XCTFail("Could not find the label's leading edge for a custom SF Symbol folder icon.")
            return
        }

        XCTAssertEqual(
            emojiX, defaultX, accuracy: 3,
            "A folder with a custom emoji icon (\(emojiX)pt) must not shift its label relative to the default " +
            "drawn glyph (\(defaultX)pt) — Finding 1: the glyph column must be the same width regardless of " +
            "custom-icon kind."
        )
        XCTAssertEqual(
            symbolX, defaultX, accuracy: 3,
            "A folder with a custom SF Symbol icon (\(symbolX)pt) must not shift its label relative to the " +
            "default drawn glyph (\(defaultX)pt) — same Finding 1 guarantee, SF Symbol case."
        )
    }

    // MARK: - Guard 3: a live toggle neither crashes nor blanks the glyph

    func test_liveToggle_defaultGlyph_survivesRepeatedRealClicksAndKeepsDrawingContent() async throws {
        try await assertLiveToggleSurvivesRealClicks(icon: nil, isEmoji: false, label: "default")
    }

    func test_liveToggle_customEmojiIcon_survivesRepeatedRealClicksAndKeepsDrawingContent() async throws {
        try await assertLiveToggleSurvivesRealClicks(icon: "🔥", isEmoji: true, label: "emoji")
    }

    func test_liveToggle_customSFSymbolIcon_survivesRepeatedRealClicksAndKeepsDrawingContent() async throws {
        try await assertLiveToggleSurvivesRealClicks(icon: "tray.full", isEmoji: false, label: "SF Symbol")
    }

    private func assertLiveToggleSurvivesRealClicks(icon: String?, isEmoji: Bool, label: String) async throws {
        let size = CGSize(width: 260, height: OrbitMetrics.sidebarRowHeight)
        let theme = SpaceTheme()
        let folder = Folder(name: "Live \(label)", icon: icon, iconIsEmoji: isEmoji)
        let (env, spaceID) = makeSpace(pinned: [.folder(folder)])

        let hosted = LiveReactiveFolderRow(folderID: folder.id, spaceID: spaceID, theme: theme)
            .environment(env)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: hosted)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let catcher = findClickCatcher(in: hostingView) else {
            XCTFail("\(label): could not find the folder row's real OrbitActionButtonClickCatchingView in the live-hosted view tree.")
            return
        }

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ),
            "\(label): could not construct a synthesized mouseDown event."
        )

        for round in 1...5 {
            catcher.mouseDown(with: event)
            try await Task.sleep(nanoseconds: 30_000_000)
            hostingView.layoutSubtreeIfNeeded()
            _ = round
        }

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("\(label): bitmapImageRepForCachingDisplay produced nothing after 5 live toggles.")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        let rendered = RenderedImage(bitmap: rep, pointSize: size, scale: scale)

        guard let box = rendered.boundingBoxOfContent(tolerance: 0.05) else {
            rendered.writeDiagnosticPNG(named: "FolderToggleLiveUpdate-\(label)-FAILED-blank")
            XCTFail(
                "\(label): after 5 live, real-AppKit-dispatched toggles the row drew nothing at all — this is " +
                "the exact \"i dont see the folder glyph or the one set its just blank\" symptom the coordinator " +
                "relayed. See the diagnostic PNG."
            )
            return
        }
        XCTAssertGreaterThan(
            box.width, 20,
            "\(label): after 5 live toggles the row's drawn content (\(box.width)pt wide) is too narrow to be " +
            "more than a bare, possibly-corrupted sliver — expected a real glyph plus the row's label."
        )
    }

    // MARK: - Helpers

    private func findClickCatcher(in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)).contains("OrbitActionButtonClickCatchingView") {
            return root
        }
        for sub in root.subviews {
            if let found = findClickCatcher(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - A minimal, genuinely reactive host for PinnedFolderRowView

@MainActor
private struct LiveReactiveFolderRow: View {
    @Environment(AppEnvironment.self) private var env
    var folderID: FolderID
    var spaceID: SpaceID
    var theme: SpaceTheme

    private var folder: Folder? {
        for node in env.pinnedNodes(in: spaceID) {
            if case .folder(let folder) = node, folder.id == folderID { return folder }
        }
        return nil
    }

    var body: some View {
        if let folder {
            PinnedFolderRowView(folder: folder, spaceID: spaceID, theme: theme, depth: 0)
        }
    }
}

// MARK: - Test-only helper: NSHostingView-based rendering

@MainActor
private func hostedRender<V: View>(_ view: V, size: CGSize, colorScheme: ColorScheme = .dark) -> RenderedImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    let hosted = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, colorScheme)
    let hostingView = NSHostingView(rootView: hosted)
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / size.width
    return RenderedImage(bitmap: rep, pointSize: size, scale: scale)
}
