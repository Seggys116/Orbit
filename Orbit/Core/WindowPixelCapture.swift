//  A dlsym'd CGWindowListCreateImage that reads this process's own window
//  pixels with no Screen Recording grant needed.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum WindowPixelCapture {

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    static func image(of window: NSWindow) -> CGImage? {
        guard let createImage else { return nil }
        let listOptionIncludingWindow: UInt32 = 1 << 3
        let imageBoundsIgnoreFraming: UInt32 = 1 << 0
        let imageBestResolution: UInt32 = 1 << 3
        return createImage(
            .null,
            listOptionIncludingWindow,
            UInt32(bitPattern: Int32(window.windowNumber)),
            imageBoundsIgnoreFraming | imageBestResolution
        )?.takeRetainedValue()
    }

    /// Retries until the capture comes back at the screen's backing scale: a
    /// half-resolution shot means the window is not being composited yet.
    static func atBackingScale(
        of window: NSWindow,
        attempts: Int = 4,
        log: (String) -> Void = { _ in }
    ) async -> CGImage? {
        let wanted = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let expectedWidth = Int(window.frame.width * wanted)

        var last: CGImage?
        for attempt in 1...max(1, attempts) {
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 600_000_000)

            guard let image = image(of: window) else {
                log("CGWindowListCreateImage produced nothing (attempt \(attempt)/\(attempts))")
                return last
            }
            last = image
            if Double(image.width) >= Double(expectedWidth) * 0.9 {
                return image
            }
            log("capture returned \(image.width)px wide for a \(Int(window.frame.width))pt window (attempt \(attempt)/\(attempts)) — retrying")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return last
    }

    static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func moveToBestScreen(_ window: NSWindow) {
        guard let best = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return }
        guard window.screen !== best else { return }
        let frame = window.frame
        let visible = best.visibleFrame
        window.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    static func crop(_ full: CGImage, toWindowRect rectInWindow: CGRect, of window: NSWindow) -> CGImage? {
        let scale = CGFloat(full.width) / window.frame.width
        guard scale > 0 else { return nil }
        let flippedY = window.frame.height - rectInWindow.maxY
        let rect = CGRect(
            x: (rectInWindow.minX * scale).rounded(.down),
            y: (flippedY * scale).rounded(.down),
            width: (rectInWindow.width * scale).rounded(.down),
            height: (rectInWindow.height * scale).rounded(.down)
        ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard rect.width > 8, rect.height > 8 else { return nil }
        return full.cropping(to: rect)
    }

    // MARK: - Measures

    /// Redraws into a known 8-bit RGBA layout: two captures of the same window
    /// are not guaranteed to share a byte order, so comparing raw buffers
    /// directly would compare encodings.
    nonisolated static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
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

    nonisolated static func distinctSampledColours(of image: CGImage) -> Int {
        guard let bytes = rgbaBytes(of: image) else { return 0 }
        var colours = Set<UInt32>()
        let stepX = max(1, image.width / 64)
        let stepY = max(1, image.height / 64)
        for y in stride(from: 0, to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                let offset = (y * image.width + x) * 4
                guard offset + 3 < bytes.count else { continue }
                colours.insert(
                    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
                )
            }
        }
        return colours.count
    }

    nonisolated static func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return .max }
        guard let left = rgbaBytes(of: a), let right = rgbaBytes(of: b) else { return .max }
        var count = 0
        var index = 0
        while index + 3 < left.count {
            let dr = abs(Int(left[index]) - Int(right[index]))
            let dg = abs(Int(left[index + 1]) - Int(right[index + 1]))
            let db = abs(Int(left[index + 2]) - Int(right[index + 2]))
            if dr + dg + db > 24 { count += 1 }
            index += 4
        }
        return count
    }

    /// Share of sampled pixels within `tolerance` of one colour, per channel.
    /// The tolerance absorbs the display's own colour space — an exact match would fail on P3.
    nonisolated static func fractionMatching(
        _ image: CGImage,
        red: Int,
        green: Int,
        blue: Int,
        tolerance: Int
    ) -> Double {
        guard let bytes = rgbaBytes(of: image) else { return 0 }
        let stepX = max(1, image.width / 128)
        let stepY = max(1, image.height / 128)
        var sampled = 0
        var matched = 0
        for y in stride(from: 0, to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                let offset = (y * image.width + x) * 4
                guard offset + 3 < bytes.count else { continue }
                sampled += 1
                if abs(Int(bytes[offset]) - red) <= tolerance,
                   abs(Int(bytes[offset + 1]) - green) <= tolerance,
                   abs(Int(bytes[offset + 2]) - blue) <= tolerance {
                    matched += 1
                }
            }
        }
        guard sampled > 0 else { return 0 }
        return Double(matched) / Double(sampled)
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
