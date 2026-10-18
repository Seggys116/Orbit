import Darwin
import Foundation

// MARK: - A sampled process

nonisolated struct OrbitProcessInfo: Identifiable, Equatable, Sendable {

    // WebKit's services (WebContent, Networking, GPU) are launched by launchd, not as children of
    // Orbit, so their roles come from WebKitProcessAttribution; the name is the fallback for children.
    enum Role: String, Sendable, CaseIterable {
        case browser
        case webContent
        case extensionProcess
        case networking
        case gpu
        case helper
        case other

        var displayName: String {
            switch self {
            case .browser: return "Orbit"
            case .webContent: return "Web Page"
            case .extensionProcess: return "Extension"
            case .networking: return "Network Service"
            case .gpu: return "GPU Process"
            case .helper: return "Utility"
            case .other: return "Subprocess"
            }
        }

        // Substring, case-insensitive: Apple's service names are reverse-DNS
        // (com.apple.WebKit.WebContent) and variants append a suffix.
        static func forExecutableName(_ name: String, isBrowserProcess: Bool) -> Role {
            if isBrowserProcess { return .browser }
            let lowered = name.lowercased()
            if lowered.contains("webkit.webcontent") { return .webContent }
            if lowered.contains("webkit.networking") { return .networking }
            if lowered.contains("webkit.gpu") { return .gpu }
            if lowered.contains("helper") { return .helper }
            return .other
        }
    }

    var id: pid_t { processID }

    var processID: pid_t
    var executableName: String
    var role: Role
    // ri_phys_footprint — what Activity Monitor calls "Memory".
    var memoryFootprintBytes: UInt64
    // Absolute lifetime CPU time, user + system; only meaningful as a delta between two samples.
    var cpuTimeNanoseconds: UInt64
    var cpuPercent: Double
    // Titles of the open tabs a WebContent process is rendering; empty for every other role.
    var tabTitles: [String] = []
    // Names of the extensions whose pages this process hosts; empty for every other role.
    var extensionNames: [String] = []

    var isBrowserProcess: Bool { role == .browser }
}

// MARK: - The monitor

