// Foundation-only (no AppKit, SwiftUI or WebKit) so it compiles into the unit-test bundle with OrbitInspectDecode.swift.

import Darwin
import Foundation

enum LHRunMode: String, Codable, CaseIterable, Hashable {
    case navigation, snapshot, timespan

    var title: String {
        switch self {
        case .navigation: return "Navigation"
        case .snapshot:   return "Snapshot"
        case .timespan:   return "Timespan"
        }
    }
    var detail: String {
        switch self {
        case .navigation: return "Reload, wait for idle, then audit."
        case .snapshot:   return "Audit the current DOM without reloading."
        case .timespan:   return "Start, interact, stop — measures CLS/INP/TBT."
        }
    }
}

enum LHDevice: String, Codable, CaseIterable, Hashable {
    case mobile, desktop

    var title: String {
        switch self {
        case .mobile:  return "Mobile"
        case .desktop: return "Desktop"
        }
    }

    // Lighthouse v12 log-normal control points: (p10, median)
    var fcpCurve:  (p10: Double, median: Double) { mobile ? (1800, 3000) : (934, 1600) }
    var lcpCurve:  (p10: Double, median: Double) { mobile ? (2500, 4000) : (1200, 2400) }
    var tbtCurve:  (p10: Double, median: Double) { mobile ? (200, 600)   : (150, 350)   }
    var clsCurve:  (p10: Double, median: Double) { (0.1, 0.25) }
    var siCurve:   (p10: Double, median: Double) { mobile ? (3387, 5800) : (1311, 2300) }

    /// Link speed assumed for byte savings: Lighthouse's mobile preset is 1.6 Mbps, desktop 10 Mbps. Nothing is throttled here.
    var assumedBytesPerSecond: Double { mobile ? 200_000 : 1_250_000 }

    private var mobile: Bool { self == .mobile }
}

enum LHCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case performance, accessibility, bestPractices, seo, security

    var id: String { rawValue }
    var title: String {
        switch self {
        case .performance:    return "Performance"
        case .accessibility:  return "Accessibility"
        case .bestPractices:  return "Best practices"
        case .seo:            return "SEO"
        case .security:       return "Security"
        }
    }
    var symbol: String {
        switch self {
        case .performance:    return "gauge.with.dots.needle.67percent"
        case .accessibility:  return "figure.roll"
        case .bestPractices:  return "checkmark.shield"
        case .seo:            return "magnifyingglass"
        case .security:       return "lock.shield"
        }
    }
}

enum LHAuditStatus: String, Codable {
    case pass, fail, warning, informative, manual, notApplicable
}

enum LHAuditBand: String, Hashable {
    case passed, warning, failed, informative, notApplicable
}

struct LHAuditItem: Codable, Identifiable {
    var id: String
    var nodeID: Int?
    var selector: String?
    var snippet: String?
    var url: String?
    var label: String?
    var wastedBytes: Int?
    var wastedMs: Double?
    var transferSize: Int?
    var subLabel: String?

    init(
        id: String = UUID().uuidString,
        nodeID: Int? = nil, selector: String? = nil, url: String? = nil,
        wastedBytes: Int? = nil, wastedMs: Double? = nil, transferSize: Int? = nil,
        label: String? = nil, snippet: String? = nil, subLabel: String? = nil
    ) {
        self.id = id; self.nodeID = nodeID; self.selector = selector
        self.snippet = snippet; self.url = url; self.label = label
        self.wastedBytes = wastedBytes; self.wastedMs = wastedMs
        self.transferSize = transferSize; self.subLabel = subLabel
    }
}

struct LHAuditResult: Codable, Identifiable {
    var id: String
    var category: LHCategory
    var title: String
    var description: String
    var docsURL: String?        = nil
    var status: LHAuditStatus
    var score: Double?          = nil  // 0.0–1.0; nil for manual/notApplicable
    var weight: Double                 // 0 = informative
    var numericValue: Double?   = nil
    var displayValue: String
    var items: [LHAuditItem]
    /// Estimated saving for opportunities. Set from the full list, because `items` is capped for display.
    var savingsMs: Double? = nil
    var savingsBytes: Int? = nil
    /// How the estimate was made, shown with the audit so an estimate is never mistaken for a measurement.
    var savingsNote: String? = nil
    /// Plain-language remedy, set for failed and warning audits that have guidance.
    var howToFix: String? = nil

    var totalWastedMs: Double {
        items.compactMap(\.wastedMs).reduce(0, +)
    }
    var totalWastedBytes: Int {
        items.compactMap(\.wastedBytes).reduce(0, +)
    }

    /// Passed at 0.9 and above, failed below 0.5, and in between a warning, as in Lighthouse's gauge bands.
    var band: LHAuditBand {
        switch status {
        case .informative, .manual: return .informative
        case .notApplicable: return .notApplicable
        case .pass: return .passed
        case .warning: return .warning
        case .fail:
            if let score, score >= 0.5 { return .warning }
            return .failed
        }
    }
}

/// A rectangle in CSS pixels.
struct LHRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var area: Double { max(width, 0) * max(height, 0) }

    func intersection(_ other: LHRect) -> LHRect? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(x + width, other.x + other.width), bottom = min(y + height, other.y + other.height)
        guard right > left, bottom > top else { return nil }
        return LHRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// One element that moved in a layout shift. `previous` and `current` are viewport rectangles when it shifted;
/// `live` is where the element sits when the audit ran, and is nil if it has since left the page.
struct LHShiftSource: Codable {
    var selector: String
    var nodeID: Int? = nil
    var previous: LHRect? = nil
    var current: LHRect? = nil
    var live: LHRect? = nil
}

struct LHLayoutShift: Codable {
    var value: Double
    var sources: [String]
    var startMs: Double? = nil
    var details: [LHShiftSource]? = nil
}

/// A named slice of a duration, for the phases of LCP and the parts of TTFB.
struct LHTimingPart: Codable, Equatable {
    var name: String
    var ms: Double
}

struct LHLCPDetail: Codable {
    var selector: String
    var tag: String
    var nodeID: Int? = nil
    var snippet: String? = nil
    var url: String? = nil
    /// Where the element sits in the viewport when the audit ran; nil once it has left the page.
    var rect: LHRect? = nil
    var loadMs: Double? = nil
    var renderMs: Double? = nil
    var isLazyLoaded: Bool = false
    var phases: [LHTimingPart] = []
}

struct LHMetrics: Codable {
    var fcp:          Double? = nil
    var lcp:          Double? = nil
    var lcpElement:   String? = nil
    var tbt:          Double? = nil
    var cls:          Double? = nil
    var clsShifts:    [LHLayoutShift] = []
    var inp:          Double? = nil
    var ttfb:         Double? = nil
    var speedIndex:   Double? = nil
    var longTaskCount: Int?  = nil
    var lcpDetail:    LHLCPDetail? = nil
    var ttfbParts:    [LHTimingPart]? = nil
}

struct LHFilmstripFrame: Codable {
    var ms: Double
    /// Pixel similarity to the final frame, 0 to 1, from the same snapshots that feed Speed Index.
    var completeness: Double? = nil
    var jpeg: Data
}

struct LHScreenshot: Codable {
    var jpeg: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var viewportWidth: Double
    var viewportHeight: Double
    var scrollX: Double = 0
    var scrollY: Double = 0

    var viewport: LHRect { LHRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight) }

    /// Overlays are only drawn when the picture and the page's viewport have the same shape, otherwise they would land in the wrong place.
    var alignsWithViewport: Bool {
        guard pixelWidth > 0, pixelHeight > 0, viewportWidth > 0, viewportHeight > 0 else { return false }
        let picture = Double(pixelWidth) / Double(pixelHeight)
        let page = viewportWidth / viewportHeight
        return abs(picture - page) / page <= 0.03
    }
}

/// An element to outline on the screenshot. `rect` is in viewport CSS pixels.
struct LHShotMark: Codable, Identifiable {
    enum Kind: String, Codable { case lcp, layoutShift }

    var kind: Kind
    var label: String
    var selector: String
    var nodeID: Int? = nil
    var rect: LHRect
    var detail: String? = nil

    var id: String { "\(kind.rawValue):\(selector):\(Int(clamping: rect.x)):\(Int(clamping: rect.y))" }
}

struct LHVisuals: Codable {
    var screenshot: LHScreenshot? = nil
    var filmstrip: [LHFilmstripFrame] = []
    var marks: [LHShotMark] = []
    /// Why there is no screenshot, when there is none.
    var note: String? = nil

    /// Marks that fall inside the captured viewport and can be drawn on it.
    var drawnMarks: [LHShotMark] {
        guard let shot = screenshot, shot.alignsWithViewport else { return [] }
        return marks.filter { $0.rect.intersection(shot.viewport) != nil }
    }

    /// Marks that exist but cannot be drawn, listed instead so none is silently dropped.
    var undrawnMarks: [LHShotMark] {
        let drawn = Set(drawnMarks.map(\.id))
        return marks.filter { !drawn.contains($0.id) }
    }
}

enum LHRating: String, Hashable {
    case good, needsImprovement, poor

    var plainWord: String {
        switch self {
        case .good: return "good"
        case .needsImprovement: return "needs improvement"
        case .poor: return "poor"
        }
    }
}

enum LHMetricKind: String, CaseIterable, Identifiable {
    case lcp, cls, inp, fcp, tbt, speedIndex, ttfb

    var id: String { rawValue }

    var isCoreWebVital: Bool { self == .lcp || self == .cls || self == .inp }
    var isUnitless: Bool { self == .cls }

    var title: String {
        switch self {
        case .lcp: return "LCP"
        case .cls: return "CLS"
        case .inp: return "INP"
        case .fcp: return "FCP"
        case .tbt: return "TBT"
        case .speedIndex: return "Speed Index"
        case .ttfb: return "TTFB"
        }
    }

    var fullName: String {
        switch self {
        case .lcp: return "Largest Contentful Paint"
        case .cls: return "Cumulative Layout Shift"
        case .inp: return "Interaction to Next Paint"
        case .fcp: return "First Contentful Paint"
        case .tbt: return "Total Blocking Time"
        case .speedIndex: return "Speed Index"
        case .ttfb: return "Time to First Byte"
        }
    }

    var goodLimit: Double {
        switch self {
        case .lcp: return 2_500
        case .cls: return 0.1
        case .inp: return 200
        case .fcp: return 1_800
        case .tbt: return 200
        case .speedIndex: return 3_400
        case .ttfb: return 800
        }
    }

    var poorLimit: Double {
        switch self {
        case .lcp: return 4_000
        case .cls: return 0.25
        case .inp: return 500
        case .fcp: return 3_000
        case .tbt: return 600
        case .speedIndex: return 5_800
        case .ttfb: return 1_800
        }
    }

    func format(_ value: Double) -> String {
        isUnitless ? String(format: "%.3f", value) : OrbitDevToolsFormat.milliseconds(value)
    }

    var thresholdText: String {
        "Good \u{2264} \(format(goodLimit)). Poor > \(format(poorLimit))."
    }

    func rating(for value: Double) -> LHRating {
        if value <= goodLimit { return .good }
        if value > poorLimit { return .poor }
        return .needsImprovement
    }

    func value(in metrics: LHMetrics) -> Double? {
        switch self {
        case .lcp: return metrics.lcp
        case .cls: return metrics.cls
        case .inp: return metrics.inp
        case .fcp: return metrics.fcp
        case .tbt: return metrics.tbt
        case .speedIndex: return metrics.speedIndex
        case .ttfb: return metrics.ttfb
        }
    }

    /// The audit that carries this metric's evidence in a report.
    var auditID: String {
        switch self {
        case .lcp: return "largest-contentful-paint"
        case .cls: return "cumulative-layout-shift"
        case .inp: return "interaction-to-next-paint"
        case .fcp: return "first-contentful-paint"
        case .tbt: return "total-blocking-time"
        case .speedIndex: return "speed-index"
        case .ttfb: return "server-response-time"
        }
    }

    /// Weight in the Performance score; INP and TTFB are shown but do not count towards it.
    var scoreWeight: Double {
        switch self {
        case .lcp: return 25
        case .cls: return 25
        case .tbt: return 30
        case .fcp: return 10
        case .speedIndex: return 10
        case .inp, .ttfb: return 0
        }
    }

    /// What the metric is and why a visitor would care.
    var explanation: String {
        switch self {
        case .lcp:
            return "How long the largest image or block of text in the first screen takes to appear. It is the moment a visitor feels the main content has loaded."
        case .cls:
            return "How much visible content jumps around while the page loads. Each shift is scored by how much of the screen moved and how far, and the page's figure is its worst burst of shifts."
        case .inp:
            return "How long the page takes to respond to a click, tap or key press. Orbit's figure is a proxy: the longest input delay plus handler time seen by the Event Timing API, without the time to paint the next frame."
        case .fcp:
            return "When the first text or image appears. Until then the visitor sees a blank page."
        case .tbt:
            return "The total time the main thread was blocked for longer than 50 ms after First Contentful Paint. While it is blocked, taps and typing feel stuck."
        case .speedIndex:
            return "How quickly the visible part of the page fills in. Orbit estimates it from small snapshots of the page taken every 100 ms, compared with the final frame."
        case .ttfb:
            return "How long the server takes to start answering, including redirects, DNS, connection set-up and waiting for the first byte."
        }
    }

    var improvement: String {
        switch self {
        case .lcp:
            return "Make the LCP element load sooner: serve a smaller or modern-format image, preload it with fetchpriority=\"high\", never lazy-load it, remove render-blocking CSS and scripts, and speed up the server response."
        case .cls:
            return "Give images, videos, embeds and ads an explicit width and height or an aspect-ratio, reserve space for content that arrives late, and avoid inserting content above what the visitor is already reading."
        case .inp:
            return "Break up long tasks, do less work in event handlers, and move non-urgent work out of the way with requestIdleCallback or setTimeout."
        case .fcp:
            return "Cut the server response time, remove render-blocking CSS and scripts, and inline the CSS needed for the first screen."
        case .tbt:
            return "Split long JavaScript tasks, remove unused code, and defer third-party scripts until after the page is usable."
        case .speedIndex:
            return "Show first-screen content early: inline critical CSS, preload hero images and fonts, and avoid content that only appears after JavaScript has run."
        case .ttfb:
            return "Use a CDN or caching, remove redirect chains, reuse connections, and reduce the server's own work before it responds."
        }
    }

    /// How Orbit measures it, where that differs from a lab run in Chrome. Nil when there is nothing to caveat.
    var measurementNote: String? {
        switch self {
        case .lcp: return "From the Largest Contentful Paint API. Nothing is throttled, so this Mac is faster than a typical phone."
        case .cls: return "From the Layout Instability API. Shifts right after a tap or key press are ignored, as they are expected."
        case .inp: return "Measured in Timespan mode, from the interactions you make while recording."
        case .fcp: return "From the Paint Timing API. Nothing is throttled."
        case .tbt: return "From the Long Tasks API, counting tasks that start after First Contentful Paint. Nothing is throttled."
        case .speedIndex: return "An estimate from 20 by 20 pixel snapshots, not a video of the load."
        case .ttfb: return "From the Navigation Timing API for this page load."
        }
    }

    /// A plain-language reason for the rating, stated from the value and the thresholds.
    func assessment(for value: Double) -> String {
        let shown = format(value)
        switch rating(for: value) {
        case .good:
            return "\(shown) is within the good limit of \(format(goodLimit)), with \(format(goodLimit - value)) to spare."
        case .needsImprovement:
            return "\(shown) is \(format(value - goodLimit)) over the good limit of \(format(goodLimit)) and \(format(poorLimit - value)) under the poor limit of \(format(poorLimit))."
        case .poor:
            return "\(shown) is \(format(value - poorLimit)) past the poor limit of \(format(poorLimit)); a visitor would notice this."
        }
    }
}

struct LHScores: Codable {
    var performance:   Int? = nil
    var accessibility: Int? = nil
    var bestPractices: Int? = nil
    var seo:           Int? = nil
    var security:      Int? = nil
}

extension LHScores {
    subscript(_ cat: LHCategory) -> Int? {
        switch cat {
        case .performance:   return performance
        case .accessibility: return accessibility
        case .bestPractices: return bestPractices
        case .seo:           return seo
        case .security:      return security
        }
    }

