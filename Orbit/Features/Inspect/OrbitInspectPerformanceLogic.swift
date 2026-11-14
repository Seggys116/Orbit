// Foundation only (no AppKit, SwiftUI or WebKit) so it compiles into the unit-test bundle.

import Foundation

/// Published by OrbitPerformanceModel and read by Lighthouse; times are milliseconds from navigation start unless noted.
struct OrbitVitals: Equatable {
    var ttfb: Double?
    var fcp: Double?
    var lcp: Double?
    var cls: Double?
    var inp: Double?
    var tbtEstimate: Double?
    var domContentLoaded: Double?
    var load: Double?

    var lcpElement: PerfLCPEntry?
    var clsEntries: [PerfLayoutShiftEntry]
    var inpWorstInteraction: PerfInteractionEntry?
    var longTasks: [PerfLongTask]
    var navigationPhases: PerfNavigationPhases?

    init(
        ttfb: Double? = nil,
        fcp: Double? = nil,
        lcp: Double? = nil,
        cls: Double? = nil,
        inp: Double? = nil,
        tbtEstimate: Double? = nil,
        domContentLoaded: Double? = nil,
        load: Double? = nil,
        lcpElement: PerfLCPEntry? = nil,
        clsEntries: [PerfLayoutShiftEntry] = [],
        inpWorstInteraction: PerfInteractionEntry? = nil,
        longTasks: [PerfLongTask] = [],
        navigationPhases: PerfNavigationPhases? = nil
    ) {
        self.ttfb = ttfb; self.fcp = fcp; self.lcp = lcp; self.cls = cls
        self.inp = inp; self.tbtEstimate = tbtEstimate
        self.domContentLoaded = domContentLoaded; self.load = load
        self.lcpElement = lcpElement; self.clsEntries = clsEntries
        self.inpWorstInteraction = inpWorstInteraction; self.longTasks = longTasks
        self.navigationPhases = navigationPhases
    }
}


struct PerfPaintEntry: Equatable, Codable {
    var name: String   // "first-paint" or "first-contentful-paint"
    var startTime: Double
}

struct PerfLCPEntry: Equatable, Codable {
    var startTime: Double
    var renderTime: Double?
    var loadTime: Double?
    var size: Double?
    var url: String
    var elementID: String
    var nodeID: Int
    var selector: String
    var isLazy: Bool
}

struct PerfRect: Equatable, Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
}

struct PerfLayoutShiftSource: Equatable, Codable {
    var nodeID: Int
    var nodeTag: String
    var selector: String
    var previousRect: PerfRect?
    var currentRect: PerfRect?
}

struct PerfLayoutShiftEntry: Equatable, Codable, Identifiable {
    var id: String
    var startTime: Double
    var value: Double
    var hadRecentInput: Bool
    var sources: [PerfLayoutShiftSource]
}

struct PerfInteractionEntry: Equatable, Codable, Identifiable {
    var id: String
    var interactionID: Double
    var name: String
    var startTime: Double
    var processingStart: Double?
    var processingEnd: Double?
    var duration: Double
    var nodeID: Int

    var inputDelay: Double? {
        guard let ps = processingStart, ps >= startTime else { return nil }
        return ps - startTime
    }
    var processingDuration: Double? {
        guard let ps = processingStart, let pe = processingEnd, pe >= ps else { return nil }
        return pe - ps
    }
    var presentationDelay: Double? {
        guard let pe = processingEnd else { return nil }
        let end = startTime + duration
        return end > pe ? end - pe : nil
    }
}

struct PerfLongTaskAttribution: Equatable, Codable {
    var url: String
    var containerType: String
    var containerName: String
    var containerID: String
}

struct PerfLongTask: Equatable, Codable, Identifiable {
    var id: String
    var startTime: Double
    var duration: Double
    var attribution: PerfLongTaskAttribution?
}

struct PerfNavigationEntry: Equatable, Codable {
    var startTime: Double
    var duration: Double
    var redirectStart: Double?; var redirectEnd: Double?
    var fetchStart: Double?
    var domainLookupStart: Double?; var domainLookupEnd: Double?
    var connectStart: Double?; var connectEnd: Double?
    var secureConnectionStart: Double?
    var requestStart: Double?
    var responseStart: Double?; var responseEnd: Double?
    var domContentLoadedEventStart: Double?; var domContentLoadedEventEnd: Double?
    var loadEventStart: Double?; var loadEventEnd: Double?
    var transferSize: Double?; var decodedBodySize: Double?
    var domInteractive: Double?
}

