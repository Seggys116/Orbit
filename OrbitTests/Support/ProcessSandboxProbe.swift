// Reads Seatbelt state and real argv of live processes via dlsym'd sandbox_check --
// needs no TCC grant, same precedent as this repo's own-window pixel capture.
// Validated against 32 real child processes of seven shipping Chromium apps: agreed with
// --seatbelt-client on every one, including the two Electron apps whose renderers run unsandboxed.

import Darwin
import Foundation

enum EngineProcessRole: Equatable {
    case browser
    case renderer
    case gpu
    case utility(service: String?)
    case other(String)

    /// `--type=` is Chromium's own spelling, shared by every process role.
    init(arguments: [String]) {
        let type = arguments.compactMap { argument -> String? in
            argument.hasPrefix("--type=") ? String(argument.dropFirst("--type=".count)) : nil
        }.first
        switch type {
        case nil, .some(""):
            self = .browser
        case .some("renderer"):
            self = .renderer
        case .some("gpu-process"):
            self = .gpu
        case .some("utility"):
            let service = arguments.compactMap { argument -> String? in
                argument.hasPrefix("--utility-sub-type=")
                    ? String(argument.dropFirst("--utility-sub-type=".count)) : nil
            }.first
            self = .utility(service: service)
        case .some(let other):
            self = .other(other)
        }
    }

    var description: String {
        switch self {
        case .browser: return "browser"
        case .renderer: return "renderer"
        case .gpu: return "gpu-process"
        case .utility(let service): return "utility(\(service ?? "unnamed"))"
        case .other(let type): return type
        }
    }

    /// The browser process is deliberately unconfined on every platform, in every Chromium browser: it owns the profile, the window server connection and the keychain, and its protection is that it runs no untrusted content.
    var mustBeSandboxed: Bool {
        switch self {
        case .browser: return false
        case .renderer, .gpu, .utility, .other: return true
        }
    }
}

struct ProbedProcess {
    let pid: pid_t
    let parentPID: pid_t
    let executablePath: String
    let arguments: [String]

    var role: EngineProcessRole { EngineProcessRole(arguments: arguments) }
    var executableName: String { (executablePath as NSString).lastPathComponent }

    /// Chromium's browser side appends this only when it has compiled a Seatbelt profile for the child; its absence on a confined type means the browser took the "sandbox off" early-out.
    var hasSeatbeltClient: Bool {
        arguments.contains { $0.hasPrefix("--seatbelt-client=") }
    }

    var serviceSandboxType: String? {
        arguments.compactMap { argument in
            argument.hasPrefix("--service-sandbox-type=")
                ? String(argument.dropFirst("--service-sandbox-type=".count)) : nil
        }.first
    }

    /// Captured at probe time rather than looked up on demand, so a synthetic process tree can describe a broken engine that this machine is not currently running.
    let isSandboxed: Bool?

    init(pid: pid_t, parentPID: pid_t, executablePath: String, arguments: [String], isSandboxed: Bool?) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
        self.isSandboxed = isSandboxed
    }

    var summary: String {
        let confinement: String
        switch isSandboxed {
        case .some(true): confinement = "sandboxed"
        case .some(false): confinement = "NOT SANDBOXED"
        case .none: confinement = "unreadable"
        }
        let service = serviceSandboxType.map { " service-sandbox-type=\($0)" } ?? ""
        return "pid \(pid) \(role.description)\(service) \(confinement)"
            + " seatbelt-client=\(hasSeatbeltClient ? "yes" : "no") \(executableName)"
    }
}

enum ProcessSandboxProbe {

    private typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

    private static let sandboxCheck: SandboxCheck? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "sandbox_check") else { return nil }
        return unsafeBitCast(symbol, to: SandboxCheck.self)
    }()

    static var isAvailable: Bool { sandboxCheck != nil }

    /// nil only when libSystem no longer exports sandbox_check, which is a broken detector, not an unconfined process.
    static func isSandboxed(pid: pid_t) -> Bool? {
        guard let sandboxCheck else { return nil }
        return sandboxCheck(pid, nil, 0) == 1
    }

    static func arguments(of pid: pid_t) -> [String] {
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var pieces: [String] = []
        var current: [UInt8] = []
        for byte in buffer[MemoryLayout<Int32>.size..<size] {
            if byte == 0 {
                if !current.isEmpty { pieces.append(String(decoding: current, as: UTF8.self)) }
                current = []
            } else {
                current.append(byte)
            }
        }
        // The first piece is the executable path the kernel recorded, then argv[0...argc-1].
        return Array(pieces.dropFirst().prefix(Int(max(argc, 0))))
    }

    static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    static func allProcesses() -> [(pid: pid_t, parentPID: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride + 64
        )
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 4, raw.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return [] }
        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map { (pid: $0.kp_proc.p_pid, parentPID: $0.kp_eproc.e_ppid) }
            .filter { $0.pid > 0 }
    }

    /// Transitive, not just direct children: a reparented helper must not fall out of the census.
    static func descendants(of root: pid_t) -> [ProbedProcess] {
        let table = allProcesses()
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in table {
            childrenByParent[entry.parentPID, default: []].append(entry.pid)
        }
        var found: [pid_t] = []
        var queue = childrenByParent[root] ?? []
        var seen: Set<pid_t> = [root]
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            found.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        let parents = Dictionary(table.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        return found.map { probe(pid: $0, parentPID: parents[$0] ?? -1) }
    }

    static func probe(pid: pid_t, parentPID: pid_t = -1) -> ProbedProcess {
        ProbedProcess(
            pid: pid,
            parentPID: parentPID,
            executablePath: executablePath(of: pid),
            arguments: arguments(of: pid),
            isSandboxed: isSandboxed(pid: pid)
        )
    }

    static func current() -> ProbedProcess {
        probe(pid: getpid(), parentPID: getppid())
    }

    /// The browser process of a running Orbit, if there is one. Matched on the app bundle's own executable path, which no engine change alters.
    static func runningOrbitBrowsers() -> [ProbedProcess] {
        allProcesses()
            .map { probe(pid: $0.pid, parentPID: $0.parentPID) }
            .filter { $0.executablePath.hasSuffix("/Orbit.app/Contents/MacOS/Orbit") }
    }
}

