import AppKit
import XCTest
@testable import Orbit

// tearDown shuts down the demo environment's own engine; the shared live engine is never touched.
@MainActor
// Excluded on GitHub-hosted runners: hosts a real window and starts a real engine.
final class DockMenuNewTabTests: XCTestCase {

    private var scratchEnv: AppEnvironment?
    private var previousProcessRoot: AppEnvironment?
    private var previousCommandDispatch: ((_ extensionID: String, _ name: String) -> Bool)?

    private func closeAllOpenWindows() {
        for env in OrbitWindowController.openEnvironments {
            OrbitWindowController.controller(for: env)?.window?.close()
        }
    }

    override func setUp() {
        super.setUp()
        closeAllOpenWindows()
        // Scoped to a throwaway demo environment, not .shared, so the engine cannot bleed out.
        previousProcessRoot = AppEnvironment.processRoot
        previousCommandDispatch = ExtensionCommandRegistry.shared.dispatch
        let env = AppEnvironment.demo
        scratchEnv = env
        AppEnvironment.processRoot = env
    }

    override func tearDown() {
        closeAllOpenWindows()
        _ = scratchEnv?.shutdownEngine()
        scratchEnv = nil
        ExtensionCommandRegistry.shared.dispatch = previousCommandDispatch
        previousCommandDispatch = nil
        if let previousProcessRoot { AppEnvironment.processRoot = previousProcessRoot }
        super.tearDown()
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_newTabDockItem_withNoWindowOpen_opensARealWindow

    func test_newTabDockItem_withNoWindowOpen_opensARealWindow() throws {
        XCTAssertTrue(OrbitWindowController.openEnvironments.isEmpty, "test precondition: no window is open")

        let menu = OrbitAppDelegate.buildDockMenu()
        guard let newTabItem = menu.items.first(where: { $0.title == "New Tab" }) else {
            return XCTFail("test precondition: the dock menu has no 'New Tab' item")
        }
        guard let action = newTabItem.action else {
            return XCTFail("test precondition: 'New Tab' has no action")
        }

        // The real AppKit dispatch a menu click would use, not calling a Swift method directly.
        NSApp.sendAction(action, to: newTabItem.target, from: newTabItem)

        XCTAssertFalse(
            OrbitWindowController.openEnvironments.isEmpty,
            "The dock menu's New Tab item's own precondition (OrbitWindowController.activateBrowserWindow()) must open a window when none exists — invoking the item's real action left none open."
        )
    }
}

@MainActor
final class DockDownloadProgressTests: XCTestCase {

    private func renderDock(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func attach(_ rep: NSBitmapImageRep, named name: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDockBarFillsInProportionToTheCombinedProgress() throws {
        let icon = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(white: 0.5, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let view = DockProgressIconView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.icon = icon

        func fillWidth(at fraction: Double?) throws -> Int {
            view.fraction = fraction
            let rep = try renderDock(view)
            let scale: CGFloat = CGFloat(rep.pixelsWide) / 128
            let lowerBar: CGFloat = 128 * 0.1 + 128 * 0.105 * 0.3
            let y = Int(lowerBar * scale)
            let reference = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            var count = 0
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - reference.redComponent) < 0.12,
                   abs(pixel.greenComponent - reference.greenComponent) < 0.12,
                   abs(pixel.blueComponent - reference.blueComponent) < 0.12 { count += 1 }
            }
            return count
        }

        let none = try fillWidth(at: 0)
        let half = try fillWidth(at: 0.5)
        let full = try fillWidth(at: 1)
        XCTAssertGreaterThan(half, none + 20, "half progress must paint clearly more of the bar than none")
        XCTAssertGreaterThan(full, half + 20, "full progress must paint clearly more than half")
        XCTAssertEqual(Double(half) / Double(full), 0.5, accuracy: 0.12, "the filled width tracks the fraction")

        view.fraction = 0.62
        attach(try renderDock(view), named: "dock-62-percent")
        view.fraction = nil
        view.sweepPhase = 0.5
        attach(try renderDock(view), named: "dock-unknown-size")
    }

    func testTheDockTileFollowsTheStoreFromFirstByteToCompletion() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DockDownloadProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tile = NSApp.dockTile
        defer {
            tile.contentView = nil
            tile.badgeLabel = nil
        }
        let store = DownloadStore(fileURL: scratch.appendingPathComponent("downloads.json"))
        let dock = DockDownloadProgress(store: store, tile: tile)
        withExtendedLifetime(dock) {
            XCTAssertNil(tile.contentView, "nothing is downloading, so the Dock shows the plain app icon")

            let first = store.beginDownload(sourceURL: URL(string: "https://example.com/a.zip")!, destinationURL: scratch.appendingPathComponent("a.zip"), suggestedFileName: "a.zip", totalBytes: 100)
            XCTAssertTrue(tile.contentView is DockProgressIconView, "a download in flight puts the progress bar on the icon")
            XCTAssertNil(tile.badgeLabel, "one download needs no count")

            let second = store.beginDownload(sourceURL: URL(string: "https://example.com/b.zip")!, destinationURL: scratch.appendingPathComponent("b.zip"), suggestedFileName: "b.zip", totalBytes: 100)
            XCTAssertEqual(tile.badgeLabel, "2")

            store.updateProgress(id: first.id, progress: DownloadProgress(receivedBytes: 100, totalBytes: 100, state: .inProgress))
            store.updateProgress(id: second.id, progress: DownloadProgress(receivedBytes: 50, totalBytes: 100, state: .inProgress))
            XCTAssertEqual((tile.contentView as? DockProgressIconView)?.fraction, 0.75)

            store.updateProgress(id: first.id, progress: DownloadProgress(receivedBytes: 100, totalBytes: 100, state: .completed))
            XCTAssertNil(tile.badgeLabel, "back to one running download")

            store.updateProgress(id: second.id, progress: DownloadProgress(receivedBytes: 100, totalBytes: 100, state: .completed))
            XCTAssertNil(tile.contentView, "the bar is gone once nothing is downloading")
            XCTAssertNil(tile.badgeLabel)
        }
    }
}