struct PerfNavigationPhases: Equatable, Codable {
    var redirectDuration: Double?
    var dnsDuration: Double?
    var tcpDuration: Double?
    var tlsDuration: Double?
    var requestDuration: Double?
    var responseDuration: Double?
    var domProcessingDuration: Double?
    var loadEventDuration: Double?
    var ttfb: Double?
    var fetchStart: Double?
    var responseStart: Double?
    var responseEnd: Double?
    var domInteractive: Double?
    var domContentLoadedEventEnd: Double?
    var loadEventEnd: Double?
    var totalDuration: Double?
}

struct PerfResourceEntry: Equatable, Codable, Identifiable {
    var id: String
    var url: String
    var startTime: Double?
    var duration: Double?
    var transferSize: Double?
    var decodedBodySize: Double?
    var initiatorType: String
    var nextHopProtocol: String
}

struct PerfResourceBucket: Equatable, Identifiable {
    var id: String { type }
    var type: String
    var count: Int
    var transferBytes: Int
    var bodyBytes: Int
}

struct PerfUserTiming: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var startTime: Double
    var duration: Double  // 0 for marks
    var isMeasure: Bool
}

struct PerfFrameSample: Equatable, Codable, Identifiable {
    var id: String
    var timestamp: Double
    var duration: Double
}

struct PerfDriftSample: Equatable, Codable, Identifiable {
    var id: String
    var timestamp: Double
    var expected: Double
    var actual: Double
    /// mainThreadJank = actual - expected (ms added by main-thread blocking)
    var jank: Double { max(0, actual - expected) }
}

struct PerfNativeSample: Equatable, Codable, Identifiable {
    var id: String
    var timestamp: Double  // ms since recording start (approximate wall clock)
    var memoryBytes: UInt64
    var cpuPercent: Double
    var processID: Int32
    var resolved: Bool     // false when the web process PID could not be determined
}

struct PerfNetworkRecord: Equatable, Codable, Identifiable {
    var id: String
    var url: String
    var resourceType: String
    var startTime: Double?
    var duration: Double?
    var transferSize: Int?
    var status: Int
    var failed: Bool
}

struct PerfElementTimingEntry: Equatable, Codable, Identifiable {
    var id: String
    var elementID: String
    var startTime: Double
    var renderTime: Double?
    var loadTime: Double?
    var url: String
    var nodeID: Int
}

struct PerfFilmstripFrame: Equatable, Codable, Identifiable {
    var id: String
    var timestamp: Double  // ms from navigation start
    var imageData: Data?
}

struct PerfDOMScan: Equatable, Codable {
    var blockingScriptURLs: [String]
    var nodeCount: Int
}


struct PerfLCPPhases: Equatable {
    var ttfb: Double?           // time-to-first-byte
    var resourceLoadDelay: Double?   // ttfb → resource request start
    var resourceLoadDuration: Double? // request start → response end (resource load)
    var renderDelay: Double?    // response end → lcp renderTime
}


enum PerfRating: Equatable {
    case good, needsImprovement, poor, unknown
}


struct PerfInsight: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var severity: PerfRating
    var url: String?
    var nodeID: Int?
}


struct PerfRecording: Equatable, Codable, Identifiable {
    var id: String
    var url: String
    var title: String
    var startWallTime: Double   // Unix timestamp when recording started
    var duration: Double        // ms

    var paintEntries: [PerfPaintEntry] = []
    var lcpEntries: [PerfLCPEntry] = []
    var layoutShiftEntries: [PerfLayoutShiftEntry] = []
    var longTaskEntries: [PerfLongTask] = []
    var interactionEntries: [PerfInteractionEntry] = []
    var firstInputEntry: PerfInteractionEntry? = nil
    var navigationEntry: PerfNavigationEntry? = nil
    var resourceEntries: [PerfResourceEntry] = []
    var markEntries: [PerfUserTiming] = []
    var measureEntries: [PerfUserTiming] = []
    var elementTimingEntries: [PerfElementTimingEntry] = []
    var frameSamples: [PerfFrameSample] = []
    var driftSamples: [PerfDriftSample] = []
    var nativeSamples: [PerfNativeSample] = []
    var networkRecords: [PerfNetworkRecord] = []
    var filmstripFrames: [PerfFilmstripFrame] = []
    var domScan: PerfDOMScan? = nil

