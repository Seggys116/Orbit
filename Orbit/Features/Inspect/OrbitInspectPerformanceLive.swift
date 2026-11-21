import Darwin
import Foundation
import IOKit
import WebKit

nonisolated struct OrbitLiveSeries: Equatable, Sendable {
    static let capacity = 60

    private(set) var values: [Double?] = []

    var current: Double? { values.last ?? nil }
    var peak: Double { values.compactMap { $0 }.max() ?? 0 }
    var hasData: Bool { values.contains { $0 != nil } }

    mutating func append(_ value: Double?) {
        values.append(value)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    mutating func removeAll() { values.removeAll() }
}

nonisolated struct OrbitLivePageSample: Equatable, Sendable {
    var timestampMs: Double
    var frames: Double
    var maxStallMs: Double
    var longTasks: Int?
    var longTaskMs: Double
    var hidden: Bool
    var domNodes: Int?
    var heapUsed: Double?
    var heapTotal: Double?
    var heapLimit: Double?

    private static let samplerKey = "window.__orbitLiveStats"

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = (object["t"] as? NSNumber)?.doubleValue,
              let frames = (object["frames"] as? NSNumber)?.doubleValue else { return nil }
        timestampMs = timestamp
        self.frames = frames
        maxStallMs = (object["stall"] as? NSNumber)?.doubleValue ?? 0
        longTasks = (object["long"] as? NSNumber)?.intValue
        longTaskMs = (object["longMs"] as? NSNumber)?.doubleValue ?? 0
        hidden = (object["hidden"] as? Bool) ?? false
        domNodes = (object["nodes"] as? NSNumber)?.intValue
        heapUsed = (object["heapUsed"] as? NSNumber)?.doubleValue
        heapTotal = (object["heapTotal"] as? NSNumber)?.doubleValue
        heapLimit = (object["heapLimit"] as? NSNumber)?.doubleValue
    }

    static func framesPerSecond(from previous: OrbitLivePageSample?, to current: OrbitLivePageSample) -> Double? {
        guard let previous, !current.hidden, !previous.hidden else { return nil }
        let elapsed = current.timestampMs - previous.timestampMs
        guard elapsed > 0, current.frames >= previous.frames else { return nil }
        return (current.frames - previous.frames) / (elapsed / 1000)
    }

    static func script(runID: UUID, includeNodes: Bool) -> String {
        """
        (function(){
        var s=\(samplerKey), id='\(runID.uuidString)';
        if(s&&s.id!==id){s.stop();s=null;}
        if(!s){
        s=\(samplerKey)={id:id,frames:0,stall:0,long:0,longMs:0,observer:null};
        var loop=function(){s.frames++;s.frameHandle=requestAnimationFrame(loop);};
        s.frameHandle=requestAnimationFrame(loop);
        var expected=performance.now()+50;
        s.interval=setInterval(function(){var n=performance.now();var lag=n-expected;if(lag>s.stall)s.stall=lag;expected=n+50;},50);
        s.stop=function(){
        cancelAnimationFrame(s.frameHandle);
        clearInterval(s.interval);
        clearTimeout(s.expiration);
        if(s.observer)s.observer.disconnect();
        window.removeEventListener('pagehide',s.stop);
        if(\(samplerKey)===s)delete \(samplerKey);
        };
        window.addEventListener('pagehide',s.stop);
        try{
        var types=PerformanceObserver.supportedEntryTypes||[];
        if(types.indexOf('longtask')>=0){
        var observer=new PerformanceObserver(function(list){list.getEntries().forEach(function(e){s.long++;s.longMs+=e.duration;});});
        observer.observe({type:'longtask'});
        s.observer=observer;
        }
        }catch(e){}
        }
        clearTimeout(s.expiration);
        s.expiration=setTimeout(s.stop,3000);
        var out={t:performance.now(),frames:s.frames,stall:Math.max(0,s.stall),long:s.observer?s.long:null,longMs:s.longMs,hidden:document.hidden};
        s.stall=0;
        \(includeNodes ? "out.nodes=document.getElementsByTagName('*').length;" : "")
        var m=performance.memory;
        if(m&&m.usedJSHeapSize>0){out.heapUsed=m.usedJSHeapSize;out.heapTotal=m.totalJSHeapSize;out.heapLimit=m.jsHeapSizeLimit;}
        return JSON.stringify(out);
        })()
        """
    }

    static func stopScript(runID: UUID) -> String {
        "\(samplerKey)?.id === '\(runID.uuidString)' && \(samplerKey).stop();"
    }
}