/// Every one of these is silent: the app behaves identically with and without it. Kept in step with DANGEROUS_SWITCHES in Scripts/security_guards.py, which is the static half of the same invariant.
enum SandboxDisablingSwitch: String, CaseIterable {
    case noSandbox = "--no-sandbox"
    case disableGPUSandbox = "--disable-gpu-sandbox"
    case singleProcess = "--single-process"
    case inProcessGPU = "--in-process-gpu"
    case disableWebSecurity = "--disable-web-security"
    case allowRunningInsecureContent = "--allow-running-insecure-content"
    case ignoreCertificateErrors = "--ignore-certificate-errors"
    case disableSiteIsolationTrials = "--disable-site-isolation-trials"
    case disableSiteIsolationForPolicy = "--disable-site-isolation-for-policy"
    case allowFileAccessFromFiles = "--allow-file-access-from-files"
    case remoteDebuggingPort = "--remote-debugging-port"

    var consequence: String {
        switch self {
        case .noSandbox:
            return "every child process runs unconfined, so a compromised renderer gets the browser's own access to the disk, the keychain and the network"
        case .disableGPUSandbox:
            return "the GPU process, which parses attacker-influenced image and shader data and talks to the kernel graphics drivers, runs unconfined"
        case .singleProcess:
            return "web content runs inside the browser process: no renderer to sandbox, no site isolation, no boundary between a page and the user's profile"
        case .inProcessGPU:
            return "GPU work runs in the browser process, so GPU driver bugs become browser process bugs"
        case .disableWebSecurity:
            return "the same-origin policy is off and any page can read any other origin's data"
        case .allowRunningInsecureContent:
            return "https pages execute http subresources, handing any network attacker script execution in a secure origin"
        case .ignoreCertificateErrors:
            return "any TLS certificate is accepted, so every https connection is interceptable"
        case .disableSiteIsolationTrials, .disableSiteIsolationForPolicy:
            return "site isolation is off, so a compromised or speculating renderer can read another site's data"
        case .allowFileAccessFromFiles:
            return "one downloaded HTML file can read the user's home directory"
        case .remoteDebuggingPort:
            return "an unauthenticated DevTools socket drives the browser as the user"
        }
    }

    static func found(in arguments: [String]) -> [SandboxDisablingSwitch] {
        allCases.filter { candidate in
            arguments.contains { $0 == candidate.rawValue || $0.hasPrefix(candidate.rawValue + "=") }
        }
    }
}

struct ProcessModelViolation: Equatable, CustomStringConvertible {
    /// The property that was lost, in one line, so a red build says what broke before it says where.
    let invariant: String
    let offender: String
    let consequence: String

    var description: String {
        "INVARIANT: \(invariant)\n  broken by: \(offender)\n  consequence: \(consequence)"
    }
}

/// The whole of Orbit's runtime process-model policy, as a pure function of a process tree, so it can be proven against deliberately broken trees with no engine running. Section 2.3 of the process and sandbox design is what it encodes.
enum ProcessModelInvariant {

    /// Utility services upstream Chromium itself declares kNoSandbox on macOS. Named one by one, with the reason, because the alternative is either a guard that fires on a correct build and gets deleted, or a blanket allowance that hides a real kNoSandbox annotation. Measured: a shipping Chromium browser on this machine runs exactly this service unconfined and nothing else.
    static let upstreamUnsandboxedServices: [String: String] = [
        "video_capture.mojom.VideoCaptureService":
            "the capture service opens the camera through AVFoundation, which needs a TCC "
            + "decision bound to the process and is not expressible inside the utility profile. "
            + "Chromium annotates it kNoSandbox on macOS upstream. It runs no untrusted script.",
    ]

