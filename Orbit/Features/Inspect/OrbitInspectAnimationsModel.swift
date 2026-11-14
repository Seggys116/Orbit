import Foundation

enum AnimTab: String, CaseIterable, Hashable {
    case timeline, events
    var title: String { rawValue.capitalized }
}

@MainActor
@Observable
final class OrbitAnimationsModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    // MARK: - Published State

    var records: [AnimRecord] = []

    var events: [AnimEvent] = []

    var selectedID: String? = nil

    var activeTab: AnimTab = .timeline

    var globalPaused = false

    var globalPlaybackRate: Double = 1.0

    var scrubTime: Double? = nil

    /// Cached derived arrays – updated by updateDerived() after every mutation.
    var groups: [AnimRowGroup] = []
    var totalDuration: Double = 1000.0

    /// Cross-tool contract: non-composited-property animations for Lighthouse.
    var nonCompositedAnimations: [AnimNonCompositedRecord] = []


    var selectedRecord: AnimRecord? {
        guard let id = selectedID else { return nil }
        return records.first { $0.id == id }
    }

    var liveRecords: [AnimRecord] {
        records.filter { !$0.isGone }
    }


    var messageTypes: Set<String> { ["anim.batch"] }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard type == "anim.batch" else { return }
        applyBatch(object)
    }

    func pageDidReset(preservingLog: Bool) {
        records = []
        events = []
        selectedID = nil
        scrubTime = nil
        globalPaused = false
        updateDerived()
    }

    func panelDidAppear(force: Bool) {
        if force {
            records = []
            events = []
            selectedID = nil
            scrubTime = nil
            updateDerived()
        }
        session?.command(["op": "anim.start"])
    }


    private func applyBatch(_ obj: [String: Any]) {
        let shouldClear = OrbitInspectDecode.bool(obj, "clear")
        if shouldClear {
            records = []
            if selectedID != nil {
                let id = selectedID
                selectedID = nil
                let adds = OrbitInspectDecode.objects(obj, "add")
                if adds.contains(where: { OrbitInspectDecode.string($0, "id") == id }) {
                    selectedID = id
                }
            }
        }

        for addObj in OrbitInspectDecode.objects(obj, "add") {
            guard let record = decodeRecord(addObj) else { continue }
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx] = record
            } else {
                records.append(record)
            }
        }

        for updateObj in OrbitInspectDecode.objects(obj, "update") {
            let id = OrbitInspectDecode.string(updateObj, "id")
            guard !id.isEmpty, let idx = records.firstIndex(where: { $0.id == id }) else { continue }
            let psStr = OrbitInspectDecode.string(updateObj, "playState")
            if !psStr.isEmpty {
                records[idx].playState = AnimPlayState(rawValue: psStr) ?? records[idx].playState
            }
            if let ct = OrbitInspectDecode.number(updateObj, "currentTime") {
                records[idx].currentTime = ct
            }
            if OrbitInspectDecode.bool(updateObj, "gone") {
                records[idx].isGone = true
            }
        }

        for evObj in OrbitInspectDecode.objects(obj, "events") {
            if let event = decodeEvent(evObj) {
                OrbitAnimationsLogic.addToRingBuffer(event, buffer: &events, cap: 500)
            }
        }

        // Cap records at 500; prefer removing oldest gone entries first
        if records.count > 500 {
            var removed = 0
            records.removeAll { record in
                if removed < records.count - 500, record.isGone {
                    removed += 1
                    return true
                }
                return false
            }
            if records.count > 500 {
                records.removeFirst(records.count - 500)
            }
        }

        updateDerived()
    }

    private func decodeRecord(_ obj: [String: Any]) -> AnimRecord? {
        let id = OrbitInspectDecode.string(obj, "id")
        guard !id.isEmpty else { return nil }

        let typeStr = OrbitInspectDecode.string(obj, "type")
        let type = AnimType(rawValue: typeStr) ?? .waapi

        let iterRaw = OrbitInspectDecode.number(obj, "iterations") ?? 1.0
        let iterations: Double = iterRaw < 0 ? Double.infinity : max(0, iterRaw)

        let keyframeObjs = OrbitInspectDecode.objects(obj, "keyframes")

        return AnimRecord(
            id: id,
            type: type,
            elementID: OrbitInspectDecode.integer(obj, "nodeId"),
            elementLabel: OrbitInspectDecode.string(obj, "label"),
            selector: OrbitInspectDecode.string(obj, "selector"),
            name: OrbitInspectDecode.string(obj, "name"),
            properties: OrbitInspectDecode.strings(obj, "props"),
            playState: AnimPlayState(rawValue: OrbitInspectDecode.string(obj, "playState")) ?? .idle,
            playbackRate: OrbitInspectDecode.number(obj, "rate") ?? 1.0,
            duration: OrbitInspectDecode.number(obj, "duration") ?? 0.0,
            delay: OrbitInspectDecode.number(obj, "delay") ?? 0.0,
            endDelay: OrbitInspectDecode.number(obj, "endDelay") ?? 0.0,
            iterations: iterations,
            iterationStart: OrbitInspectDecode.number(obj, "iterationStart") ?? 0.0,
            direction: AnimDirection.from(OrbitInspectDecode.string(obj, "direction")),
            fill: AnimFill.from(OrbitInspectDecode.string(obj, "fill")),
            easing: OrbitInspectDecode.string(obj, "easing").isEmpty ? "linear" : OrbitInspectDecode.string(obj, "easing"),
            composite: OrbitInspectDecode.string(obj, "composite").isEmpty ? "replace" : OrbitInspectDecode.string(obj, "composite"),
            currentTime: OrbitInspectDecode.number(obj, "currentTime"),
            startTime: OrbitInspectDecode.number(obj, "startTime"),
            keyframes: keyframeObjs.enumerated().map { decodeKeyframe($0.element, index: $0.offset) },
            timelineKind: AnimTimelineKind(rawValue: OrbitInspectDecode.string(obj, "timelineKind")) ?? .document,
            scrollSource: OrbitInspectDecode.string(obj, "scrollSource"),
            isGone: OrbitInspectDecode.bool(obj, "gone")
        )
    }

    private func decodeKeyframe(_ obj: [String: Any], index: Int) -> AnimKeyframe {
        let props = (obj["props"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return AnimKeyframe(
            id: "kf_\(index)",
            offset: OrbitInspectDecode.number(obj, "offset"),
            computedOffset: OrbitInspectDecode.number(obj, "computedOffset") ?? 0.0,
            easing: OrbitInspectDecode.string(obj, "easing").isEmpty ? "linear" : OrbitInspectDecode.string(obj, "easing"),
            properties: props
        )
    }

    private func decodeEvent(_ obj: [String: Any]) -> AnimEvent? {
        let id = OrbitInspectDecode.string(obj, "id")
        guard !id.isEmpty else { return nil }
        return AnimEvent(
            id: id,
            timestamp: OrbitInspectDecode.number(obj, "ts") ?? 0.0,
            type: OrbitInspectDecode.string(obj, "type"),
            elementLabel: OrbitInspectDecode.string(obj, "label"),
            animationName: OrbitInspectDecode.string(obj, "name"),
            elapsedTime: OrbitInspectDecode.number(obj, "elapsed") ?? 0.0
        )
    }


    private func updateDerived() {
        groups = OrbitAnimationsLogic.groupRows(records)
        let maxEnd = records.map { r -> Double in
            let ad = OrbitAnimationsLogic.activeDuration(duration: r.duration, iterations: r.iterations)
            let adCapped = ad.isInfinite ? r.duration * 3 : ad
            return r.delay + adCapped + r.endDelay
        }.max() ?? 0
        totalDuration = max(100, maxEnd)
        nonCompositedAnimations = OrbitAnimationsLogic.nonCompositedRecords(from: records)
    }


    func pauseAll() {
        globalPaused = true
        session?.command(["op": "anim.pauseAll"])
    }

    func resumeAll() {
        globalPaused = false
        session?.command(["op": "anim.resumeAll"])
    }

    func replayAll() {
        session?.command(["op": "anim.replayAll"])
    }

    func setGlobalRate(_ rate: Double) {
        globalPlaybackRate = rate
        session?.command(["op": "anim.setRate", "rate": rate])
    }

    func clearAll() {
        records = []
        events = []
        selectedID = nil
        scrubTime = nil
        updateDerived()
        session?.command(["op": "anim.clear"])
    }


    func scrub(to timeMs: Double) {
        scrubTime = timeMs
        session?.command(["op": "anim.scrub", "time": timeMs])
    }

    func endScrub() {
        // Keep scrubTime visible for reference; user can click resume to continue
    }


    func selectAnimation(_ id: String?) {
        selectedID = id
    }

    func hoverAnimation(_ id: String) {
        if let record = records.first(where: { $0.id == id }), record.elementID > 0 {
            session?.highlight(nodeID: record.elementID)
        }
    }

    func unhoverAnimation() {
        session?.clearHighlight()
    }

    func revealAnimationInElements(_ id: String) {
        if let record = records.first(where: { $0.id == id }), record.elementID > 0 {
            session?.reveal(nodeID: record.elementID)
        }
    }


    func play(id: String) {
        session?.command(["op": "anim.playOne", "id": id])
    }

    func pause(id: String) {
        session?.command(["op": "anim.pauseOne", "id": id])
    }

    func replay(id: String) {
        session?.command(["op": "anim.replayOne", "id": id])
    }

    func finish(id: String) {
        session?.command(["op": "anim.finishOne", "id": id])
    }

    func reverse(id: String) {
        session?.command(["op": "anim.reverseOne", "id": id])
    }

    func cancel(id: String) {
        session?.command(["op": "anim.cancelOne", "id": id])
        if selectedID == id { selectedID = nil }
    }

    // MARK: - Live editing

    func updateTiming(
        id: String,
        duration: Double? = nil,
        delay: Double? = nil,
        endDelay: Double? = nil,
        iterations: Double? = nil,
        easing: String? = nil,
        direction: String? = nil,
        fill: String? = nil
    ) {
        var cmd: [String: Any] = ["op": "anim.updateTiming", "id": id]
        if let v = duration  { cmd["duration"]   = v }
        if let v = delay     { cmd["delay"]       = v }
        if let v = endDelay  { cmd["endDelay"]    = v }
        if let v = iterations {
            cmd["iterations"] = v.isInfinite ? -1.0 : v
        }
        if let v = easing    { cmd["easing"]      = v }
        if let v = direction { cmd["direction"]   = v }
        if let v = fill      { cmd["fill"]        = v }
        session?.command(cmd)
    }

    func setKeyframes(id: String, keyframes: [[String: Any]]) {
        session?.command(["op": "anim.setKeyframes", "id": id, "keyframes": keyframes])
    }


    func pauseSVGAnimations() {
        session?.command(["op": "anim.svgPause"])
    }

    func resumeSVGAnimations() {
        session?.command(["op": "anim.svgResume"])
    }

    // MARK: - collectNonCompositedAnimations (async, for Lighthouse)

    func collectNonCompositedAnimations() async -> [AnimNonCompositedRecord] {
        nonCompositedAnimations
    }
}