nonisolated struct OrbitProcessMonitor {

    struct Baseline: Equatable, Sendable {
        var wallClockNanoseconds: UInt64
        var cpuTimeByProcessID: [pid_t: UInt64]

        static let none = Baseline(wallClockNanoseconds: 0, cpuTimeByProcessID: [:])

        var isEmpty: Bool { wallClockNanoseconds == 0 }
    }

    struct Sample: Equatable, Sendable {
        var processes: [OrbitProcessInfo]
        var baseline: Baseline
    }

    static func sample(
        against baseline: Baseline = .none,
        attribution: WebKitProcessAttribution = .none
    ) -> Sample {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = baseline.isEmpty ? 0 : now &- baseline.wallClockNanoseconds
        let identifiers = processIdentifiers(attribution: attribution)

        var rows: [OrbitProcessInfo] = []
        var cpuTimes: [pid_t: UInt64] = [:]
        rows.reserveCapacity(identifiers.count)
        cpuTimes.reserveCapacity(identifiers.count)
        // One path buffer for the whole sample. proc_pidpath null-terminates, so the next pid
        // overwrites the previous path instead of allocating another 4KB buffer.
        var pathBuffer = [CChar](repeating: 0, count: pathBufferCount)

        for pid in identifiers {
            guard let usage = resourceUsage(of: pid) else { continue }
            let cpuTime = usage.userTimeNanoseconds &+ usage.systemTimeNanoseconds
            cpuTimes[pid] = cpuTime

            let isBrowser = pid == getpid()
            let name = executableName(of: pid, pathBuffer: &pathBuffer)
                ?? (isBrowser ? ProcessInfo.processInfo.processName : "Process \(pid)")

            rows.append(
                OrbitProcessInfo(
                    processID: pid,
                    executableName: name,
                    role: attribution.roles[pid]
                        ?? OrbitProcessInfo.Role.forExecutableName(name, isBrowserProcess: isBrowser),
                    memoryFootprintBytes: usage.physicalFootprintBytes,
                    cpuTimeNanoseconds: cpuTime,
                    cpuPercent: cpuPercent(
                        previousCPUTime: baseline.cpuTimeByProcessID[pid],
                        currentCPUTime: cpuTime,
                        elapsedNanoseconds: elapsed
                    ),
                    tabTitles: attribution.tabTitles[pid] ?? [],
                    extensionNames: attribution.extensionNames[pid] ?? []
                )
            )
        }

        return Sample(
            processes: sorted(rows),
            baseline: Baseline(wallClockNanoseconds: now, cpuTimeByProcessID: cpuTimes)
        )
    }

    // 0 (never a lifetime average) with no previous reading, no elapsed time, or a backwards
    // counter (a recycled pid between samples). Not clamped to 100: a multi-threaded renderer can exceed one core.
    static func cpuPercent(
        previousCPUTime: UInt64?,
        currentCPUTime: UInt64,
        elapsedNanoseconds: UInt64
    ) -> Double {
        guard let previousCPUTime, elapsedNanoseconds > 0, currentCPUTime >= previousCPUTime else { return 0 }
        return Double(currentCPUTime - previousCPUTime) / Double(elapsedNanoseconds) * 100
    }

    static func sorted(_ processes: [OrbitProcessInfo]) -> [OrbitProcessInfo] {
        processes.sorted { lhs, rhs in
            if lhs.isBrowserProcess != rhs.isBrowserProcess { return lhs.isBrowserProcess }
            if lhs.memoryFootprintBytes != rhs.memoryFootprintBytes {
                return lhs.memoryFootprintBytes > rhs.memoryFootprintBytes
            }
            return lhs.processID < rhs.processID
        }
    }

    // MARK: Ending a process

    enum EndProcessRefusal: Equatable, Sendable {
        case isBrowserProcess
        // Re-checked at kill time, not trusted from the last sample: a pid can be recycled
        // between a refresh and a click, and kill() on a recycled pid hits an unrelated process.
        case notAnOrbitProcess
    }

    static func refusalForEndingProcess(
        _ processID: pid_t,
        attribution: WebKitProcessAttribution = .none
    ) -> EndProcessRefusal? {
        if processID == getpid() { return .isBrowserProcess }
        guard processIdentifiers(attribution: attribution).contains(processID) else { return .notAnOrbitProcess }
        return nil
    }

    // SIGKILL, not SIGTERM: the button exists for a task that already ignores polite signals.
    // The engine reports the death through webContentsDidCrash, which becomes the crashed-tab card.
    @discardableResult
    static func endProcess(
        _ processID: pid_t,
        attribution: WebKitProcessAttribution = .none
    ) -> EndProcessRefusal? {
        if let refusal = refusalForEndingProcess(processID, attribution: attribution) { return refusal }
        guard kill(processID, SIGKILL) == 0 else { return .notAnOrbitProcess }
        return nil
    }

    // MARK: - libproc

    // Children are one level deep on purpose: descending further would sweep in whatever a page
    // spawned (a downloaded installer the user ran) and offer to kill it under Orbit's name.
    // WebKit's services are not children, so only the pids Orbit's own web views report are added.
    static func processIdentifiers(attribution: WebKitProcessAttribution = .none) -> [pid_t] {
        var identifiers = childProcessIdentifiers()
        let attributed = attribution.processIdentifiers
        if attributed.isEmpty { return identifiers }
        // Children stay in proc_listpids order; attributed services follow, sorted, once each.
        var seen = Set(identifiers)
        for pid in attributed where seen.insert(pid).inserted {
            identifiers.append(pid)
        }
        return identifiers
    }

    private static func childProcessIdentifiers() -> [pid_t] {
        let parent = getpid()
        var identifiers: [pid_t] = [parent]

        let byteCount = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard byteCount > 0 else { return identifiers }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return identifiers }

        let count = min(Int(written) / MemoryLayout<pid_t>.size, capacity)
        for index in 0..<count where buffer[index] > 0 && buffer[index] != parent {
            identifiers.append(buffer[index])
        }
        return identifiers
    }

    private struct ResourceUsage {
        var physicalFootprintBytes: UInt64
        var userTimeNanoseconds: UInt64
        var systemTimeNanoseconds: UInt64
    }

    // RUSAGE_INFO_V0: ri_phys_footprint/ri_user_time/ri_system_time are all present in the
    // first revision, so a later one adds nothing and risks failing on systems without it.
    private static func resourceUsage(of processID: pid_t) -> ResourceUsage? {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(processID, RUSAGE_INFO_V0, rebound)
            }
        }
        guard result == 0 else { return nil }
        return ResourceUsage(
            physicalFootprintBytes: usage.ri_phys_footprint,
            userTimeNanoseconds: usage.ri_user_time,
            systemTimeNanoseconds: usage.ri_system_time
        )
    }

    // PROC_PIDPATHINFO_MAXSIZE, not imported by Swift.
    private static let pathBufferCount = 4 * Int(PATH_MAX)

    // proc_pidpath, not proc_name, which truncates to shorter than "com.apple.WebKit.WebContent".
    private static func executableName(of processID: pid_t, pathBuffer: inout [CChar]) -> String? {
        let length = pathBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return proc_pidpath(processID, baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        // proc_pidpath null-terminates, but a reused buffer must not keep the previous path's tail
        // if a future OS reports the length without writing that null.
        pathBuffer[min(Int(length), pathBuffer.count - 1)] = 0
        let path = pathBuffer.withUnsafeBufferPointer { buffer -> String in
            guard let baseAddress = buffer.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
        guard !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Formatting

extension OrbitProcessInfo {

    // .memory style: the same units Activity Monitor uses for this quantity.
    // One formatter for every row. Building a ByteCountFormatter per body pass dominates
    // the cost of drawing the table, and the units do not change between rows.
    @MainActor
    var memoryFootprintText: String {
        Self.memoryFormatter.string(fromByteCount: Int64(clamping: memoryFootprintBytes))
    }

    @MainActor
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter
    }()

    var cpuPercentText: String {
        String(format: "%.1f%%", cpuPercent)
    }
}