    init(id: String = UUID().uuidString, url: String = "", title: String = "",
         startWallTime: Double = Date().timeIntervalSince1970,
         duration: Double = 0) {
        self.id = id; self.url = url; self.title = title
        self.startWallTime = startWallTime; self.duration = duration
    }
}


enum OrbitPerformanceLogic {


    static func ratingForLCP(_ ms: Double) -> PerfRating {
        if ms <= 2500 { return .good }
        if ms <= 4000 { return .needsImprovement }
        return .poor
    }

    static func ratingForINP(_ ms: Double) -> PerfRating {
        if ms <= 200 { return .good }
        if ms <= 500 { return .needsImprovement }
        return .poor
    }

    static func ratingForCLS(_ score: Double) -> PerfRating {
        if score <= 0.1 { return .good }
        if score <= 0.25 { return .needsImprovement }
        return .poor
    }

    static func ratingForFCP(_ ms: Double) -> PerfRating {
        if ms <= 1800 { return .good }
        if ms <= 3000 { return .needsImprovement }
        return .poor
    }

    static func ratingForTTFB(_ ms: Double) -> PerfRating {
        if ms <= 800 { return .good }
        if ms <= 1800 { return .needsImprovement }
        return .poor
    }

    /// Maximum session-window CLS, ignoring entries with hadRecentInput; a session ends after a 1000 ms gap or 5000 ms duration.
    static func clsScore(entries: [PerfLayoutShiftEntry]) -> Double {
        let valid = entries.filter { !$0.hadRecentInput }.sorted { $0.startTime < $1.startTime }
        guard !valid.isEmpty else { return 0 }

        var maxScore = 0.0
        var sessionScore = 0.0
        var sessionStart = valid[0].startTime
        var lastTime = valid[0].startTime

        for entry in valid {
            let gap = entry.startTime - lastTime
            let span = entry.startTime - sessionStart
            if gap > 1000 || span > 5000 {
                maxScore = max(maxScore, sessionScore)
                sessionScore = 0
                sessionStart = entry.startTime
            }
            sessionScore += entry.value
            lastTime = entry.startTime
        }
        maxScore = max(maxScore, sessionScore)
        return maxScore
    }

    /// p98 of the maximum duration per interactionID (>0), plus the worst interaction entry.
    static func inpFromInteractions(
        _ entries: [PerfInteractionEntry]
    ) -> (value: Double?, worst: PerfInteractionEntry?) {
        let withID = entries.filter { $0.interactionID > 0 }
        guard !withID.isEmpty else { return (nil, nil) }

        var byID: [Double: PerfInteractionEntry] = [:]
        for entry in withID {
            if let existing = byID[entry.interactionID] {
                if entry.duration > existing.duration { byID[entry.interactionID] = entry }
            } else {
                byID[entry.interactionID] = entry
            }
        }

        let sorted = byID.values.sorted { $0.duration < $1.duration }
        let count = sorted.count
        // p98: take the item at index floor(count / 50) from the top (Chrome's definition)
        let skipFromTop = max(0, count / 50)
        let targetIndex = count - 1 - skipFromTop
        let pick = sorted[max(0, targetIndex)]
        return (pick.duration, pick)
    }

    /// Sum of (task.duration - 50) for long tasks overlapping [fcp, loadEnd]; with no loadEnd, tasks after FCP only.
    static func tbt(longTasks: [PerfLongTask], fcp: Double?, loadEnd: Double?) -> Double {
        guard let fcp else { return 0 }
        return longTasks.reduce(0.0) { acc, task in
            let taskEnd = task.startTime + task.duration
            guard task.startTime >= fcp else { return acc }
            if let end = loadEnd, taskEnd > end { return acc }
            return acc + max(0, task.duration - 50)
        }
    }


