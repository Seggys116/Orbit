import AppKit
import WebKit
import SwiftUI

/// An NSViewRepresentable that forwards macOS scroll wheel and magnify (trackpad pinch) events.
struct PerfScrollCapture: NSViewRepresentable {
    var onScroll: (_ deltaX: Double, _ deltaY: Double) -> Void
    var onMagnify: (_ magnification: Double) -> Void

    func makeNSView(context: Context) -> PerfScrollCaptureView {
        let view = PerfScrollCaptureView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ nsView: PerfScrollCaptureView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
    }
}

final class PerfScrollCaptureView: NSView {
    var onScroll: (Double, Double) -> Void = { _, _ in }
    var onMagnify: (Double) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum-phase events from trackpad inertia are passed through, so the view keeps panning and zooming after the fingers lift.
        onScroll(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        onMagnify(Double(event.magnification))
    }
}

extension PerfRating {
    var color: Color {
        switch self {
        case .good: return InspectChrome.goodColor
        case .needsImprovement: return InspectChrome.warnColor
        case .poor: return InspectChrome.badColor
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .good: return "Good"
        case .needsImprovement: return "Needs improvement"
        case .poor: return "Poor"
        case .unknown: return "n/a"
        }
    }
}

extension PerfFrameSample {
    var classification: OrbitPerformanceLogic.FrameClass {
        OrbitPerformanceLogic.classifyFrame(duration)
    }

    var barColor: Color {
        switch classification {
        case .smooth: return InspectChrome.goodColor
        case .slightDrop: return InspectChrome.warnColor
        case .moderateDrop, .severeDrop: return InspectChrome.badColor
        }
    }
}

extension PerfNativeSample {
    var memoryText: String {
        let mb = Double(memoryBytes) / 1_048_576
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    var cpuText: String {
        String(format: "%.1f%%", cpuPercent)
    }
}

extension PerfFilmstripFrame {
    var nsImage: NSImage? {
        guard let data = imageData else { return nil }
        return NSImage(data: data)
    }
}

extension OrbitVitals {
    var lcpPhases: PerfLCPPhases? {
        guard let lcp = lcpElement, let nav = navigationPhases else { return nil }
        return OrbitPerformanceLogic.lcpPhases(entry: lcp, nav: nav)
    }
}

extension PerfRecording {
    var resourceSummary: [PerfResourceBucket] {
        OrbitPerformanceLogic.resourceSummary(entries: resourceEntries)
    }

    var userTimings: [PerfUserTiming] {
        (markEntries + measureEntries).sorted { $0.startTime < $1.startTime }
    }

    var fpsSamples: [PerfFrameSample] { frameSamples }

    var averageFPS: Double? {
        let durations = frameSamples.map { $0.duration }.filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }
        let avg = durations.reduce(0, +) / Double(durations.count)
        return avg > 0 ? min(144, 1000 / avg) : nil
    }

    var droppedFrameCount: Int {
        frameSamples.filter { $0.duration > 16.7 }.count
    }
}
