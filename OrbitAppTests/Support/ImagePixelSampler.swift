import AppKit
import CoreGraphics

/// Reads real pixel values out of an engine snapshot.
///
/// `NSBitmapImageRep.colorAt` on a snapshot's TIFF round trip comes back tagged Generic RGB (gamma 1.8) while
/// holding sRGB numbers, so converting that colour to `.deviceRGB` shifts #112233 to roughly (20, 46, 67). The
/// snapshot's CGImage is plainly sRGB, so it is drawn into an sRGB bitmap and the bytes read directly.
enum ImagePixelSampler {
    struct Pixel: Equatable {
        var red: Int
        var green: Int
        var blue: Int
        var alpha: Int
    }

    struct SnapshotSample {
        var width: Int
        var height: Int
        var pixel: Pixel
    }

    /// The image rendered once into sRGB, for reading many pixels.
    struct SnapshotBitmap {
        let width: Int
        let height: Int
        fileprivate let bytes: [UInt8]

        /// The pixel at (x, y), counted from the top left, or nil outside the image.
        func pixel(x: Int, y: Int) -> Pixel? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let offset = (y * width + x) * 4
            let alpha = Int(bytes[offset + 3])
            // Premultiplied: undo it so a translucent pixel still reports its own colour.
            func channel(_ value: UInt8) -> Int {
                alpha == 0 || alpha == 255 ? Int(value) : min(255, Int((Double(value) * 255 / Double(alpha)).rounded()))
            }
            return Pixel(red: channel(bytes[offset]), green: channel(bytes[offset + 1]), blue: channel(bytes[offset + 2]), alpha: alpha)
        }
    }

    static func bitmap(_ image: NSImage) -> SnapshotBitmap? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? SnapshotBitmap(width: width, height: height, bytes: bytes) : nil
    }

    /// The pixel at (x, y), counted from the top left. Defaults to the centre.
    static func sample(_ image: NSImage, x: Int? = nil, y: Int? = nil) -> SnapshotSample? {
        guard let bitmap = bitmap(image) else { return nil }
        let column = min(max(x ?? bitmap.width / 2, 0), bitmap.width - 1)
        let row = min(max(y ?? bitmap.height / 2, 0), bitmap.height - 1)
        guard let pixel = bitmap.pixel(x: column, y: row) else { return nil }
        return SnapshotSample(width: bitmap.width, height: bitmap.height, pixel: pixel)
    }
}