    static func lcpPhases(entry: PerfLCPEntry, nav: PerfNavigationPhases) -> PerfLCPPhases {
        let ttfb = nav.ttfb
        let lcpTime = entry.renderTime ?? entry.loadTime ?? entry.startTime
        let responseStart = nav.responseStart
        let responseEnd = nav.responseEnd
        let fetchStart = nav.fetchStart ?? 0

        let ttfbMs = responseStart.map { $0 - fetchStart }

        // Resource load delay = TTFB → start of LCP resource load (approximated as responseEnd for navigation, or startTime for resource)
        var resourceLoadDelay: Double? = nil
        var resourceLoadDuration: Double? = nil
        if !entry.url.isEmpty, let re = responseEnd, let rs = responseStart {
            resourceLoadDelay = max(0, entry.startTime - re)
            if let lt = entry.loadTime, let rt = entry.renderTime {
                resourceLoadDuration = max(0, lt - rs)
                let renderDelay = max(0, rt - lt)
                return PerfLCPPhases(
                    ttfb: ttfbMs, resourceLoadDelay: resourceLoadDelay,
                    resourceLoadDuration: resourceLoadDuration, renderDelay: renderDelay)
            }
        }

        let renderDelay: Double?
        if let rs = responseStart {
            renderDelay = max(0, lcpTime - rs)
        } else {
            renderDelay = nil
        }
        return PerfLCPPhases(ttfb: ttfbMs, resourceLoadDelay: resourceLoadDelay,
                             resourceLoadDuration: resourceLoadDuration, renderDelay: renderDelay)
    }


    static func navigationPhases(from entry: PerfNavigationEntry) -> PerfNavigationPhases {
        let fetchStart = entry.fetchStart ?? 0

        func dur(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }

        let tlsDur: Double?
        if let scs = entry.secureConnectionStart, scs > 0, let ce = entry.connectEnd, ce >= scs {
            tlsDur = ce - scs
        } else {
            tlsDur = nil
        }

        let ttfb: Double?
        if let rs = entry.responseStart {
            ttfb = rs - fetchStart
        } else {
            ttfb = nil
        }

        return PerfNavigationPhases(
            redirectDuration: dur(entry.redirectStart, entry.redirectEnd),
            dnsDuration: dur(entry.domainLookupStart, entry.domainLookupEnd),
            tcpDuration: dur(entry.connectStart, entry.connectEnd),
            tlsDuration: tlsDur,
            requestDuration: dur(entry.requestStart, entry.responseStart),
            responseDuration: dur(entry.responseStart, entry.responseEnd),
            domProcessingDuration: dur(entry.responseEnd, entry.domContentLoadedEventStart),
            loadEventDuration: dur(entry.loadEventStart, entry.loadEventEnd),
            ttfb: ttfb,
            fetchStart: entry.fetchStart,
            responseStart: entry.responseStart,
            responseEnd: entry.responseEnd,
            domInteractive: entry.domInteractive,
            domContentLoadedEventEnd: entry.domContentLoadedEventEnd,
            loadEventEnd: entry.loadEventEnd,
            totalDuration: entry.duration > 0 ? entry.duration : nil
        )
    }


    static func resourceSummary(entries: [PerfResourceEntry]) -> [PerfResourceBucket] {
        var buckets: [String: (count: Int, transfer: Int, body: Int)] = [:]
        for entry in entries {
            let type = normalizeResourceType(entry.initiatorType)
            var b = buckets[type] ?? (0, 0, 0)
            b.count += 1
            b.transfer = b.transfer.addingReportingOverflow(Int(clamping: entry.transferSize ?? 0)).partialValue
            b.body = b.body.addingReportingOverflow(Int(clamping: entry.decodedBodySize ?? 0)).partialValue
            buckets[type] = b
        }
        return buckets.map { (type, data) in
            PerfResourceBucket(type: type, count: data.count,
                               transferBytes: data.transfer, bodyBytes: data.body)
        }.sorted { $0.transferBytes > $1.transferBytes }
    }

    private static func normalizeResourceType(_ initiator: String) -> String {
        switch initiator.lowercased() {
        case "script": return "Script"
        case "stylesheet", "css": return "CSS"
        case "img", "image": return "Image"
        case "font": return "Font"
        case "fetch": return "Fetch"
        case "xmlhttprequest", "xhr": return "XHR"
        case "media", "video", "audio": return "Media"
        case "link": return "Link"
        case "document", "navigation": return "Document"
        case "other", "": return "Other"
        default: return initiator.prefix(1).uppercased() + initiator.dropFirst().lowercased()
        }
    }


