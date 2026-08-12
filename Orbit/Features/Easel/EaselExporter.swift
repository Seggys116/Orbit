//  Not ImageRenderer: it cannot rasterise NSViewRepresentable/ScrollView content
//  that EaselCanvasView is full of, so items are drawn straight into a bitmap instead.

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum EaselExporter {

    static let margin: CGFloat = 32

    static let scale: CGFloat = 2 // pixels per point; 2x for Retina

    // MARK: - Bounds

    static func contentBounds(of easel: Easel) -> CGRect {
        var union: CGRect?
        for item in easel.items {
            let frame = rotatedBounds(of: item)
            union = union.map { $0.union(frame) } ?? frame
        }
        guard let union else {
            return CGRect(x: 0, y: 0, width: 320, height: 200)
        }
        return union.insetBy(dx: -margin, dy: -margin)
    }

    private static func rotatedBounds(of item: EaselItem) -> CGRect {
        guard item.rotation != 0 else { return item.frame }
        let radians = item.rotation * .pi / 180
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let corners = [
            CGPoint(x: item.frame.minX, y: item.frame.minY),
            CGPoint(x: item.frame.maxX, y: item.frame.minY),
            CGPoint(x: item.frame.minX, y: item.frame.maxY),
            CGPoint(x: item.frame.maxX, y: item.frame.maxY)
        ].map { corner -> CGPoint in
            let dx = corner.x - centre.x
            let dy = corner.y - centre.y
            return CGPoint(
                x: centre.x + dx * cos(radians) - dy * sin(radians),
                y: centre.y + dx * sin(radians) + dy * cos(radians)
            )
        }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: - Render

    static func pngData(for easel: Easel, store: EaselStore, background: NSColor = .white) -> Data? {
        let bounds = contentBounds(of: easel)
        let pixelsWide = max(1, Int((bounds.width * scale).rounded()))
        let pixelsHigh = max(1, Int((bounds.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: bounds.width, height: bounds.height)

        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = base.cgContext

        // EaselItem.frame is top-left-origin; a bitmap context is bottom-left. Flip the CTM.
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -bounds.minX, y: -bounds.minY)

        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = flipped
        defer { NSGraphicsContext.current = previous }

        background.setFill()
        NSBezierPath(rect: bounds).fill()

        for item in easel.items.sorted(by: { $0.zIndex < $1.zIndex }) {
            cg.saveGState()
            if item.rotation != 0 {
                let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
                cg.translateBy(x: centre.x, y: centre.y)
                cg.rotate(by: item.rotation * .pi / 180)
                cg.translateBy(x: -centre.x, y: -centre.y)
            }
            draw(item, of: easel, store: store)
            cg.restoreGState()
        }

        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Per-item drawing

    private static func draw(_ item: EaselItem, of easel: Easel, store: EaselStore) {
        switch item.content {
        case .text(let text):
            drawText(text, in: item.frame)
        case .drawing(let points, let color, let width):
            drawStroke(points: points, color: color, width: width, origin: item.frame.origin)
        case .shape(let kind, let color, let lineWidth, let unitStart, let unitEnd):
            drawShape(kind: kind, color: color, lineWidth: lineWidth, unitStart: unitStart, unitEnd: unitEnd, in: item.frame)
        case .image(let fileName):
            if let data = store.loadImageData(fileName: fileName, forEasel: easel.id),
               let image = NSImage(data: data) {
                drawAspectFill(image, in: item.frame, cornerRadius: 8)
            } else {
                drawMissingCard(label: "Image", in: item.frame)
            }
        case .liveWebRegion(let url, _, _):
            let cacheName = EaselCanvasModel.webRegionCacheFileName(item.id)
            if let data = store.loadImageData(fileName: cacheName, forEasel: easel.id),
               let image = NSImage(data: data) {
                drawAspectFill(image, in: item.frame, cornerRadius: 8)
            } else {
                drawMissingCard(label: url.host() ?? url.absoluteString, in: item.frame)
            }
            drawHostChip(url.host() ?? url.absoluteString, in: item.frame)
        case .link(let url, let title):
            drawLinkCard(url: url, title: title, in: item.frame)
        }
    }

    private static func drawText(_ text: String, in frame: CGRect) {
        let background = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        background.fill()

        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: frame.insetBy(dx: 8, dy: 8))
    }

    private static func drawStroke(points: [CGPoint], color: ThemeColor, width: Double, origin: CGPoint) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: origin.x + first.x, y: origin.y + first.y))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: origin.x + point.x, y: origin.y + point.y))
        }
        path.lineWidth = CGFloat(width)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawShape(
        kind: EaselItem.ShapeKind,
        color: ThemeColor,
        lineWidth: Double,
        unitStart: CGPoint,
        unitEnd: CGPoint,
        in frame: CGRect
    ) {
        let path = EaselShapeGeometry.nsBezierPath(
            kind: kind,
            lineWidth: CGFloat(lineWidth),
            unitStart: unitStart,
            unitEnd: unitEnd,
            in: frame
        )
        color.nsColor.setStroke()
        path.stroke()
    }

    private static func drawAspectFill(_ image: NSImage, in frame: CGRect, cornerRadius: CGFloat) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        let source = image.size
        guard source.width > 0, source.height > 0 else {
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }
        let scale = max(frame.width / source.width, frame.height / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        let target = CGRect(
            x: frame.midX - drawn.width / 2,
            y: frame.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func drawMissingCard(label: String, in frame: CGRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    private static func drawHostChip(_ host: String, in frame: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: host, attributes: attributes)
        let textSize = string.size()
        let chip = CGRect(
            x: frame.minX + 6,
            y: frame.maxY - 6 - (textSize.height + 6),
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        string.draw(at: CGPoint(x: chip.minX + 6, y: chip.minY + 3))
    }

    private static func drawLinkCard(url: URL, title: String, in frame: CGRect) {
        NSColor.textBackgroundColor.setFill()
        let card = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        let heading = NSAttributedString(
            string: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        )
        heading.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 10))

        let subtitle = NSAttributedString(
            string: url.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        )
        subtitle.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 10 + heading.size().height + 2))
    }

    // MARK: - Save

    static func suggestedFileName(for easel: Easel) -> String {
        let trimmed = easel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Easel" : trimmed
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return "\(cleaned).png"
    }

    @discardableResult
    static func presentExportPanel(for easelID: UUID, store: EaselStore) -> URL? {
        guard let easel = store.easel(easelID), let data = pngData(for: easel, store: store) else { return nil }

        let panel = NSSavePanel()
        panel.title = "Export Easel"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFileName(for: easel)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
