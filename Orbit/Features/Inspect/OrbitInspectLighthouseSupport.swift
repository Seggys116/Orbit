import AppKit
import Foundation
import UniformTypeIdentifiers

enum OrbitLighthouseSupport {

    /// Completeness is each frame's similarity to the final frame, as a fraction in 0...1.
    static func computeCompleteness(rawFrames: [(ms: Double, cgImage: CGImage)]) -> [(ms: Double, completeness: Double)] {
        guard rawFrames.count >= 2 else { return [] }
        guard let finalImage = rawFrames.last?.cgImage else { return [] }
        let finalPixels = extractPixels(cgImage: finalImage)
        guard !finalPixels.isEmpty else { return [] }
        return rawFrames.map { frame in
            let pixels = extractPixels(cgImage: frame.cgImage)
            let c = pixelCompleteness(pixels, reference: finalPixels)
            return (ms: frame.ms, completeness: c)
        }
    }

    static func extractPixels(cgImage: CGImage) -> [UInt8] {
        let width = 20, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return pixels }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    static func pixelCompleteness(_ current: [UInt8], reference: [UInt8]) -> Double {
        guard current.count == reference.count, !current.isEmpty else { return 0 }
        var totalDiff = 0.0
        var i = 0
        while i < current.count - 2 {
            totalDiff += Double(abs(Int(current[i]) - Int(reference[i])))
            totalDiff += Double(abs(Int(current[i + 1]) - Int(reference[i + 1])))
            totalDiff += Double(abs(Int(current[i + 2]) - Int(reference[i + 2])))
            i += 4
        }
        let maxDiff = Double(current.count / 4) * 255.0 * 3.0
        return maxDiff > 0 ? max(0, min(1, 1.0 - totalDiff / maxDiff)) : 1.0
    }

    /// A JPEG of the image and its size in pixels. The pixel size is read from the bitmap, because a snapshot's point size is not its pixel size on a Retina display.
    static func jpegData(from image: NSImage, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return (data, cgImage.width, cgImage.height)
    }

    /// A JPEG exactly `pixelWidth` pixels across. A snapshot comes back at the display's backing scale, not at the
    /// emulated device's pixel ratio, so it is redrawn at the device's size.
    static func jpegData(from image: NSImage, quality: Double, pixelWidth: Int) -> (data: Data, width: Int, height: Int)? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0, pixelWidth > 0 else { return nil }
        guard source.width != pixelWidth else { return jpegData(from: image, quality: quality) }
        let pixelHeight = max(1, Int((Double(source.height) * Double(pixelWidth) / Double(source.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let scaled = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return (data, pixelWidth, pixelHeight)
    }

    @MainActor
    static func saveFile(data: Data, suggestedName: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes  = ext == "json"
            ? [.json]
            : [.html]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
