import SwiftUI

// The owning AppEnvironment's cache, injected at every hosting root. The
// default is the process-default cache rather than a real-profile singleton:
// this file is also compiled into OrbitTests, where no AppEnvironment exists.
private struct FaviconCacheKey: EnvironmentKey {
    @MainActor static var defaultValue: FaviconCache { .processDefault }
}

extension EnvironmentValues {
    var faviconCache: FaviconCache {
        get { self[FaviconCacheKey.self] }
        set { self[FaviconCacheKey.self] = newValue }
    }
}

struct FaviconView: View {
    var url: URL?
    var host: String

    var body: some View {
        ResolvedFaviconView(url: url, host: host)
            .equatable()
    }
}

private struct ResolvedFaviconView: View, Equatable {
    var url: URL?
    var host: String

    @Environment(\.faviconCache) private var faviconCache
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var tone: FaviconLegibility.Tone?

    static func == (lhs: ResolvedFaviconView, rhs: ResolvedFaviconView) -> Bool {
        lhs.url == rhs.url && lhs.host == rhs.host
    }

    var body: some View {
        Group {
            if let image {
                // A near-monochrome icon that is as dark as a dark background (or as light as a light one) is inverted, not drawn as an invisible shape: github's black mark on a dark row.
                let icon = Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                if FaviconLegibility.shouldInvert(tone, onDarkBackground: colorScheme == .dark) {
                    icon.colorInvert()
                } else {
                    icon
                }
            } else {
                Color.clear
            }
        }
        .task(id: FaviconRequestKey(url: url, host: host)) {
            if let cached = faviconCache.cachedImage(forHost: host) {
                assign(PreparedFavicon.prepare(cached))
                return
            }
            assign(PreparedFavicon.prepare(await faviconCache.image(for: url, host: host)))
        }
    }

    private func assign(_ resolved: NSImage) {
        if image !== resolved {
            image = resolved
            tone = FaviconLegibility.tone(of: resolved)
        }
    }
}

// The default cache mode is allowed to drop a file-backed bitmap, so the next
// draw decodes the file again. Keep the decoded representation for the life of this image.
private enum PreparedFavicon {
    static func prepare(_ image: NSImage) -> NSImage {
        if image.cacheMode != .always {
            image.cacheMode = .always
        }
        return image
    }
}

private struct FaviconRequestKey: Equatable {
    var url: URL?
    var host: String
}

// What a favicon looks like against a plain background: how bright it is and how little colour it has. Judged once per resolved image, from a 16 by 16 redraw of its opaque pixels.
enum FaviconLegibility {
    struct Tone: Equatable {
        /// Mean relative luminance of the opaque pixels, 0 (black) to 1 (white).
        var luminance: Double
        /// Mean saturation of the opaque pixels, 0 (grey) to 1 (fully coloured).
        var saturation: Double
    }

    // Below this mean saturation an icon counts as monochrome: a coloured logo that happens to be dark keeps its colours.
    static let monochromeSaturationCeiling = 0.25
    static let darkLuminanceCeiling = 0.30
    static let lightLuminanceFloor = 0.75
    private static let sampleSide = 16
    private static let minimumOpaqueFraction = 0.04

    static func shouldInvert(_ tone: Tone?, onDarkBackground: Bool) -> Bool {
        guard let tone, tone.saturation < monochromeSaturationCeiling else { return false }
        return onDarkBackground ? tone.luminance < darkLuminanceCeiling : tone.luminance > lightLuminanceFloor
    }

    /// Nil when the image cannot be drawn or has next to no opaque pixels, in which case it is left as it is.
    static func tone(of image: NSImage) -> Tone? {
        let side = sampleSide
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: rect)
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var opaque = 0
        var luminanceSum = 0.0
        var saturationSum = 0.0
        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.4 else { continue }
            // Premultiplied, so divide the alpha back out.
            let red = min(Double(pixels[index * 4]) / 255 / alpha, 1)
            let green = min(Double(pixels[index * 4 + 1]) / 255 / alpha, 1)
            let blue = min(Double(pixels[index * 4 + 2]) / 255 / alpha, 1)
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            opaque += 1
            luminanceSum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            saturationSum += high > 0 ? (high - low) / high : 0
        }
        guard Double(opaque) / Double(side * side) >= minimumOpaqueFraction else { return nil }
        return Tone(luminance: luminanceSum / Double(opaque), saturation: saturationSum / Double(opaque))
    }
}