    static func vitals(from recording: PerfRecording) -> OrbitVitals {
        let nav = recording.navigationEntry.map { navigationPhases(from: $0) }

        let ttfb = nav?.ttfb

        let fcp = recording.paintEntries
            .first { $0.name == "first-contentful-paint" }?.startTime

        // The last LCP entry wins: the spec updates the candidate and the last one is final.
        let lcpEntry = recording.lcpEntries.last
        let lcpMs = lcpEntry.map { $0.renderTime ?? $0.loadTime ?? $0.startTime }

        let clsScore = Self.clsScore(entries: recording.layoutShiftEntries)

        let (inpMs, inpWorst) = inpFromInteractions(recording.interactionEntries)

        let loadEnd = nav?.loadEventEnd
        let tbt = Self.tbt(longTasks: recording.longTaskEntries, fcp: fcp, loadEnd: loadEnd)

        let dcl = nav?.domContentLoadedEventEnd
        let load = nav?.loadEventEnd

        return OrbitVitals(
            ttfb: ttfb, fcp: fcp, lcp: lcpMs,
            cls: clsScore > 0 ? clsScore : (recording.layoutShiftEntries.isEmpty ? nil : clsScore),
            inp: inpMs,
            tbtEstimate: tbt > 0 ? tbt : nil,
            domContentLoaded: dcl, load: load,
            lcpElement: lcpEntry,
            clsEntries: recording.layoutShiftEntries.filter { !$0.hadRecentInput },
            inpWorstInteraction: inpWorst,
            longTasks: recording.longTaskEntries,
            navigationPhases: nav
        )
    }


    enum FrameClass: Equatable {
        case smooth           // ≤ 16.7ms (60fps)
        case slightDrop       // ≤ 33.4ms (30fps)
        case moderateDrop     // ≤ 50ms   (20fps)
        case severeDrop       // > 50ms
    }

    static func classifyFrame(_ duration: Double) -> FrameClass {
        if duration <= 16.7 { return .smooth }
        if duration <= 33.4 { return .slightDrop }
        if duration <= 50 { return .moderateDrop }
        return .severeDrop
    }

    /// `zoom` 1.0 shows the whole recording; `offset` is ms from the recording start to the left edge of the view.
    static func visibleRange(zoom: Double, offset: Double, duration: Double) -> ClosedRange<Double> {
        guard duration > 0, zoom >= 1 else { return 0...max(1, duration) }
        let visible = duration / zoom
        let clamped = min(max(0, offset), max(0, duration - visible))
        return clamped...(clamped + visible)
    }

    static func xAtTime(_ time: Double, in range: ClosedRange<Double>, width: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, width > 0 else { return 0 }
        return (time - range.lowerBound) / span * width
    }

    static func timeAtX(_ x: Double, in range: ClosedRange<Double>, width: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard width > 0 else { return range.lowerBound }
        return range.lowerBound + (x / width) * span
    }