    enum Band: String { case good, needsImprovement, poor }

    static func band(for score: Int) -> Band {
        score >= 90 ? .good : score >= 50 ? .needsImprovement : .poor
    }
}

struct LHReport: Codable, Identifiable {
    var id: UUID
    var url: String
    var pageTitle: String
    var timestamp: Date
    var mode: LHRunMode
    var device: LHDevice
    var runCount: Int
    var enabledCategories: [LHCategory]
    var scores: LHScores
    var metrics: LHMetrics
    var audits: [LHAuditResult]
    var throttlingNote: String
    var redistributionNote: String? = nil
    var visuals: LHVisuals? = nil

    /// The screenshots are large, so saved history keeps the numbers and evidence but not the pictures.
    func strippingVisuals() -> LHReport {
        var copy = self
        copy.visuals = nil
        return copy
    }
}

struct LHClsShift {
    var value: Double
    var sources: [String]
    var startMs: Double? = nil
    var details: [LHShiftSource] = []
}
struct LHLongTask    { var startMs: Double; var durationMs: Double }
struct LHHreflangEntry { var lang: String; var href: String }

struct LHHeading {
    var level: Int; var text: String; var nodeID: Int; var selector: String
}

struct LHImage {
    var src: String; var alt: String?   // nil = no attr; "" = decorative
    var naturalWidth: Int; var naturalHeight: Int
    var displayWidth: Int; var displayHeight: Int
    var hasWidthAttr: Bool; var hasHeightAttr: Bool
    var loading: String                 // "lazy" | "eager" | ""
    var nodeID: Int; var selector: String; var snippet: String
    var isAboveFold: Bool; var transferSize: Int; var mimeType: String
}

struct LHLink {
    var href: String; var text: String; var selector: String; var nodeID: Int
    var isGenericText: Bool; var isCrawlable: Bool
    var hasBlankTarget: Bool; var hasNoopener: Bool; var isCrossOrigin: Bool
}

struct LHElement {
    var accessibleName: String; var selector: String; var nodeID: Int; var snippet: String
}

struct LHInput {
    var inputType: String; var hasLabel: Bool; var autocomplete: String
    var selector: String; var nodeID: Int; var snippet: String
}

struct LHFrameEntry {
    var src: String; var title: String; var selector: String; var nodeID: Int
}

struct LHAriaIssue {
    var ruleID: String; var selector: String; var nodeID: Int
    var snippet: String; var detail: String
}

struct LHContrastIssue {
    var selector: String; var nodeID: Int
    var foreground: [Double]; var background: [Double]
    var ratio: Double; var requiredRatio: Double
    var isLargeText: Bool; var needsReview: Bool
}

struct LHTargetEntry {
    var selector: String; var nodeID: Int
    var width: Double; var height: Double; var snippet: String
}

struct LHRenderBlocker {
    var url: String; var type: String; var wastedMs: Double; var transferSize: Int
}

/// One stylesheet and how much of it matched nothing in the current DOM. Sizes are characters of CSS text.
struct LHUnusedCSS {
    var url: String; var totalBytes: Int; var unusedBytes: Int; var unusedRules: Int
    var nodeID: Int; var selector: String
}

/// An element that failed a check that has no richer record of its own.
struct LHEvidenceNode {
    var selector: String; var nodeID: Int; var snippet: String
}

struct LHDeprecatedElement {
    var tag: String; var selector: String; var nodeID: Int
}

struct LHSmallFontNode {
    var selector: String; var nodeID: Int; var fontSize: Double; var snippet: String
}

struct LHAnimation {
    var selector: String; var nodeID: Int; var type: String
    var properties: [String]; var triggersPaint: Bool; var triggersLayout: Bool
    var isInfinite: Bool; var respectsReducedMotion: Bool
}

struct LHNetRecord {
    var id: String; var url: String; var resourceType: String; var mimeType: String
    var status: Int; var transferSize: Int?; var bodySize: Int?
    var startMs: Double?; var durationMs: Double?
    var fromCache: Bool; var failed: Bool; var protocolName: String?
    var requestHeaders: [String: String]; var responseHeaders: [String: String]
    var initiatorURL: String?
}

struct LHBundle {
    var url:            String = ""
    var pageTitle:      String = ""
    var timestamp:      Date   = Date()
    var mode:           LHRunMode            = .snapshot
    var device:         LHDevice             = .mobile
    var enabledCategories: Set<LHCategory>   = Set(LHCategory.allCases)

    var fcpMs:              Double?           = nil
    var lcpMs:              Double?           = nil
    var lcpSelector:        String            = ""
    var lcpURL:             String            = ""
    var clsScore:           Double            = 0
    var clsShifts:          [LHClsShift]      = []
    /// True when the page reported more shifts than were kept, so the shift list cannot be summed into a worst burst.
    var clsShiftsTruncated: Bool              = false
    var lcpDetail:          LHLCPDetail?      = nil
    var ttfbParts:          [LHTimingPart]    = []
    var inpMs:              Double?           = nil
    var ttfbMs:             Double?           = nil
    var longTasks:          [LHLongTask]      = []
    var longTasksAPIAvailable: Bool           = false
    var timespanDurationMs: Double?           = nil
    var siFrames:           [(ms: Double, completeness: Double)] = []

    var htmlLang:           String?           = nil   // nil = no lang attr
    var documentTitle:      String            = ""
    var hasDoctype:         Bool              = false
    var charset:            String?           = nil
    var hasViewport:        Bool              = false
    var viewportContent:    String            = ""
    var metaDescription:    String            = ""
    var canonicalURL:       String?           = nil
    var hreflangLinks:      [LHHreflangEntry] = []
    var robotsMetaContent:  String            = ""   // e.g. "noindex,nofollow"
    var httpStatus:         Int               = 200

    var headings:           [LHHeading]       = []
    var images:             [LHImage]         = []
    var links:              [LHLink]          = []
    var buttons:            [LHElement]       = []
    var inputs:             [LHInput]         = []
    var frames:             [LHFrameEntry]    = []
    var ariaIssues:         [LHAriaIssue]     = []
    var contrastIssues:     [LHContrastIssue] = []
    var smallTargets:       [LHTargetEntry]   = []
    var totalInteractiveTargets: Int          = 0

    var domNodeCount:       Int               = 0
    var domMaxDepth:        Int               = 0
    var domMaxChildCount:   Int               = 0

    var renderBlockers:     [LHRenderBlocker] = []
    var fontDisplayIssues:  [String]          = []
    var lcpHasFetchPriority: Bool             = false
    var preconnectOrigins:  [String]          = []
    var devicePixelRatio:   Double            = 1
    var unusedCSS:          [LHUnusedCSS]     = []
    /// Stylesheets the page could not read (cross-origin) or that were cut off by the time budget.
    var cssSkipped:         Int               = 0

    var hasDocumentDomain:  Bool              = false
    var hasSyncXHR:         Bool              = false
    var hasDocumentWrite:   Bool              = false
    var hasUnloadListeners: Bool              = false
    var geoPromptDuringLoad: Bool            = false
    var notifPromptDuringLoad: Bool          = false

    var deprecatedElements: [LHDeprecatedElement] = []
    var smallFontNodes:     [LHSmallFontNode] = []
    var totalTextNodes:     Int               = 0

    var jsonLDScripts:      [String]          = []
    var animations:         [LHAnimation]     = []

    var hasMainLandmark:    Bool              = false
    var hasSkipLink:        Bool              = false
    var videosWithoutCaptions: Int           = 0
    var scrollableNotFocusable: Int          = 0
    var nestedInteractiveCount: Int          = 0
    var duplicateActiveIDs: [String]          = []
    var positiveTabindexCount: Int           = 0
    var blankTargetNoopenerIssues: [LHLink]  = []
    var nestedInteractiveNodes: [LHEvidenceNode] = []
    var unfocusableScrollRegions: [LHEvidenceNode] = []
    var videosWithoutCaptionNodes: [LHEvidenceNode] = []
    var positiveTabindexNodes: [LHEvidenceNode] = []

    var screenshot:         LHScreenshot?     = nil
    var screenshotNote:     String?           = nil
    var filmstrip:          [LHFilmstripFrame] = []

    var networkRecords:     [LHNetRecord]     = []

    var consoleErrorCount:   Int              = 0
    var consoleErrorMessages: [String]        = []

    var robotsTxtContent:   String?           = nil

    // Security evidence (TLS chain, headers, cookies, DOM). Nil when the Security tool had nothing to offer.
    var security:           OrbitSecurityInput? = nil
}


enum OrbitLighthouseLogic {

