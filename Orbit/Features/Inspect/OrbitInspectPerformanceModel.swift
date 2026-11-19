import AppKit
import Foundation
import WebKit

enum PerfRecordingState: Equatable {
    case idle
    case recording
    case reloadAndRecord
}

@MainActor
@Observable
final class OrbitPerformanceModel: OrbitInspectModule {

    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> { ["perf.batch"] }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard frame.isMain, type == "perf.batch" else { return }
        let entries = OrbitInspectDecode.objects(object, "entries")
        for raw in entries {
            guard let parsed = OrbitPerformanceLogic.parseEntry(from: raw) else { continue }
            accumulate(parsed, into: &liveData)
            if recordingState != .idle {
                accumulate(parsed, into: &activeRecording)
            }
        }
        // Auto-stop for "reload and record": wait for the navigation entry with loadEventEnd
        if recordingState == .reloadAndRecord, liveData.navigationEntry?.loadEventEnd != nil {
            if autoStopTask == nil {
                autoStopTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 s quiet time
                    self?.finishRecordingSync()
                    self?.autoStopTask = nil
                }
            }
        }
    }

    func pageDidReset(preservingLog: Bool) {
        if recordingState != .idle { stopRecording() }
        live.resetPage()
        liveData = PerfRecording()
        liveData.url = session?.pageURL ?? ""
        liveData.title = session?.pageTitle ?? ""
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    func panelDidAppear(force: Bool) {
        if force || !didAppear {
            didAppear = true
            session?.command(["op": "perf.snapshot"])
        }
    }


    private(set) var liveData: PerfRecording = PerfRecording()


    private(set) var recordings: [PerfRecording] = []
    var selectedRecordingIndex: Int = 0

    var selectedRecording: PerfRecording? {
        recordings.indices.contains(selectedRecordingIndex) ? recordings[selectedRecordingIndex] : nil
    }

    var displayRecording: PerfRecording { selectedRecording ?? liveData }


    private(set) var recordingState: PerfRecordingState = .idle
    private var activeRecording: PerfRecording = PerfRecording()
    @ObservationIgnored private var recordingStartWall: Double = 0
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored private var didAppear: Bool = false


    @ObservationIgnored private var processBaseline = OrbitProcessMonitor.Baseline.none
    @ObservationIgnored private var processSamplingTask: Task<Void, Never>?
    private(set) var canResolveWebProcess: Bool = true


    @ObservationIgnored private var filmstripTask: Task<Void, Never>?


    var timelineZoom: Double = 1.0
    var timelineOffset: Double = 0.0
    var timelineSelection: ClosedRange<Double>? = nil


    enum PerfTab: String, CaseIterable, Identifiable {
        case live, summary, timeline
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    var activeTab: PerfTab = .live

    @ObservationIgnored let live = OrbitPerformanceLiveModel()


    var vitals: OrbitVitals {
        OrbitPerformanceLogic.vitals(from: displayRecording)
    }

    func collectVitalsNow() async -> OrbitVitals {
        session?.command(["op": "perf.snapshot"])
        try? await Task.sleep(nanoseconds: 150_000_000)
        return vitals
    }


    func startRecording() {
        guard recordingState == .idle else { return }
        activeRecording = PerfRecording(
            url: session?.pageURL ?? "",
            title: session?.pageTitle ?? "",
            startWallTime: Date().timeIntervalSince1970
        )
        recordingStartWall = Date().timeIntervalSince1970
        recordingState = .recording
        session?.command(["op": "perf.startSampling"])
        startProcessSampling()
    }

    func stopRecording() {
        guard recordingState != .idle else { return }
        session?.command(["op": "perf.stopSampling"])
        session?.command(["op": "perf.snapshot"])
        // Brief pause: flush the batch that perf.snapshot triggers
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.finishRecordingSync()
        }
    }

    func reloadAndRecord() {
        guard recordingState == .idle else { return }
        activeRecording = PerfRecording(
            url: session?.pageURL ?? "",
            title: session?.pageTitle ?? "",
            startWallTime: Date().timeIntervalSince1970
        )
        recordingStartWall = Date().timeIntervalSince1970
        recordingState = .reloadAndRecord
        session?.command(["op": "perf.startSampling"])
        startProcessSampling()
        startFilmstrip()
        session?.reloadPage(ignoringCache: false)
    }

    private func finishRecordingSync() {
        guard recordingState != .idle else { return }
        autoStopTask?.cancel(); autoStopTask = nil
        stopProcessSampling(); stopFilmstrip()

        let elapsed = (Date().timeIntervalSince1970 - recordingStartWall) * 1000
        activeRecording.duration = max(100, elapsed)
        if let net = session?.network {
            activeRecording.networkRecords = net.records.map { r in
                PerfNetworkRecord(id: r.id, url: r.url, resourceType: r.resourceType,
                                   startTime: r.startTime, duration: r.duration,
                                   transferSize: r.transferSize, status: r.status, failed: r.failed)
            }
        }
        recordings.insert(activeRecording, at: 0)
        if recordings.count > 5 { recordings = Array(recordings.prefix(5)) }
        selectedRecordingIndex = 0
        activeRecording = PerfRecording()
        recordingState = .idle
        resetTimeline()
    }

    func deleteRecording(id: String) {
        recordings.removeAll { $0.id == id }
        if selectedRecordingIndex >= recordings.count {
            selectedRecordingIndex = max(0, recordings.count - 1)
        }
    }

    func selectRecording(_ recording: PerfRecording) {
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            selectedRecordingIndex = idx
            resetTimeline()
        }
    }

    func exportCurrentRecording() -> Data? {
        try? JSONEncoder().encode(selectedRecording ?? liveData)
    }

    func importRecording(from data: Data) -> Bool {
        guard let rec = try? JSONDecoder().decode(PerfRecording.self, from: data) else { return false }
        recordings.insert(rec, at: 0)
        if recordings.count > 5 { recordings = Array(recordings.prefix(5)) }
        selectedRecordingIndex = 0
        resetTimeline()
        return true
    }


    private func resetTimeline() {
        timelineZoom = 1.0; timelineOffset = 0.0; timelineSelection = nil
    }

    func applyTimelineScroll(deltaX: Double, deltaY: Double) {
        let dur = displayRecording.duration
        guard dur > 0 else { return }
        let visible = dur / max(1, timelineZoom)
        let panDelta = deltaX * (visible / 300)
        let range = OrbitPerformanceLogic.visibleRange(
            zoom: timelineZoom, offset: timelineOffset + panDelta, duration: dur)
        timelineOffset = range.lowerBound
        if abs(deltaY) > 0.5 {
            applyTimelineZoom(factor: deltaY > 0 ? 1.1 : (1.0 / 1.1))
        }
    }

    func applyTimelineZoom(factor: Double) {
        let dur = displayRecording.duration
        guard dur > 0 else { return }
        let newZoom = min(200, max(1, timelineZoom * factor))
        let visible = dur / max(1, timelineZoom)
        let center = timelineOffset + visible / 2
        timelineZoom = newZoom
        let newVisible = dur / newZoom
        let range = OrbitPerformanceLogic.visibleRange(
            zoom: newZoom, offset: center - newVisible / 2, duration: dur)
        timelineOffset = range.lowerBound
    }

    private func startProcessSampling() {
        stopProcessSampling()
        processBaseline = .none
        processSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                self?.takeSample()
            }
        }
    }

    private func stopProcessSampling() {
        processSamplingTask?.cancel()
        processSamplingTask = nil
    }

    // Runs on MainActor. OrbitProcessMonitor calls are fast Darwin syscalls (microseconds).
    private func takeSample() {
        guard let webView = session?.contents?.webView else { return }
        let attribution = WebKitProcessAttribution.gather(from: [webView])
        let sample = OrbitProcessMonitor.sample(against: processBaseline, attribution: attribution)
        processBaseline = sample.baseline

        let webPID: pid_t? = attribution.processIdentifiers.first { attribution.roles[$0] == .webContent }
        canResolveWebProcess = webPID != nil

        guard let pid = webPID, recordingState != .idle else { return }
        let info = sample.processes.first { $0.processID == pid }
        let ts = (Date().timeIntervalSince1970 - recordingStartWall) * 1000
        let native = PerfNativeSample(
            id: "ns-\(Int(ts))",
            timestamp: ts,
            memoryBytes: info?.memoryFootprintBytes ?? 0,
            cpuPercent: info?.cpuPercent ?? 0,
            processID: Int32(pid),
            resolved: info != nil
        )
        activeRecording.nativeSamples.append(native)
        if activeRecording.nativeSamples.count > 5000 {
            activeRecording.nativeSamples.removeFirst()
        }
    }


    private func startFilmstrip() {
        stopFilmstrip()
        filmstripTask = Task { [weak self] in
            var seq = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { break }
                await self?.captureFilmstripFrame(seq: seq)
                seq += 1
            }
        }
    }

    private func stopFilmstrip() {
        filmstripTask?.cancel(); filmstripTask = nil
    }

    private func captureFilmstripFrame(seq: Int) async {
        guard let contents = session?.contents else { return }
        let ts = (Date().timeIntervalSince1970 - recordingStartWall) * 1000
        let size = CGSize(width: 160, height: 100)
        let image = await contents.capturePreview(rect: nil, size: size)
        guard let image else { return }
        let data: Data? = image.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .png, properties: [:]) }
        let frame = PerfFilmstripFrame(id: "fs-\(seq)", timestamp: ts, imageData: data)
        guard recordingState != .idle else { return }
        activeRecording.filmstripFrames.append(frame)
        if activeRecording.filmstripFrames.count > 120 {
            activeRecording.filmstripFrames.removeFirst()
        }
    }


    private func accumulate(_ entry: PerfParsedEntry, into recording: inout PerfRecording) {
        switch entry {
        case .paint(let e):
            // Deduplicate: only keep one entry per paint name (last wins for FCP)
            recording.paintEntries.removeAll { $0.name == e.name }
            recording.paintEntries.append(e)
        case .lcp(let e):
            recording.lcpEntries.append(e)
            cap(&recording.lcpEntries, to: 50) // last one wins per spec; cap history
        case .layoutShift(let e):
            recording.layoutShiftEntries.append(e)
            cap(&recording.layoutShiftEntries, to: 500)
        case .longTask(let e):
            recording.longTaskEntries.append(e)
            cap(&recording.longTaskEntries, to: 2000)
        case .interaction(let e):
            recording.interactionEntries.append(e)
            cap(&recording.interactionEntries, to: 2000)
        case .firstInput(let e):
            if recording.firstInputEntry == nil { recording.firstInputEntry = e }
        case .navigation(let e):
            recording.navigationEntry = e
        case .resource(let e):
            recording.resourceEntries.append(e)
            cap(&recording.resourceEntries, to: 5000)
        case .mark(let e):
            recording.markEntries.append(e)
            cap(&recording.markEntries, to: 1000)
        case .measure(let e):
            recording.measureEntries.append(e)
            cap(&recording.measureEntries, to: 1000)
        case .element(let e):
            recording.elementTimingEntries.append(e)
            cap(&recording.elementTimingEntries, to: 500)
        case .frame(let e):
            recording.frameSamples.append(e)
            cap(&recording.frameSamples, to: 10000)
        case .drift(let e):
            recording.driftSamples.append(e)
            cap(&recording.driftSamples, to: 5000)
        case .domScan(let e):
            recording.domScan = e
        case .softNav, .bfcacheRestore:
            break
        }
    }

    private func cap<T>(_ array: inout [T], to limit: Int) {
        if array.count > limit { array.removeFirst(array.count - limit) }
    }
}
