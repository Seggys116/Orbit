import AppKit
import SwiftUI

// Shared by EaselItemContentView and EaselExporter so canvas and export never drift apart.
enum EaselShapeGeometry {

    static func endpoints(unitStart: CGPoint, unitEnd: CGPoint, in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        (
            CGPoint(x: rect.minX + unitStart.x * rect.width, y: rect.minY + unitStart.y * rect.height),
            CGPoint(x: rect.minX + unitEnd.x * rect.width, y: rect.minY + unitEnd.y * rect.height)
        )
    }

    static func arrowHead(start: CGPoint, end: CGPoint, lineWidth: CGFloat) -> (left: CGPoint, right: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        let barb = min(max(10, lineWidth * 4), length * 0.4)
        let angle = atan2(dy, dx)
        let spread: CGFloat = 28 * .pi / 180
        return (
            CGPoint(x: end.x - barb * cos(angle - spread), y: end.y - barb * sin(angle - spread)),
            CGPoint(x: end.x - barb * cos(angle + spread), y: end.y - barb * sin(angle + spread))
        )
    }

    static func strokeRect(_ rect: CGRect, lineWidth: CGFloat) -> CGRect {
        let inset = lineWidth / 2
        return CGRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: max(rect.width - lineWidth, 0.5),
            height: max(rect.height - lineWidth, 0.5)
        )
    }

    // MARK: - SwiftUI

    static func path(
        kind: EaselItem.ShapeKind,
        lineWidth: CGFloat,
        unitStart: CGPoint,
        unitEnd: CGPoint,
        in rect: CGRect
    ) -> Path {
        var path = Path()
        switch kind {
        case .ellipse:
            path.addEllipse(in: strokeRect(rect, lineWidth: lineWidth))
        case .rectangle:
            path.addRect(strokeRect(rect, lineWidth: lineWidth))
        case .arrow:
            let ends = endpoints(unitStart: unitStart, unitEnd: unitEnd, in: rect)
            let head = arrowHead(start: ends.start, end: ends.end, lineWidth: lineWidth)
            path.move(to: ends.start)
            path.addLine(to: ends.end)
            path.move(to: head.left)
            path.addLine(to: ends.end)
            path.addLine(to: head.right)
        }
        return path
    }

    // MARK: - AppKit

    static func nsBezierPath(
        kind: EaselItem.ShapeKind,
        lineWidth: CGFloat,
        unitStart: CGPoint,
        unitEnd: CGPoint,
        in rect: CGRect
    ) -> NSBezierPath {
        let path = NSBezierPath()
        switch kind {
        case .ellipse:
            path.appendOval(in: strokeRect(rect, lineWidth: lineWidth))
        case .rectangle:
            path.appendRect(strokeRect(rect, lineWidth: lineWidth))
        case .arrow:
            let ends = endpoints(unitStart: unitStart, unitEnd: unitEnd, in: rect)
            let head = arrowHead(start: ends.start, end: ends.end, lineWidth: lineWidth)
            path.move(to: ends.start)
            path.line(to: ends.end)
            path.move(to: head.left)
            path.line(to: ends.end)
            path.line(to: head.right)
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