nonisolated enum OrbitGPUStatistics {
    static func deviceUtilizationPercent() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let value = utilization(of: entry) { best = max(best ?? 0, value) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }

    private static func utilization(of entry: io_registry_entry_t) -> Double? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
              let value = statistics["Device Utilization %"] as? NSNumber else { return nil }
        return value.doubleValue
    }
}

@MainActor
@Observable
final class OrbitPerformanceLiveModel {

    private(set) var memory = OrbitLiveSeries()
    private(set) var cpu = OrbitLiveSeries()
    private(set) var gpuDevice = OrbitLiveSeries()
    private(set) var gpuProcessCPU = OrbitLiveSeries()
    private(set) var gpuProcessMemory = OrbitLiveSeries()
    private(set) var fps = OrbitLiveSeries()
    private(set) var domNodes = OrbitLiveSeries()
    private(set) var jsHeap = OrbitLiveSeries()
    private(set) var stall = OrbitLiveSeries()

    private(set) var webProcessID: pid_t?
    private(set) var gpuProcessID: pid_t?
    private(set) var pageReachable = true
    private(set) var longTasks: Int?
    private(set) var longTaskMs: Double = 0
    private(set) var jsHeapLimit: Double?
    private(set) var pageHidden = false

    @ObservationIgnored private var baseline = OrbitProcessMonitor.Baseline.none
    @ObservationIgnored private var previousPage: OrbitLivePageSample?
    @ObservationIgnored private var tickCount = 0

    func run(session: OrbitInspectSession) async {
        let runID = UUID()
        baseline = .none
        previousPage = nil
        tickCount = 0
        while !Task.isCancelled, session.contents?.isClosed == false {
            await tick(session: session, runID: runID)
            try? await Task.sleep(for: .seconds(1))
        }
        // An in-flight JavaScript reply can cross a stop/start; only stop the sampler this run owns.
        _ = try? await session.evaluate(OrbitLivePageSample.stopScript(runID: runID))
    }

    func resetPage() {
        previousPage = nil
        fps.removeAll()
        domNodes.removeAll()
        jsHeap.removeAll()
        stall.removeAll()
        longTasks = nil
        longTaskMs = 0
        jsHeapLimit = nil
    }

    private func tick(session: OrbitInspectSession, runID: UUID) async {
        guard let webView = session.contents?.webView else { return }
        sampleProcesses(webView: webView)
        gpuDevice.append(OrbitGPUStatistics.deviceUtilizationPercent())
        await samplePage(session: session, runID: runID)
        guard !Task.isCancelled else { return }
        tickCount += 1
    }

    private func sampleProcesses(webView: WKWebView) {
        let attribution = WebKitProcessAttribution.gather(from: [webView])
        let first = baseline.isEmpty
        let sample = OrbitProcessMonitor.sample(against: baseline, attribution: attribution)
        baseline = sample.baseline

        webProcessID = attribution.processIdentifiers.first { attribution.roles[$0] == .webContent }
        gpuProcessID = attribution.processIdentifiers.first { attribution.roles[$0] == .gpu }

        let web = webProcessID.flatMap { pid in sample.processes.first { $0.processID == pid } }
        memory.append(web.map { Double($0.memoryFootprintBytes) })
        cpu.append(web.flatMap { first ? nil : $0.cpuPercent })

        let gpu = gpuProcessID.flatMap { pid in sample.processes.first { $0.processID == pid } }
        gpuProcessMemory.append(gpu.map { Double($0.memoryFootprintBytes) })
        gpuProcessCPU.append(gpu.flatMap { first ? nil : $0.cpuPercent })
    }

    private func samplePage(session: OrbitInspectSession, runID: UUID) async {
        let script = OrbitLivePageSample.script(runID: runID, includeNodes: tickCount % 3 == 0)
        let raw = try? await session.evaluate(script) as? String
        guard !Task.isCancelled else { return }
        guard let raw, let page = OrbitLivePageSample(json: raw) else {
            pageReachable = false
            fps.append(nil)
            stall.append(nil)
            previousPage = nil
            return
        }
        pageReachable = true
        pageHidden = page.hidden
        fps.append(OrbitLivePageSample.framesPerSecond(from: previousPage, to: page))
        previousPage = page
        stall.append(page.hidden ? nil : page.maxStallMs)
        domNodes.append(page.domNodes.map(Double.init) ?? domNodes.current)
        jsHeap.append(page.heapUsed)
        jsHeapLimit = page.heapLimit
        longTasks = page.longTasks
        longTaskMs = page.longTaskMs
    }
}