    /// Log-normal CDF score for a "lower is better" metric: `p10` scores 0.9 and `median` scores 0.5.
    static func logNormalScore(value: Double, p10: Double, median: Double) -> Double {
        guard value > 0, p10 > 0, median > 0, p10 < median else {
            return value <= p10 ? 1.0 : 0.0
        }
        let mu = log(median)
        let phiInv09: Double = 1.2815515655446004   // Φ^-1(0.9)
        let sigma = (log(median) - log(p10)) / phiInv09
        let z = (log(value) - mu) / sigma
        // 1 - Φ(z) = erfc(z / √2) / 2
        let score = erfc(z / 1.4142135623730951) / 2.0
        return max(0.0, min(1.0, score))
    }

    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double {
            let v = c / 255.0
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrastRatioOpaque(fg: [Double], bg: [Double]) -> Double {
        guard fg.count >= 3, bg.count >= 3 else { return 1.0 }
        let l1 = relativeLuminance(r: fg[0], g: fg[1], b: fg[2])
        let l2 = relativeLuminance(r: bg[0], g: bg[1], b: bg[2])
        let lighter = max(l1, l2)
        let darker  = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func compositeOver(top: [Double], bottom: [Double]) -> [Double] {
        guard top.count >= 4, bottom.count >= 4 else { return top }
        let a = top[3]
        if a >= 1.0 { return top }
        let botA = bottom[3]
        let outA = a + botA * (1.0 - a)
        guard outA > 0 else { return [0, 0, 0, 0] }
        func blend(_ tc: Double, _ bc: Double) -> Double {
            return (tc * a + bc * botA * (1.0 - a)) / outA
        }
        return [blend(top[0], bottom[0]), blend(top[1], bottom[1]),
                blend(top[2], bottom[2]), outA]
    }

    /// Sum of (duration − 50 ms) for long tasks after FCP; nil when the long tasks API was unavailable.
    static func computeTBT(longTasks: [LHLongTask], fcpMs: Double?, apiAvailable: Bool) -> Double? {
        guard apiAvailable, let fcp = fcpMs else { return nil }
        return longTasks
            .filter { $0.startMs >= fcp }
            .reduce(0.0) { acc, task in acc + max(0.0, task.durationMs - 50.0) }
    }

    /// Trapezoidal integration over frames of (elapsedMs, completeness), where completeness is pixel similarity to the final frame.
    static func computeSpeedIndex(frames: [(ms: Double, completeness: Double)]) -> Double? {
        guard frames.count >= 2 else { return nil }
        var si = 0.0
        for i in 1 ..< frames.count {
            let dt = frames[i].ms - frames[i - 1].ms
            guard dt > 0 else { continue }
            let avgIncomplete = ((1.0 - frames[i].completeness) + (1.0 - frames[i - 1].completeness)) / 2.0
            si += dt * avgIncomplete
        }
        return si
    }


    static func isCompressible(mimeType: String) -> Bool {
        let m = mimeType.lowercased()
        return m.hasPrefix("text/")
            || m == "application/javascript"
            || m == "application/json"
            || m == "application/xml"
            || m == "application/x-javascript"
            || m == "application/xhtml+xml"
            || m == "image/svg+xml"
            || m == "application/wasm"
    }

    static func isStaticAsset(resourceType: String, url: String) -> Bool {
        if ["script", "stylesheet", "font", "image", "media", "wasm"].contains(resourceType) { return true }
        let lower = url.lowercased().components(separatedBy: "?")[0]
        return [".js", ".css", ".woff", ".woff2", ".ttf", ".otf",
                ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif",
                ".svg", ".ico", ".mp4", ".webm", ".wav", ".mp3"].contains { lower.hasSuffix($0) }
    }

    static func isModernImageFormat(mimeType: String) -> Bool {
        ["image/webp", "image/avif", "image/jxl"].contains(mimeType.lowercased())
    }

    static func robotsTxtDisallows(txt: String, userAgent: String = "Googlebot", path: String) -> Bool {
        var inBlock = false
        for raw in txt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let colon = line.firstIndex(of: ":")
            guard let colon else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if field == "user-agent" {
                inBlock = value == "*" || value.lowercased() == userAgent.lowercased()
            } else if field == "disallow" && inBlock {
                if value.isEmpty { return false }
                if path.hasPrefix(value) { return true }
            }
        }
        return false
    }

    /// A simplified BCP 47 check.
    static func isValidLangTag(_ lang: String) -> Bool {
        let trimmed = lang.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.components(separatedBy: "-")
        guard let primary = parts.first, primary.count >= 2, primary.count <= 8 else { return false }
        return primary.allSatisfy(\.isLetter)
    }

    /// Audits with a nil score or zero weight are excluded from the denominator.
    static func categoryScore(_ audits: [LHAuditResult], category: LHCategory) -> Int? {
        let relevant = audits.filter { $0.category == category && $0.weight > 0 && $0.score != nil }
        let totalW = relevant.reduce(0.0) { $0 + $1.weight }
        guard totalW > 0 else { return nil }
        let weighted = relevant.reduce(0.0) { $0 + $1.weight * ($1.score ?? 0) }
        return Int((weighted / totalW * 100).rounded())
    }


    static func medianReport(runs: [LHReport]) -> LHReport {
        precondition(!runs.isEmpty)
        guard runs.count > 1 else { return runs[0] }

        func medDouble(_ vals: [Double?]) -> Double? {
            let v = vals.compactMap { $0 }.sorted()
            guard !v.isEmpty else { return nil }
            return v.count % 2 == 0 ? (v[v.count/2 - 1] + v[v.count/2]) / 2 : v[v.count/2]
        }
        func medInt(_ vals: [Int?]) -> Int? {
            let v = vals.compactMap { $0 }.sorted()
            guard !v.isEmpty else { return nil }
            return v[v.count / 2]
        }

        let perfScores = runs.compactMap(\.scores.performance)
        let medPerf = perfScores.sorted()[perfScores.count / 2]
        var rep = runs.min(by: {
            abs(($0.scores.performance ?? 0) - medPerf) < abs(($1.scores.performance ?? 0) - medPerf)
        }) ?? runs[0]

        rep.metrics.fcp = medDouble(runs.map(\.metrics.fcp))
        rep.metrics.lcp = medDouble(runs.map(\.metrics.lcp))
        rep.metrics.tbt = medDouble(runs.map(\.metrics.tbt))
        rep.metrics.cls = medDouble(runs.map(\.metrics.cls))
        rep.metrics.ttfb = medDouble(runs.map(\.metrics.ttfb))
        rep.metrics.speedIndex = medDouble(runs.map(\.metrics.speedIndex))
        rep.scores.performance  = medInt(runs.map(\.scores.performance))
        rep.scores.accessibility = medInt(runs.map(\.scores.accessibility)) ?? rep.scores.accessibility
        rep.scores.bestPractices = medInt(runs.map(\.scores.bestPractices)) ?? rep.scores.bestPractices
        rep.scores.seo           = medInt(runs.map(\.scores.seo)) ?? rep.scores.seo
        rep.scores.security      = medInt(runs.map(\.scores.security)) ?? rep.scores.security
        rep.runCount = runs.count
        return rep
    }


    static func score(bundle: LHBundle) -> LHReport {
        var audits: [LHAuditResult] = []
        let cats = bundle.enabledCategories

        if cats.contains(.performance)   { audits += performanceAudits(bundle: bundle) }
        if cats.contains(.accessibility) { audits += accessibilityAudits(bundle: bundle) }
        if cats.contains(.bestPractices) { audits += bestPracticesAudits(bundle: bundle) }
        if cats.contains(.seo)           { audits += seoAudits(bundle: bundle) }
        if cats.contains(.security)      { audits += securityAudits(bundle: bundle) }
        audits += networkAudits(bundle: bundle)
        audits = audits.map { withEstimatedSavings($0, device: bundle.device) }.map(withGuidance)

        let tbt = computeTBT(longTasks: bundle.longTasks, fcpMs: bundle.fcpMs, apiAvailable: bundle.longTasksAPIAvailable)
        let si  = computeSpeedIndex(frames: bundle.siFrames)

        // Note redistribution when some performance metrics are absent
        let perfWeightExpected: Double = 100
        let perfMeasured = audits.filter { $0.category == .performance && $0.weight > 0 && $0.score != nil }.reduce(0.0) { $0 + $1.weight }
        let redist: String? = (cats.contains(.performance) && perfMeasured < perfWeightExpected - 0.5 && bundle.mode != .snapshot)
            ? "Performance score excludes unmeasurable metrics (weights redistributed proportionally)."
            : nil

        let navOrTimespan = bundle.mode == .navigation
        let scores = LHScores(
            performance:   (cats.contains(.performance) && navOrTimespan) ? categoryScore(audits, category: .performance) : nil,
            accessibility:  cats.contains(.accessibility) ? categoryScore(audits, category: .accessibility) : nil,
            bestPractices:  cats.contains(.bestPractices) ? categoryScore(audits, category: .bestPractices) : nil,
            seo:            cats.contains(.seo) ? categoryScore(audits, category: .seo) : nil,
            security:       cats.contains(.security) ? categoryScore(audits, category: .security) : nil
        )

        let shifts = layoutShifts(bundle)
        let parts = ttfbBreakdown(parts: bundle.ttfbParts, ttfbMs: bundle.ttfbMs)
        let metrics = LHMetrics(
            fcp: bundle.fcpMs, lcp: bundle.lcpMs,
            lcpElement: bundle.lcpSelector.isEmpty ? nil : bundle.lcpSelector,
            tbt: tbt, cls: effectiveCLS(bundle),
            clsShifts: shifts,
            inp: bundle.inpMs, ttfb: bundle.ttfbMs, speedIndex: si,
            longTaskCount: bundle.longTasksAPIAvailable ? bundle.longTasks.count : nil,
            lcpDetail: bundle.lcpDetail,
            ttfbParts: parts.isEmpty ? nil : parts
        )

        return LHReport(
            id: UUID(), url: bundle.url, pageTitle: bundle.pageTitle,
            timestamp: bundle.timestamp, mode: bundle.mode, device: bundle.device,
            runCount: 1, enabledCategories: Array(bundle.enabledCategories),
            scores: scores, metrics: metrics, audits: audits,
            throttlingNote: "No CPU or network throttling applied; metrics measured on this Mac.",
            redistributionNote: redist,
            visuals: visuals(bundle: bundle, shifts: shifts)
        )
    }

    // MARK: Decoding what the page agent sends

    /// A rectangle sent as [left, top, width, height]; nil for anything else.
    static func decodeRect(_ value: Any?) -> LHRect? {
        guard let parts = value as? [Any], parts.count == 4 else { return nil }
        let numbers = parts.compactMap { OrbitInspectDecode.number(["v": $0], "v") }
        guard numbers.count == 4 else { return nil }
        return LHRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    static func decodeShifts(_ objects: [[String: Any]]) -> [LHClsShift] {
        objects.map { shift in
            let details = OrbitInspectDecode.objects(shift, "det").map { detail -> LHShiftSource in
                let id = OrbitInspectDecode.integer(detail, "id")
                return LHShiftSource(selector: OrbitInspectDecode.string(detail, "sel"), nodeID: id > 0 ? id : nil,
                                     previous: decodeRect(detail["prev"]), current: decodeRect(detail["cur"]),
                                     live: decodeRect(detail["live"]))
            }
            return LHClsShift(value: OrbitInspectDecode.number(shift, "v") ?? 0, sources: OrbitInspectDecode.strings(shift, "srcs"),
                              startMs: OrbitInspectDecode.number(shift, "t"), details: details)
        }
    }

    /// Nil when the page reported no LCP. The phases come from the page's own resource timing for the LCP image, if it has one.
    static func decodeLCPDetail(_ object: [String: Any]?, lcpMs: Double?, ttfbMs: Double?) -> LHLCPDetail? {
        guard let object, let lcpMs else { return nil }
        let id = OrbitInspectDecode.integer(object, "id")
        let url = OrbitInspectDecode.optionalString(object, "url")
        let timed = url != nil
        return LHLCPDetail(
            selector: OrbitInspectDecode.string(object, "sel"),
            tag: OrbitInspectDecode.string(object, "tag"),
            nodeID: id > 0 ? id : nil,
            snippet: OrbitInspectDecode.optionalString(object, "snip"),
            url: url,
            rect: decodeRect(object["rect"]),
            loadMs: OrbitInspectDecode.number(object, "load"),
            renderMs: OrbitInspectDecode.number(object, "render"),
            isLazyLoaded: OrbitInspectDecode.bool(object, "lazy"),
            phases: lcpPhases(lcpMs: lcpMs, ttfbMs: ttfbMs,
                              resourceStartMs: timed ? OrbitInspectDecode.number(object, "resStart") : nil,
                              resourceEndMs: timed ? OrbitInspectDecode.number(object, "resEnd") : nil)
        )
    }

    static func decodeEvidence(_ objects: [[String: Any]]) -> [LHEvidenceNode] {
        objects.map {
            LHEvidenceNode(selector: OrbitInspectDecode.string($0, "sel"), nodeID: OrbitInspectDecode.integer($0, "id"),
                           snippet: OrbitInspectDecode.string($0, "snip"))
        }
    }

    static func decodeTimingParts(_ objects: [[String: Any]]) -> [LHTimingPart] {
        objects.compactMap { part in
            guard let ms = OrbitInspectDecode.number(part, "ms") else { return nil }
            return LHTimingPart(name: OrbitInspectDecode.string(part, "n"), ms: ms)
        }
    }

    static func layoutShifts(_ bundle: LHBundle) -> [LHLayoutShift] {
        bundle.clsShifts.map {
            LHLayoutShift(value: $0.value, sources: $0.sources, startMs: $0.startMs,
                          details: $0.details.isEmpty ? nil : $0.details)
        }
    }

    /// The worst burst of shifts when every shift's time is known and none was dropped, otherwise the page's running total.
    static func effectiveCLS(_ bundle: LHBundle) -> Double {
        let timed = bundle.clsShifts.compactMap { shift in shift.startMs.map { (startMs: $0, value: shift.value) } }
        guard !bundle.clsShifts.isEmpty, !bundle.clsShiftsTruncated, timed.count == bundle.clsShifts.count else {
            return bundle.clsScore
        }
        return clsSessionWindowMax(timed)
    }

    /// CLS as the Core Web Vitals define it: shifts group into windows that end after a 1 s gap or 5 s in total, and the largest window counts.
    static func clsSessionWindowMax(_ shifts: [(startMs: Double, value: Double)]) -> Double {
        var best = 0.0, current = 0.0
        var windowStart = 0.0, previous = 0.0
        var open = false
        for shift in shifts.sorted(by: { $0.startMs < $1.startMs }) {
            if open, shift.startMs - previous < 1_000, shift.startMs - windowStart < 5_000 {
                current += shift.value
            } else {
                current = shift.value
                windowStart = shift.startMs
                open = true
            }
            previous = shift.startMs
            best = max(best, current)
        }
        return best
    }

    /// A layout-shift culprit: an element and the part of the total shift attributed to it.
    struct ShiftCulprit {
        var selector: String
        var nodeID: Int?
        var value: Double
        var shiftCount: Int
        var live: LHRect?
        var lastKnown: LHRect?
    }

    /// A shift's score belongs to the whole shift, so it is split between the elements that moved in proportion to the area each covers.
    static func clsCulprits(_ shifts: [LHLayoutShift]) -> [ShiftCulprit] {
        var order: [String] = []
        var byName: [String: ShiftCulprit] = [:]
        for shift in shifts {
            let sources = shift.details ?? shift.sources.map { LHShiftSource(selector: $0) }
            guard !sources.isEmpty else { continue }
            let areas = sources.map { max($0.previous?.area ?? 0, $0.current?.area ?? 0) }
            let total = areas.reduce(0, +)
            for (index, source) in sources.enumerated() {
                let name = source.selector.isEmpty ? "(unnamed element)" : source.selector
                let share = total > 0 ? areas[index] / total : 1 / Double(sources.count)
                if byName[name] == nil {
                    order.append(name)
                    byName[name] = ShiftCulprit(selector: name, nodeID: nil, value: 0, shiftCount: 0, live: nil, lastKnown: nil)
                }
                var entry = byName[name]!
                entry.value += shift.value * share
                entry.shiftCount += 1
                if let id = source.nodeID, id > 0 { entry.nodeID = id }
                if let live = source.live { entry.live = live }
                if let current = source.current { entry.lastKnown = current }
                byName[name] = entry
            }
        }
        return order.compactMap { byName[$0] }.sorted { $0.value > $1.value }
    }

    /// Phases that add up to the LCP time: server, then the wait to start the image, the image download, and the paint.
    /// Without a resource (text, or an image the page cannot time) the time after the first byte is all render delay.
    static func lcpPhases(lcpMs: Double, ttfbMs: Double?, resourceStartMs: Double?, resourceEndMs: Double?) -> [LHTimingPart] {
        guard lcpMs > 0 else { return [] }
        let first = min(max(ttfbMs ?? 0, 0), lcpMs)
        guard let start = resourceStartMs, let end = resourceEndMs else {
            return [LHTimingPart(name: "Time to first byte", ms: first),
                    LHTimingPart(name: "Element render delay", ms: lcpMs - first)]
        }
        let requested = min(max(start, first), lcpMs)
        let loaded = min(max(end, requested), lcpMs)
        return [LHTimingPart(name: "Time to first byte", ms: first),
                LHTimingPart(name: "Resource load delay", ms: requested - first),
                LHTimingPart(name: "Resource load time", ms: loaded - requested),
                LHTimingPart(name: "Element render delay", ms: lcpMs - loaded)]
    }

    /// The parts the page reported, plus whatever of the TTFB they do not explain (queueing, cache lookups, service workers).
    static func ttfbBreakdown(parts: [LHTimingPart], ttfbMs: Double?) -> [LHTimingPart] {
        let known = parts.filter { $0.ms >= 0.5 }
        guard let ttfbMs, ttfbMs > 0 else { return known }
        let rest = ttfbMs - known.reduce(0) { $0 + $1.ms }
        return rest >= 1 ? known + [LHTimingPart(name: "Queueing and other", ms: rest)] : known
    }

    /// Which frames to keep for the filmstrip: drop frames that look like the one before, then thin the rest evenly.
    /// The first and last frames are always kept.
    static func filmstripSelection(completeness: [Double?], maxFrames: Int) -> [Int] {
        guard maxFrames > 0, !completeness.isEmpty else { return [] }
        let last = completeness.count - 1
        if maxFrames == 1 { return [last] }
        var kept: [Int] = []
        for index in completeness.indices {
            if index == 0 || index == last { kept.append(index); continue }
            if let value = completeness[index], let before = completeness[kept[kept.count - 1]], abs(value - before) < 0.02 {
                continue
            }
            kept.append(index)
        }
        guard kept.count > maxFrames else { return kept }
        var picked: [Int] = []
        for slot in 0 ..< maxFrames {
            let position = Int((Double(slot) * Double(kept.count - 1) / Double(maxFrames - 1)).rounded())
            if picked.last != kept[position] { picked.append(kept[position]) }
        }
        return picked
    }

    /// Tags the first frame at or after each paint time, so the strip shows where FCP and LCP fell.
    static func filmstripMilestones(frameMs: [Double], fcpMs: Double?, lcpMs: Double?) -> [[String]] {
        var tags = [[String]](repeating: [], count: frameMs.count)
        for (name, time) in [("FCP", fcpMs), ("LCP", lcpMs)] {
            guard let time, let index = frameMs.firstIndex(where: { $0 >= time }) else { continue }
            tags[index].append(name)
        }
        return tags
    }

    /// A rectangle as fractions (0 to 1) of the viewport, clipped to it. Nil when it lies entirely outside.
    static func fractionalRect(_ rect: LHRect, in viewport: LHRect) -> LHRect? {
        guard viewport.width > 0, viewport.height > 0, let clipped = rect.intersection(viewport) else { return nil }
        return LHRect(x: (clipped.x - viewport.x) / viewport.width, y: (clipped.y - viewport.y) / viewport.height,
                      width: clipped.width / viewport.width, height: clipped.height / viewport.height)
    }

    static func visuals(bundle: LHBundle, shifts: [LHLayoutShift]) -> LHVisuals? {
        var marks: [LHShotMark] = []
        if let lcp = bundle.lcpDetail, let rect = lcp.rect {
            marks.append(LHShotMark(
                kind: .lcp, label: "LCP element", selector: lcp.selector, nodeID: lcp.nodeID, rect: rect,
                detail: "<\(lcp.tag)> \(Int(clamping: rect.width.rounded())) by \(Int(clamping: rect.height.rounded())) px"
            ))
        }
        // Shifts happen during load at the top of the page, so where an element has since left the page its position
        // at the shift is only offered while the page is still scrolled to the top.
        let atTop = (bundle.screenshot?.scrollX ?? 0) == 0 && (bundle.screenshot?.scrollY ?? 0) == 0
        for culprit in clsCulprits(shifts).prefix(5) {
            if let live = culprit.live {
                marks.append(LHShotMark(kind: .layoutShift, label: "Shifted: " + String(format: "%.3f", culprit.value),
                                        selector: culprit.selector, nodeID: culprit.nodeID, rect: live))
            } else if atTop, let known = culprit.lastKnown {
                marks.append(LHShotMark(kind: .layoutShift, label: "Shifted: " + String(format: "%.3f", culprit.value),
                                        selector: culprit.selector, nodeID: culprit.nodeID, rect: known,
                                        detail: "Position when it shifted; the element is no longer on the page."))
            }
        }
        let visuals = LHVisuals(screenshot: bundle.screenshot, filmstrip: bundle.filmstrip, marks: marks,
                                note: bundle.screenshot == nil ? bundle.screenshotNote : nil)
        if visuals.screenshot == nil && visuals.filmstrip.isEmpty && visuals.note == nil { return nil }
        return visuals
    }

    /// One row of the score breakdown. `points` out of `maxPoints` is what the audit adds to the category score.
    struct ScoreContribution: Identifiable {
        var id: String
        var title: String
        var displayValue: String
        var score: Double?
        var weight: Double
        var maxPoints: Double
        var points: Double
        /// False when the audit could not be measured; its weight is then shared among the audits that were.
        var measured: Bool

        var pointsLost: Double { maxPoints - points }
    }

    /// How each weighted audit contributes to a category score, largest loss first. Measured points add up to the unrounded category score.
    static func scoreBreakdown(_ audits: [LHAuditResult], category: LHCategory) -> [ScoreContribution] {
        let weighted = audits.filter { $0.category == category && $0.weight > 0 }
        let totalWeight = weighted.filter { $0.score != nil }.reduce(0.0) { $0 + $1.weight }
        let rows = weighted.map { audit -> ScoreContribution in
            guard let score = audit.score, totalWeight > 0 else {
                return ScoreContribution(id: audit.id, title: audit.title, displayValue: audit.displayValue, score: nil,
                                         weight: audit.weight, maxPoints: 0, points: 0, measured: false)
            }
            let ceiling = audit.weight / totalWeight * 100
            return ScoreContribution(id: audit.id, title: audit.title, displayValue: audit.displayValue, score: score,
                                     weight: audit.weight, maxPoints: ceiling, points: ceiling * score, measured: true)
        }
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.measured != rhs.element.measured { return lhs.element.measured }
            if lhs.element.pointsLost != rhs.element.pointsLost { return lhs.element.pointsLost > rhs.element.pointsLost }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }


    private static func performanceAudits(bundle: LHBundle) -> [LHAuditResult] {
        let dev = bundle.device
        let nav = bundle.mode == .navigation
        let ts  = bundle.mode == .timespan
        var out: [LHAuditResult] = []

        out.append(metricAudit(
            id: "first-contentful-paint",
            title: "First Contentful Paint",
            desc: "Time until the browser renders the first text or image.",
            docs: "https://developer.chrome.com/docs/lighthouse/performance/first-contentful-paint/",
            value: nav ? bundle.fcpMs : nil, curve: dev.fcpCurve, weight: 10, unit: .timeMs
        ))

        let lcpItems = lcpAuditItems(bundle)
        out.append(metricAudit(
            id: "largest-contentful-paint",
            title: "Largest Contentful Paint",
            desc: "Time until the browser renders the largest text block or image.",
            docs: "https://developer.chrome.com/docs/lighthouse/performance/largest-contentful-paint/",
            value: nav ? bundle.lcpMs : nil, curve: dev.lcpCurve, weight: 25, unit: .timeMs, items: lcpItems
        ))

        if !bundle.longTasksAPIAvailable {
            out.append(naAudit("total-blocking-time", .performance,
                               "Total Blocking Time",
                               "Long Tasks API not available in this WebKit version; TBT cannot be measured.",
                               weight: 30))
        } else {
            let tbt = computeTBT(longTasks: bundle.longTasks, fcpMs: bundle.fcpMs, apiAvailable: true)
            out.append(metricAudit(
                id: "total-blocking-time",
                title: "Total Blocking Time",
                desc: "Sum of (duration − 50 ms) for long tasks after FCP.",
                docs: "https://developer.chrome.com/docs/lighthouse/performance/lighthouse-total-blocking-time/",
                value: nav ? tbt : nil, curve: dev.tbtCurve, weight: 30, unit: .timeMs,
                items: blockingTaskItems(bundle)
            ))
        }

        let cls = effectiveCLS(bundle)
        out.append(metricAudit(
            id: "cumulative-layout-shift",
            title: "Cumulative Layout Shift",
            desc: "Unexpected layout shifts during page load.",
            docs: "https://developer.chrome.com/docs/lighthouse/performance/cls/",
            value: nav ? cls : nil,
            rawOverride: nav ? cls : nil,
            curve: dev.clsCurve, weight: 25, unit: .cls, items: clsAuditItems(bundle)
        ))

        if let si = computeSpeedIndex(frames: bundle.siFrames), nav {
            out.append(metricAudit(
                id: "speed-index",
                title: "Speed Index",
                desc: "How quickly page contents are visibly populated (visual-progress from compositor snapshots).",
                docs: "https://developer.chrome.com/docs/lighthouse/performance/speed-index/",
                value: si, curve: dev.siCurve, weight: 10, unit: .timeMs
            ))
        } else {
            out.append(naAudit("speed-index", .performance, "Speed Index",
                               "No compositor snapshots available; Speed Index cannot be computed.",
                               weight: 10))
        }

        if let ttfb = bundle.ttfbMs, nav {
            let score = ttfb <= 800 ? 1.0 : ttfb <= 1800 ? max(0, (1800 - ttfb) / 1000) : 0.0
            out.append(LHAuditResult(
                id: "server-response-time", category: .performance,
                title: "Initial server response time was short",
                description: "Time to First Byte (TTFB). Target: ≤ 800 ms.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/time-to-first-byte/",
                status: ttfb <= 800 ? .pass : .fail, score: score, weight: 0,
                numericValue: ttfb, displayValue: formatMs(ttfb),
                items: ttfbBreakdown(parts: bundle.ttfbParts, ttfbMs: ttfb).map {
                    LHAuditItem(label: $0.name, subLabel: formatMs($0.ms) + " (\(percentOf($0.ms, of: ttfb)))")
                }
            ))
        }

        let domScore: Double = bundle.domNodeCount < 800 ? 1 : bundle.domNodeCount < 1500 ? 0.5 : 0
        out.append(LHAuditResult(
            id: "dom-size", category: .performance,
            title: "Avoids an excessive DOM size",
            description: "Large DOMs slow rendering. Lighthouse recommends fewer than 1,500 elements.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/performance/dom-size/",
            status: bundle.domNodeCount > 1500 ? .fail : .pass, score: domScore, weight: 0,
            numericValue: Double(bundle.domNodeCount), displayValue: "\(bundle.domNodeCount) elements",
            items: bundle.domNodeCount > 800 ? [
                LHAuditItem(label: "\(bundle.domNodeCount) total elements"),
                LHAuditItem(label: "Maximum depth: \(bundle.domMaxDepth)"),
                LHAuditItem(label: "Maximum children: \(bundle.domMaxChildCount)")
            ] : []
        ))

        if bundle.longTasksAPIAvailable && nav {
            let taskItems = bundle.longTasks.prefix(10).map {
                LHAuditItem(label: formatMs($0.durationMs), subLabel: "at \(formatMs($0.startMs))")
            }
            out.append(LHAuditResult(
                id: "long-tasks", category: .performance,
                title: "Avoid long main-thread tasks",
                description: "Tasks longer than 50 ms block the main thread and delay interaction.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/long-tasks/",
                status: bundle.longTasks.isEmpty ? .pass : .informative, score: nil, weight: 0,
                numericValue: Double(bundle.longTasks.count),
                displayValue: "\(bundle.longTasks.count) long task(s)",
                items: Array(taskItems)
            ))
        }

        if ts, let inp = bundle.inpMs {
            let inpScore = inp < 200 ? 1.0 : inp < 500 ? 0.5 : 0.0
            out.append(LHAuditResult(
                id: "interaction-to-next-paint", category: .performance,
                title: "Interaction to Next Paint",
                description: "Worst interaction delay during the timespan.",
                docsURL: nil,
                status: inp < 200 ? .pass : .fail, score: inpScore, weight: 0,
                numericValue: inp, displayValue: formatMs(inp), items: []
            ))
        }

        if !bundle.renderBlockers.isEmpty {
            // Blocking resources download in parallel, so the time a page can win back is the slowest one, not the sum.
            let savedMs = renderBlockingSavingsMs(bundle.renderBlockers, fcpMs: bundle.fcpMs)
            out.append(LHAuditResult(
                id: "render-blocking-resources", category: .performance,
                title: "Eliminate render-blocking resources",
                description: "Synchronous <script> or <link rel=stylesheet> in <head> blocks first paint.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/render-blocking-resources/",
                status: .fail, score: 0, weight: 0,
                numericValue: savedMs, displayValue: "~\(formatMs(savedMs)) savings",
                items: bundle.renderBlockers.prefix(20).map {
                    LHAuditItem(url: $0.url, wastedMs: $0.wastedMs, transferSize: $0.transferSize, subLabel: $0.type)
                },
                savingsMs: savedMs,
                savingsNote: "Estimated from each resource's load time in Resource Timing. Resources load in parallel, so the saving is the slowest blocker, capped at First Contentful Paint."
            ))
        }

        let paintAnims = bundle.animations.filter { $0.triggersPaint || $0.triggersLayout }
        if !paintAnims.isEmpty {
            out.append(LHAuditResult(
                id: "non-composited-animations", category: .performance,
                title: "Avoid non-composited animations",
                description: "Animations that trigger layout or paint cannot run on the compositor thread.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/non-composited-animations/",
                status: .fail, score: 0, weight: 0,
                numericValue: Double(paintAnims.count), displayValue: "\(paintAnims.count) animation(s)",
                items: paintAnims.prefix(20).map {
                    LHAuditItem(selector: $0.selector, label: $0.properties.joined(separator: ", "), subLabel: $0.triggersLayout ? "layout" : "paint")
                }
            ))
        }

        let rmViol = bundle.animations.filter { !$0.respectsReducedMotion }
        if !rmViol.isEmpty {
            out.append(LHAuditResult(
                id: "prefers-reduced-motion", category: .performance,
                title: "Respects prefers-reduced-motion",
                description: "Animations not inside a @media (prefers-reduced-motion) query may cause discomfort.",
                docsURL: nil,
                status: .fail, score: 0, weight: 0,
                numericValue: Double(rmViol.count), displayValue: "\(rmViol.count) animation(s)",
                items: rmViol.prefix(20).map {
                    LHAuditItem(selector: $0.selector, label: $0.properties.joined(separator: ", "))
                }
            ))
        }

        if !bundle.lcpURL.isEmpty && !bundle.lcpHasFetchPriority {
            out.append(LHAuditResult(
                id: "preload-lcp-image", category: .performance,
                title: "Preload Largest Contentful Paint image",
                description: "Add fetchpriority=\"high\" or <link rel=preload> for the LCP image.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/lcp-lazy-loading/",
                status: .fail, score: 0, weight: 0,
                numericValue: nil, displayValue: "LCP image not preloaded",
                items: [LHAuditItem(nodeID: bundle.lcpDetail?.nodeID, selector: bundle.lcpSelector.isEmpty ? nil : bundle.lcpSelector,
                                    url: bundle.lcpURL, snippet: bundle.lcpDetail?.snippet)]
            ))
        }

        if let lcp = bundle.lcpDetail, lcp.isLazyLoaded {
            out.append(LHAuditResult(
                id: "lcp-lazy-loaded", category: .performance,
                title: "Largest Contentful Paint image was not lazily loaded",
                description: "The LCP image has loading=\"lazy\", so the browser waits until layout before it starts the download.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/lcp-lazy-loading/",
                status: .fail, score: 0, weight: 0,
                numericValue: nil, displayValue: "LCP image is lazy-loaded",
                items: [LHAuditItem(nodeID: lcp.nodeID, selector: lcp.selector.isEmpty ? nil : lcp.selector, url: lcp.url, snippet: lcp.snippet)]
            ))
        }

        let missDim = bundle.images.filter { !$0.hasWidthAttr || !$0.hasHeightAttr }
        if !missDim.isEmpty {
            out.append(LHAuditResult(
                id: "image-explicit-dimensions", category: .performance,
                title: "Image elements have explicit width and height",
                description: "Missing width/height on images causes layout shifts during load.",
                docsURL: nil,
                status: .fail, score: 0, weight: 0,
                numericValue: Double(missDim.count), displayValue: "\(missDim.count) image(s)",
                items: missDim.prefix(20).map {
                    LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.src, snippet: $0.snippet)
                }
            ))
        }

        let offscreen = bundle.images.filter { !$0.isAboveFold && $0.loading != "lazy" && $0.transferSize > 10_000 }
        if !offscreen.isEmpty {
            let bytes = offscreen.reduce(0) { $0 + $1.transferSize }
            out.append(LHAuditResult(
                id: "offscreen-images", category: .performance,
                title: "Defer offscreen images",
                description: "Lazy-load images below the fold with loading=\"lazy\".",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/offscreen-images/",
                status: .fail, score: 0, weight: 0,
                numericValue: Double(bytes), displayValue: OrbitDevToolsFormat.bytes(bytes) + " potential savings",
                items: offscreen.prefix(20).map {
                    LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.src, wastedBytes: $0.transferSize)
                },
                savingsBytes: bytes,
                savingsNote: "Counts the full transfer size of each offscreen image that loads eagerly."
            ))
        }

        // Images downloaded larger than they are displayed.
        var oversized: [(image: LHImage, wasted: Int)] = []
        for image in bundle.images {
            if let wasted = oversizedImageWaste(image: image, devicePixelRatio: bundle.devicePixelRatio) {
                oversized.append((image, wasted))
            }
        }
        if !oversized.isEmpty {
            oversized.sort { $0.wasted > $1.wasted }
            let bytes = oversized.reduce(0) { $0 + $1.wasted }
            out.append(LHAuditResult(
                id: "uses-responsive-images", category: .performance,
                title: "Properly size images",
                description: "These images download more pixels than the page shows. Serve a smaller file, or use srcset and sizes.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/uses-responsive-images/",
                status: .fail, score: 0, weight: 0, numericValue: Double(bytes),
                displayValue: "~" + OrbitDevToolsFormat.bytes(bytes) + " potential savings",
                items: oversized.prefix(20).map {
                    LHAuditItem(
                        nodeID: $0.image.nodeID, selector: $0.image.selector, url: $0.image.src,
                        wastedBytes: $0.wasted, transferSize: $0.image.transferSize,
                        label: "\($0.image.naturalWidth)x\($0.image.naturalHeight) shown at \($0.image.displayWidth)x\($0.image.displayHeight)"
                    )
                },
                savingsBytes: bytes,
                savingsNote: "Estimated: transfer size times the share of pixels beyond what the displayed size needs at \(formatRatio(bundle.devicePixelRatio))x."
            ))
        }

        // Unused CSS, by selector matching against the DOM that is on screen now.
        let unused = unusedCSSWaste(bundle: bundle)
        if !unused.isEmpty {
            let bytes = unused.reduce(0) { $0 + $1.wasted }
            let skippedNote = bundle.cssSkipped > 0
                ? " \(bundle.cssSkipped) stylesheet(s) could not be read (cross-origin or over the time budget) and are not counted."
                : ""
            out.append(LHAuditResult(
                id: "unused-css-rules", category: .performance,
                title: "Reduce unused CSS",
                description: "These stylesheets contain rules that match nothing in the current page. Orbit matches selectors against the DOM as it is now, so rules for other pages, hover states or UI not yet opened count as unused. It is not a coverage trace.\(skippedNote)",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/unused-css-rules/",
                status: .fail, score: 0, weight: 0, numericValue: Double(bytes),
                displayValue: "~" + OrbitDevToolsFormat.bytes(bytes) + " potential savings",
                items: unused.prefix(20).map {
                    LHAuditItem(
                        nodeID: $0.sheet.nodeID > 0 ? $0.sheet.nodeID : nil,
                        selector: $0.sheet.selector.isEmpty ? nil : $0.sheet.selector,
                        url: $0.sheet.url.isEmpty ? "inline <style>" : $0.sheet.url,
                        wastedBytes: $0.wasted,
                        label: "\($0.sheet.unusedRules) unused rules, \(Int((Double($0.sheet.unusedBytes) / Double(max($0.sheet.totalBytes, 1)) * 100).rounded()))% of the sheet"
                    )
                },
                savingsBytes: bytes,
                savingsNote: "Selector matching against the current DOM; sizes are scaled to each file's transfer size when it is known."
            ))
        }

        // JavaScript coverage cannot be measured from a page in WebKit, so say so instead of guessing.
        let bigScripts = bundle.networkRecords
            .filter { $0.resourceType == "script" && ($0.transferSize ?? 0) >= 100_000 && !$0.failed }
            .sorted { ($0.transferSize ?? 0) > ($1.transferSize ?? 0) }
        if !bigScripts.isEmpty {
            out.append(LHAuditResult(
                id: "unused-javascript", category: .performance,
                title: "Reduce unused JavaScript",
                description: "WebKit exposes no JavaScript coverage API to pages, so Orbit cannot say how much of a script ran. These are the largest scripts, the usual candidates for code splitting or removal. Use Safari's Web Inspector coverage for exact numbers.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/unused-javascript/",
                status: .manual, score: nil, weight: 0, numericValue: nil,
                displayValue: "Not measurable",
                items: bigScripts.prefix(10).map {
                    LHAuditItem(url: $0.url, transferSize: $0.transferSize, label: OrbitDevToolsFormat.bytes($0.transferSize ?? 0))
                }
            ))
        }

        return out
    }

