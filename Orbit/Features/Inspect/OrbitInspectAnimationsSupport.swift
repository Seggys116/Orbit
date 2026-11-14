import SwiftUI


/// Traces an easing function in a unit square with Y flipped (0 = bottom) to match the usual curve orientation.
enum AnimEasingPath {

    static func path(for easing: ParsedEasing, in rect: CGRect, samples: Int = 120) -> Path {
        switch easing {
        case .identity:
            return linePath([(0.0, 0.0), (1.0, 1.0)], in: rect)
        case .cubicBezier:
            return sampledPath(easing: easing, in: rect, samples: samples)
        case .steps:
            return stepsPath(easing: easing, in: rect)
        case .linearStops:
            return sampledPath(easing: easing, in: rect, samples: samples)
        }
    }

    static func bezierCurvePath(p1x: Double, p1y: Double, p2x: Double, p2y: Double, in rect: CGRect) -> Path {
        var path = Path()
        let start = point(0, 0, in: rect)
        let end   = point(1, 1, in: rect)
        let cp1   = point(p1x, p1y, in: rect)
        let cp2   = point(p2x, p2y, in: rect)
        path.move(to: start)
        path.addCurve(to: end, control1: cp1, control2: cp2)
        return path
    }

    static func handleArmPaths(p1x: Double, p1y: Double, p2x: Double, p2y: Double, in rect: CGRect) -> (arm1: Path, arm2: Path) {
        var arm1 = Path()
        arm1.move(to: point(0, 0, in: rect))
        arm1.addLine(to: point(p1x, p1y, in: rect))

        var arm2 = Path()
        arm2.move(to: point(1, 1, in: rect))
        arm2.addLine(to: point(p2x, p2y, in: rect))
        return (arm1, arm2)
    }


    private static func sampledPath(easing: ParsedEasing, in rect: CGRect, samples: Int) -> Path {
        var path = Path()
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let y = OrbitAnimationsLogic.evaluateEasing(easing, t: t)
            let pt = point(t, y, in: rect)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    private static func stepsPath(easing: ParsedEasing, in rect: CGRect) -> Path {
        guard case .steps(let n, _) = easing, n > 0 else { return Path() }
        var path = Path()
        let dt = 1.0 / Double(n)
        var moved = false
        for i in 0...n {
            let tLeft  = Double(i) * dt
            let tRight = Double(min(i + 1, n)) * dt
            let y      = OrbitAnimationsLogic.evaluateEasing(easing, t: tLeft)
            let ptL    = point(tLeft, y, in: rect)
            let ptR    = point(tRight, y, in: rect)
            if !moved { path.move(to: ptL); moved = true } else {
                // Vertical jump
                path.addLine(to: ptL)
            }
            path.addLine(to: ptR)
        }
        return path
    }

    private static func linePath(_ pairs: [(Double, Double)], in rect: CGRect) -> Path {
        var path = Path()
        for (i, (t, y)) in pairs.enumerated() {
            let pt = point(t, y, in: rect)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    static func point(_ t: Double, _ y: Double, in rect: CGRect) -> CGPoint {
        let pad: CGFloat = 0
        let x = rect.minX + pad + CGFloat(t) * (rect.width  - 2 * pad)
        let yp = rect.maxY - pad - CGFloat(y) * (rect.height - 2 * pad)
        return CGPoint(x: x, y: yp)
    }

    /// Inverse of point(): screen coords → (t, y) in [0,1].
    static func normalize(_ pt: CGPoint, in rect: CGRect) -> (t: Double, y: Double) {
        let t = Double((pt.x - rect.minX) / rect.width)
        let y = Double((rect.maxY - pt.y) / rect.height)
        return (max(0, min(1, t)), max(-0.5, min(1.5, y)))
    }
}

struct AnimBezierEdit: Equatable {
    var p1x: Double = 0.25
    var p1y: Double = 0.1
    var p2x: Double = 0.25
    var p2y: Double = 1.0

    init() {}

    init(from css: String) {
        let parsed = OrbitAnimationsLogic.parseEasing(css)
        if case .cubicBezier(let a, let b, let c, let d) = parsed {
            p1x = a; p1y = b; p2x = c; p2y = d
        }
    }

    var cssString: String {
        String(format: "cubic-bezier(%.3f, %.3f, %.3f, %.3f)", p1x, p1y, p2x, p2y)
    }
}


extension AnimType {
    var barColor: Color {
        switch self {
        case .css:        return Color(nsColor: .systemBlue).opacity(0.75)
        case .transition: return Color(nsColor: .systemGreen).opacity(0.75)
        case .waapi:      return Color(nsColor: .systemPurple).opacity(0.75)
        }
    }
    var badgeColor: Color {
        switch self {
        case .css:        return Color(nsColor: .systemBlue)
        case .transition: return Color(nsColor: .systemGreen)
        case .waapi:      return Color(nsColor: .systemPurple)
        }
    }
}

extension AnimPlayState {
    var statusColor: Color {
        switch self {
        case .running:  return Color(nsColor: .systemGreen)
        case .paused:   return Color(nsColor: .systemOrange)
        case .finished: return Color.secondary
        case .idle:     return Color.secondary
        }
    }
}


extension AnimRecord {
    var iterationsDisplay: String {
        if iterations.isInfinite { return "∞" }
        let n = iterations.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(clamping: iterations))" : String(format: "%.2f", iterations)
        return n
    }

    var durationDisplay: String { OrbitDevToolsFormat.milliseconds(duration) }
    var delayDisplay: String    { delay    == 0 ? "0ms" : OrbitDevToolsFormat.milliseconds(delay) }
    var endDelayDisplay: String { endDelay == 0 ? "0ms" : OrbitDevToolsFormat.milliseconds(endDelay) }
}

import AppKit

extension NSColor {
    static var animDelay: NSColor    { .systemGray.withAlphaComponent(0.35) }
    static var animActive: NSColor   { .systemBlue.withAlphaComponent(0.50) }
    static var animEndDelay: NSColor { .systemGray.withAlphaComponent(0.20) }
}