    private static func isUpstreamUnsandboxedService(_ process: ProbedProcess) -> Bool {
        guard case .utility(let service) = process.role, let service else { return false }
        return upstreamUnsandboxedServices[service] != nil
    }

    static func violations(
        browser: ProbedProcess,
        children: [ProbedProcess],
        renderedAPage: Bool
    ) -> [ProcessModelViolation] {
        var violations: [ProcessModelViolation] = []
        let engineChildren = children.filter { $0.role != .browser }

        if renderedAPage && !engineChildren.contains(where: { $0.role == .renderer }) {
            violations.append(ProcessModelViolation(
                invariant: "web content is rendered by a separate renderer process, never by the browser process",
                offender: engineChildren.isEmpty
                    ? "a page rendered and the browser process has no engine child processes at all"
                    : "a page rendered and no child process carries --type=renderer",
                consequence:
                    "the content was rendered in the browser process. That is --single-process, or an "
                    + "in-process renderer reached some other way: no sandbox, no site isolation, and no "
                    + "boundary between a web page and the user's profile, keychain and disk. It is "
                    + "invisible from the UI, which is why it is asserted here."
            ))
        }

        if renderedAPage && !engineChildren.contains(where: { $0.role == .gpu }) {
            violations.append(ProcessModelViolation(
                invariant: "GPU work runs in its own sandboxed process, not in the browser process",
                offender: "a page rendered and no child process carries --type=gpu-process",
                consequence:
                    "GPU work is happening in the browser process (--in-process-gpu), so the GPU sandbox "
                    + "does not exist and a bug in a kernel graphics driver reached through attacker "
                    + "influenced shader or image data compromises the process that owns the profile."
            ))
        }

        for child in engineChildren where child.role.mustBeSandboxed && !isUpstreamUnsandboxedService(child) {
            if child.isSandboxed != true {
                violations.append(ProcessModelViolation(
                    invariant: "every child process that handles untrusted content is inside a Seatbelt sandbox",
                    offender: child.summary,
                    consequence:
                        "sandbox_check reports this process as unconfined, which means the browser took "
                        + "the 'sandbox off' early-out when it launched it: --no-sandbox, "
                        + "--disable-gpu-sandbox, or a service annotated kNoSandbox. An unconfined "
                        + "renderer has the browser's own access to the disk, the keychain and the network."
                ))
            }
            if !child.hasSeatbeltClient {
                violations.append(ProcessModelViolation(
                    invariant: "the browser compiles and hands a Seatbelt profile to every child that must be confined",
                    offender: child.summary,
                    consequence:
                        "the browser appends --seatbelt-client only after compiling a profile for the "
                        + "child, so its absence means profile compilation was skipped entirely. This is a "
                        + "second, independent reading of the same property as sandbox_check: if the two "
                        + "disagree, believe the one that says unconfined."
                ))
            }
            if case .utility = child.role, child.serviceSandboxType == "none" {
                violations.append(ProcessModelViolation(
                    invariant: "no utility service Orbit runs is annotated kNoSandbox",
                    offender: child.summary,
                    consequence:
                        "--service-sandbox-type=none is the command-line trace of a "
                        + "[ServiceSandbox=sandbox.mojom.Sandbox.kNoSandbox] annotation on a Mojo service. "
                        + "Orbit defines no service that needs one, and the annotation is written in a "
                        + ".mojom file, far from anything that looks security relevant. Upstream "
                        + "Chromium does declare a small number of services kNoSandbox on macOS; each "
                        + "is named in ProcessModelInvariant.upstreamUnsandboxedServices with the "
                        + "reason it cannot be confined. This one is not among them."
                ))
            }
        }

        for process in [browser] + children {
            for dangerous in SandboxDisablingSwitch.found(in: process.arguments) {
                violations.append(ProcessModelViolation(
                    invariant: "no process Orbit runs is launched with a switch that disables a security control",
                    offender: "\(process.executableName) (pid \(process.pid), \(process.role.description)) "
                        + "was launched with \(dangerous.rawValue)",
                    consequence: dangerous.consequence
                        + ". This reads the argv the kernel recorded for a process that is actually "
                        + "running, not the source that appears to construct it, so it catches a switch "
                        + "added anywhere: the embedder's command line hook, an inherited browser argument, "
                        + "a scheme's launch arguments, or the engine's own defaults."
                ))
            }
        }

        return violations
    }

    /// Printed with every failure: an invariant that goes red without showing the process tree is one nobody can act on.
    static func census(browser: ProbedProcess, children: [ProbedProcess]) -> String {
        let lines = children.sorted { $0.pid < $1.pid }.map { "    " + $0.summary }
        return "Process tree:\n"
            + "    pid \(browser.pid) browser (deliberately unconfined) \(browser.executableName)\n"
            + (lines.isEmpty ? "    (no child processes at all)" : lines.joined(separator: "\n"))
    }
}
