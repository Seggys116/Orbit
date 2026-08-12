import AppKit
import SwiftUI
import XCTest

// MARK: - RGBA

/// A sampled colour, components in `0...1`.
struct RGBA: Equatable, CustomStringConvertible {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// What `color(atX:y:)` returns for an out-of-bounds sample rather than
    /// trapping, so a mis-computed test rectangle fails the assertion instead
    /// of crashing the test run.
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    func isApproximately(_ other: RGBA, tolerance: Double = 0.04) -> Bool {
        abs(r - other.r) <= tolerance
            && abs(g - other.g) <= tolerance
            && abs(b - other.b) <= tolerance
            && abs(a - other.a) <= tolerance
    }

    var description: String {
        String(format: "RGBA(r=%.3f g=%.3f b=%.3f a=%.3f)", r, g, b, a)
    }
}

// MARK: - RenderedImage

/// The rasterised result of one `render(_:size:)` call. Every public API
/// here takes **points**, origin top-left; internally the bitmap stores
/// pixels at `pointSize * scale`.
struct RenderedImage {
    let bitmap: NSBitmapImageRep
    let pointSize: CGSize
    let scale: CGFloat

    // MARK: Sampling

    func color(atX x: Int, y: Int) -> RGBA {
        let pixelX = Int((CGFloat(x) * scale).rounded())
        let pixelY = Int((CGFloat(y) * scale).rounded())
        guard pixelX >= 0, pixelY >= 0, pixelX < bitmap.pixelsWide, pixelY < bitmap.pixelsHigh else {
            return .clear
        }
        guard let color = bitmap.colorAt(x: pixelX, y: pixelY) else { return .clear }
        let converted = color.usingColorSpace(.sRGB) ?? color
        return RGBA(
            r: Double(converted.redComponent),
            g: Double(converted.greenComponent),
            b: Double(converted.blueComponent),
            a: Double(converted.alphaComponent)
        )
    }

    /// The mean colour over a point-space rectangle, clamped to the rendered bounds.
    func averageColor(in rect: CGRect) -> RGBA {
        let clamped = rect.intersection(CGRect(origin: .zero, size: pointSize))
        guard !clamped.isEmpty, !clamped.isNull else { return .clear }

        var totalR = 0.0, totalG = 0.0, totalB = 0.0, totalA = 0.0
        var count = 0
        let minX = Int(clamped.minX.rounded(.down))
        let maxX = Int(clamped.maxX.rounded(.up))
        let minY = Int(clamped.minY.rounded(.down))
        let maxY = Int(clamped.maxY.rounded(.up))
        guard minX < maxX, minY < maxY else { return .clear }

        for y in stride(from: minY, to: maxY, by: 1) {
            for x in stride(from: minX, to: maxX, by: 1) {
                let sample = color(atX: x, y: y)
                totalR += sample.r
                totalG += sample.g
                totalB += sample.b
                totalA += sample.a
                count += 1
            }
        }
        guard count > 0 else { return .clear }
        return RGBA(r: totalR / Double(count), g: totalG / Double(count), b: totalB / Double(count), a: totalA / Double(count))
    }

    func containsNonBackgroundPixels(in rect: CGRect, background: RGBA, tolerance: Double = 0.04) -> Bool {
        let clamped = rect.intersection(CGRect(origin: .zero, size: pointSize))
        guard !clamped.isEmpty, !clamped.isNull else { return false }
        let minX = Int(clamped.minX.rounded(.down))
        let maxX = Int(clamped.maxX.rounded(.up))
        let minY = Int(clamped.minY.rounded(.down))
        let maxY = Int(clamped.maxY.rounded(.up))
        guard minX < maxX, minY < maxY else { return false }

        for y in stride(from: minY, to: maxY, by: 1) {
            for x in stride(from: minX, to: maxX, by: 1) {
                if !color(atX: x, y: y).isApproximately(background, tolerance: tolerance) {
                    return true
                }
            }
        }
        return false
    }

    /// `nil` if nothing was drawn. Measures against fully transparent, not the corner pixel: an
    /// edge-to-edge view can paint its own (0, 0) corner, so treating that corner as "background"
    /// finds the bounding box of everything OUTSIDE the view instead of inside it.
    func boundingBoxOfContent(tolerance: Double = 0.04) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let widthPoints = Int(pointSize.width.rounded(.up))
        let heightPoints = Int(pointSize.height.rounded(.up))