    static func insights(recording: PerfRecording, vitals: OrbitVitals) -> [PerfInsight] {
        var out: [PerfInsight] = []

        if let ttfb = vitals.ttfb, ttfb > 800 {
            out.append(PerfInsight(
                id: "ttfb-slow",
                title: "Slow time to first byte",
                detail: "TTFB is \(ms(ttfb)) — server response time is above the 800ms threshold. Check server-side processing, CDN configuration, and network latency.",
                severity: ttfb > 1800 ? .poor : .needsImprovement
            ))
        }

        if let lcp = vitals.lcpElement, lcp.isLazy {
            out.append(PerfInsight(
                id: "lcp-lazy",
                title: "LCP image is lazy-loaded",
                detail: "The largest contentful paint element has loading=\"lazy\". Lazy-loading defers the LCP image and directly increases LCP time. Remove the lazy attribute from this image.",
                severity: .poor,
                url: lcp.url.isEmpty ? nil : lcp.url,
                nodeID: lcp.nodeID != 0 ? lcp.nodeID : nil
            ))
        }

        if let scan = recording.domScan, !scan.blockingScriptURLs.isEmpty {
            let urls = scan.blockingScriptURLs.prefix(3).joined(separator: ", ")
            out.append(PerfInsight(
                id: "blocking-scripts",
                title: "\(scan.blockingScriptURLs.count) render-blocking script(s) in <head>",
                detail: "Scripts without async or defer in <head> block HTML parsing: \(urls). Add async or defer, or move them before </body>.",
                severity: .needsImprovement
            ))
        }

        if let scan = recording.domScan, scan.nodeCount > 1500 {
            out.append(PerfInsight(
                id: "large-dom",
                title: "Large DOM (\(scan.nodeCount) nodes)",
                detail: "Excessive DOM size slows style recalculation, layout, and memory. Aim for fewer than 1,500 nodes. Use virtual scrolling for long lists.",
                severity: scan.nodeCount > 3000 ? .poor : .needsImprovement
            ))
        }

        if let cls = vitals.cls, cls > 0.1 {
            let imgShifts = vitals.clsEntries.flatMap { $0.sources }.filter {
                $0.nodeTag.lowercased() == "img" || $0.nodeTag.lowercased() == "video"
            }
            if !imgShifts.isEmpty {
                out.append(PerfInsight(
                    id: "cls-images",
                    title: "Layout shifts from images/videos without explicit dimensions",
                    detail: "Images or videos without width/height attributes cause layout shifts as they load. Specify explicit dimensions or use CSS aspect-ratio to reserve space.",
                    severity: ratingForCLS(cls) == .poor ? .poor : .needsImprovement,
                    nodeID: imgShifts.first?.nodeID
                ))
            }
        }

        let tasksAtLoad: [PerfLongTask]
        if let load = vitals.load {
            tasksAtLoad = vitals.longTasks.filter { $0.startTime >= (vitals.fcp ?? 0) && $0.startTime + $0.duration <= load + 500 }
        } else {
            tasksAtLoad = []
        }
        if tasksAtLoad.count >= 3 {
            let total = tasksAtLoad.reduce(0.0) { $0 + $1.duration }
            out.append(PerfInsight(
                id: "long-tasks-load",
                title: "\(tasksAtLoad.count) long tasks during page load",
                detail: "A total of \(ms(total)) of main-thread blocking during load. Long tasks (>50ms) prevent the browser from responding to user input (FID) and inflate TBT.",
                severity: .needsImprovement
            ))
        }

        if let tbt = vitals.tbtEstimate, tbt > 300 {
            out.append(PerfInsight(
                id: "high-tbt",
                title: "High Total Blocking Time estimate (\(ms(tbt)))",
                detail: "TBT measures main-thread blocking between FCP and load. Values above 300ms indicate the page is not reliably interactive at load. Break up long tasks.",
                severity: tbt > 600 ? .poor : .needsImprovement
            ))
        }

        return out
    }

    private static func ms(_ value: Double) -> String {
        if value < 1000 { return "\(Int(clamping: value))ms" }
        return String(format: "%.2fs", value / 1000)
    }


