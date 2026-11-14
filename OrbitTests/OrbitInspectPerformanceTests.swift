// Unit tests for OrbitInspectPerformanceLogic.swift, compiled directly with OrbitInspectDecode.swift (no @testable import).

import XCTest

final class OrbitInspectPerformanceTests: XCTestCase {


    func test_ratingForLCP_good() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(0), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(2500), .good)
    }

    func test_ratingForLCP_needsImprovement() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(2501), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(4000), .needsImprovement)
    }

    func test_ratingForLCP_poor() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(4001), .poor)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForLCP(10000), .poor)
    }

    func test_ratingForINP_thresholds() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForINP(0), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForINP(200), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForINP(201), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForINP(500), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForINP(501), .poor)
    }

    func test_ratingForCLS_thresholds() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForCLS(0), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForCLS(0.1), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForCLS(0.101), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForCLS(0.25), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForCLS(0.251), .poor)
    }

    func test_ratingForFCP_thresholds() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForFCP(1800), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForFCP(1801), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForFCP(3001), .poor)
    }

    func test_ratingForTTFB_thresholds() {
        XCTAssertEqual(OrbitPerformanceLogic.ratingForTTFB(800), .good)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForTTFB(801), .needsImprovement)
        XCTAssertEqual(OrbitPerformanceLogic.ratingForTTFB(1801), .poor)
    }


    func test_cls_empty() {
        XCTAssertEqual(OrbitPerformanceLogic.clsScore(entries: []), 0)
    }

    func test_cls_singleEntry() {
        let entries = [
            PerfLayoutShiftEntry(id: "ls-0", startTime: 100, value: 0.05, hadRecentInput: false, sources: [])
        ]
        XCTAssertEqual(OrbitPerformanceLogic.clsScore(entries: entries), 0.05, accuracy: 1e-10)
    }

    func test_cls_sumWithinSession() {
        // Two shifts 200ms apart — same session window, should sum
        let entries = [
            PerfLayoutShiftEntry(id: "ls-1", startTime: 100, value: 0.05, hadRecentInput: false, sources: []),
            PerfLayoutShiftEntry(id: "ls-2", startTime: 300, value: 0.04, hadRecentInput: false, sources: []),
        ]
        XCTAssertEqual(OrbitPerformanceLogic.clsScore(entries: entries), 0.09, accuracy: 1e-10)
    }

    func test_cls_hadRecentInputIgnored() {
        // Entry with hadRecentInput should not count
        let entries = [
            PerfLayoutShiftEntry(id: "ls-1", startTime: 100, value: 0.3, hadRecentInput: true, sources: []),
            PerfLayoutShiftEntry(id: "ls-2", startTime: 200, value: 0.05, hadRecentInput: false, sources: []),
        ]
        XCTAssertEqual(OrbitPerformanceLogic.clsScore(entries: entries), 0.05, accuracy: 1e-10)
    }

    func test_cls_gapStartsNewSession() {
        // Gap > 1000ms → new session. Both have 0.1, so max = 0.1 (each session has one entry)
        let entries = [
            PerfLayoutShiftEntry(id: "ls-1", startTime: 100, value: 0.1, hadRecentInput: false, sources: []),
            PerfLayoutShiftEntry(id: "ls-2", startTime: 1300, value: 0.08, hadRecentInput: false, sources: []),
        ]
        let score = OrbitPerformanceLogic.clsScore(entries: entries)
        XCTAssertEqual(score, 0.1, accuracy: 1e-10, "New session after 1s gap; max of 0.1 and 0.08 = 0.1")
    }

    func test_cls_maxSessionWins() {
        // Session 1: 0.05+0.06 = 0.11. Session 2 (>1s gap): 0.03. Max = 0.11
        let entries = [
            PerfLayoutShiftEntry(id: "ls-1", startTime: 100, value: 0.05, hadRecentInput: false, sources: []),
            PerfLayoutShiftEntry(id: "ls-2", startTime: 300, value: 0.06, hadRecentInput: false, sources: []),
            PerfLayoutShiftEntry(id: "ls-3", startTime: 2000, value: 0.03, hadRecentInput: false, sources: []),
        ]
        XCTAssertEqual(OrbitPerformanceLogic.clsScore(entries: entries), 0.11, accuracy: 1e-10)
    }

    func test_cls_sessionExceeds5s_startsNew() {
        // Shifts every 800ms keep one window open (gap < 1s) until it is 5s old; the shift at 5600ms must start a new window.
        var entries = (0..<7).map { index in
            PerfLayoutShiftEntry(id: "ls-\(index)", startTime: Double(index) * 800, value: 0.01, hadRecentInput: false, sources: [])
        }
        entries.append(PerfLayoutShiftEntry(id: "ls-late", startTime: 5600, value: 0.2, hadRecentInput: false, sources: []))
        let score = OrbitPerformanceLogic.clsScore(entries: entries)
        // Window 1 holds the first seven shifts (0.07). The late shift opens window 2 (0.2). The worst window wins.
        XCTAssertEqual(score, 0.2, accuracy: 1e-10)
    }


    func test_inp_empty() {
        let (value, worst) = OrbitPerformanceLogic.inpFromInteractions([])
        XCTAssertNil(value)
        XCTAssertNil(worst)
    }

    func test_inp_noInteractionID() {
        // Entries without interactionID (= 0) are ignored
        let entries = [
            PerfInteractionEntry(id: "e1", interactionID: 0, name: "click", startTime: 100,
                                  processingStart: nil, processingEnd: nil, duration: 500, nodeID: 0)
        ]
        let (value, _) = OrbitPerformanceLogic.inpFromInteractions(entries)
        XCTAssertNil(value)
    }

    func test_inp_singleInteraction() {
        let entries = [
            PerfInteractionEntry(id: "e1", interactionID: 1, name: "click", startTime: 100,
                                  processingStart: nil, processingEnd: nil, duration: 250, nodeID: 0)
        ]
        let (value, worst) = OrbitPerformanceLogic.inpFromInteractions(entries)
        XCTAssertEqual(value, 250)
        XCTAssertEqual(worst?.interactionID, 1)
    }

    func test_inp_maxPerInteractionGroup() {
        // Two entries with same interactionID; take the higher duration
        let entries = [
            PerfInteractionEntry(id: "e1", interactionID: 42, name: "pointerdown", startTime: 100,
                                  processingStart: nil, processingEnd: nil, duration: 120, nodeID: 0),
            PerfInteractionEntry(id: "e2", interactionID: 42, name: "click", startTime: 100,
                                  processingStart: nil, processingEnd: nil, duration: 300, nodeID: 0),
        ]
        let (value, _) = OrbitPerformanceLogic.inpFromInteractions(entries)
        XCTAssertEqual(value, 300)
    }

    func test_inp_p98_lessThan50Interactions_returnsWorst() {
        // < 50 interactions: floor(count/50) = 0, so take index 0 = worst
        var entries: [PerfInteractionEntry] = []
        for i in 1...10 {
            entries.append(PerfInteractionEntry(id: "e\(i)", interactionID: Double(i), name: "click",
                                                 startTime: Double(i * 100), processingStart: nil,
                                                 processingEnd: nil, duration: Double(i * 20), nodeID: 0))
        }
        // Durations 20...200 in steps of 20: p98 of 10 items is floor(10/50) = 0, so the worst (200) is taken.
        let (value, _) = OrbitPerformanceLogic.inpFromInteractions(entries)
        XCTAssertEqual(value, 200)
    }

    func test_inp_p98_100Interactions() {
        // 100 interactions: floor(100/50) = 2, take index 97 from sorted ascending = 3rd from worst
        var entries: [PerfInteractionEntry] = []
        for i in 1...100 {
            entries.append(PerfInteractionEntry(id: "e\(i)", interactionID: Double(i), name: "click",
                                                 startTime: Double(i), processingStart: nil,
                                                 processingEnd: nil, duration: Double(i), nodeID: 0))
        }
        // Sorted ascending: 1..100. Skip 2 from top (100, 99). Take 98.
        let (value, _) = OrbitPerformanceLogic.inpFromInteractions(entries)
        XCTAssertEqual(value, 98)
    }


    func test_tbt_noFCP() {
        let tasks = [PerfLongTask(id: "t1", startTime: 100, duration: 200, attribution: nil)]
        XCTAssertEqual(OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: nil, loadEnd: nil), 0)
    }

    func test_tbt_taskBeforeFCP_notCounted() {
        let tasks = [PerfLongTask(id: "t1", startTime: 50, duration: 200, attribution: nil)]
        let result = OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: 100, loadEnd: nil)
        XCTAssertEqual(result, 0, "Task starts before FCP, should not contribute")
    }

    func test_tbt_shortTask_notCounted() {
        let tasks = [PerfLongTask(id: "t1", startTime: 200, duration: 50, attribution: nil)]
        let result = OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: 100, loadEnd: nil)
        XCTAssertEqual(result, 0)
    }

    func test_tbt_longTask_counted() {
        let tasks = [PerfLongTask(id: "t1", startTime: 200, duration: 150, attribution: nil)]
        let result = OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: 100, loadEnd: nil)
        XCTAssertEqual(result, 100)
    }

    func test_tbt_taskAfterLoadEnd_notCounted() {
        let tasks = [PerfLongTask(id: "t1", startTime: 500, duration: 200, attribution: nil)]
        // Task ends at 700, loadEnd is 600 → excluded
        let result = OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: 100, loadEnd: 600)
        XCTAssertEqual(result, 0, "Task ends after loadEnd, should not contribute")
    }

    func test_tbt_multipleTasks() {
        let tasks = [
            PerfLongTask(id: "t1", startTime: 200, duration: 100, attribution: nil),  // +50
            PerfLongTask(id: "t2", startTime: 400, duration: 200, attribution: nil),  // +150
            PerfLongTask(id: "t3", startTime: 50,  duration: 300, attribution: nil),  // before FCP, skip
        ]
        let result = OrbitPerformanceLogic.tbt(longTasks: tasks, fcp: 100, loadEnd: nil)
        XCTAssertEqual(result, 200)
    }


    func test_classifyFrame_smooth() {
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(16.7), .smooth)
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(0), .smooth)
    }

    func test_classifyFrame_slightDrop() {
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(16.8), .slightDrop)
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(33.4), .slightDrop)
    }

    func test_classifyFrame_moderateDrop() {
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(33.5), .moderateDrop)
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(50), .moderateDrop)
    }

    func test_classifyFrame_severeDrop() {
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(50.1), .severeDrop)
        XCTAssertEqual(OrbitPerformanceLogic.classifyFrame(200), .severeDrop)
    }


    func test_visibleRange_noZoom() {
        let range = OrbitPerformanceLogic.visibleRange(zoom: 1, offset: 0, duration: 5000)
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 5000)
    }

    func test_visibleRange_2xZoom() {
        let range = OrbitPerformanceLogic.visibleRange(zoom: 2, offset: 0, duration: 5000)
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 2500)
    }

    func test_visibleRange_clampedOffset() {
        // With 2x zoom, offset 4000 would put the right edge past the end — clamp it
        let range = OrbitPerformanceLogic.visibleRange(zoom: 2, offset: 4000, duration: 5000)
        XCTAssertEqual(range.lowerBound, 2500, accuracy: 0.01)
        XCTAssertEqual(range.upperBound, 5000, accuracy: 0.01)
    }

    func test_xAtTime_leftEdge() {
        let range = 0.0...5000.0
        XCTAssertEqual(OrbitPerformanceLogic.xAtTime(0, in: range, width: 1000), 0)
    }

    func test_xAtTime_rightEdge() {
        let range = 0.0...5000.0
        XCTAssertEqual(OrbitPerformanceLogic.xAtTime(5000, in: range, width: 1000), 1000)
    }

    func test_xAtTime_midpoint() {
        let range = 0.0...5000.0
        XCTAssertEqual(OrbitPerformanceLogic.xAtTime(2500, in: range, width: 1000), 500)
    }

    func test_timeAtX_roundTrip() {
        let range = 100.0...3000.0
        let time = 1500.0
        let x = OrbitPerformanceLogic.xAtTime(time, in: range, width: 800)
        let recovered = OrbitPerformanceLogic.timeAtX(x, in: range, width: 800)
        XCTAssertEqual(recovered, time, accuracy: 0.001)
    }


    func test_navigationPhases_ttfb() {
        let nav = PerfNavigationEntry(
            startTime: 0, duration: 2000,
            redirectStart: nil, redirectEnd: nil,
            fetchStart: 10,
            domainLookupStart: 20, domainLookupEnd: 80,
            connectStart: 80, connectEnd: 200,
            secureConnectionStart: 100,
            requestStart: 200, responseStart: 600, responseEnd: 800,
            domContentLoadedEventStart: 1200, domContentLoadedEventEnd: 1210,
            loadEventStart: 1800, loadEventEnd: 1820,
            transferSize: nil, decodedBodySize: nil, domInteractive: nil
        )
        let phases = OrbitPerformanceLogic.navigationPhases(from: nav)
        XCTAssertEqual(phases.ttfb ?? .nan, 590, accuracy: 0.01)
        XCTAssertEqual(phases.dnsDuration ?? .nan, 60, accuracy: 0.01)
        XCTAssertEqual(phases.tcpDuration ?? .nan, 120, accuracy: 0.01)
        XCTAssertEqual(phases.tlsDuration ?? .nan, 100, accuracy: 0.01)
    }

    func test_navigationPhases_noTLS_whenSecureConnectionStartIsZero() {
        let nav = PerfNavigationEntry(
            startTime: 0, duration: 1000,
            redirectStart: nil, redirectEnd: nil, fetchStart: 0,
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: 10, connectEnd: 100,
            secureConnectionStart: 0,  // HTTP, not HTTPS
            requestStart: nil, responseStart: nil, responseEnd: nil,
            domContentLoadedEventStart: nil, domContentLoadedEventEnd: nil,
            loadEventStart: nil, loadEventEnd: nil,
            transferSize: nil, decodedBodySize: nil, domInteractive: nil
        )
        let phases = OrbitPerformanceLogic.navigationPhases(from: nav)
        XCTAssertNil(phases.tlsDuration, "secureConnectionStart=0 means HTTP; no TLS")
    }


    func test_lcpPhases_ttfb() {
        let lcp = PerfLCPEntry(startTime: 2000, renderTime: 2100, loadTime: 1900,
                                size: 50000, url: "https://example.com/hero.jpg",
                                elementID: "", nodeID: 1, selector: "img", isLazy: false)
        let nav = PerfNavigationPhases(
            ttfb: 400,
            fetchStart: 0, responseStart: 400, responseEnd: 800,
            loadEventEnd: 3000
        )
        let phases = OrbitPerformanceLogic.lcpPhases(entry: lcp, nav: nav)
        XCTAssertEqual(phases.ttfb ?? .nan, 400, accuracy: 0.01)
    }


    func test_insights_lazyLCP() {
        var rec = PerfRecording()
        rec.lcpEntries = [PerfLCPEntry(startTime: 3000, renderTime: 3000, loadTime: nil,
                                        size: 50000, url: "https://example.com/hero.jpg",
                                        elementID: "", nodeID: 1, selector: "img.hero", isLazy: true)]
        let vitals = OrbitPerformanceLogic.vitals(from: rec)
        let insights = OrbitPerformanceLogic.insights(recording: rec, vitals: vitals)
        XCTAssertTrue(insights.contains { $0.id == "lcp-lazy" },
                      "Should generate an insight for a lazy-loaded LCP image")
    }

    func test_insights_blockingScripts() {
        var rec = PerfRecording()
        rec.domScan = PerfDOMScan(blockingScriptURLs: [
            "https://cdn.example.com/analytics.js",
            "https://cdn.example.com/chat.js"
        ], nodeCount: 800)
        let vitals = OrbitPerformanceLogic.vitals(from: rec)
        let insights = OrbitPerformanceLogic.insights(recording: rec, vitals: vitals)
        XCTAssertTrue(insights.contains { $0.id == "blocking-scripts" })
    }

    func test_insights_largeDom() {
        var rec = PerfRecording()
        rec.domScan = PerfDOMScan(blockingScriptURLs: [], nodeCount: 2000)
        let vitals = OrbitPerformanceLogic.vitals(from: rec)
        let insights = OrbitPerformanceLogic.insights(recording: rec, vitals: vitals)
        XCTAssertTrue(insights.contains { $0.id == "large-dom" })
    }

    func test_insights_slowTTFB() {
        let nav = PerfNavigationEntry(startTime: 0, duration: 2000,
                                       redirectStart: nil, redirectEnd: nil,
                                       fetchStart: 0,
                                       domainLookupStart: nil, domainLookupEnd: nil,
                                       connectStart: nil, connectEnd: nil,
                                       secureConnectionStart: nil,
                                       requestStart: nil, responseStart: 1200, responseEnd: 1400,
                                       domContentLoadedEventStart: nil, domContentLoadedEventEnd: nil,
                                       loadEventStart: nil, loadEventEnd: 2000,
                                       transferSize: nil, decodedBodySize: nil, domInteractive: nil)
        var rec = PerfRecording()
        rec.navigationEntry = nav
        let vitals = OrbitPerformanceLogic.vitals(from: rec)
        let insights = OrbitPerformanceLogic.insights(recording: rec, vitals: vitals)
        XCTAssertTrue(insights.contains { $0.id == "ttfb-slow" },
                      "TTFB of 1200ms should generate a slow-TTFB insight")
    }


    func test_parse_paint() {
        let obj: [String: Any] = ["et": "paint", "name": "first-contentful-paint", "ts": 1234.5]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .paint(let entry) = result else { return XCTFail("Expected paint") }
        XCTAssertEqual(entry.name, "first-contentful-paint")
        XCTAssertEqual(entry.startTime, 1234.5, accuracy: 0.001)
    }

    func test_parse_lcp() {
        let obj: [String: Any] = [
            "et": "lcp", "ts": 2500.0, "rt": 2600.0, "lt": 2400.0, "size": 50000.0,
            "url": "https://example.com/hero.jpg", "eid": "hero", "nid": 42,
            "sel": "img#hero", "lazy": false
        ]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .lcp(let entry) = result else { return XCTFail("Expected lcp") }
        XCTAssertEqual(entry.startTime, 2500)
        XCTAssertEqual(entry.renderTime, 2600)
        XCTAssertEqual(entry.nodeID, 42)
        XCTAssertFalse(entry.isLazy)
    }

    func test_parse_layoutShift() {
        let obj: [String: Any] = [
            "et": "layout-shift", "ts": 500.0, "val": 0.08, "had": false,
            "sources": [[
                "nid": 7, "tag": "img", "sel": "img.banner",
                "pr": ["x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0],
                "cr": ["x": 0.0, "y": 50.0, "w": 300.0, "h": 100.0]
            ] as [String: Any]]
        ]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .layoutShift(let entry) = result else { return XCTFail("Expected layoutShift") }
        XCTAssertEqual(entry.value, 0.08, accuracy: 1e-9)
        XCTAssertFalse(entry.hadRecentInput)
        XCTAssertEqual(entry.sources.count, 1)
        XCTAssertEqual(entry.sources[0].nodeID, 7)
        XCTAssertEqual(entry.sources[0].nodeTag, "img")
        XCTAssertEqual(entry.sources[0].previousRect?.y, 0)
        XCTAssertEqual(entry.sources[0].currentRect?.y, 50)
    }

    func test_parse_longtask() {
        let obj: [String: Any] = [
            "et": "longtask", "ts": 300.0, "dur": 120.0,
            "attr": ["url": "https://cdn.example.com/script.js", "ct": "iframe", "cn": "ad-frame", "ci": "frame1"]
        ]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .longTask(let entry) = result else { return XCTFail("Expected longTask") }
        XCTAssertEqual(entry.duration, 120)
        XCTAssertEqual(entry.attribution?.containerType, "iframe")
    }

    func test_parse_event_interaction() {
        let obj: [String: Any] = [
            "et": "event", "name": "click", "ts": 1000.0, "ps": 1005.0, "pe": 1020.0,
            "dur": 60.0, "iid": 101.0, "nid": 99
        ]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .interaction(let entry) = result else { return XCTFail("Expected interaction") }
        XCTAssertEqual(entry.interactionID, 101)
        XCTAssertEqual(entry.duration, 60)
        XCTAssertEqual(entry.nodeID, 99)
        XCTAssertEqual(entry.inputDelay ?? .nan, 5, accuracy: 0.001)
        XCTAssertEqual(entry.processingDuration ?? .nan, 15, accuracy: 0.001)
        XCTAssertEqual(entry.presentationDelay ?? .nan, 40, accuracy: 0.001)
    }

    func test_parse_navigation() {
        let obj: [String: Any] = [
            "et": "navigation", "ts": 0.0, "dur": 1500.0,
            "fs": 5.0, "ds": 10.0, "de": 50.0,
            "cs": 50.0, "ce": 150.0, "scs": 80.0,
            "rqs": 150.0, "rss": 500.0, "rse": 600.0,
            "dcls": 1000.0, "dcle": 1010.0,
            "les": 1400.0, "lee": 1500.0
        ]
        let result = OrbitPerformanceLogic.parseEntry(from: obj)
        guard case .navigation(let entry) = result else { return XCTFail("Expected navigation") }
        XCTAssertEqual(entry.fetchStart, 5)
        XCTAssertEqual(entry.responseStart, 500)
        XCTAssertEqual(entry.loadEventEnd, 1500)
    }


    func test_recording_jsonRoundTrip() throws {
        var rec = PerfRecording(id: "test-id", url: "https://example.com", title: "Example",
                                 startWallTime: 1000, duration: 5000)
        rec.paintEntries = [PerfPaintEntry(name: "first-contentful-paint", startTime: 1234)]
        rec.longTaskEntries = [PerfLongTask(id: "lt-1", startTime: 500, duration: 100, attribution: nil)]
        rec.frameSamples = [PerfFrameSample(id: "frm-1", timestamp: 100, duration: 16)]

        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(PerfRecording.self, from: data)

        XCTAssertEqual(decoded.id, rec.id)
        XCTAssertEqual(decoded.url, rec.url)
        XCTAssertEqual(decoded.duration, rec.duration)
        XCTAssertEqual(decoded.paintEntries.count, 1)
        XCTAssertEqual(decoded.paintEntries[0].name, "first-contentful-paint")
        XCTAssertEqual(decoded.longTaskEntries.count, 1)
        XCTAssertEqual(decoded.longTaskEntries[0].duration, 100)
        XCTAssertEqual(decoded.frameSamples.count, 1)
        XCTAssertEqual(decoded.frameSamples[0].timestamp, 100)
    }

    func test_recording_emptyRoundTrip() throws {
        let rec = PerfRecording()
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(PerfRecording.self, from: data)
        XCTAssertEqual(decoded.paintEntries.count, 0)
        XCTAssertEqual(decoded.clsEntriesEmpty, true)
    }


    func test_resourceSummary_groupsByType() {
        let entries: [PerfResourceEntry] = [
            PerfResourceEntry(id: "r1", url: "a.js", startTime: 0, duration: 100, transferSize: 1000, decodedBodySize: 2000, initiatorType: "script", nextHopProtocol: ""),
            PerfResourceEntry(id: "r2", url: "b.js", startTime: 10, duration: 50, transferSize: 500, decodedBodySize: 900, initiatorType: "script", nextHopProtocol: ""),
            PerfResourceEntry(id: "r3", url: "c.jpg", startTime: 20, duration: 80, transferSize: 20000, decodedBodySize: 50000, initiatorType: "img", nextHopProtocol: ""),
        ]
        let summary = OrbitPerformanceLogic.resourceSummary(entries: entries)
        let script = summary.first { $0.type == "Script" }
        let image = summary.first { $0.type.lowercased().contains("image") || $0.type == "Img" }
        XCTAssertNotNil(script)
        XCTAssertEqual(script?.count, 2)
        XCTAssertEqual(script?.transferBytes, 1500)
    }
}

// Helper to avoid using member access on arrays in assertions
private extension PerfRecording {
    var clsEntriesEmpty: Bool { layoutShiftEntries.isEmpty }
}

// Helper for PerfNavigationPhases partial init
private extension PerfNavigationPhases {
    init(ttfb: Double? = nil, fetchStart: Double? = nil,
         responseStart: Double? = nil, responseEnd: Double? = nil,
         loadEventEnd: Double? = nil) {
        self.init(redirectDuration: nil, dnsDuration: nil, tcpDuration: nil, tlsDuration: nil,
                  requestDuration: nil, responseDuration: nil, domProcessingDuration: nil,
                  loadEventDuration: nil, ttfb: ttfb,
                  fetchStart: fetchStart, responseStart: responseStart, responseEnd: responseEnd,
                  domInteractive: nil, domContentLoadedEventEnd: nil, loadEventEnd: loadEventEnd,
                  totalDuration: nil)
    }
}
