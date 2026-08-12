import AppKit
import SwiftUI

@MainActor
enum SiteSearchTintResolver {

    // fromFavicon: a host resolved from the deterministic fallback is re-checked on every call so the chip picks up the real brand colour the moment its favicon lands.
    private struct Entry {
        var tint: CommandRowTint
        var fromFavicon: Bool
    }

    private static var cache: [String: Entry] = [:]

    static func tint(forHost host: String) -> CommandRowTint {
        let key = host.lowercased()
        if let entry = cache[key], entry.fromFavicon { return entry.tint }

        if let favicon = AppEnvironment.processRoot.faviconCache.cachedImage(forHost: host),
           let color = dominantColor(of: favicon) {
            let tint = makeTint(from: color)
            cache[key] = Entry(tint: tint, fromFavicon: true)
            return tint
        }

        if let entry = cache[key] { return entry.tint }

        let generated = FaviconCache.fallbackIcon(forHost: host, size: 32)
        let color = dominantColor(of: generated) ?? .systemGray
        let tint = makeTint(from: color)
        cache[key] = Entry(tint: tint, fromFavicon: false)
        return tint
    }

    private static func makeTint(from color: NSColor) -> CommandRowTint {
        CommandRowTint(fill: Color(nsColor: color), foreground: Color(nsColor: contrastingForeground(for: color)))
    }

    private static func contrastingForeground(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1.0) : .white
    }

    // Skips near-transparent and near-white pixels: a favicon is overwhelmingly a mark on a white/transparent field, and averaging one flat would hand back unusable white.
    private static func dominantColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var totalRed = 0.0
        var totalGreen = 0.0
        var totalBlue = 0.0
        var counted = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            // premultipliedLast: stored bytes are component * alpha, so un-premultiply before judging the colour.
            guard alpha > 0.5 else { continue }
            let red = Double(pixels[index]) / 255 / alpha
            let green = Double(pixels[index + 1]) / 255 / alpha
            let blue = Double(pixels[index + 2]) / 255 / alpha
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            guard luminance < 0.9 else { continue }
            totalRed += red
            totalGreen += green
            totalBlue += blue
            counted += 1
        }

        guard counted > 0 else { return nil }
        return NSColor(
            srgbRed: min(1, totalRed / counted),
            green: min(1, totalGreen / counted),
            blue: min(1, totalBlue / counted),
            alpha: 1
        )
    }
}
