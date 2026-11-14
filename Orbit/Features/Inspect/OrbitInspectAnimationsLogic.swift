// Foundation-only logic (no AppKit, SwiftUI or WebKit) so it compiles into the unit-test bundle.

import Foundation

// MARK: - Data Types

enum AnimType: String, Equatable, Hashable, Codable {
    case css, transition, waapi

    var displayName: String {
        switch self {
        case .css: return "CSS"
        case .transition: return "Transition"
        case .waapi: return "WAAPI"
        }
    }
}

enum AnimPlayState: String, Equatable, Hashable {
    case idle, running, paused, finished
}

enum AnimDirection: String, Equatable, Hashable {
    case normal, reverse, alternate
    case alternateReverse = "alternate-reverse"

    static func from(_ s: String) -> AnimDirection {
        AnimDirection(rawValue: s) ?? .normal
    }
}

enum AnimFill: String, Equatable, Hashable {
    case fillNone = "none"
    case auto, forwards, backwards, both

    static func from(_ s: String) -> AnimFill {
        AnimFill(rawValue: s) ?? .fillNone
    }
}

enum AnimTimelineKind: String, Equatable, Hashable {
    case document, scroll, view
}

struct AnimKeyframe: Identifiable, Equatable {
    var id: String
    var offset: Double?
    var computedOffset: Double
    var easing: String
    var properties: [String: String]
}

struct AnimRecord: Identifiable, Equatable {
    var id: String
    var type: AnimType
    var elementID: Int
    var elementLabel: String
    var selector: String
    var name: String
    var properties: [String]
    var playState: AnimPlayState
    var playbackRate: Double
    var duration: Double      // ms
    var delay: Double         // ms
    var endDelay: Double      // ms
    var iterations: Double    // Double.infinity for infinite
    var iterationStart: Double
    var direction: AnimDirection
    var fill: AnimFill
    var easing: String
    var composite: String
    var currentTime: Double?
    var startTime: Double?
    var keyframes: [AnimKeyframe]
    var timelineKind: AnimTimelineKind
    var scrollSource: String
    var isGone: Bool
}

struct AnimEvent: Identifiable, Equatable {
    var id: String
    var timestamp: Double
    var type: String
    var elementLabel: String
    var animationName: String
    var elapsedTime: Double
}

/// Published for Lighthouse cross-tool contract: `session.animations.nonCompositedAnimations`.
struct AnimNonCompositedRecord: Equatable {
    var elementID: Int
    var selector: String
    var properties: [String]
    var animationName: String
    var animationType: String
}

struct AnimRowGroup: Identifiable, Equatable {
    var id: Int { elementID }
    var elementID: Int
    var elementLabel: String
    var rows: [AnimRecord]
}

struct AnimRulerTick: Identifiable, Equatable {
    var id: Double { ms }
    var ms: Double
    var label: String
    var isMajor: Bool
}

// MARK: - Easing

enum ParsedEasing: Equatable {
    case identity
    case cubicBezier(Double, Double, Double, Double)
    case steps(Int, StepJump)
    case linearStops([(Double, Double)])

    enum StepJump: String, Equatable {
        case jumpStart = "jump-start"
        case jumpEnd   = "jump-end"
        case jumpNone  = "jump-none"
        case jumpBoth  = "jump-both"
    }

