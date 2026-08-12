import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum GrainTexture {
    static let tile: CGImage? = generate(size: 256)

    private static func generate(size: Int) -> CGImage? {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let generator = CIFilter.randomGenerator()
        guard let noise = generator.outputImage else { return nil }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let cropped = noise.cropped(to: rect)

        let controls = CIFilter.colorControls()
        controls.inputImage = cropped
        controls.saturation = 0
        controls.brightness = 0
        controls.contrast = 0.18

        let clamped = (controls.outputImage ?? cropped).clampedToExtent() // avoids sampling transparent tile edges
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = clamped
        blur.radius = 0.6

        guard let softened = blur.outputImage?.cropped(to: rect) else {
            return context.createCGImage(controls.outputImage ?? cropped, from: rect)
        }
        return context.createCGImage(softened, from: rect)
    }
}

struct GrainOverlay: View {
    var opacity: Double

    // Not `\.colorScheme`: a theme's colour can be dark in Light Mode.
    var isDarkSurface: Bool = true

    @Environment(\.displayScale) private var displayScale

    private static let maximumAlphaDark = 0.11
    private static let maximumAlphaLight = 0.16

    var body: some View {
        GeometryReader { proxy in
            if let cgImage = GrainTexture.tile, opacity > 0.001 {
                Image(decorative: cgImage, scale: displayScale, orientation: .up)
                    .resizable(resizingMode: .tile)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blendMode(isDarkSurface ? .screen : .overlay)
                    .opacity(min(max(opacity, 0), 1) * (isDarkSurface ? Self.maximumAlphaDark : Self.maximumAlphaLight))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}
