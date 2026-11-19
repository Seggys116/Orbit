//  Records what a real window does while something is happening in it: when each display frame was produced,
//  and what the pane pixels were on that frame. Used by the interaction smoothness live tests.

import AppKit
import QuartzCore
@testable import Orbit

@MainActor
final class FrameProbe: NSObject {

    struct Frame {
        /// Seconds since `start()`.
        var at: Double
        /// Gap since the previous callback, in milliseconds. The first frame has none.
        var gapMilliseconds: Double?
        /// What was wrong with the window on this frame. Empty means the frame was fine.
        var defects: [String]
    }

    struct Report {
        var label: String
        var frames: [Frame]
        /// How long the action itself held the main thread before the first frame could be produced.
        var actionMilliseconds: Double
        var nominalFrameMilliseconds: Double

        var gaps: [Double] { frames.compactMap(\.gapMilliseconds) }
        var longestGapMilliseconds: Double { gaps.max() ?? 0 }
        /// A frame arriving after more than 1.5 refresh intervals is one the user can see stall.
        var hitchCount: Int { gaps.filter { $0 > nominalFrameMilliseconds * 1.5 }.count }
        var defectiveFrames: [Frame] { frames.filter { !$0.defects.isEmpty } }

        var percentile95Milliseconds: Double {
            let sorted = gaps.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        }

        /// Where the long frames fell, as "+offset ms: gap ms".
        var stallTimeline: String {
            frames.compactMap { frame -> String? in
                guard let gap = frame.gapMilliseconds, gap > nominalFrameMilliseconds * 1.5 else { return nil }
                return String(format: "+%.0f:%.0f", frame.at * 1000, gap)
            }.joined(separator: " ")
        }

        var summary: String {
            let defects = defectiveFrames
            let first = defects.first.map { " first defect at +\(Int($0.at * 1000))ms: \($0.defects.joined(separator: "; "))" } ?? ""
            return String(
                format: "%@: action %.1fms, %d frames, longest gap %.1fms, p95 gap %.1fms, %d hitches (>%.1fms), %d defective frames.%@",
                label, actionMilliseconds, frames.count, longestGapMilliseconds, percentile95Milliseconds,
                hitchCount, nominalFrameMilliseconds * 1.5, defects.count, first
            ) + (stallTimeline.isEmpty ? "" : " stalls[\(stallTimeline)]")
        }
    }

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var previous: CFTimeInterval?
    private var frames: [Frame] = []
    private var inspect: (() -> [String])?

    /// The display's own refresh interval.
    static func nominalFrameMilliseconds(for window: NSWindow) -> Double {
        let rate = window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return 1000.0 / Double(max(rate, 30))
    }

    /// Runs `action`, then watches `duration` seconds of frames. `inspect` runs on every frame and returns what is wrong.
    func record(
        label: String,
        in window: NSWindow,
        duration: TimeInterval,
        inspect: @escaping () -> [String] = { [] },
        action: () -> Void
    ) async -> Report {
        guard let view = window.contentView else {
            return Report(label: label, frames: [], actionMilliseconds: 0, nominalFrameMilliseconds: 16.7)
        }
        frames = []
        previous = nil
        self.inspect = inspect
        started = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link

        let before = CACurrentMediaTime()
        action()
        let actionMilliseconds = (CACurrentMediaTime() - before) * 1000

        try? await Task.sleep(for: .seconds(duration))

        link.invalidate()
        self.link = nil
        self.inspect = nil
        return Report(
            label: label,
            frames: frames,
            actionMilliseconds: actionMilliseconds,
            nominalFrameMilliseconds: Self.nominalFrameMilliseconds(for: window)
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = previous.map { ($0 < now ? now - $0 : 0) * 1000 }
        previous = now
        frames.append(Frame(at: now - started, gapMilliseconds: gap, defects: inspect?() ?? []))
    }
}

/// What a pane must look like for the user to see the page, judged from the window's real composited pixels.
@MainActor
struct PanePixelCheck {
    struct Expectation {
        var tabID: TabID
        var red: Int
        var green: Int
        var blue: Int
    }

    var window: NSWindow
    var env: AppEnvironment
    /// Share of the pane that must be the page's own colour. The rest is text and the card's rounded corners.
    var minimumFraction = 0.75

    func defects(for expectations: [Expectation], capturePixels: Bool) -> [String] {
        let full: CGImage? = capturePixels ? WindowPixelCapture.image(of: window) : nil
        var found: [String] = []
        for expectation in expectations {
            let name = String(expectation.tabID.uuidString.prefix(4))
            guard let contents = env.webContents[expectation.tabID] else {
                found.append("tab \(name) has no page")
                continue
            }
            let view = contents.view
            guard view.window === window else {
                found.append("tab \(name) page is not in the window")
                continue
            }
            if view.isHiddenOrHasHiddenAncestor {
                found.append("tab \(name) page is hidden")
                continue
            }
            let rect = view.convert(view.bounds, to: nil)
            guard rect.width > 60, rect.height > 60 else {
                found.append("tab \(name) page is \(Int(rect.width))x\(Int(rect.height))")
                continue
            }
            guard let full else { continue }
            let inner = rect.insetBy(dx: 14, dy: 14)
            guard let pane = WindowPixelCapture.crop(full, toWindowRect: inner, of: window) else { continue }
            let fraction = WindowPixelCapture.fractionMatching(
                pane, red: expectation.red, green: expectation.green, blue: expectation.blue, tolerance: 28
            )
            if fraction < minimumFraction {
                found.append(String(format: "tab %@ pane is only %.0f%% the page colour", name, fraction * 100))
            }
        }
        return found
    }
}