    private static func evidenceItems(_ nodes: [LHEvidenceNode]) -> [LHAuditItem] {
        nodes.prefix(20).map {
            LHAuditItem(nodeID: $0.nodeID > 0 ? $0.nodeID : nil, selector: $0.selector.isEmpty ? nil : $0.selector,
                        snippet: $0.snippet.isEmpty ? nil : $0.snippet)
        }
    }

    private static func percentOf(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((part / whole * 100).rounded()))%"
    }

    private static func lcpAuditItems(_ bundle: LHBundle) -> [LHAuditItem] {
        guard let lcp = bundle.lcpDetail else {
            guard !bundle.lcpSelector.isEmpty else { return [] }
            return [LHAuditItem(selector: bundle.lcpSelector, url: bundle.lcpURL.isEmpty ? nil : bundle.lcpURL, label: "LCP element")]
        }
        var label = "LCP element: <\(lcp.tag)>"
        if let rect = lcp.rect { label += " \(Int(clamping: rect.width.rounded())) by \(Int(clamping: rect.height.rounded())) px" }
        var items = [LHAuditItem(nodeID: lcp.nodeID, selector: lcp.selector.isEmpty ? nil : lcp.selector,
                                 url: lcp.url, label: label, snippet: lcp.snippet)]
        let total = lcp.phases.reduce(0) { $0 + $1.ms }
        for phase in lcp.phases {
            items.append(LHAuditItem(label: phase.name, subLabel: formatMs(phase.ms) + " (\(percentOf(phase.ms, of: total)) of LCP)"))
        }
        return items
    }

    /// The tasks that make up Total Blocking Time, longest first.
    private static func blockingTaskItems(_ bundle: LHBundle) -> [LHAuditItem] {
        guard bundle.longTasksAPIAvailable, let fcp = bundle.fcpMs else { return [] }
        return bundle.longTasks
            .filter { $0.startMs >= fcp && $0.durationMs > 50 }
            .sorted { $0.durationMs > $1.durationMs }
            .prefix(10)
            .map {
                LHAuditItem(wastedMs: $0.durationMs - 50, label: "Task of \(formatMs($0.durationMs))",
                            subLabel: "started at \(formatMs($0.startMs)); only the time over 50 ms counts")
            }
    }

    private static func clsAuditItems(_ bundle: LHBundle) -> [LHAuditItem] {
        let shifts = layoutShifts(bundle)
        let culprits = clsCulprits(shifts).prefix(5).map { culprit in
            LHAuditItem(nodeID: culprit.nodeID, selector: culprit.selector,
                        label: String(format: "%.4f", culprit.value) + " from this element",
                        subLabel: "\(culprit.shiftCount) shift(s); each shift's score is split by the area that moved")
        }
        let worst = shifts.sorted { $0.value > $1.value }.prefix(5).map { shift in
            LHAuditItem(label: String(format: "%.4f", shift.value),
                        subLabel: (shift.startMs.map { "at \(formatMs($0)): " } ?? "") + shift.sources.prefix(3).joined(separator: ", "))
        }
        return culprits + worst
    }

    /// Fills `howToFix` for a failed or warning audit that has guidance.
    static func withGuidance(_ audit: LHAuditResult) -> LHAuditResult {
        guard audit.howToFix == nil, audit.status == .fail || audit.status == .warning,
              let fix = fixGuidance[audit.id] else { return audit }
        var audit = audit
        audit.howToFix = fix
        return audit
    }

    private static let fixGuidance: [String: String] = [
        "first-contentful-paint": LHMetricKind.fcp.improvement,
        "largest-contentful-paint": LHMetricKind.lcp.improvement,
        "total-blocking-time": LHMetricKind.tbt.improvement,
        "cumulative-layout-shift": LHMetricKind.cls.improvement,
        "speed-index": LHMetricKind.speedIndex.improvement,
        "server-response-time": LHMetricKind.ttfb.improvement,
        "interaction-to-next-paint": LHMetricKind.inp.improvement,
        "dom-size": "Render only what is visible: paginate or virtualize long lists, remove wrapper elements, and build large sections on demand.",
        "long-tasks": "Split the work into smaller chunks that yield to the browser, move heavy computation to a Web Worker, and defer scripts that are not needed for the first screen.",
        "render-blocking-resources": "Add defer or async to scripts in the head, inline the CSS needed for the first screen, and load the rest of the CSS with media attributes or after first paint.",
        "non-composited-animations": "Animate transform and opacity instead of layout or paint properties such as width, top, margin or box-shadow.",
        "prefers-reduced-motion": "Wrap decorative animation in @media (prefers-reduced-motion: no-preference) or switch it off inside @media (prefers-reduced-motion: reduce).",
        "preload-lcp-image": "Add fetchpriority=\"high\" to the LCP image, or add <link rel=\"preload\" as=\"image\"> for it in the head so the download starts early.",
        "lcp-lazy-loaded": "Remove loading=\"lazy\" from the LCP image. Lazy loading is for images below the first screen.",
        "image-explicit-dimensions": "Set width and height attributes (or a CSS aspect-ratio) on every image so the browser reserves its space before it loads.",
        "offscreen-images": "Add loading=\"lazy\" to images below the first screen so they download only when the visitor scrolls near them.",
        "uses-responsive-images": "Resize images to the size they are shown at, and use srcset and sizes so smaller screens get smaller files.",
        "unused-css-rules": "Remove rules no page uses, split CSS per page or route, and inline only what the first screen needs.",
        "uses-text-compression": "Turn on gzip or Brotli for HTML, CSS, JavaScript, JSON and SVG responses on the server or CDN.",
        "uses-long-cache-ttl": "Send Cache-Control: max-age=31536000, immutable for fingerprinted static files, and a short max-age or revalidation for the rest.",
        "uses-webp-images": "Convert JPEG, PNG and GIF images to WebP or AVIF, which are usually 30 to 50 percent smaller at the same quality.",
        "total-byte-weight": "Compress and resize images, drop unused libraries, and lazy-load what is not needed at the start.",
        "uses-http2": "Serve the site over HTTP/2 or HTTP/3 so many resources can share one connection.",
        "no-mixed-content": "Load every resource over https:// and change any http:// URLs in the page, its CSS and its scripts.",
        "redirects": "Link straight to the final URL and avoid chains of redirects, each of which adds a round trip before the page can start.",
        "html-has-lang": "Add a lang attribute to the <html> element, for example <html lang=\"en\">.",
        "html-lang-valid": "Use a valid BCP 47 language tag such as en, en-GB or zh-Hant.",
        "document-title": "Add a short, descriptive <title> inside <head>.",
        "image-alt": "Add alt text that says what the image shows, or alt=\"\" when it is purely decorative.",
        "button-name": "Give each button visible text, an aria-label, or an aria-labelledby that points at a label.",
        "link-name": "Give each link text that says where it goes, or an aria-label when it only holds an icon or image.",
        "label": "Connect each form control to a <label for=...>, wrap it in a <label>, or add an aria-label.",
        "frame-title": "Add a title attribute to each <iframe> that says what it contains.",
        "heading-order": "Use heading levels in order (h1, then h2, then h3) without skipping, and style headings with CSS rather than by changing the level.",
        "color-contrast": "Darken the text or lighten the background until the ratio is at least 4.5:1 (3:1 for large text).",
        "duplicate-id-active": "Make every id unique on the page; rename or remove the duplicates.",
        "tabindex": "Remove positive tabindex values and let the DOM order set the tab order; use tabindex=\"0\" or \"-1\" only.",
        "meta-viewport": "Remove user-scalable=no and maximum-scale from the viewport meta tag so people can zoom.",
        "bypass": "Add a skip link to the main content, a <main> landmark, or headings so keyboard users can jump past repeated navigation.",
        "landmark-one-main": "Wrap the page's primary content in a single <main> element.",
        "target-size": "Make tap targets at least 24 by 24 CSS pixels, or add spacing around smaller ones.",
        "nested-interactive": "Do not put links, buttons or inputs inside other interactive elements; restructure so each control stands alone.",
        "scrollable-region-focusable": "Add tabindex=\"0\" to scrollable containers, or make sure they hold something focusable, so keyboard users can scroll them.",
        "video-caption": "Add a <track kind=\"captions\"> to each video.",
        "aria-roles": "Use a role value defined by ARIA, or remove the role attribute.",
        "aria-hidden-body": "Remove aria-hidden from <body>; hide individual regions instead.",
        "aria-hidden-focus": "Remove focusable elements from inside aria-hidden regions, or take aria-hidden off the container.",
        "aria-required-attr": "Add the attributes the role requires, for example aria-checked on role=\"checkbox\".",
        "is-on-https": "Serve the page and all of its resources over HTTPS.",
        "doctype": "Start the document with <!DOCTYPE html> so the browser does not use quirks mode.",
        "charset": "Declare the encoding with <meta charset=\"utf-8\"> in the first 1024 bytes of the head.",
        "no-console-errors": "Open the Console panel, fix the errors listed, and reload until it is clean.",
        "geolocation-on-start": "Ask for location only after the visitor does something that needs it, such as pressing a button.",
        "notification-on-start": "Ask for notification permission only after the visitor does something that shows why you need it.",
        "no-sync-xhr": "Make XMLHttpRequest asynchronous or switch to fetch(); synchronous requests freeze the page.",
        "no-unload-listeners": "Replace unload and beforeunload handlers with pagehide or visibilitychange, which keep the page eligible for the back-forward cache.",
        "document-domain": "Stop setting document.domain; use postMessage or a CORS-enabled request for cross-origin communication.",
        "deprecations": "Replace deprecated elements and APIs with their modern equivalents, using CSS for presentation.",
        "rel-noopener": "Add rel=\"noopener\" to links that use target=\"_blank\" so the new page cannot reach window.opener.",
        "document-title-seo": "Add a unique <title> that describes the page; search results show it as the headline.",
        "meta-description": "Add <meta name=\"description\" content=\"...\"> with a one or two sentence summary of the page.",
        "http-status-code": "Make the page respond with a 2xx status; search engines drop pages that return an error.",
        "link-text": "Replace links such as \"click here\" with text that describes the destination.",
        "crawlable-anchors": "Give links a real href (not # or javascript:) so crawlers and assistive technology can follow them.",
        "is-crawlable": "Remove noindex from the robots meta tag or robots.txt if the page should appear in search.",
        "viewport-seo": "Add <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">.",
        "font-size": "Use at least 12px text so it is legible on phones without zooming.",
        "canonical": "Point rel=\"canonical\" at one valid absolute URL for this content.",
        "hreflang": "Use valid language codes and absolute URLs in hreflang links, and include a self-reference.",
        "structured-data": "Fix the JSON-LD so it parses as valid JSON and follows the schema.org type it declares.",
    ]

    static func renderBlockingSavingsMs(_ blockers: [LHRenderBlocker], fcpMs: Double?) -> Double {
        let slowest = blockers.map(\.wastedMs).max() ?? 0
        guard let fcpMs, fcpMs > 0 else { return slowest }
        return min(slowest, fcpMs)
    }

    /// Nil when the image is not oversized, cannot be judged, or the saving is under 4 KB.
    static func oversizedImageWaste(image: LHImage, devicePixelRatio: Double) -> Int? {
        guard image.naturalWidth > 0, image.naturalHeight > 0,
              image.displayWidth > 0, image.displayHeight > 0,
              image.transferSize > 0,
              image.mimeType.lowercased() != "image/svg+xml" else { return nil }
        let ratio = devicePixelRatio > 0 ? devicePixelRatio : 1
        let neededPixels = Double(image.displayWidth) * ratio * Double(image.displayHeight) * ratio
        let actualPixels = Double(image.naturalWidth) * Double(image.naturalHeight)
        // Up to a quarter more pixels than needed is normal rounding of breakpoints, not waste.
        guard actualPixels > neededPixels * 1.25 else { return nil }
        let wasted = Int(Double(image.transferSize) * (1 - neededPixels / actualPixels))
        return wasted >= 4_096 ? wasted : nil
    }

    static func modernFormatSavingsFraction(mimeType: String) -> Double {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return 0.30
        case "image/png": return 0.40
        case "image/gif": return 0.50
        default: return 0
        }
    }

    static let textCompressionSavingsFraction = 0.65

    /// Zero for no-store, no-cache or an Expires in the past; nil when the response says nothing about caching.
    static func cacheTTLSeconds(cacheControl: String?, expires: String?, date: String? = nil) -> Int? {
        if let cacheControl {
            let lower = cacheControl.lowercased()
            let directives = lower.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if directives.contains("no-store") || directives.contains("no-cache") { return 0 }
            for key in ["s-maxage", "max-age"] {
                if let match = directives.first(where: { $0.hasPrefix(key + "=") }),
                   let value = Int(match.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) {
                    return max(0, value)
                }
            }
        }
        if let expires {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let expiry = formatter.date(from: expires) else { return 0 }
            let base = date.flatMap { formatter.date(from: $0) } ?? Date()
            return max(0, Int(expiry.timeIntervalSince(base)))
        }
        return nil
    }

    static func formatTTL(_ seconds: Int?) -> String {
        guard let seconds else { return "no cache headers" }
        if seconds <= 0 { return "not cached" }
        if seconds < 3_600 { return "\(seconds / 60) min" }
        if seconds < 86_400 { return "\(seconds / 3_600) h" }
        return "\(seconds / 86_400) days"
    }

    static func unusedCSSWaste(bundle: LHBundle) -> [(sheet: LHUnusedCSS, wasted: Int)] {
        bundle.unusedCSS
            .compactMap { sheet -> (sheet: LHUnusedCSS, wasted: Int)? in
                guard sheet.totalBytes > 0, sheet.unusedBytes > 0 else { return nil }
                let share = Double(sheet.unusedBytes) / Double(sheet.totalBytes)
                var base = sheet.totalBytes
                if !sheet.url.isEmpty,
                   let record = bundle.networkRecords.first(where: { $0.url == sheet.url }),
                   let transfer = record.transferSize, transfer > 0 {
                    base = transfer
                }
                let wasted = Int(Double(base) * share)
                return wasted >= 2_048 ? (sheet, wasted) : nil
            }
            .sorted { $0.wasted > $1.wasted }
    }

    /// Fills an opportunity's estimated time and bytes from whichever one it has, so every opportunity ranks on one scale.
    static func withEstimatedSavings(_ audit: LHAuditResult, device: LHDevice) -> LHAuditResult {
        guard audit.weight == 0, audit.status == .fail || audit.status == .warning else { return audit }
        var audit = audit
        if audit.savingsBytes == nil, audit.totalWastedBytes > 0 { audit.savingsBytes = audit.totalWastedBytes }
        if audit.savingsMs == nil, audit.totalWastedMs > 0 { audit.savingsMs = audit.totalWastedMs }
        // Caching helps repeat visits, not the load being measured, so it gets no time estimate.
        if audit.savingsMs == nil, let bytes = audit.savingsBytes, bytes > 0, audit.id != "uses-long-cache-ttl" {
            audit.savingsMs = Double(bytes) / device.assumedBytesPerSecond * 1000
            if audit.savingsNote == nil {
                audit.savingsNote = "Time is estimated from the byte saving at an assumed \(device == .mobile ? "1.6" : "10") Mbps."
            }
        }
        return audit
    }

    static func rankedOpportunities(_ audits: [LHAuditResult]) -> [LHAuditResult] {
        audits
            .filter { audit in
                audit.status == .fail && audit.weight == 0
                    && ((audit.savingsMs ?? 0) > 0 || (audit.savingsBytes ?? 0) > 0 || !audit.items.isEmpty)
            }
            .enumerated()
            .sorted { lhs, rhs in
                let l = (lhs.element.savingsMs ?? 0, lhs.element.savingsBytes ?? 0)
                let r = (rhs.element.savingsMs ?? 0, rhs.element.savingsBytes ?? 0)
                if l.0 != r.0 { return l.0 > r.0 }
                if l.1 != r.1 { return l.1 > r.1 }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func formatRatio(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func accessibilityAudits(bundle: LHBundle) -> [LHAuditResult] {
        var out: [LHAuditResult] = []

        out.append(LHAuditResult(
            id: "html-has-lang", category: .accessibility,
            title: "<html> element has a [lang] attribute",
            description: "Screen readers use the document language to select a voice profile.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/html-has-lang",
            status: bundle.htmlLang != nil ? .pass : .fail,
            score: bundle.htmlLang != nil ? 1 : 0, weight: 7,
            numericValue: nil, displayValue: bundle.htmlLang ?? "missing",
            items: bundle.htmlLang == nil ? [LHAuditItem(selector: "html", snippet: "<html>")] : []
        ))

        if let lang = bundle.htmlLang {
            let valid = isValidLangTag(lang)
            out.append(LHAuditResult(
                id: "html-lang-valid", category: .accessibility,
                title: "html element has a valid lang attribute",
                description: "The lang value must be a valid BCP 47 language tag.",
                docsURL: "https://dequeuniversity.com/rules/axe/4.4/html-lang-valid",
                status: valid ? .pass : .fail, score: valid ? 1 : 0, weight: 7,
                numericValue: nil, displayValue: valid ? lang : "invalid: \(lang)",
                items: valid ? [] : [LHAuditItem(selector: "html", snippet: "<html lang=\"\(lang)\">")]
            ))
        }

        out.append(LHAuditResult(
            id: "document-title", category: .accessibility,
            title: "Document has a <title> element",
            description: "The title is the accessible name of the browser tab.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/document-title",
            status: !bundle.documentTitle.isEmpty ? .pass : .fail,
            score: !bundle.documentTitle.isEmpty ? 1 : 0, weight: 3,
            numericValue: nil, displayValue: bundle.documentTitle.isEmpty ? "missing" : bundle.documentTitle,
            items: []
        ))

        let noAlt = bundle.images.filter { $0.alt == nil }
        out.append(LHAuditResult(
            id: "image-alt", category: .accessibility,
            title: "Image elements have [alt] text",
            description: "Informative images need descriptive alt text. Decorative images use alt=\"\".",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/image-alt",
            status: noAlt.isEmpty ? .pass : .fail,
            score: noAlt.isEmpty ? 1 : 0, weight: 10,
            numericValue: Double(noAlt.count),
            displayValue: noAlt.isEmpty ? "\(bundle.images.count) image(s) pass" : "\(noAlt.count) missing alt",
            items: noAlt.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.src, snippet: $0.snippet)
            }
        ))

        let noName = bundle.buttons.filter { $0.accessibleName.isEmpty }
        out.append(LHAuditResult(
            id: "button-name", category: .accessibility,
            title: "Buttons have an accessible name",
            description: "A button needs text, aria-label, or an aria-labelledby target.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/button-name",
            status: noName.isEmpty ? .pass : .fail,
            score: noName.isEmpty ? 1 : 0, weight: 10,
            numericValue: Double(noName.count),
            displayValue: noName.isEmpty ? "\(bundle.buttons.count) pass" : "\(noName.count) failing",
            items: noName.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, snippet: $0.snippet)
            }
        ))

        let noLink = bundle.links.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        out.append(LHAuditResult(
            id: "link-name", category: .accessibility,
            title: "Links have discernible text",
            description: "A link with no accessible name has nothing for a screen reader to announce.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/link-name",
            status: noLink.isEmpty ? .pass : .fail,
            score: noLink.isEmpty ? 1 : 0, weight: 7,
            numericValue: Double(noLink.count),
            displayValue: noLink.isEmpty ? "\(bundle.links.count) pass" : "\(noLink.count) failing",
            items: noLink.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.href)
            }
        ))

        let unlabeled = bundle.inputs.filter {
            !$0.hasLabel && !["hidden", "submit", "reset", "button", "image"].contains($0.inputType)
        }
        out.append(LHAuditResult(
            id: "label", category: .accessibility,
            title: "Form elements have associated labels",
            description: "Labels ensure form controls are announced properly by assistive technology.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/label",
            status: unlabeled.isEmpty ? .pass : .fail,
            score: unlabeled.isEmpty ? 1 : 0, weight: 7,
            numericValue: Double(unlabeled.count),
            displayValue: unlabeled.isEmpty ? "\(bundle.inputs.count) pass" : "\(unlabeled.count) failing",
            items: unlabeled.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, snippet: $0.snippet)
            }
        ))

        let noTitle = bundle.frames.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        out.append(LHAuditResult(
            id: "frame-title", category: .accessibility,
            title: "Frames have a title attribute",
            description: "<iframe> elements must have a title to announce their purpose.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/frame-title",
            status: noTitle.isEmpty ? .pass : .fail,
            score: noTitle.isEmpty ? 1 : 0, weight: 3,
            numericValue: Double(noTitle.count),
            displayValue: noTitle.isEmpty ? "\(bundle.frames.count) pass" : "\(noTitle.count) failing",
            items: noTitle.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.src)
            }
        ))

        var skips = 0, prevH = 0
        var skipItems: [LHAuditItem] = []
        for h in bundle.headings {
            if prevH > 0 && h.level > prevH + 1 {
                skips += 1
                skipItems.append(LHAuditItem(nodeID: h.nodeID, selector: h.selector, label: "h\(h.level) after h\(prevH)"))
            }
            prevH = h.level
        }
        out.append(LHAuditResult(
            id: "heading-order", category: .accessibility,
            title: "Heading elements appear in sequentially-descending order",
            description: "Skipping heading levels makes the page outline harder to navigate.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/heading-order",
            status: skips == 0 ? .pass : .fail, score: skips == 0 ? 1 : 0, weight: 3,
            numericValue: Double(skips), displayValue: skips == 0 ? "Correct order" : "\(skips) skip(s)",
            items: Array(skipItems.prefix(20))
        ))

        let fails  = bundle.contrastIssues.filter { !$0.needsReview && $0.ratio < $0.requiredRatio }
        let review = bundle.contrastIssues.filter { $0.needsReview }
        let contrastDisp = fails.isEmpty
            ? (review.isEmpty ? "All pass" : "\(review.count) need manual review")
            : "\(fails.count) failing"
        out.append(LHAuditResult(
            id: "color-contrast", category: .accessibility,
            title: "Background and foreground colors have sufficient contrast ratio",
            description: "WCAG AA: 4.5:1 for normal text, 3:1 for large text (≥18 pt or bold ≥14 pt).",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/color-contrast",
            status: fails.isEmpty ? (review.isEmpty ? .pass : .informative) : .fail,
            score: fails.isEmpty ? 1 : 0, weight: 3,
            numericValue: Double(fails.count), displayValue: contrastDisp,
            items: (fails.prefix(20).map { i in
                LHAuditItem(nodeID: i.nodeID, selector: i.selector, label: String(format: "%.2f:1 (need %.1f:1)", i.ratio, i.requiredRatio), subLabel: i.isLargeText ? "large text" : "normal text")
            } + review.prefix(5).map { i in
                LHAuditItem(nodeID: i.nodeID, selector: i.selector, label: "Needs manual review — complex background")
            })
        ))

        out.append(LHAuditResult(
            id: "duplicate-id-active", category: .accessibility,
            title: "Active [id] values are unique",
            description: "Duplicate IDs break ARIA and label associations.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/duplicate-id-active",
            status: bundle.duplicateActiveIDs.isEmpty ? .pass : .fail,
            score: bundle.duplicateActiveIDs.isEmpty ? 1 : 0, weight: 3,
            numericValue: Double(bundle.duplicateActiveIDs.count),
            displayValue: bundle.duplicateActiveIDs.isEmpty ? "All unique" : "\(bundle.duplicateActiveIDs.count) duplicate(s)",
            items: bundle.duplicateActiveIDs.prefix(20).map { LHAuditItem(label: "#\($0)") }
        ))

        out.append(LHAuditResult(
            id: "tabindex", category: .accessibility,
            title: "No element has a [tabindex] value greater than 0",
            description: "Positive tabindex overrides natural reading order.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/tabindex",
            status: bundle.positiveTabindexCount == 0 ? .pass : .fail,
            score: bundle.positiveTabindexCount == 0 ? 1 : 0, weight: 3,
            numericValue: Double(bundle.positiveTabindexCount),
            displayValue: bundle.positiveTabindexCount == 0 ? "None" : "\(bundle.positiveTabindexCount) element(s)",
            items: evidenceItems(bundle.positiveTabindexNodes)
        ))

        let scalable = !bundle.viewportContent.lowercased().contains("user-scalable=no")
        out.append(LHAuditResult(
            id: "meta-viewport", category: .accessibility,
            title: "[user-scalable=no] is not set in the viewport",
            description: "Disabling pinch-zoom makes the page inaccessible to users who need to zoom.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/meta-viewport",
            status: scalable ? .pass : .fail, score: scalable ? 1 : 0, weight: 10,
            numericValue: nil, displayValue: scalable ? "Pinch zoom enabled" : "user-scalable=no detected",
            items: scalable ? [] : [LHAuditItem(snippet: bundle.viewportContent)]
        ))

        let bypass = bundle.hasSkipLink || bundle.hasMainLandmark || !bundle.headings.isEmpty
        out.append(LHAuditResult(
            id: "bypass", category: .accessibility,
            title: "Page has a heading, skip link, or landmark region",
            description: "Keyboard users need a mechanism to reach the main content.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/bypass",
            status: bypass ? .pass : .fail, score: bypass ? 1 : 0, weight: 3,
            numericValue: nil, displayValue: bypass ? "Present" : "Missing", items: []
        ))

        out.append(LHAuditResult(
            id: "landmark-one-main", category: .accessibility,
            title: "Document has a main landmark",
            description: "A <main> element or role=\"main\" lets screen reader users navigate to primary content.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/landmark-one-main",
            status: bundle.hasMainLandmark ? .pass : .fail,
            score: bundle.hasMainLandmark ? 1 : 0, weight: 3,
            numericValue: nil, displayValue: bundle.hasMainLandmark ? "Present" : "Missing", items: []
        ))

        out.append(LHAuditResult(
            id: "target-size", category: .accessibility,
            title: "Touch targets have sufficient size and spacing",
            description: "Touch targets should be at least 24×24 CSS pixels.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/target-size",
            status: bundle.smallTargets.isEmpty ? .pass : .fail,
            score: bundle.smallTargets.isEmpty ? 1 : 0, weight: 7,
            numericValue: Double(bundle.smallTargets.count),
            displayValue: bundle.smallTargets.isEmpty ? "All pass" : "\(bundle.smallTargets.count) too small",
            items: bundle.smallTargets.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, label: String(format: "%.0f×%.0f px", $0.width, $0.height), snippet: $0.snippet)
            }
        ))

        out.append(LHAuditResult(
            id: "nested-interactive", category: .accessibility,
            title: "Interactive controls are not nested",
            description: "Nested interactive elements produce unpredictable behavior for assistive technology.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/nested-interactive",
            status: bundle.nestedInteractiveCount == 0 ? .pass : .fail,
            score: bundle.nestedInteractiveCount == 0 ? 1 : 0, weight: 3,
            numericValue: Double(bundle.nestedInteractiveCount),
            displayValue: bundle.nestedInteractiveCount == 0 ? "None" : "\(bundle.nestedInteractiveCount)",
            items: evidenceItems(bundle.nestedInteractiveNodes)
        ))

        out.append(LHAuditResult(
            id: "scrollable-region-focusable", category: .accessibility,
            title: "Scrollable regions are keyboard-accessible",
            description: "Scrollable regions must be focusable so keyboard users can scroll them.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/scrollable-region-focusable",
            status: bundle.scrollableNotFocusable == 0 ? .pass : .fail,
            score: bundle.scrollableNotFocusable == 0 ? 1 : 0, weight: 3,
            numericValue: Double(bundle.scrollableNotFocusable),
            displayValue: bundle.scrollableNotFocusable == 0 ? "None" : "\(bundle.scrollableNotFocusable)",
            items: evidenceItems(bundle.unfocusableScrollRegions)
        ))

        out.append(LHAuditResult(
            id: "video-caption", category: .accessibility,
            title: "Video elements have captions",
            description: "<video> elements need <track kind=\"captions\"> for deaf users.",
            docsURL: "https://dequeuniversity.com/rules/axe/4.4/video-caption",
            status: bundle.videosWithoutCaptions == 0 ? .pass : .fail,
            score: bundle.videosWithoutCaptions == 0 ? 1 : 0, weight: 10,
            numericValue: Double(bundle.videosWithoutCaptions),
            displayValue: bundle.videosWithoutCaptions == 0 ? "All captioned" : "\(bundle.videosWithoutCaptions) missing",
            items: evidenceItems(bundle.videosWithoutCaptionNodes)
        ))

        let byRule = Dictionary(grouping: bundle.ariaIssues, by: \.ruleID)
        for (ruleID, issues) in byRule.sorted(by: { $0.key < $1.key }) {
            let (t, d, w) = ariaAuditMeta(ruleID: ruleID)
            out.append(LHAuditResult(
                id: ruleID, category: .accessibility,
                title: t, description: d,
                docsURL: "https://dequeuniversity.com/rules/axe/4.4/\(ruleID)",
                status: .fail, score: 0, weight: w,
                numericValue: Double(issues.count), displayValue: "\(issues.count) element(s)",
                items: issues.prefix(20).map {
                    LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, label: $0.detail, snippet: $0.snippet)
                }
            ))
        }

        return out
    }

    private static func ariaAuditMeta(ruleID: String) -> (String, String, Double) {
        let t: [String: (String, String, Double)] = [
            "aria-allowed-attr":    ("ARIA attributes match their role", "Only attributes appropriate for the element's ARIA role may be used.", 10),
            "aria-required-attr":   ("Required ARIA attributes are present", "Some roles have required attributes (e.g. aria-checked on checkbox).", 10),
            "aria-valid-attr":      ("ARIA attributes are valid names", "Attributes beginning with aria- must be valid names.", 10),
            "aria-valid-attr-value":("ARIA attributes have valid values", "ARIA attribute values must match the expected type.", 10),
            "aria-roles":           ("[role] values are valid ARIA roles", "The role attribute must reference a defined ARIA role.", 10),
            "aria-hidden-body":     ("aria-hidden=true not on body", "Setting aria-hidden on body hides the entire page from assistive technology.", 10),
            "aria-hidden-focus":    ("aria-hidden elements have no focusable descendants", "Focusable elements inside aria-hidden are reachable by keyboard but invisible to AT.", 7),
            "aria-dialog-name":     ("[role=dialog] has accessible name", "Dialogs must have a name so users understand their purpose.", 7),
        ]
        return t[ruleID] ?? (ruleID, "ARIA rule \(ruleID) violated.", 3)
    }

    private static func bestPracticesAudits(bundle: LHBundle) -> [LHAuditResult] {
        var out: [LHAuditResult] = []
        let https = bundle.url.hasPrefix("https://")
        let local = bundle.url.hasPrefix("http://localhost") || bundle.url.hasPrefix("http://127.")

        out.append(LHAuditResult(
            id: "is-on-https", category: .bestPractices,
            title: "Uses HTTPS", description: "All sites should be served over HTTPS. Localhost is exempt.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/is-on-https/",
            status: https || local ? .pass : .fail, score: https || local ? 1 : 0, weight: 5,
            numericValue: nil, displayValue: https ? "HTTPS" : local ? "localhost" : "HTTP", items: []
        ))

        out.append(LHAuditResult(
            id: "doctype", category: .bestPractices,
            title: "Page has a DOCTYPE",
            description: "Without a DOCTYPE the page may enter quirks mode.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/doctype/",
            status: bundle.hasDoctype ? .pass : .fail, score: bundle.hasDoctype ? 1 : 0, weight: 5,
            numericValue: nil, displayValue: bundle.hasDoctype ? "Present" : "Missing", items: []
        ))

        out.append(LHAuditResult(
            id: "charset", category: .bestPractices,
            title: "Declares a character set",
            description: "A missing charset makes text decoding ambiguous.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/charset/",
            status: bundle.charset != nil ? .pass : .fail, score: bundle.charset != nil ? 1 : 0, weight: 3,
            numericValue: nil, displayValue: bundle.charset ?? "Missing", items: []
        ))

        out.append(LHAuditResult(
            id: "no-console-errors", category: .bestPractices,
            title: "Avoids console errors",
            description: "Console errors indicate runtime problems that may surface as broken features.",
            docsURL: nil,
            status: bundle.consoleErrorCount == 0 ? .pass : .fail,
            score: bundle.consoleErrorCount == 0 ? 1 : 0, weight: 28,
            numericValue: Double(bundle.consoleErrorCount),
            displayValue: bundle.consoleErrorCount == 0 ? "None" : "\(bundle.consoleErrorCount) error(s)",
            items: bundle.consoleErrorMessages.prefix(10).map { LHAuditItem(label: $0) }
        ))

        out.append(LHAuditResult(
            id: "geolocation-on-start", category: .bestPractices,
            title: "Doesn't request location on page load",
            description: "Location prompts without a user gesture interrupt the experience.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/geolocation-on-start/",
            status: bundle.geoPromptDuringLoad ? .fail : .pass,
            score: bundle.geoPromptDuringLoad ? 0 : 1, weight: 10,
            numericValue: nil,
            displayValue: bundle.geoPromptDuringLoad ? "Prompted on load" : "Not prompted", items: []
        ))

        out.append(LHAuditResult(
            id: "notification-on-start", category: .bestPractices,
            title: "Doesn't request notification permission on load",
            description: "Notification prompts without a user gesture are disruptive.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/notification-on-start/",
            status: bundle.notifPromptDuringLoad ? .fail : .pass,
            score: bundle.notifPromptDuringLoad ? 0 : 1, weight: 10,
            numericValue: nil,
            displayValue: bundle.notifPromptDuringLoad ? "Prompted on load" : "Not prompted", items: []
        ))

        out.append(LHAuditResult(
            id: "no-sync-xhr", category: .bestPractices,
            title: "Avoids synchronous XMLHttpRequest",
            description: "Synchronous XHR blocks the main thread and is deprecated.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/no-sync-xhr/",
            status: bundle.hasSyncXHR ? .fail : .pass, score: bundle.hasSyncXHR ? 0 : 1, weight: 3,
            numericValue: nil,
            displayValue: bundle.hasSyncXHR ? "Detected" : "Not detected", items: []
        ))

        out.append(LHAuditResult(
            id: "no-unload-listeners", category: .bestPractices,
            title: "Avoids unload event listeners",
            description: "The unload event prevents bfcache optimization.",
            docsURL: nil,
            status: bundle.hasUnloadListeners ? .fail : .pass,
            score: bundle.hasUnloadListeners ? 0 : 1, weight: 3,
            numericValue: nil,
            displayValue: bundle.hasUnloadListeners ? "Detected" : "Not detected", items: []
        ))

        out.append(LHAuditResult(
            id: "document-domain", category: .bestPractices,
            title: "Avoids document.domain",
            description: "Setting document.domain is deprecated and disables COOP/COEP isolation.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/document-domain/",
            status: bundle.hasDocumentDomain ? .fail : .pass,
            score: bundle.hasDocumentDomain ? 0 : 1, weight: 3,
            numericValue: nil,
            displayValue: bundle.hasDocumentDomain ? "Detected" : "Not detected", items: []
        ))

        out.append(LHAuditResult(
            id: "deprecations", category: .bestPractices,
            title: "Avoids deprecated HTML elements",
            description: "Deprecated elements (<center>, <font>, <blink> …) may be removed.",
            docsURL: nil,
            status: bundle.deprecatedElements.isEmpty ? .pass : .fail,
            score: bundle.deprecatedElements.isEmpty ? 1 : 0, weight: 5,
            numericValue: Double(bundle.deprecatedElements.count),
            displayValue: bundle.deprecatedElements.isEmpty ? "None" : "\(bundle.deprecatedElements.count) found",
            items: bundle.deprecatedElements.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, label: "<\($0.tag)>")
            }
        ))

        out.append(LHAuditResult(
            id: "rel-noopener", category: .bestPractices,
            title: "Cross-origin links use rel=noopener",
            description: "target=_blank without rel=noopener lets the opened page access window.opener.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/best-practices/external-anchors-use-rel-noopener/",
            status: bundle.blankTargetNoopenerIssues.isEmpty ? .pass : .fail,
            score: bundle.blankTargetNoopenerIssues.isEmpty ? 1 : 0, weight: 3,
            numericValue: Double(bundle.blankTargetNoopenerIssues.count),
            displayValue: bundle.blankTargetNoopenerIssues.isEmpty ? "None" : "\(bundle.blankTargetNoopenerIssues.count) link(s)",
            items: bundle.blankTargetNoopenerIssues.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.href)
            }
        ))

        return out
    }

    private static func seoAudits(bundle: LHBundle) -> [LHAuditResult] {
        var out: [LHAuditResult] = []
        let noindex = bundle.robotsMetaContent.lowercased().contains("noindex")

        out.append(LHAuditResult(
            id: "document-title-seo", category: .seo,
            title: "Document has a <title> element",
            description: "The title element appears in search results and browser tabs.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/document-title/",
            status: !bundle.documentTitle.isEmpty ? .pass : .fail,
            score: !bundle.documentTitle.isEmpty ? 1 : 0, weight: 9,
            numericValue: nil,
            displayValue: bundle.documentTitle.isEmpty ? "Missing" : bundle.documentTitle, items: []
        ))

        let desc = bundle.metaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(LHAuditResult(
            id: "meta-description", category: .seo,
            title: "Document has a meta description",
            description: "Meta descriptions may be used in search result snippets.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/meta-description/",
            status: !desc.isEmpty ? .pass : .fail, score: !desc.isEmpty ? 1 : 0, weight: 9,
            numericValue: nil,
            displayValue: desc.isEmpty ? "Missing" : "\(desc.count) characters", items: []
        ))

        let goodStatus = bundle.httpStatus == 0 || (bundle.httpStatus >= 200 && bundle.httpStatus < 300)
        out.append(LHAuditResult(
            id: "http-status-code", category: .seo,
            title: "Page has a successful HTTP status code",
            description: "Pages returning an error status code may not be indexed.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/http-status-code/",
            status: goodStatus ? .pass : .fail, score: goodStatus ? 1 : 0, weight: 9,
            numericValue: Double(bundle.httpStatus),
            displayValue: bundle.httpStatus == 0 ? "Unknown" : "\(bundle.httpStatus)", items: []
        ))

        let generic = bundle.links.filter(\.isGenericText)
        out.append(LHAuditResult(
            id: "link-text", category: .seo,
            title: "Links have descriptive text",
            description: "Generic link text like 'click here' gives no context to search engines.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/link-text/",
            status: generic.isEmpty ? .pass : .fail, score: generic.isEmpty ? 1 : 0, weight: 9,
            numericValue: Double(generic.count),
            displayValue: generic.isEmpty ? "All descriptive" : "\(generic.count) generic",
            items: generic.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.href, label: $0.text)
            }
        ))

        let uncrawlable = bundle.links.filter { !$0.isCrawlable }
        out.append(LHAuditResult(
            id: "crawlable-anchors", category: .seo,
            title: "Links are crawlable",
            description: "Search engines cannot follow javascript: or void: links.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/crawlable-anchors/",
            status: uncrawlable.isEmpty ? .pass : .fail, score: uncrawlable.isEmpty ? 1 : 0, weight: 9,
            numericValue: Double(uncrawlable.count),
            displayValue: uncrawlable.isEmpty ? "All crawlable" : "\(uncrawlable.count) uncrawlable",
            items: uncrawlable.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, url: $0.href)
            }
        ))

        var crawlItems: [LHAuditItem] = []
        var robotsBlocked = false
        if let txt = bundle.robotsTxtContent {
            let path = URL(string: bundle.url)?.path ?? "/"
            robotsBlocked = robotsTxtDisallows(txt: txt, path: path)
        }
        let blocked = noindex || robotsBlocked
        if noindex { crawlItems.append(LHAuditItem(label: "noindex in meta robots")) }
        if robotsBlocked { crawlItems.append(LHAuditItem(label: "Disallowed in robots.txt")) }
        out.append(LHAuditResult(
            id: "is-crawlable", category: .seo,
            title: "Page is not blocked from indexing",
            description: "Search engines cannot index pages blocked by noindex or robots.txt.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/is-crawlable/",
            status: blocked ? .fail : .pass, score: blocked ? 0 : 1, weight: 9,
            numericValue: nil, displayValue: blocked ? "Blocked" : "Crawlable",
            items: crawlItems
        ))

        out.append(LHAuditResult(
            id: "viewport-seo", category: .seo,
            title: "Has a <meta name=\"viewport\"> tag",
            description: "A viewport meta tag is required for the page to be mobile-friendly.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/meta-viewport/",
            status: bundle.hasViewport ? .pass : .fail, score: bundle.hasViewport ? 1 : 0, weight: 9,
            numericValue: nil, displayValue: bundle.hasViewport ? "Present" : "Missing", items: []
        ))

        let smallRatio = bundle.totalTextNodes > 0
            ? Double(bundle.smallFontNodes.count) / Double(bundle.totalTextNodes) : 0
        let fontPass = smallRatio < 0.4
        out.append(LHAuditResult(
            id: "font-size", category: .seo,
            title: "Document uses legible font sizes",
            description: "Font sizes smaller than 12px are too small to read comfortably on a screen.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/font-size/",
            status: fontPass ? .pass : .fail, score: fontPass ? 1 : 0, weight: 8,
            numericValue: Double(bundle.smallFontNodes.count),
            displayValue: bundle.smallFontNodes.isEmpty ? "All legible" : "\(bundle.smallFontNodes.count) small",
            items: bundle.smallFontNodes.prefix(20).map {
                LHAuditItem(nodeID: $0.nodeID, selector: $0.selector, label: String(format: "%.1f px", $0.fontSize), snippet: $0.snippet)
            }
        ))

        let canon = bundle.canonicalURL ?? ""
        var canonIssues: [LHAuditItem] = []
        if !canon.isEmpty && !canon.hasPrefix("http://") && !canon.hasPrefix("https://") {
            canonIssues.append(LHAuditItem(label: "Not absolute: \(canon)"))
        }
        out.append(LHAuditResult(
            id: "canonical", category: .seo,
            title: "Document has a valid rel=canonical",
            description: "A canonical URL helps search engines when a page is reachable at multiple URLs.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/seo/canonical/",
            status: canonIssues.isEmpty ? (canon.isEmpty ? .informative : .pass) : .fail,
            score: canonIssues.isEmpty ? 1 : 0, weight: 0,
            numericValue: nil, displayValue: canon.isEmpty ? "Not set" : (canonIssues.isEmpty ? canon : "Invalid"),
            items: canonIssues
        ))

        var hrefIssues: [LHAuditItem] = []
        for e in bundle.hreflangLinks where !isValidLangTag(e.lang) {
            hrefIssues.append(LHAuditItem(url: e.href, label: "Invalid lang: \(e.lang)"))
        }
        if !bundle.hreflangLinks.isEmpty {
            out.append(LHAuditResult(
                id: "hreflang", category: .seo,
                title: "Document has valid hreflang attributes",
                description: "Valid hreflang links help search engines serve the correct language version.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/seo/hreflang/",
                status: hrefIssues.isEmpty ? .pass : .fail, score: hrefIssues.isEmpty ? 1 : 0, weight: 8,
                numericValue: Double(hrefIssues.count),
                displayValue: hrefIssues.isEmpty ? "\(bundle.hreflangLinks.count) valid" : "\(hrefIssues.count) invalid",
                items: hrefIssues
            ))
        }

        var jsonLDIssues: [LHAuditItem] = []
        for (i, raw) in bundle.jsonLDScripts.enumerated() {
            if let data = raw.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) == nil {
                jsonLDIssues.append(LHAuditItem(label: "JSON-LD block \(i + 1): invalid JSON"))
            }
        }
        if !bundle.jsonLDScripts.isEmpty {
            out.append(LHAuditResult(
                id: "structured-data", category: .seo,
                title: "Structured data is valid",
                description: "Valid JSON-LD structured data helps search engines understand the page content.",
                docsURL: nil,
                status: jsonLDIssues.isEmpty ? .pass : .fail, score: jsonLDIssues.isEmpty ? 1 : 0, weight: 0,
                numericValue: Double(bundle.jsonLDScripts.count),
                displayValue: "\(bundle.jsonLDScripts.count) block(s), \(jsonLDIssues.count) invalid",
                items: jsonLDIssues
            ))
        }

        return out
    }

    /// Graded from the Security tool's checks so the pane and this category cannot disagree; a check with no verdict carries no weight.
    static func securityAudits(bundle: LHBundle) -> [LHAuditResult] {
        guard let input = bundle.security else { return [] }
        return OrbitSecurityLogic.evaluate(input).checks.compactMap { check in
            // Rows that only say "not exposed by WebKit" are not audits.
            if check.state == .info && check.weight == 0 { return nil }
            let status: LHAuditStatus
            let score: Double?
            switch check.state {
            case .pass: status = .pass; score = 1
            case .warn: status = .warning; score = 0.5
            case .fail: status = .fail; score = 0
            case .info: status = .notApplicable; score = nil
            }
            let firstLine = check.value?.split(separator: "\n").first.map(String.init) ?? ""
            let display = firstLine.isEmpty ? check.summary : (firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine)
            return LHAuditResult(
                id: "security-\(check.id)", category: .security,
                title: check.title,
                description: check.summary + " " + check.advice,
                docsURL: nil, status: status, score: score,
                weight: check.weight,
                numericValue: nil, displayValue: display,
                items: check.findings.filter { $0.state != .pass }.prefix(20).map {
                    LHAuditItem(nodeID: $0.nodeID.flatMap { $0 > 0 ? $0 : nil }, selector: $0.selector, url: $0.url, label: $0.text)
                }
            )
        }
    }

    private static func networkAudits(bundle: LHBundle) -> [LHAuditResult] {
        guard !bundle.networkRecords.isEmpty else { return [] }
        let recs = bundle.networkRecords
        var out: [LHAuditResult] = []
        let isHTTPS = bundle.url.hasPrefix("https://")

        let uncomp = recs.filter {
            isCompressible(mimeType: $0.mimeType)
                && $0.responseHeaders["content-encoding"] == nil
                && ($0.transferSize ?? 0) > 1_400
                && !$0.fromCache && !$0.failed
        }
        if !uncomp.isEmpty {
            let fraction = textCompressionSavingsFraction
            let saved = uncomp.map { Int(Double($0.transferSize ?? 0) * fraction) }
            let bytes = saved.reduce(0, +)
            out.append(LHAuditResult(
                id: "uses-text-compression", category: .performance,
                title: "Enable text compression",
                description: "Text resources should be compressed (gzip, br, deflate).",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/uses-text-compression/",
                status: .fail, score: 0, weight: 0, numericValue: Double(bytes),
                displayValue: "~" + OrbitDevToolsFormat.bytes(bytes) + " potential savings",
                items: zip(uncomp, saved).sorted { $0.1 > $1.1 }.prefix(20).map {
                    LHAuditItem(url: $0.0.url, wastedBytes: $0.1, transferSize: $0.0.transferSize, label: $0.0.mimeType)
                },
                savingsBytes: bytes,
                savingsNote: "Estimated at \(Int(fraction * 100))% of each uncompressed file, the typical gzip or Brotli saving on text. Orbit does not compress the body to measure it."
            ))
        }

        // Cache policy: static assets that are not reused for at least a week.
        let weekSeconds = 7 * 86_400
        let weakCache: [(record: LHNetRecord, ttl: Int?)] = recs.compactMap { rec in
            guard isStaticAsset(resourceType: rec.resourceType, url: rec.url),
                  !rec.fromCache, !rec.failed, (rec.transferSize ?? 0) > 0 else { return nil }
            let ttl = cacheTTLSeconds(
                cacheControl: rec.responseHeaders["cache-control"],
                expires: rec.responseHeaders["expires"],
                date: rec.responseHeaders["date"]
            )
            return (ttl ?? 0) < weekSeconds ? (rec, ttl) : nil
        }
        if !weakCache.isEmpty {
            let sorted = weakCache.sorted { ($0.record.transferSize ?? 0) > ($1.record.transferSize ?? 0) }
            let bytes = sorted.reduce(0) { $0 + ($1.record.transferSize ?? 0) }
            out.append(LHAuditResult(
                id: "uses-long-cache-ttl", category: .performance,
                title: "Serve static assets with an efficient cache policy",
                description: "Static assets that are not cached for at least a week are fetched again on repeat visits.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/uses-long-cache-ttl/",
                status: .fail, score: 0, weight: 0, numericValue: Double(weakCache.count),
                displayValue: "\(weakCache.count) asset(s), " + OrbitDevToolsFormat.bytes(bytes) + " re-fetched",
                items: sorted.prefix(20).map {
                    LHAuditItem(
                        url: $0.record.url, transferSize: $0.record.transferSize,
                        label: "Cached: " + formatTTL($0.ttl),
                        subLabel: $0.record.responseHeaders["cache-control"] ?? "no Cache-Control header"
                    )
                },
                savingsBytes: bytes,
                savingsNote: "The bytes a repeat visit would download again. Caching does not speed up the load measured here, so no time is estimated."
            ))
        }

        let legacy = recs.filter {
            $0.resourceType == "image"
                && !isModernImageFormat(mimeType: $0.mimeType)
                && ["image/jpeg", "image/png", "image/gif"].contains($0.mimeType.lowercased())
                && ($0.transferSize ?? 0) > 10_000
        }
        if !legacy.isEmpty {
            let saved = legacy.map { Int(Double($0.transferSize ?? 0) * modernFormatSavingsFraction(mimeType: $0.mimeType)) }
            let bytes = saved.reduce(0, +)
            out.append(LHAuditResult(
                id: "uses-webp-images", category: .performance,
                title: "Serve images in next-gen formats (AVIF or WebP)",
                description: "AVIF and WebP typically compress better than JPEG and PNG.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/uses-webp-images/",
                status: .fail, score: 0, weight: 0, numericValue: Double(bytes),
                displayValue: "~" + OrbitDevToolsFormat.bytes(bytes) + " potential savings",
                items: zip(legacy, saved).sorted { $0.1 > $1.1 }.prefix(20).map {
                    LHAuditItem(url: $0.0.url, wastedBytes: $0.1, transferSize: $0.0.transferSize, label: $0.0.mimeType)
                },
                savingsBytes: bytes,
                savingsNote: "Estimated from typical savings by source format (JPEG 30%, PNG 40%, GIF 50%). Orbit does not re-encode the images to measure it."
            ))
        }

        let total = recs.reduce(0) { $0 + ($1.transferSize ?? 0) }
        out.append(LHAuditResult(
            id: "total-byte-weight", category: .performance,
            title: "Avoids enormous network payloads",
            description: "Total page transfer size.",
            docsURL: "https://developer.chrome.com/docs/lighthouse/performance/total-byte-weight/",
            status: total > 5_000_000 ? .fail : .informative, score: nil, weight: 0,
            numericValue: Double(total), displayValue: OrbitDevToolsFormat.bytes(total), items: []
        ))

        let http1 = recs.filter {
            ($0.protocolName == "http/1.0" || $0.protocolName == "http/1.1") && !$0.fromCache && !$0.failed
        }
        if !http1.isEmpty {
            out.append(LHAuditResult(
                id: "uses-http2", category: .performance,
                title: "Use HTTP/2",
                description: "HTTP/2 offers header compression and request multiplexing.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/uses-http2/",
                status: .fail, score: 0, weight: 0, numericValue: Double(http1.count),
                displayValue: "\(http1.count) request(s) not on HTTP/2",
                items: http1.prefix(20).map {
                    LHAuditItem(url: $0.url, label: $0.protocolName ?? "http/1.1")
                }
            ))
        }

        if isHTTPS {
            let mixed = recs.filter { $0.url.hasPrefix("http://") && !$0.failed }
            if !mixed.isEmpty {
                out.append(LHAuditResult(
                    id: "no-mixed-content", category: .bestPractices,
                    title: "No mixed content",
                    description: "HTTP resources on an HTTPS page may be blocked or downgraded.",
                    docsURL: nil,
                    status: .fail, score: 0, weight: 5, numericValue: Double(mixed.count),
                    displayValue: "\(mixed.count) HTTP resource(s)",
                    items: mixed.prefix(20).map { LHAuditItem(url: $0.url, label: $0.resourceType) }
                ))
            }
        }

        let redirects = recs.filter { $0.status >= 300 && $0.status < 400 }
        if !redirects.isEmpty {
            let ms = redirects.compactMap(\.durationMs).reduce(0, +)
            out.append(LHAuditResult(
                id: "redirects", category: .performance,
                title: "Avoid multiple page redirects",
                description: "Redirects add HTTP round trips before the page loads.",
                docsURL: "https://developer.chrome.com/docs/lighthouse/performance/redirects/",
                status: .fail, score: 0, weight: 0, numericValue: ms,
                displayValue: "\(redirects.count) redirect(s)",
                items: redirects.prefix(10).map {
                    LHAuditItem(url: $0.url, wastedMs: $0.durationMs, label: "HTTP \($0.status)")
                }
            ))
        }

        // The security headers are graded in the Security category (see securityAudits), which shows the same raw values.

        if let pageHost = URL(string: bundle.url)?.host {
            let third = recs.filter {
                guard let u = URL(string: $0.url), let host = u.host else { return false }
                return !host.hasSuffix(pageHost) && host != pageHost
            }
            if !third.isEmpty {
                let byHost = Dictionary(grouping: third) { URL(string: $0.url)?.host ?? "unknown" }
                let items = byHost.map { (host, r) -> LHAuditItem in
                    let bytes = r.reduce(0) { $0 + ($1.transferSize ?? 0) }
                    return LHAuditItem(url: host, wastedBytes: bytes, label: "\(r.count) request(s)")
                }.sorted { ($0.wastedBytes ?? 0) > ($1.wastedBytes ?? 0) }
                let totalB = third.reduce(0) { $0 + ($1.transferSize ?? 0) }
                out.append(LHAuditResult(
                    id: "third-party-summary", category: .performance,
                    title: "Third-party code",
                    description: "Third-party resources can delay page loading.",
                    docsURL: nil, status: .informative, score: nil, weight: 0,
                    numericValue: Double(totalB),
                    displayValue: "\(third.count) requests, " + OrbitDevToolsFormat.bytes(totalB),
                    items: Array(items.prefix(20))
                ))
            }
        }

        return out
    }

    private enum MetricUnit { case timeMs, cls, bytes, count }

    private static func metricAudit(
        id: String, title: String, desc: String, docs: String?,
        value: Double?, rawOverride: Double? = nil,
        curve: (p10: Double, median: Double), weight: Double, unit: MetricUnit,
        items: [LHAuditItem] = []
    ) -> LHAuditResult {
        guard let v = value else {
            return naAudit(id, .performance, title, desc, weight: weight, docs: docs, items: items)
        }
        let raw = rawOverride ?? v
        let score = logNormalScore(value: max(raw, 0.001), p10: curve.p10, median: curve.median)
        return LHAuditResult(
            id: id, category: .performance, title: title, description: desc, docsURL: docs,
            status: score >= 0.9 ? .pass : .fail, score: score, weight: weight,
            numericValue: v, displayValue: formatMetric(v, unit: unit), items: items
        )
    }

    private static func naAudit(
        _ id: String, _ cat: LHCategory, _ title: String, _ desc: String,
        weight: Double, docs: String? = nil, items: [LHAuditItem] = []
    ) -> LHAuditResult {
        LHAuditResult(
            id: id, category: cat, title: title, description: desc, docsURL: docs,
            status: .notApplicable, score: nil, weight: weight,
            numericValue: nil, displayValue: "n/a", items: items
        )
    }

    private static func formatMetric(_ v: Double, unit: MetricUnit) -> String {
        switch unit {
        case .timeMs: return formatMs(v)
        case .cls:    return String(format: "%.3f", v)
        case .bytes:  return OrbitDevToolsFormat.bytes(Int(clamping: v))
        case .count:  return "\(Int(clamping: v))"
        }
    }

    static func formatMs(_ ms: Double) -> String {
        OrbitDevToolsFormat.milliseconds(ms)
    }


    static func summaryText(_ report: LHReport) -> String {
        var lines = [
            "Lighthouse — \(report.url)",
            DateFormatter.localizedString(from: report.timestamp, dateStyle: .short, timeStyle: .short)
                + " · \(report.mode.title) · \(report.device.title) curves"
        ]
        if let p = report.scores.performance    { lines.append("Performance:    \(p)/100") }
        if let a = report.scores.accessibility  { lines.append("Accessibility:  \(a)/100") }
        if let b = report.scores.bestPractices  { lines.append("Best practices: \(b)/100") }
        if let s = report.scores.seo            { lines.append("SEO:            \(s)/100") }
        if let s = report.scores.security       { lines.append("Security:       \(s)/100") }
        if report.mode != .snapshot {
            for kind in LHMetricKind.allCases {
                guard let value = kind.value(in: report.metrics) else { continue }
                lines.append("\(kind.title) \(kind.format(value)) (\(kind.rating(for: value).plainWord))")
            }
            if let lcp = report.metrics.lcpDetail, !lcp.selector.isEmpty {
                lines.append("LCP element: \(lcp.selector)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func generateHTMLReport(_ report: LHReport) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The pictures appear as images below, so the raw JSON leaves out their base64.
        let json = (try? enc.encode(report.strippingVisuals())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func badge(_ label: String, _ score: Int?) -> String {
            guard let s = score else { return "" }
            let cls = s >= 90 ? "#1a9e3f" : s >= 50 ? "#e67e00" : "#d93025"
            return "<div style=\"display:inline-block;margin:8px;text-align:center\">"
                + "<div style=\"font-size:36px;font-weight:700;color:\(cls)\">\(s)</div>"
                + "<div style=\"font-size:12px;color:#666\">\(label)</div></div>"
        }
        func ratingColor(_ rating: LHRating) -> String {
            switch rating {
            case .good: return "#1a9e3f"
            case .needsImprovement: return "#e67e00"
            case .poor: return "#d93025"
            }
        }

        var sections = ""

        if report.mode != .snapshot {
            var rows = ""
            for kind in LHMetricKind.allCases {
                guard let value = kind.value(in: report.metrics) else { continue }
                let rating = kind.rating(for: value)
                rows += "<tr><td><b>\(kind.title)</b><br><span class=\"dim\">\(esc(kind.fullName))</span></td>"
                rows += "<td style=\"color:\(ratingColor(rating))\"><b>\(esc(kind.format(value)))</b><br>\(rating.plainWord)</td>"
                rows += "<td>\(esc(kind.assessment(for: value)))<br><span class=\"dim\">\(esc(kind.explanation))</span></td></tr>"
            }
            if !rows.isEmpty {
                sections += "<h2>Metrics</h2><table>\(rows)</table>"
            }
            if let lcp = report.metrics.lcpDetail, !lcp.phases.isEmpty {
                let total = lcp.phases.reduce(0) { $0 + $1.ms }
                var phaseRows = ""
                for phase in lcp.phases {
                    phaseRows += "<tr><td>\(esc(phase.name))</td><td>\(esc(formatMs(phase.ms)))</td><td>\(percentOf(phase.ms, of: total))</td></tr>"
                }
                sections += "<h2>Largest Contentful Paint</h2><p>Element: <code>\(esc(lcp.selector))</code>"
                if let url = lcp.url { sections += " loaded from <code>\(esc(url))</code>" }
                sections += "</p><table>\(phaseRows)</table>"
            }
        }

        if let visuals = report.visuals {
            sections += "<h2>Visual evidence</h2>"
            if let shot = visuals.screenshot {
                var boxes = ""
                if shot.alignsWithViewport {
                    for mark in visuals.drawnMarks {
                        guard let f = fractionalRect(mark.rect, in: shot.viewport) else { continue }
                        let color = mark.kind == .lcp ? "#6d3fe0" : "#d93025"
                        let box = String(format: "left:%.2f%%;top:%.2f%%;width:%.2f%%;height:%.2f%%", f.x * 100, f.y * 100, f.width * 100, f.height * 100)
                        boxes += "<div style=\"position:absolute;\(box);border:2px solid \(color);box-sizing:border-box\">"
                        boxes += "<span style=\"background:\(color);color:#fff;font-size:10px;padding:0 3px\">\(esc(mark.label))</span></div>"
                    }
                }
                let encoded = shot.jpeg.base64EncodedString()
                sections += "<div style=\"position:relative;max-width:720px\">"
                sections += "<img style=\"width:100%;display:block;border:1px solid #ccc\" alt=\"Screenshot of the page when the audit ran\" src=\"data:image/jpeg;base64,\(encoded)\">"
                sections += boxes + "</div>"
                var list = ""
                for mark in visuals.marks {
                    list += "<li><b>\(esc(mark.label))</b> <code>\(esc(mark.selector))</code>"
                    if let detail = mark.detail { list += " <span class=\"dim\">\(esc(detail))</span>" }
                    list += "</li>"
                }
                if !list.isEmpty { sections += "<ul>\(list)</ul>" }
            } else if let note = visuals.note {
                sections += "<p class=\"dim\">\(esc(note))</p>"
            }
            if !visuals.filmstrip.isEmpty {
                let tags = filmstripMilestones(frameMs: visuals.filmstrip.map(\.ms), fcpMs: report.metrics.fcp, lcpMs: report.metrics.lcp)
                var frames = ""
                for (index, frame) in visuals.filmstrip.enumerated() {
                    var caption = formatMs(frame.ms)
                    if let completeness = frame.completeness { caption += ", \(Int((completeness * 100).rounded()))% complete" }
                    if !tags[index].isEmpty { caption += " (" + tags[index].joined(separator: ", ") + ")" }
                    let encoded = frame.jpeg.base64EncodedString()
                    frames += "<figure style=\"display:inline-block;margin:6px;text-align:center\">"
                    frames += "<img style=\"width:140px;border:1px solid #ccc\" alt=\"Page at \(esc(formatMs(frame.ms)))\" src=\"data:image/jpeg;base64,\(encoded)\">"
                    frames += "<figcaption class=\"dim\">\(esc(caption))</figcaption></figure>"
                }
                sections += "<h3>Filmstrip</h3><div>\(frames)</div>"
            }
        }

        if report.scores.performance != nil {
            let rows = scoreBreakdown(report.audits, category: .performance)
            if !rows.isEmpty {
                var body = ""
                for row in rows {
                    if row.measured {
                        let points = String(format: "%.1f of %.1f", row.points, row.maxPoints)
                        body += "<tr><td>\(esc(row.title))</td><td>\(esc(row.displayValue))</td><td>\(Int(row.weight))</td><td>\(points)</td></tr>"
                    } else {
                        body += "<tr><td>\(esc(row.title))</td><td colspan=\"3\" class=\"dim\">Not measured; its weight went to the other metrics.</td></tr>"
                    }
                }
                sections += "<h2>Performance score breakdown</h2><table><tr><th>Metric</th><th>Value</th><th>Weight</th><th>Points</th></tr>\(body)</table>"
            }
        }

        let problems = report.audits.filter { $0.band == .failed || $0.band == .warning }
        if !problems.isEmpty {
            var body = ""
            for audit in problems {
                body += "<h3>\(esc(audit.title)) <span class=\"dim\">\(esc(audit.displayValue))</span></h3><p>\(esc(audit.description))</p>"
                if let fix = audit.howToFix { body += "<p><b>How to fix:</b> \(esc(fix))</p>" }
                if !audit.items.isEmpty {
                    body += "<ul>"
                    for item in audit.items {
                        let parts = [item.label, item.url, item.selector, item.snippet, item.subLabel].compactMap { $0 }.filter { !$0.isEmpty }
                        body += "<li><code>\(esc(parts.joined(separator: " | ")))</code></li>"
                    }
                    body += "</ul>"
                }
            }
            sections += "<h2>Audits to look at</h2>\(body)"
        }

        return """
        <!DOCTYPE html><html lang="en">
        <head><meta charset="UTF-8"><title>Lighthouse — \(esc(report.url))</title>
        <style>body{font-family:-apple-system,sans-serif;margin:0;padding:24px;color:#222;background:#f8f8f8}
        h1{font-size:18px}table{border-collapse:collapse;width:100%;margin:12px 0}
        td,th{padding:4px 8px;border-bottom:1px solid #ddd;font-size:13px;text-align:left}
        pre{background:#eee;padding:12px;border-radius:6px;overflow-x:auto;font-size:11px}
        details summary{cursor:pointer;font-weight:600;margin:12px 0}
        h2{font-size:16px;margin-top:28px}h3{font-size:14px}.dim{color:#888;font-size:12px}code{font-size:12px;word-break:break-all}</style></head>
        <body>
        <h1>Lighthouse — \(esc(report.pageTitle.isEmpty ? report.url : report.pageTitle))</h1>
        <p style="color:#666;font-size:13px">\(esc(DateFormatter.localizedString(from: report.timestamp, dateStyle: .long, timeStyle: .medium))) · \(report.mode.title) · \(report.device.title) curves</p>
        <p style="color:#888;font-size:12px">\(esc(report.throttlingNote))</p>
        <div>\(badge("Performance", report.scores.performance))\(badge("Accessibility", report.scores.accessibility))\(badge("Best practices", report.scores.bestPractices))\(badge("SEO", report.scores.seo))\(badge("Security", report.scores.security))</div>
        \(sections)
        <details><summary>Raw JSON</summary><pre>\(esc(json))</pre></details>
        </body></html>
        """
    }
}
