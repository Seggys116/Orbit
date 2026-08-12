// Never derive the header colour from a screenshot: WebContents.capturePreview uses ScreenCaptureKit, which would prompt for Screen Recording permission on every navigation.
// The colour comes from the page itself (<meta name="theme-color">, then computed <body>/<html> background) via evaluateJavaScript instead.

import AppKit
import Foundation
import Observation

public enum PaneHeaderForeground: Equatable {
    case dark
    case light
}

// @Observable, not a plain class: ToolbarView reads cachedColor(for:) straight from body, and a plain class there establishes no Observation dependency, letting background and foreground resolve on different renders and disagree — the near-black-on-near-black glyph bug.
@MainActor
@Observable
final class PaneHeaderColorResolver {
    static let shared = PaneHeaderColorResolver()
    private init() {}

    static let maximumReadAttempts = 6
    static let readRetryDelay: Duration = .milliseconds(150)

    // color is Optional and its nil is meaningful: "read, finished parsing, genuinely no colour" must not fall through to a stale URL hint.
    struct Reading: Equatable {
        var url: URL
        var color: ThemeColor?
    }

    // Keyed by tab, not URL: a tab that navigates while a read is in flight must land its answer under the old URL, and color(forTab:url:) declines a reading taken from a different URL than the caller believes it's showing.
    private var liveByTab: [TabID: Reading] = [:]

    private var hintByURL: [URL: ThemeColor] = [:]

    @ObservationIgnored private var inFlight: Set<TabID> = []

    private var documentByTab: [TabID: ThemeColor?] = [:]

    func documentColor(forTab tab: TabID) -> ThemeColor? {
        documentByTab[tab] ?? nil
    }

    func color(forTab tab: TabID, url: URL) -> ThemeColor? {
        if let live = liveByTab[tab], live.url == url {
            return live.color
        }
        return hintByURL[url]
    }

    func cachedColor(for url: URL) -> ThemeColor? { hintByURL[url] }

    static func foreground(for background: ThemeColor) -> PaneHeaderForeground {
        background.luminance > 0.5 ? .dark : .light
    }

    // MARK: - The derived glyph colour

    // Direction must come from measured contrastRatio, never a luminance
    // threshold; "inverted" means luminance-inverted (black/white), not per-channel.

    static let foregroundContrastTarget: Double = 7.0

    static let dimmedForegroundContrastTarget: Double = 3.0

    static let invertedDark = ThemeColor(red: 0, green: 0, blue: 0)
    static let invertedLight = ThemeColor(red: 1, green: 1, blue: 1)

    static func foregroundColor(for background: ThemeColor) -> ThemeColor {
        towardsDark(on: background.opaque) ? invertedDark : invertedLight
    }

    static func dimmedForegroundColor(for background: ThemeColor) -> ThemeColor {
        let opaque = background.opaque
        let extreme = foregroundColor(for: opaque).hsb.brightness

        let candidateAt: (Double) -> ThemeColor = { brightness in
            ThemeColor(red: brightness, green: brightness, blue: brightness)
        }

        guard candidateAt(extreme).contrastRatio(against: opaque) >= dimmedForegroundContrastTarget else {
            return candidateAt(extreme)
        }

        // Binary search for the brightness nearest the background that still clears the target; passing/failing invariant guarantees a legible result.
        var passing = extreme
        var failing = opaque.hsb.brightness
        for _ in 0..<12 {
            let midpoint = (passing + failing) / 2
            if candidateAt(midpoint).contrastRatio(against: opaque) >= dimmedForegroundContrastTarget {
                passing = midpoint
            } else {
                failing = midpoint
            }
        }
        return candidateAt(passing)
    }

    static func hasDarkForeground(on background: ThemeColor) -> Bool {
        towardsDark(on: background.opaque)
    }

    private static func towardsDark(on background: ThemeColor) -> Bool {
        background.contrastRatio(against: invertedDark) >= background.contrastRatio(against: invertedLight)
    }

    @discardableResult
    func sample(tab: TabID, url: URL, contents: any WebContents) async -> ThemeColor? {
        guard !inFlight.contains(tab) else { return nil }
        inFlight.insert(tab)
        defer { inFlight.remove(tab) }

        for attempt in 0..<Self.maximumReadAttempts {
            let raw = try? await contents.evaluateJavaScript(PageThemeColorScript.source)
            guard let reading = PageThemeColorScript.decode(raw) else { return nil }

            documentByTab[tab] = reading.documentColor.map(ThemeColor.init)

            if let color = reading.color {
                let resolved = ThemeColor(color)
                record(Reading(url: url, color: resolved), for: tab)
                hintByURL[url] = resolved
                return resolved
            }
            if reading.isReady {
                record(Reading(url: url, color: nil), for: tab)
                return nil
            }

            if attempt < Self.maximumReadAttempts - 1 {
                try? await Task.sleep(for: Self.readRetryDelay)
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    // Guard is not a micro-optimisation: liveByTab is observed by every pane header, so writing an identical value re-invalidates them all and re-runs the .task(id:) that calls sample() — a repeated read of an unchanging page must terminate here.
    private func record(_ reading: Reading, for tab: TabID) {
        guard liveByTab[tab] != reading else { return }
        liveByTab[tab] = reading
    }

    func forget(tab: TabID) {
        liveByTab.removeValue(forKey: tab)
        documentByTab.removeValue(forKey: tab)
        inFlight.remove(tab)
    }

    #if DEBUG
    func _test_reset() {
        liveByTab.removeAll()
        documentByTab.removeAll()
        hintByURL.removeAll()
        inFlight.removeAll()
    }
    #endif
}

extension NSImage {
    func orbitAverageColor() -> NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        // premultipliedLast: each byte is component * alpha, so a fully transparent pixel (alpha 0) carries no colour to recover and dividing by it would be undefined.
        guard pixel[3] > 0 else { return nil }
        let alphaByte = CGFloat(pixel[3])
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / alphaByte,
            green: CGFloat(pixel[1]) / alphaByte,
            blue: CGFloat(pixel[2]) / alphaByte,
            alpha: alphaByte / 255
        )
    }
}
