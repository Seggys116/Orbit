import Darwin
import Foundation

// MARK: - A sampled process

nonisolated struct OrbitProcessInfo: Identifiable, Equatable, Sendable {

    // Derived from the executable's file name: Chromium's helper bundles are named for their role
    // (Orbit Helper (Renderer)/(GPU)/(Plugin)/(Alerts)), so no --type= probe or extra privilege is needed.
    enum Role: String, Sendable, CaseIterable {
        case browser
        case renderer
        case gpu
        case plugin
        case alerts
        case helper
        case other

        var displayName: String {
            switch self {
            case .browser: return "Orbit"
            case .renderer: return "Web Page"
            case .gpu: return "GPU Process"
            case .plugin: return "Plugin Process"
            case .alerts: return "Notifications"
            case .helper: return "Utility"
            case .other: return "Subprocess"
            }
        }

        // Substring, case-insensitive: the bundle name carries the app name as a prefix,
        // which a product rename would change while the parenthesised role would not.
        static func forExecutableName(_ name: String, isBrowserProcess: Bool) -> Role {
            if isBrowserProcess { return .browser }
            let lowered = name.lowercased()
            if lowered.contains("(renderer)") { return .renderer }
            if lowered.contains("(gpu)") { return .gpu }
            if lowered.contains("(plugin)") { return .plugin }
            if lowered.contains("(alerts)") { return .alerts }
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

    static func sample(against baseline: Baseline = .none) -> Sample {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = baseline.isEmpty ? 0 : now &- baseline.wallClockNanoseconds

        var rows: [OrbitProcessInfo] = []
        var cpuTimes: [pid_t: UInt64] = [:]

        for pid in processIdentifiers() {
            guard let usage = resourceUsage(of: pid) else { continue }
            let cpuTime = usage.userTimeNanoseconds &+ usage.systemTimeNanoseconds
            cpuTimes[pid] = cpuTime

            let isBrowser = pid == getpid()
            let name = executableName(of: pid) ?? (isBrowser ? ProcessInfo.processInfo.processName : "Process \(pid)")

            rows.append(
                OrbitProcessInfo(
                    processID: pid,
                    executableName: name,
                    role: OrbitProcessInfo.Role.forExecutableName(name, isBrowserProcess: isBrowser),
                    memoryFootprintBytes: usage.physicalFootprintBytes,
                    cpuTimeNanoseconds: cpuTime,
                    cpuPercent: cpuPercent(
                        previousCPUTime: baseline.cpuTimeByProcessID[pid],
                        currentCPUTime: cpuTime,
                        elapsedNanoseconds: elapsed
                    )
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

    static func refusalForEndingProcess(_ processID: pid_t) -> EndProcessRefusal? {
        if processID == getpid() { return .isBrowserProcess }
        guard processIdentifiers().contains(processID) else { return .notAnOrbitProcess }
        return nil
    }

    // SIGKILL, not SIGTERM: the button exists for a task that already ignores polite signals.
    // The engine reports the death through webContentsDidCrash, which becomes the crashed-tab card.
    @discardableResult
    static func endProcess(_ processID: pid_t) -> EndProcessRefusal? {
        if let refusal = refusalForEndingProcess(processID) { return refusal }
        guard kill(processID, SIGKILL) == 0 else { return .notAnOrbitProcess }
        return nil
    }

    // MARK: - libproc

    // One level deep on purpose: descending further would sweep in whatever a page spawned
    // (a downloaded installer the user ran) and offer to kill it under Orbit's name.
    static func processIdentifiers() -> [pid_t] {
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

    // proc_pidpath, not proc_name, which truncates to shorter than "Orbit Helper (Renderer)".
    private static func executableName(of processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX)) // PROC_PIDPATHINFO_MAXSIZE, not imported by Swift
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Formatting

extension OrbitProcessInfo {

    // .memory style: the same units Activity Monitor uses for this quantity.
    var memoryFootprintText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(clamping: memoryFootprintBytes))
    }

    var cpuPercentText: String {
        String(format: "%.1f%%", cpuPercent)
    }
}
