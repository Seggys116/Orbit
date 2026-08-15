import SwiftUI
import XCTest
@testable import Orbit

// Real NSWindow pixels: ImageRenderer does not paint content inside a real SwiftUI ScrollView.
@MainActor
final class LibraryRootViewWidthTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func resetRouter(section: LibrarySection, selection: LibrarySelection?) {
        LibraryRouter.shared.selectedSection = section
        LibraryRouter.shared.selection = selection
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// dlsym, not a direct call: obsoleted in the macOS 15 SDK but the symbol is still live.
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

    private func hostRealLibraryWindow(size: CGSize) -> NSWindow {
        let hostView = NSHostingView(rootView: LibraryRootView().orbitEnvironment(env))
        hostView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        self.window = window
        return window
    }

    private func capture(size: CGSize) -> RenderedImage? {
        let window = hostRealLibraryWindow(size: size)
        pump(seconds: 0.2)
        window.displayIfNeeded()
        guard let bitmap = captureBitmap(of: window) else { return nil }
        return RenderedImage(bitmap: bitmap, pointSize: size, scale: window.backingScaleFactor)
    }

    // Rightmost pixel differing from a known-empty sample, above the card tint and AA noise.
    private func rightmostInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.15) -> Int? {
        var maxX: Int?
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                if maxX == nil || x > maxX! { maxX = x }
            }
        }
        return maxX
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_downloadRowExtendsNearTheWindowsRightEdgeWhenNothingIsSelected

    // Fixed: content reaches x≈1219 of 1257. Regressed: it stops at x≈612.
    func test_downloadRowExtendsNearTheWindowsRightEdgeWhenNothingIsSelected() throws {
        let item = env.addDownload(
            sourceURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRootViewWidthTests-\(UUID().uuidString).zip"),
            suggestedFileName: "file.zip",
            mimeType: "application/zip",
            totalBytes: 100
        )
        env.updateDownload(id: item.id, progress: DownloadProgress(receivedBytes: 100, totalBytes: 100, state: .completed))
        defer { env.downloadStore.remove(item.id) }

        resetRouter(section: .downloads, selection: nil)
        defer { resetRouter(section: .downloads, selection: nil) }

        let size = CGSize(width: LibraryMetrics.windowDefaultWidth, height: LibraryMetrics.windowDefaultHeight)
        guard let image = capture(size: size) else {
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
        }

        // Well inside the list's own horizontal padding margin, below the header: guaranteed
        // empty in both the fixed and regressed layouts.
        let background = image.color(atX: Int(LibraryMetrics.navWidth) + 6, y: Int(size.height) - 60)
        // Excludes a 10pt margin at the window's own physical edges, which real (rounded-corner)
        // window capture can antialias against whatever is behind the window on the desktop.
        let ink = rightmostInk(
            in: image,
            xRange: (Int(LibraryMetrics.navWidth) + 1)..<(Int(size.width) - 10),
            yRange: 60..<(Int(size.height) - 10),
            background: background
        )

        guard let ink else {
            XCTFail("No download row content was found at all — test precondition is broken, not the fix under test.")
            return
        }
        XCTAssertGreaterThan(
            ink, Int(size.width) - 150,
            "The download row's own content must reach near the window's right edge when nothing is selected — its rightmost content stopped at x=\(ink) of \(Int(size.width)), meaning the list is still squeezed into the narrow preview-mode column width instead of using the full window."
        )
    }
}