    static func == (lhs: ParsedEasing, rhs: ParsedEasing) -> Bool {
        switch (lhs, rhs) {
        case (.identity, .identity): return true
        case (.cubicBezier(let a, let b, let c, let d), .cubicBezier(let e, let f, let g, let h)):
            return a == e && b == f && c == g && d == h
        case (.steps(let n1, let j1), .steps(let n2, let j2)):
            return n1 == n2 && j1 == j2
        case (.linearStops(let a), .linearStops(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        default: return false
        }
    }
}

// MARK: - Logic Namespace

enum OrbitAnimationsLogic {


    static func parseEasing(_ css: String) -> ParsedEasing {
        let s = css.trimmingCharacters(in: .whitespaces)
        switch s {
        case "linear":       return .identity
        case "ease":         return .cubicBezier(0.25, 0.1, 0.25, 1.0)
        case "ease-in":      return .cubicBezier(0.42, 0.0, 1.0,  1.0)
        case "ease-out":     return .cubicBezier(0.0,  0.0, 0.58, 1.0)
        case "ease-in-out":  return .cubicBezier(0.42, 0.0, 0.58, 1.0)
        default: break
        }
        if s.hasPrefix("cubic-bezier("), s.hasSuffix(")") {
            let inner = String(s.dropFirst("cubic-bezier(".count).dropLast())
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 4,
               let p1x = Double(parts[0]), let p1y = Double(parts[1]),
               let p2x = Double(parts[2]), let p2y = Double(parts[3]) {
                return .cubicBezier(p1x, p1y, p2x, p2y)
            }
        }
        if s.hasPrefix("steps("), s.hasSuffix(")") {
            let inner = String(s.dropFirst("steps(".count).dropLast())
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = parts.first, let n = Int(first), n > 0 {
                let term = parts.count > 1 ? parts[1] : "end"
                return .steps(n, parseStepJump(term))
            }
        }
        if s.hasPrefix("linear("), s.hasSuffix(")") {
            let stops = parseLinearStops(s)
            if !stops.isEmpty { return .linearStops(stops) }
        }
        return .identity
    }

    static func parseStepJump(_ term: String) -> ParsedEasing.StepJump {
        switch term {
        case "jump-start", "start": return .jumpStart
        case "jump-end",   "end":   return .jumpEnd
        case "jump-none":           return .jumpNone
        case "jump-both":           return .jumpBoth
        default:                    return .jumpEnd
        }
    }

    static func parseLinearStops(_ css: String) -> [(Double, Double)] {
        guard css.hasPrefix("linear("), css.hasSuffix(")") else { return [] }
        let inner = String(css.dropFirst("linear(".count).dropLast())
        var rawItems: [(y: Double, x: Double?)] = []
        for part in inner.split(separator: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces)
                            .split(separator: " ")
                            .map { String($0) }
            guard let first = tokens.first, let y = Double(first) else { continue }
            if tokens.count >= 2 {
                let pct = tokens[1].replacingOccurrences(of: "%", with: "")
                let x = Double(pct).map { $0 / 100.0 }
                rawItems.append((y: y, x: x))
            } else {
                rawItems.append((y: y, x: nil))
            }
        }
        guard !rawItems.isEmpty else { return [] }
        var result: [(Double, Double)] = Array(repeating: (0.0, 0.0), count: rawItems.count)
        for (i, item) in rawItems.enumerated() {
            if let x = item.x { result[i] = (x, item.y) }
        }
        if rawItems[0].x == nil { result[0] = (0.0, rawItems[0].y) }
        if rawItems[rawItems.count - 1].x == nil { result[rawItems.count - 1] = (1.0, rawItems[rawItems.count - 1].y) }
        var i = 0
        while i < rawItems.count {
            if rawItems[i].x == nil && i > 0 {
                var j = i + 1
                while j < rawItems.count, rawItems[j].x == nil { j += 1 }
                let x0 = result[i - 1].0
                let x1 = j < rawItems.count ? (rawItems[j].x ?? result[j].0) : 1.0
                let count = j - (i - 1)
                for k in i..<j {
                    let t = Double(k - (i - 1)) / Double(count)
                    result[k] = (x0 + t * (x1 - x0), rawItems[k].y)
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }


    static func evaluateCubicBezier(
        _ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double,
        t: Double
    ) -> Double {
        guard t > 0.0 else { return 0.0 }
        guard t < 1.0 else { return 1.0 }
        let u = solveCubicBezierX(p1x: p1x, p2x: p2x, x: t)
        return cubicBezier1D(p1: p1y, p2: p2y, t: u)
    }

    private static func cubicBezier1D(p1: Double, p2: Double, t: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
    }

    private static func solveCubicBezierX(p1x: Double, p2x: Double, x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let xAtT = cubicBezier1D(p1: p1x, p2: p2x, t: t)
            let dx = xAtT - x
            if abs(dx) < 1e-7 { return t }
            let d = derivativeCubicBezier1D(p1: p1x, p2: p2x, t: t)
            if abs(d) < 1e-10 { break }
            t -= dx / d
        }
        // Bisection fallback
        var lo = 0.0
        var hi = 1.0
        t = x
        for _ in 0..<20 {
            let xAtT = cubicBezier1D(p1: p1x, p2: p2x, t: t)
            if xAtT < x { lo = t } else { hi = t }
            t = (lo + hi) * 0.5
        }
        return t
    }

    private static func derivativeCubicBezier1D(p1: Double, p2: Double, t: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * p1 + 6.0 * mt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
    }

    static func evaluateSteps(count: Int, jumpTerm: ParsedEasing.StepJump, t: Double) -> Double {
        guard count > 0, t >= 0 else { return 0.0 }
        let n = Double(count)
        switch jumpTerm {
        case .jumpStart:
            return min(1.0, (floor(t * n) + 1.0) / n)
        case .jumpEnd:
            return min(1.0, floor(t * n) / n)
        case .jumpNone:
            guard count > 1 else { return t >= 1.0 ? 1.0 : 0.0 }
            return min(1.0, floor(t * (n - 1.0)) / (n - 1.0))
        case .jumpBoth:
            return min(1.0, (floor(t * n) + 1.0) / (n + 1.0))
        }
    }

    static func evaluateLinearStops(_ stops: [(Double, Double)], t: Double) -> Double {
        guard !stops.isEmpty else { return t }
        if t <= stops[0].0 { return stops[0].1 }
        if t >= stops[stops.count - 1].0 { return stops[stops.count - 1].1 }
        for i in 0..<(stops.count - 1) {
            let (x0, y0) = stops[i]
            let (x1, y1) = stops[i + 1]
            guard t >= x0, t <= x1 else { continue }
            let fraction = x1 > x0 ? (t - x0) / (x1 - x0) : 0.0
            return y0 + fraction * (y1 - y0)
        }
        return t
    }

    static func evaluateEasing(_ easing: ParsedEasing, t: Double) -> Double {
        switch easing {
        case .identity:
            return t
        case .cubicBezier(let p1x, let p1y, let p2x, let p2y):
            return evaluateCubicBezier(p1x, p1y, p2x, p2y, t: t)
        case .steps(let n, let jump):
            return evaluateSteps(count: n, jumpTerm: jump, t: t)
        case .linearStops(let stops):
            return evaluateLinearStops(stops, t: t)
        }
    }

    // MARK: Timing

    /// Active duration in milliseconds. Returns `.infinity` for infinite iterations.
    static func activeDuration(duration: Double, iterations: Double) -> Double {
        guard duration > 0, iterations > 0 else { return 0 }
        if iterations.isInfinite { return .infinity }
        return duration * iterations
    }

    /// Iteration progress in [0…1] for a local time in ms; nil outside the active+fill region.
    static func iterationProgress(
        localTime: Double,
        duration: Double,
        delay: Double,
        endDelay: Double,
        iterations: Double,
        iterationStart: Double,
        direction: String,
        fill: String
    ) -> Double? {
        guard duration > 0, iterations > 0 else { return nil }
        let active = activeDuration(duration: duration, iterations: iterations)
        let beforeFill = fill == "backwards" || fill == "both"
        let afterFill  = fill == "forwards"  || fill == "both"
        let inBefore = localTime < delay
        let inAfter  = !active.isInfinite && localTime > delay + active + endDelay

        if inBefore {
            guard beforeFill else { return nil }
            return max(0.0, min(1.0, iterationStart.truncatingRemainder(dividingBy: 1.0)))
        }
        if inAfter {
            guard afterFill else { return nil }
            return iterationProgressAtEnd(iterations: iterations, direction: direction)
        }
        let activeTime = max(0.0, localTime - delay)
        return progressInside(
            activeTime: activeTime, duration: duration,
            iterations: iterations, iterationStart: iterationStart, direction: direction
        )
    }

    private static func iterationProgressAtEnd(iterations: Double, direction: String) -> Double {
        let count = iterations.isInfinite ? 1 : Int(clamping: ceil(iterations))
        let isReverse: Bool
        switch direction {
        case "reverse": isReverse = true
        case "alternate": isReverse = (count % 2) == 0
        case "alternate-reverse": isReverse = (count % 2) != 0
        default: isReverse = false
        }
        return isReverse ? 0.0 : 1.0
    }

    private static func progressInside(
        activeTime: Double, duration: Double,
        iterations: Double, iterationStart: Double, direction: String
    ) -> Double {
        let scaledTime = activeTime / duration + iterationStart
        let currentIteration: Double
        let iterProgress: Double
        if !iterations.isInfinite, scaledTime >= iterations + iterationStart {
            currentIteration = ceil(iterations + iterationStart) - 1
            iterProgress = 1.0
        } else {
            currentIteration = floor(scaledTime)
            let frac = scaledTime.truncatingRemainder(dividingBy: 1.0)
            iterProgress = (frac == 0.0 && scaledTime > 0.0) ? 1.0 : frac
        }
        let isReverse: Bool
        switch direction {
        case "reverse":           isReverse = true
        case "alternate":         isReverse = Int(clamping: currentIteration.rounded(.down)) % 2 != 0
        case "alternate-reverse": isReverse = Int(clamping: currentIteration.rounded(.down)) % 2 == 0
        default:                  isReverse = false
        }
        return isReverse ? 1.0 - iterProgress : iterProgress
    }

    // MARK: Compositability

    static let compositableProperties: Set<String> = [
        "transform", "opacity", "filter", "backdrop-filter",
        "clip-path", "will-change"
    ]

    static let layoutTriggeringProperties: Set<String> = [
        "width", "height", "top", "left", "right", "bottom",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border-width", "border-top-width", "border-right-width",
        "border-bottom-width", "border-left-width",
        "font-size", "line-height", "letter-spacing", "word-spacing",
        "flex", "flex-basis", "flex-grow", "flex-shrink",
        "grid", "grid-template", "grid-template-columns", "grid-template-rows",
        "max-width", "max-height", "min-width", "min-height",
        "gap", "column-gap", "row-gap"
    ]

    static let paintTriggeringProperties: Set<String> = [
        "background", "background-color", "background-image",
        "color", "border-color", "outline", "outline-color",
        "box-shadow", "text-shadow", "border-radius", "border-style",
        "visibility", "fill", "stroke"
    ]

    /// True if the property is GPU-composited (no layout/paint cost).
    static func isCompositableProperty(_ name: String) -> Bool {
        compositableProperties.contains(name.lowercased())
    }

    static func compositabilityHint(_ name: String) -> String? {
        let key = name.lowercased()
        if compositableProperties.contains(key) { return nil }
        if layoutTriggeringProperties.contains(key) { return "layout" }
        if paintTriggeringProperties.contains(key) { return "paint" }
        return nil
    }

    // MARK: Grouping

    static func groupRows(_ records: [AnimRecord]) -> [AnimRowGroup] {
        var order: [Int] = []
        var map: [Int: [AnimRecord]] = [:]
        var labels: [Int: String] = [:]
        for record in records {
            let eid = record.elementID
            if map[eid] == nil {
                order.append(eid)
                labels[eid] = record.elementLabel
                map[eid] = []
            }
            map[eid]?.append(record)
        }
        return order.compactMap { eid -> AnimRowGroup? in
            guard let rows = map[eid] else { return nil }
            return AnimRowGroup(elementID: eid, elementLabel: labels[eid] ?? "", rows: rows)
        }
    }


    static func rulerTicks(totalDuration: Double, availableWidth: Double) -> [AnimRulerTick] {
        guard totalDuration > 0, availableWidth > 0 else { return [] }
        let minPixelsBetweenLabels = 80.0
        let candidates: [Double] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000]
        let pixelsPerMs = availableWidth / totalDuration
        var interval = candidates.last ?? 1000
        for c in candidates where c * pixelsPerMs >= minPixelsBetweenLabels {
            interval = c
            break
        }
        var ticks: [AnimRulerTick] = []
        var ms = 0.0
        while ms <= totalDuration + interval * 0.5 {
            ticks.append(AnimRulerTick(ms: ms, label: formatRulerTime(ms), isMajor: true))
            ms += interval
        }
        let half = interval / 2.0
        var minor = half
        while minor <= totalDuration + interval * 0.5 {
            if !ticks.contains(where: { abs($0.ms - minor) < 0.01 }) {
                ticks.append(AnimRulerTick(ms: minor, label: "", isMajor: false))
            }
            minor += interval
        }
        return ticks.sorted { $0.ms < $1.ms }
    }

    static func formatRulerTime(_ ms: Double) -> String {
        if ms < 1000 {
            return ms == floor(ms) ? "\(Int(ms))ms" : String(format: "%.0fms", ms)
        }
        let s = ms / 1000.0
        return s == floor(s) ? "\(Int(s))s" : String(format: "%.1fs", s)
    }


    static func addToRingBuffer(_ event: AnimEvent, buffer: inout [AnimEvent], cap: Int) {
        buffer.append(event)
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }


    static func scrubberX(currentTime: Double, totalDuration: Double, width: Double) -> Double {
        guard totalDuration > 0, width > 0 else { return 0 }
        return (currentTime / totalDuration) * width
    }

    static func timeFromScrubberX(_ x: Double, totalDuration: Double, width: Double) -> Double {
        guard width > 0, totalDuration > 0 else { return 0 }
        return max(0.0, min(Double(x / width), 1.0)) * totalDuration
    }

    // MARK: Non-composited

    static func nonCompositedRecords(from records: [AnimRecord]) -> [AnimNonCompositedRecord] {
        var result: [AnimNonCompositedRecord] = []
        for record in records where !record.isGone {
            let bad = record.properties.filter { p in
                !isCompositableProperty(p) && compositabilityHint(p) != nil
            }
            guard !bad.isEmpty else { continue }
            result.append(AnimNonCompositedRecord(
                elementID: record.elementID,
                selector: record.selector,
                properties: bad,
                animationName: record.name,
                animationType: record.type.rawValue
            ))
        }
        return result
    }

    // MARK: Bar drawing helpers

    static func barDelayFraction(delay: Double, totalDuration: Double) -> Double {
        guard totalDuration > 0 else { return 0 }
        return max(0, min(delay / totalDuration, 1))
    }

    static func barActiveFraction(duration: Double, iterations: Double, totalDuration: Double) -> Double {
        guard totalDuration > 0 else { return 0 }
        let ad = activeDuration(duration: duration, iterations: iterations)
        if ad.isInfinite { return max(0, 1.0 - barDelayFraction(delay: 0, totalDuration: totalDuration)) }
        return max(0, min(ad / totalDuration, 1))
    }

    /// Bar background segments: (x: Double, width: Double, kind: "delay"|"active"|"end-delay") all in 0…1 fractions.
    static func barSegments(
        delay: Double, duration: Double, endDelay: Double,
        iterations: Double, totalDuration: Double
    ) -> [(x: Double, w: Double, kind: String)] {
        guard totalDuration > 0 else { return [] }
        let ad = activeDuration(duration: duration, iterations: iterations)
        let activeCapped = ad.isInfinite ? max(0.0, totalDuration - delay - endDelay) : ad
        var segs: [(x: Double, w: Double, kind: String)] = []
        if delay > 0 {
            segs.append((x: 0.0, w: delay / totalDuration, kind: "delay"))
        }
        if activeCapped > 0 {
            segs.append((x: delay / totalDuration, w: activeCapped / totalDuration, kind: "active"))
        }
        if endDelay > 0 {
            segs.append((x: (delay + activeCapped) / totalDuration,
                         w: endDelay / totalDuration, kind: "end-delay"))
        }
        return segs
    }

    static func iterationSeparators(
        delay: Double, duration: Double, iterations: Double, totalDuration: Double
    ) -> [Double] {
        guard totalDuration > 0, duration > 0, iterations > 1, !iterations.isInfinite else { return [] }
        let iCount = Int(clamping: min(iterations, 20).rounded(.down))
        var result: [Double] = []
        for i in 1..<iCount {
            let sepX = (delay + Double(i) * duration) / totalDuration
            if sepX < 1.0 { result.append(sepX) }
        }
        return result
    }

    /// Keyframe dot x-fractions for one animation row (absolute, 0…1 of totalDuration).
    static func keyframeDots(
        delay: Double, duration: Double, iterations: Double,
        keyframes: [AnimKeyframe], totalDuration: Double
    ) -> [Double] {
        guard totalDuration > 0, duration > 0 else { return [] }
        let ad = activeDuration(duration: duration, iterations: iterations)
        let activeCapped = ad.isInfinite ? duration : ad
        var result: [Double] = []
        let iterCount = iterations.isInfinite ? 1 : min(1000, max(1, Int(clamping: ceil(iterations))))
        for i in 0..<iterCount {
            for kf in keyframes {
                let offset = kf.computedOffset
                let absMs = delay + Double(i) * duration + offset * duration
                let x = absMs / totalDuration
                if x >= 0 && x <= (delay + activeCapped) / totalDuration {
                    result.append(x)
                }
            }
        }
        return result
    }
}
