import AppKit
import CoreGraphics
import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum FolderToggleCrashProbe {

    static func runIfEnabled() {
        guard isEnabled else { return }
        Task { await run() }
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORBIT_FOLDER_TOGGLE_PROBE"] == "1"
    }

    private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_FOLDER_TOGGLE_PROBE_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var failures: [String] = []

    // Not a real SF Symbol: Image(systemName:) draws nothing at all for it.
    private static let unresolvableSymbolName = "rocket"

    // MARK: - The run

    private static func run() async {
        await settle(2.0)
        let env = AppEnvironment.demoApp

        guard let window = NSApp.windows.first(where: { $0 is OrbitBorderlessWindow }) else {
            fail("no browser window — nothing to probe.")
            finish()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle(0.5)

        guard let space = env.activeSpace else {
            fail("no active Space.")
            finish()
            return
        }
        env.isSidebarVisible = true

        let defaultFolderID = env.createFolder(name: "Probe Default", in: space.id)
        let emojiFolderID = env.createFolder(name: "Probe Emoji", in: space.id)
        env.setFolderIcon("🔥", isEmoji: true, forFolder: emojiFolderID, in: space.id)
        let symbolFolderID = env.createFolder(name: "Probe Symbol", in: space.id)
        env.setFolderIcon("tray.full", isEmoji: false, forFolder: symbolFolderID, in: space.id)
        // setFolderIcon directly, not FolderIconInput.resolve(typed:), to reproduce what an
        // older build or a synced state.json can store without passing through validation.
        let unresolvableFolderID = env.createFolder(name: "Probe Bad Symbol", in: space.id)
        env.setFolderIcon(unresolvableSymbolName, isEmoji: false, forFolder: unresolvableFolderID, in: space.id)

        await settle(1.0)

        emit("folders created: default=\(defaultFolderID) emoji=\(emojiFolderID) symbol=\(symbolFolderID) unresolvable=\(unresolvableFolderID)")
        emit("\"\(unresolvableSymbolName)\" resolves to a real SF Symbol: \(NSImage(systemSymbolName: unresolvableSymbolName, accessibilityDescription: nil) != nil) (expected false)")

        await captureAndReport(window: window, name: "01-before-any-toggle")

        checkGlyphColumnNonEmpty(window: window, label: "before-toggle")
        assertEveryFolderGlyphSlotHasInk(window: window, label: "before-toggle")

        for round in 1...3 {
            emit("round \(round): toggling default folder")
            env.toggleFolderExpanded(defaultFolderID, in: space.id)
            await settle(0.6)
            await captureAndReport(window: window, name: "02-round\(round)-default-toggled")
            checkGlyphColumnNonEmpty(window: window, label: "round\(round)-default")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "round\(round)-default")

            emit("round \(round): toggling emoji folder")
            env.toggleFolderExpanded(emojiFolderID, in: space.id)
            await settle(0.6)
            await captureAndReport(window: window, name: "03-round\(round)-emoji-toggled")
            checkGlyphColumnNonEmpty(window: window, label: "round\(round)-emoji")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "round\(round)-emoji")

            emit("round \(round): toggling symbol folder")
            env.toggleFolderExpanded(symbolFolderID, in: space.id)
            await settle(0.6)
            await captureAndReport(window: window, name: "04-round\(round)-symbol-toggled")
            checkGlyphColumnNonEmpty(window: window, label: "round\(round)-symbol")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "round\(round)-symbol")

            emit("round \(round): toggling unresolvable-symbol folder")
            env.toggleFolderExpanded(unresolvableFolderID, in: space.id)
            await settle(0.6)
            await captureAndReport(window: window, name: "06-round\(round)-badsymbol-toggled")
            checkGlyphColumnNonEmpty(window: window, label: "round\(round)-badsymbol")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "round\(round)-badsymbol")
        }

        emit("enumerating click-catcher views in the live window")
        let allCatchers = collectClickCatchers(in: window)
        emit("found \(allCatchers.count) OrbitActionButtonClickCatchingView instance(s) total")

        // Folder-toggle catchers are the ones framed at sidebarFolderToggleSize (15x15);
        // sorted by descending y (bottom-left origin), the last four are this probe's own folders.
        let toggleCatchers = allCatchers
            .filter { $0.0.width == OrbitMetrics.sidebarFolderToggleSize && $0.0.height == OrbitMetrics.sidebarFolderToggleSize }
            .sorted { $0.0.origin.y > $1.0.origin.y }
        emit("found \(toggleCatchers.count) folder-toggle-sized (15x15) catcher(s):")
        for (frame, _) in toggleCatchers { emit("  frame=\(frame)") }

        let probeCatchers = Array(toggleCatchers.suffix(4))
        guard probeCatchers.count == 4 else {
            fail("expected exactly 4 folder-toggle catchers for the probe's own folders (Probe Default/Emoji/Symbol/Bad Symbol), found \(probeCatchers.count) of \(toggleCatchers.count) total. Not clicking anything, to avoid hitting the wrong control.")
            finish()
            return
        }

        for round in 1...3 {
            emit("real-click round \(round): clicking each probe folder's real toggle NSView via window.sendEvent")
            for (frame, view) in probeCatchers {
                clickViaRealEvent(window: window, view: view, frameInWindow: frame)
                await settle(0.4)
            }
            await captureAndReport(window: window, name: "05-realclick-round\(round)")
            checkGlyphColumnNonEmpty(window: window, label: "realclick-round\(round)")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "realclick-round\(round)")
        }

        // The phase that reproduces the actual reported crash: FolderHoverPreviewView/Row read
        // @Environment(AppEnvironment.self) but the popover's detached NSHostingController
        // inherited none, trapping the first time that content genuinely laid out.
        await presentRealFolderPreviewAndToggleUnderneath(
            window: window,
            env: env,
            spaceID: space.id,
            folderID: fixtureFolderID(in: env, spaceID: space.id) ?? defaultFolderID,
            toggleCatchers: probeCatchers
        )

        emit("PROBE DONE — survived 3 rounds of direct-call toggling, 3 rounds of real AppKit-dispatched clicks on all four probe folders, and a real folder hover preview presented on screen and then toggled underneath, without crashing.")
        finish()
    }

    private static func fixtureFolderID(in env: AppEnvironment, spaceID: SpaceID) -> FolderID? {
        for node in env.pinnedNodes(in: spaceID) {
            if case .folder(let folder) = node, !folder.children.isEmpty { return folder.id }
        }
        return nil
    }

    private static func presentRealFolderPreviewAndToggleUnderneath(
        window: NSWindow,
        env: AppEnvironment,
        spaceID: SpaceID,
        folderID: FolderID,
        toggleCatchers: [(CGRect, NSView)]
    ) async {
        let state = FolderPreviewState.make(
            folderID: folderID,
            in: env.pinnedNodes(in: spaceID),
            resolveTab: env.tab
        )
        guard let state, state.hasContent else {
            fail("could not build a FolderPreviewState with content for folder \(folderID) — the hover-preview phase cannot run, so the reported crash would not be exercised.")
            return
        }
        emit("hover-preview phase: built a real FolderPreviewState \"\(state.title)\" with \(state.allPossibleChildren.count) item(s)")

        let host = NSHostingView(
            rootView: FolderHoverPreviewProbeHost(env: env, state: state)
        )
        host.frame = NSRect(x: 40, y: window.frame.height / 2, width: 220, height: OrbitMetrics.sidebarRowHeight)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        await settle(1.0)

        let popovers = NSApp.windows.filter { "\(type(of: $0))".contains("Popover") && $0.isVisible }
        guard let popover = popovers.first else {
            fail("the real folder hover preview did not present at all — no popover window on screen. Nothing about the reported crash was exercised.")
            host.removeFromSuperview()
            return
        }
        emit("hover-preview phase: a real NSPopover is on screen (\(popover.frame)) and its content rendered without trapping")

        if let contentView = popover.contentView {
            emit("hover-preview phase: popover content view is \(type(of: contentView)) sized \(contentView.bounds.size)")
            if contentView.bounds.width < 10 || contentView.bounds.height < 10 {
                fail("the folder hover preview presented but its content is \(contentView.bounds.size) — effectively nothing was rendered.")
            }
        } else {
            fail("the folder hover preview's popover has no content view.")
        }

        await captureAndReport(window: window, name: "07-hover-preview-presented")

        for round in 1...2 {
            emit("hover-preview phase: real-click round \(round) on every folder toggle while the preview is showing")
            for (frame, view) in toggleCatchers {
                clickViaRealEvent(window: window, view: view, frameInWindow: frame)
                await settle(0.3)
            }
            await captureAndReport(window: window, name: "08-hover-preview-toggle-round\(round)")
            assertEveryFolderGlyphSlotHasInk(window: window, label: "hover-preview-toggle-round\(round)")
        }

        emit("hover-preview phase: survived toggling folders with a real hover preview on screen")
        host.removeFromSuperview()
        await settle(0.3)
    }

    // MARK: - Real click dispatch

    private static func collectClickCatchers(in window: NSWindow) -> [(CGRect, NSView)] {
        guard let root = window.contentView else { return [] }
        var results: [(CGRect, NSView)] = []
        func walk(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("OrbitActionButtonClickCatchingView") {
                let frame = view.convert(view.bounds, to: nil)
                results.append((frame, view))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return results
    }

    // Full AppKit dispatch through window.sendEvent, not a direct view.mouseDown(with:) call.
    private static func clickViaRealEvent(window: NSWindow, view: NSView, frameInWindow: CGRect) {
        let point = CGPoint(x: frameInWindow.midX, y: frameInWindow.midY)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            fail("could not construct a synthesized mouseDown for frame \(frameInWindow).")
            return
        }
        window.sendEvent(down)
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ) else {
            fail("could not construct a synthesized mouseUp for frame \(frameInWindow).")
            return
        }
        window.sendEvent(up)
    }

    // MARK: - Checks

    private static func checkGlyphColumnNonEmpty(window: NSWindow, label: String) {
        guard let image = capture(window: window) else {
            fail("\(label): capture failed, cannot check glyph column.")
            return
        }
        guard let bytes = rgbaBytes(of: image) else {
            fail("\(label): could not read back pixel bytes.")
            return
        }
        let width = image.width
        let height = image.height
        guard width > 40, height > 100 else {
            fail("\(label): captured image too small to inspect (\(width)x\(height)).")
            return
        }
        var nonBackgroundCount = 0
        let bandWidth = min(width, Int(Double(width) * 0.12))
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: bandWidth, by: 2) {
                let index = (y * width + x) * 4
                guard index + 3 < bytes.count else { continue }
                let r = bytes[index], g = bytes[index + 1], b = bytes[index + 2]
                if !(r < 12 && g < 12 && b < 12) {
                    nonBackgroundCount += 1
                }
            }
        }
        emit("\(label): \(nonBackgroundCount) non-near-black samples in the left sidebar band (\(bandWidth)x\(height) at stride 2) — informational, not a hard failure (the sidebar background itself is rarely pure black).")
    }

    // "Blank" is luminance contrast within the glyph's own box, not a comparison to a fixed
    // background colour: the sidebar background is a gradient with no single value to compare against.
    private static func assertEveryFolderGlyphSlotHasInk(window: NSWindow, label: String) {
        guard let image = capture(window: window) else {
            fail("\(label): capture failed, cannot check folder glyph slots.")
            return
        }
        guard let bytes = rgbaBytes(of: image) else {
            fail("\(label): could not read back pixel bytes for the glyph-slot check.")
            return
        }
        let slots = collectClickCatchers(in: window)
            .filter { $0.0.width == OrbitMetrics.sidebarFolderToggleSize && $0.0.height == OrbitMetrics.sidebarFolderToggleSize }
            .sorted { $0.0.origin.y > $1.0.origin.y }
        guard !slots.isEmpty else {
            fail("\(label): found no folder-toggle glyph slots on screen at all — nothing to check.")
            return
        }

        let windowHeight = window.contentView?.bounds.height ?? window.frame.height
        let scale = CGFloat(image.height) / windowHeight

        for (frame, _) in slots {
            let originX = Int((frame.minX * scale).rounded())
            let originY = Int(((windowHeight - frame.maxY) * scale).rounded())
            let side = Int((frame.width * scale).rounded())
            var minLuma = 1.0
            var maxLuma = 0.0
            var sampled = 0
            for y in originY..<(originY + side) {
                for x in originX..<(originX + side) {
                    guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                    let index = (y * image.width + x) * 4
                    guard index + 3 < bytes.count else { continue }
                    let r = Double(bytes[index]) / 255
                    let g = Double(bytes[index + 1]) / 255
                    let b = Double(bytes[index + 2]) / 255
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    minLuma = min(minLuma, luma)
                    maxLuma = max(maxLuma, luma)
                    sampled += 1
                }
            }
            guard sampled > 0 else {
                fail("\(label): glyph slot at \(frame) mapped entirely outside the captured image — the point-to-pixel mapping is wrong, not the glyph.")
                continue
            }
            let contrast = maxLuma - minLuma
            emit("\(label): glyph slot at \(frame) — luminance contrast \(String(format: "%.3f", contrast)) over \(sampled) pixels")
            if contrast < 0.08 {
                fail(
                    "\(label): the folder glyph slot at \(frame) is BLANK on screen — luminance contrast " +
                    "\(String(format: "%.3f", contrast)) across \(sampled) real, composited pixels, i.e. nothing but " +
                    "background gradient where a glyph should be. This is the user's \"i dont see the folder glyph " +
                    "or the one set its just blank\" report."
                )
            }
        }
    }

    private static func captureAndReport(window: NSWindow, name: String) async {
        guard let image = await DemoCaptureDriver.captureAtBackingScale(of: window) else {
            fail("\(name): capture returned nothing.")
            return
        }
        dump(image, named: name)
    }

    // MARK: - Plumbing

    private static func dump(_ image: CGImage, named name: String) {
        guard let directory = outputDirectory else { return }
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            emit("wrote \(url.path) (\(image.width)x\(image.height))")
        }
    }

    private static func capture(window: NSWindow) -> CGImage? {
        DemoCaptureDriver.capture(window: window)
    }

    private static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let success: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? buffer : nil
    }

    private static func fail(_ message: String) {
        failures.append(message)
        emit("FAIL \(message)")
    }

    private static func finish() {
        if failures.isEmpty {
            emit("VERDICT: PASS")
            NSApp.terminate(nil)
            exit(0)
        } else {
            for failure in failures { emit("FAIL: \(failure)") }
            emit("VERDICT: FAIL — \(failures.count) check(s) failed.")
            exit(1)
        }
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("FolderToggleCrashProbe: \(message)\n".utf8))
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - The hover preview, presented through the real production modifier

// Trigger is a plain true, not a dwell timer: this environment has no Accessibility grant, and
// SwiftUI's .onHover resolves against the real cursor position, which synthesized events don't drive.
@MainActor
private struct FolderHoverPreviewProbeHost: View {
    var env: AppEnvironment
    var state: FolderPreviewState

    var body: some View {
        Color.clear
            .frame(width: 220, height: OrbitMetrics.sidebarRowHeight)
            .orbitHoverPopover(isPresented: .constant(true), preferredEdge: .maxX) {
                FolderHoverPreviewView(state: state) { _ in }
            }
            .orbitEnvironment(env)
    }
}