        for y in 0..<max(heightPoints, 0) {
            for x in 0..<max(widthPoints, 0) {
                if color(atX: x, y: y).a > tolerance {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x + 1)
                    maxY = max(maxY, y + 1)
                }
            }
        }
        guard minX <= maxX, minY <= maxY, minX != Int.max else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Diagnostics

    /// Never throws — an I/O failure here is swallowed rather than obscuring the real assertion failure.
    @discardableResult
    func writeDiagnosticPNG(named: String) -> URL? {
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OrbitTests-Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sanitized = named.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(sanitized).png")
        do {
            try data.write(to: url)
            print("RenderHarness: wrote diagnostic PNG to \(url.path)")
            return url
        } catch {
            return nil
        }
    }

    @discardableResult
    func writePNG(to fileURL: URL) -> Bool {
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Defeating ImageRenderer's process-wide bitmap cache

/// `(span + 1)^2` distinct paddings — 4,225 at 64 — far more renders than
/// any one `xctest` process performs, so no two renders share a size.
private let renderPaddingSpan = 64

@MainActor private var renderPaddingCounter = 0

@MainActor
private func uniqueRenderPadding() -> CGSize {
    let n = renderPaddingCounter
    renderPaddingCounter += 1
    let modulus = renderPaddingSpan + 1
    return CGSize(width: CGFloat(n % modulus), height: CGFloat((n / modulus) % modulus))
}

/// Wraps `view` at exactly `size`, inside a per-call-unique outer frame that
/// `cropToRequestedSize` removes again. `.topLeading` throughout so the
/// view's origin stays at the bitmap's (0, 0).
@MainActor
private func paddedContent<V: View>(_ view: V, size: CGSize, padding: CGSize, colorScheme: ColorScheme) -> some View {
    view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .frame(width: size.width + padding.width, height: size.height + padding.height, alignment: .topLeading)
        .environment(\.colorScheme, colorScheme)
}

private func cropToRequestedSize(_ image: CGImage, size: CGSize, scale: CGFloat) -> CGImage {
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard width > 0, height > 0, width <= image.width, height <= image.height else { return image }
    guard width < image.width || height < image.height else { return image }
    return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) ?? image
}

private func blankBitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, Int(size.width * scale)),
        pixelsHigh: max(1, Int(size.height * scale)),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
}

// MARK: - Rendering

/// Renders `view` off-screen at `size` points; never creates or shows an `NSWindow`. `appearance` only
/// sets `\.colorScheme` — there is no host app to set `NSApp.appearance` on, so views must resolve colours from it.
@MainActor
func render<V: View>(
    _ view: V,
    size: CGSize,
    appearance: NSAppearance.Name = .darkAqua,
    scale: CGFloat = 2.0
) -> RenderedImage {
    // Forcing NSApp.appearance in this bare xctest process reliably crashes it.
    let colorScheme: ColorScheme = (appearance == .darkAqua || appearance == .vibrantDark) ? .dark : .light

    let padding = uniqueRenderPadding()
    let hosted = paddedContent(view, size: size, padding: padding, colorScheme: colorScheme)

    let renderer = ImageRenderer(content: hosted)
    renderer.scale = scale
    renderer.proposedSize = ProposedViewSize(width: size.width + padding.width, height: size.height + padding.height)
    // Keep alpha so boundingBoxOfContent/containsNonBackgroundPixels can tell
    // "nothing painted" apart from "painted the same colour as the corner".
    renderer.isOpaque = false

    guard let cgImage = renderer.cgImage else {
        XCTFail("RenderHarness.render: ImageRenderer produced no image for \(V.self) at \(size) — the view likely isn't renderable off-screen (see OrbitTests/README.md).")
        return RenderedImage(bitmap: blankBitmap(size: size, scale: scale), pointSize: size, scale: scale)
    }
    let rep = NSBitmapImageRep(cgImage: cropToRequestedSize(cgImage, size: size, scale: scale))
    return RenderedImage(bitmap: rep, pointSize: size, scale: scale)
}

// MARK: - Screenshot rendering (settled, async)

/// Like `render(_:size:appearance:scale:)` but re-reads `cgImage` several times with a real `Task.sleep`
/// between reads, so a `.task`/`.onAppear` that missed one synchronous read gets another chance — not genuine I/O.
@MainActor
func renderForScreenshot<V: View>(
    _ view: V,
    size: CGSize,
    appearance: NSAppearance.Name = .darkAqua,
    scale: CGFloat = 2.0,
    settlePasses: Int = 6,
    settleDelayNanoseconds: UInt64 = 40_000_000
) async -> RenderedImage {
    let colorScheme: ColorScheme = (appearance == .darkAqua || appearance == .vibrantDark) ? .dark : .light

    let padding = uniqueRenderPadding()
    let hosted = paddedContent(view, size: size, padding: padding, colorScheme: colorScheme)

    let renderer = ImageRenderer(content: hosted)
    renderer.scale = scale
    renderer.proposedSize = ProposedViewSize(width: size.width + padding.width, height: size.height + padding.height)
    renderer.isOpaque = false

    var lastImage: CGImage?
    for _ in 0..<max(1, settlePasses) {
        lastImage = renderer.cgImage
        try? await Task.sleep(nanoseconds: settleDelayNanoseconds)
    }
    lastImage = renderer.cgImage ?? lastImage

    guard let cgImage = lastImage else {
        XCTFail("renderForScreenshot: ImageRenderer produced no image for \(V.self) at \(size).")
        return RenderedImage(bitmap: blankBitmap(size: size, scale: scale), pointSize: size, scale: scale)
    }
    let rep = NSBitmapImageRep(cgImage: cropToRequestedSize(cgImage, size: size, scale: scale))
    return RenderedImage(bitmap: rep, pointSize: size, scale: scale)
}
