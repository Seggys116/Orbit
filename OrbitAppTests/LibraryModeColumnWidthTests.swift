import SwiftUI
import XCTest
@testable import Orbit

// Real NSWindow pixels: ImageRenderer does not paint content inside a real SwiftUI ScrollView.
@MainActor
final class LibraryModeColumnWidthTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
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

    private func hostLibraryWindow(size: CGSize) -> NSWindow {
        let rootView = LibraryModeView(router: env.libraryRouter)
            .environment(\.libraryStyle, LibraryStyle(theme: SpaceTheme()))
            .orbitEnvironment(env)
        let hostView = NSHostingView(rootView: rootView)
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
        let window = hostLibraryWindow(size: size)
        pump(seconds: 0.2)
        window.displayIfNeeded()
        guard let bitmap = captureBitmap(of: window) else { return nil }
        return RenderedImage(bitmap: bitmap, pointSize: size, scale: window.backingScaleFactor)
    }

    // Rightmost pixel differing from a known-empty sample, above AA noise.
    private func rightmostInk(in image: RenderedImage, xRange: Range<Int>, yRange: Range<Int>, background: RGBA, tolerance: Double = 0.15) -> Int? {
        var maxX: Int?
        for y in yRange {
            for x in xRange where !image.color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                if maxX == nil || x > maxX! { maxX = x }
            }
        }
        return maxX
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aRunningDownloadsCancelControlSitsAtTheColumnsRightEdge

    // Cancel sits at the row's trailing edge, so the list must span the whole column, not a narrower inner width.
    func test_aRunningDownloadsCancelControlSitsAtTheColumnsRightEdge() throws {
        let item = env.addDownload(
            sourceURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("LibraryModeColumnWidthTests-\(UUID().uuidString).zip"),
            suggestedFileName: "file.zip",
            mimeType: "application/zip",
            totalBytes: 100
        )
        env.updateDownload(id: item.id, progress: DownloadProgress(receivedBytes: 40, totalBytes: 100, state: .inProgress))
        defer { env.downloadStore.remove(item.id) }

        env.libraryRouter.selectedSection = .downloads
        env.libraryRouter.selection = nil
        defer { env.libraryRouter.selection = nil }

        let size = CGSize(width: LibraryModeLayout.baseWidth, height: 520)
        guard let image = capture(size: size) else {
            throw TestStopped("Could not capture this process's own window pixels on this machine.")
        }

        let columnLeft = Int(LibraryModeMetrics.railWidth) + 1
        // Below the rows, inside the column: empty in every layout.
        let background = image.color(atX: columnLeft + 6, y: Int(size.height) - 60)
        let ink = rightmostInk(
            in: image,
            xRange: columnLeft..<(Int(size.width) - 10),
            yRange: 80..<(Int(size.height) - 10),
            background: background
        )

        guard let ink else {
            XCTFail("No download row content was found at all, so the test precondition is broken, not the layout under test.")
            return
        }
        XCTAssertGreaterThan(
            ink, Int(size.width) - 40,
            "The running download's Cancel control stopped at x=\(ink) of \(Int(size.width)): the list is not using the full column width."
        )
    }
}