    static func parseEntry(from object: [String: Any]) -> PerfParsedEntry? {
        guard let et = object["et"] as? String else { return nil }
        switch et {
        case "paint":
            guard let name = object["name"] as? String,
                  let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            return .paint(PerfPaintEntry(name: name, startTime: ts))

        case "lcp":
            guard let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let isLazy = OrbitInspectDecode.bool(object, "lazy")
            let entry = PerfLCPEntry(
                startTime: ts,
                renderTime: OrbitInspectDecode.number(object, "rt"),
                loadTime: OrbitInspectDecode.number(object, "lt"),
                size: OrbitInspectDecode.number(object, "size"),
                url: OrbitInspectDecode.string(object, "url"),
                elementID: OrbitInspectDecode.string(object, "eid"),
                nodeID: OrbitInspectDecode.integer(object, "nid"),
                selector: OrbitInspectDecode.string(object, "sel"),
                isLazy: isLazy
            )
            return .lcp(entry)

        case "layout-shift":
            guard let ts = OrbitInspectDecode.number(object, "ts"),
                  let val = OrbitInspectDecode.number(object, "val") else { return nil }
            let had = OrbitInspectDecode.bool(object, "had")
            let rawSources = OrbitInspectDecode.objects(object, "sources")
            let sources: [PerfLayoutShiftSource] = rawSources.map { src in
                let pr = parsePerfRect(from: OrbitInspectDecode.object(src, "pr"))
                let cr = parsePerfRect(from: OrbitInspectDecode.object(src, "cr"))
                return PerfLayoutShiftSource(
                    nodeID: OrbitInspectDecode.integer(src, "nid"),
                    nodeTag: OrbitInspectDecode.string(src, "tag"),
                    selector: OrbitInspectDecode.string(src, "sel"),
                    previousRect: pr, currentRect: cr
                )
            }
            let id = "ls-\(Int(clamping: ts * 1000))-\(Int(clamping: val * 10000))"
            return .layoutShift(PerfLayoutShiftEntry(id: id, startTime: ts, value: val,
                                                      hadRecentInput: had, sources: sources))

        case "longtask":
            guard let ts = OrbitInspectDecode.number(object, "ts"),
                  let dur = OrbitInspectDecode.number(object, "dur") else { return nil }
            let attr: PerfLongTaskAttribution?
            if let rawAttr = OrbitInspectDecode.object(object, "attr") {
                attr = PerfLongTaskAttribution(
                    url: OrbitInspectDecode.string(rawAttr, "url"),
                    containerType: OrbitInspectDecode.string(rawAttr, "ct"),
                    containerName: OrbitInspectDecode.string(rawAttr, "cn"),
                    containerID: OrbitInspectDecode.string(rawAttr, "ci")
                )
            } else {
                attr = nil
            }
            let id = "lt-\(Int(clamping: ts))-\(Int(clamping: dur))"
            return .longTask(PerfLongTask(id: id, startTime: ts, duration: dur, attribution: attr))

        case "event":
            guard let ts = OrbitInspectDecode.number(object, "ts"),
                  let dur = OrbitInspectDecode.number(object, "dur") else { return nil }
            let iid = OrbitInspectDecode.number(object, "iid") ?? 0
            let id = "int-\(Int(clamping: ts))-\(Int(clamping: iid))"
            let entry = PerfInteractionEntry(
                id: id, interactionID: iid,
                name: OrbitInspectDecode.string(object, "name"),
                startTime: ts,
                processingStart: OrbitInspectDecode.number(object, "ps"),
                processingEnd: OrbitInspectDecode.number(object, "pe"),
                duration: dur,
                nodeID: OrbitInspectDecode.integer(object, "nid")
            )
            return .interaction(entry)

        case "first-input":
            guard let ts = OrbitInspectDecode.number(object, "ts"),
                  let dur = OrbitInspectDecode.number(object, "dur") else { return nil }
            let id = "fi-\(Int(clamping: ts))"
            let entry = PerfInteractionEntry(
                id: id, interactionID: 0,
                name: OrbitInspectDecode.string(object, "name"),
                startTime: ts,
                processingStart: OrbitInspectDecode.number(object, "ps"),
                processingEnd: OrbitInspectDecode.number(object, "pe"),
                duration: dur,
                nodeID: OrbitInspectDecode.integer(object, "nid")
            )
            return .firstInput(entry)

        case "navigation":
            guard let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let nav = PerfNavigationEntry(
                startTime: ts,
                duration: OrbitInspectDecode.number(object, "dur") ?? 0,
                redirectStart: OrbitInspectDecode.number(object, "rs"),
                redirectEnd: OrbitInspectDecode.number(object, "re"),
                fetchStart: OrbitInspectDecode.number(object, "fs"),
                domainLookupStart: OrbitInspectDecode.number(object, "ds"),
                domainLookupEnd: OrbitInspectDecode.number(object, "de"),
                connectStart: OrbitInspectDecode.number(object, "cs"),
                connectEnd: OrbitInspectDecode.number(object, "ce"),
                secureConnectionStart: OrbitInspectDecode.number(object, "scs"),
                requestStart: OrbitInspectDecode.number(object, "rqs"),
                responseStart: OrbitInspectDecode.number(object, "rss"),
                responseEnd: OrbitInspectDecode.number(object, "rse"),
                domContentLoadedEventStart: OrbitInspectDecode.number(object, "dcls"),
                domContentLoadedEventEnd: OrbitInspectDecode.number(object, "dcle"),
                loadEventStart: OrbitInspectDecode.number(object, "les"),
                loadEventEnd: OrbitInspectDecode.number(object, "lee"),
                transferSize: OrbitInspectDecode.number(object, "xfr"),
                decodedBodySize: OrbitInspectDecode.number(object, "body"),
                domInteractive: OrbitInspectDecode.number(object, "dom")
            )
            return .navigation(nav)

        case "resource":
            guard let url = object["url"] as? String,
                  let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let id = "res-\(url.hashValue)-\(Int(clamping: ts))"
            let entry = PerfResourceEntry(
                id: id, url: url,
                startTime: ts,
                duration: OrbitInspectDecode.number(object, "dur"),
                transferSize: OrbitInspectDecode.number(object, "xfr"),
                decodedBodySize: OrbitInspectDecode.number(object, "body"),
                initiatorType: OrbitInspectDecode.string(object, "init"),
                nextHopProtocol: OrbitInspectDecode.string(object, "proto")
            )
            return .resource(entry)

        case "mark":
            guard let name = object["name"] as? String,
                  let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let id = "mark-\(name)-\(Int(clamping: ts))"
            return .mark(PerfUserTiming(id: id, name: name, startTime: ts, duration: 0, isMeasure: false))

        case "measure":
            guard let name = object["name"] as? String,
                  let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let dur = OrbitInspectDecode.number(object, "dur") ?? 0
            let id = "msr-\(name)-\(Int(clamping: ts))"
            return .measure(PerfUserTiming(id: id, name: name, startTime: ts, duration: dur, isMeasure: true))

        case "element":
            guard let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let eid = OrbitInspectDecode.string(object, "id")
            let id = "elt-\(eid)-\(Int(clamping: ts))"
            let entry = PerfElementTimingEntry(
                id: id, elementID: eid, startTime: ts,
                renderTime: OrbitInspectDecode.number(object, "rt"),
                loadTime: OrbitInspectDecode.number(object, "lt"),
                url: OrbitInspectDecode.string(object, "url"),
                nodeID: OrbitInspectDecode.integer(object, "nid")
            )
            return .element(entry)

        case "frame":
            guard let ts = OrbitInspectDecode.number(object, "ts"),
                  let dur = OrbitInspectDecode.number(object, "dur") else { return nil }
            let id = "frm-\(Int(clamping: ts))"
            return .frame(PerfFrameSample(id: id, timestamp: ts, duration: dur))

        case "drift":
            guard let ts = OrbitInspectDecode.number(object, "ts") else { return nil }
            let exp = OrbitInspectDecode.number(object, "exp") ?? 250
            let act = OrbitInspectDecode.number(object, "act") ?? exp
            let id = "drift-\(Int(clamping: ts))"
            return .drift(PerfDriftSample(id: id, timestamp: ts, expected: exp, actual: act))

        case "dom-scan":
            let urls = OrbitInspectDecode.strings(object, "blockingScripts")
            let nodeCount = OrbitInspectDecode.integer(object, "nodeCount")
            return .domScan(PerfDOMScan(blockingScriptURLs: urls, nodeCount: nodeCount))

        case "softnav":
            return .softNav

        case "bfcache":
            return .bfcacheRestore

        default:
            return nil
        }
    }

    private static func parsePerfRect(from object: [String: Any]?) -> PerfRect? {
        guard let object else { return nil }
        guard let x = OrbitInspectDecode.number(object, "x"),
              let y = OrbitInspectDecode.number(object, "y"),
              let w = OrbitInspectDecode.number(object, "w"),
              let h = OrbitInspectDecode.number(object, "h") else { return nil }
        return PerfRect(x: x, y: y, width: w, height: h)
    }
}


enum PerfParsedEntry {
    case paint(PerfPaintEntry)
    case lcp(PerfLCPEntry)
    case layoutShift(PerfLayoutShiftEntry)
    case longTask(PerfLongTask)
    case interaction(PerfInteractionEntry)
    case firstInput(PerfInteractionEntry)
    case navigation(PerfNavigationEntry)
    case resource(PerfResourceEntry)
    case mark(PerfUserTiming)
    case measure(PerfUserTiming)
    case element(PerfElementTimingEntry)
    case frame(PerfFrameSample)
    case drift(PerfDriftSample)
    case domScan(PerfDOMScan)
    case softNav
    case bfcacheRestore
}
