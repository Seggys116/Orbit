// Reads Seatbelt state and signed entitlements of live processes via dlsym'd sandbox_check and the Security
// framework -- no TCC grant needed, same precedent as this repo's own-window pixel capture.
// WebKit runs web content in system XPC services (WebContent, Networking, GPU). They are launched by launchd, so they are
// not descendants of the browser process; they are attributed to it by the responsible pid instead.

import Darwin
import Foundation
import Security

struct TestStopped: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum WebKitProcessRole: Equatable {
    case browser
    case webContent
    case networking
    case gpu
    case other(String)

    /// WebKit's XPC services are named on the executable. A Development variant (`.Development` suffix) is still the same role.
    init(executablePath: String) {
        let executable = (executablePath as NSString).lastPathComponent
        if executable.hasPrefix("com.apple.WebKit.WebContent") {
            self = .webContent
        } else if executable.hasPrefix("com.apple.WebKit.Networking") {
            self = .networking
        } else if executable.hasPrefix("com.apple.WebKit.GPU") {
            self = .gpu
        } else if executable.hasPrefix("com.apple.WebKit.") {
            self = .other(executable)
        } else {
            self = .browser
        }
    }

    var description: String {
        switch self {
        case .browser: return "browser"
        case .webContent: return "WebContent"
        case .networking: return "Networking"
        case .gpu: return "GPU"
        case .other(let name): return name
        }
    }

    /// The browser process is deliberately not App Sandboxed: it owns the profile and the window server connection, and runs no untrusted content. Its protection is that it carries no entitlement exceptions.
    var mustBeSandboxed: Bool {
        switch self {
        case .browser: return false
        case .webContent, .networking, .gpu, .other: return true
        }
    }
}

struct ProbedProcess {
    let pid: pid_t
    let parentPID: pid_t
    let executablePath: String
    /// Captured at probe time rather than looked up on demand, so a synthetic process tree can describe a broken browser that this machine is not currently running.
    let isSandboxed: Bool?
    /// Entitlement keys granted to the process's signature; nil when unreadable (unsigned, or the process is gone).
    let grantedEntitlements: Set<String>?

    var role: WebKitProcessRole { WebKitProcessRole(executablePath: executablePath) }
    var executableName: String { (executablePath as NSString).lastPathComponent }

    init(
        pid: pid_t,
        parentPID: pid_t,
        executablePath: String,
        isSandboxed: Bool?,
        grantedEntitlements: Set<String>? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.isSandboxed = isSandboxed
        self.grantedEntitlements = grantedEntitlements
    }

    var summary: String {
        let confinement: String
        switch isSandboxed {
        case .some(true): confinement = "sandboxed"
        case .some(false): confinement = "NOT SANDBOXED"
        case .none: confinement = "unreadable"
        }
        return "pid \(pid) \(role.description) \(confinement) \(executableName)"
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

    /// The entitlement keys in `pid`'s code signature, or nil when it has none or cannot be read.
    static func entitlements(of pid: pid_t) -> Set<String>? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        guard let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return Set(entitlements.keys)
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private static let responsiblePID: ResponsiblePID? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    /// False when libSystem does not export the attribution call; `webKitServices(responsibleTo:)` then cannot find anything and says so rather than returning a clean empty list.
    static var canAttributeServices: Bool { responsiblePID != nil }

    /// WebKit XPC services launched on behalf of `owner`, found by scanning every process for a `com.apple.WebKit.*` executable whose responsible pid is `owner`. Returns nil when attribution is unavailable.
    static func webKitServices(responsibleTo owner: pid_t) -> [ProbedProcess]? {
        guard let responsiblePID else { return nil }
        return allProcesses().compactMap { entry -> ProbedProcess? in
            guard entry.pid != owner, responsiblePID(entry.pid) == owner else { return nil }
            let candidate = probe(pid: entry.pid, parentPID: entry.parentPID)
            return candidate.role == .browser ? nil : candidate
        }
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

    static func probe(pid: pid_t, parentPID: pid_t = -1) -> ProbedProcess {
        ProbedProcess(
            pid: pid,
            parentPID: parentPID,
            executablePath: executablePath(of: pid),
            isSandboxed: isSandboxed(pid: pid),
            grantedEntitlements: entitlements(of: pid)
        )
    }

    static func current() -> ProbedProcess {
        probe(pid: getpid(), parentPID: getppid())
    }

    /// The browser process of a running Orbit, if there is one. Matched on the app bundle's own executable path, which no engine change alters.
    static func runningOrbitBrowsers() -> [ProbedProcess] {
        allProcesses()
            .filter { executablePath(of: $0.pid).hasSuffix("/Orbit.app/Contents/MacOS/Orbit") }
            .map { probe(pid: $0.pid, parentPID: $0.parentPID) }
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

/// Orbit's runtime process-model policy as a pure function of a process tree, so it can be proven against deliberately broken trees with no browser running.
enum ProcessModelInvariant {

    /// Hardened-runtime exceptions the browser process must not carry: WebKit compiles JavaScript in its own WebContent process, so Orbit needs none of them.
    /// disable-library-validation and get-task-allow are deliberately absent: the first is a recorded ad hoc signing waiver and the second is added to debug builds by Xcode; Scripts/release_manager.py polices both.
    static let forbiddenBrowserEntitlements: [String: String] = [
        "com.apple.security.cs.allow-jit":
            "a MAP_JIT region in the browser process; WebKit's JIT runs in the WebContent process",
        "com.apple.security.cs.allow-unsigned-executable-memory":
            "writable-and-executable memory in the process that owns the profile, which is what most exploit chains want",
        "com.apple.security.cs.disable-executable-page-protection":
            "W^X switched off for the whole browser process",
        "com.apple.security.cs.allow-dyld-environment-variables":
            "DYLD_INSERT_LIBRARIES works on the browser, so anything that can set its environment can load code into it",
        "com.apple.security.cs.debugger":
            "the browser may attach to and control other processes",
    ]

    static let temporaryExceptionPrefix = "com.apple.security.temporary-exception."

    static func violations(
        browser: ProbedProcess,
        services: [ProbedProcess],
        renderedAPage: Bool
    ) -> [ProcessModelViolation] {
        var violations: [ProcessModelViolation] = []
        let engineServices = services.filter { $0.role != .browser }

        if renderedAPage && !engineServices.contains(where: { $0.role == .webContent && $0.pid != browser.pid }) {
            violations.append(ProcessModelViolation(
                invariant: "web content is rendered by a separate WebContent process, never by the browser process",
                offender: engineServices.isEmpty
                    ? "a page rendered and no WebKit service process is attributed to the browser at all"
                    : "a page rendered and none of the WebKit services is a WebContent process",
                consequence:
                    "the content would be rendered inside the browser process: no sandbox and no boundary between a "
                    + "web page and the user's profile, keychain and disk."
            ))
        }

        for service in engineServices where service.role.mustBeSandboxed && service.isSandboxed != true {
            violations.append(ProcessModelViolation(
                invariant: "every WebKit service process that handles untrusted content is inside a sandbox",
                offender: service.summary,
                consequence:
                    "sandbox_check reports this process as unconfined. A WebContent process executes "
                    + "attacker-controlled JavaScript; an unconfined one has the user's own access to the "
                    + "disk, the keychain and the network. A nil reading means the detector itself is broken."
            ))
        }

        if let granted = browser.grantedEntitlements {
            let exceptions = granted.filter {
                forbiddenBrowserEntitlements[$0] != nil || $0.hasPrefix(temporaryExceptionPrefix)
            }.sorted()
            for key in exceptions {
                violations.append(ProcessModelViolation(
                    invariant: "the browser process carries no sandbox or hardened-runtime exception",
                    offender: "\(browser.executableName) (pid \(browser.pid)) is signed with \(key)",
                    consequence: forbiddenBrowserEntitlements[key]
                        ?? "a temporary sandbox exception widens what the browser process may reach"
                ))
            }
        } else {
            violations.append(ProcessModelViolation(
                invariant: "the browser process's signed entitlements can be read",
                offender: "\(browser.executableName) (pid \(browser.pid)) has no readable code signature",
                consequence: "without a signature the entitlements cannot be audited, so the exception check proves nothing."
            ))
        }

        return violations
    }

    /// Printed with every failure: an invariant that goes red without showing the process tree is one nobody can act on.
    static func census(browser: ProbedProcess, services: [ProbedProcess]) -> String {
        let lines = services.sorted { $0.pid < $1.pid }.map { "    " + $0.summary }
        return "Process tree:\n"
            + "    pid \(browser.pid) browser (not App Sandboxed by design) \(browser.executableName)\n"
            + (lines.isEmpty ? "    (no WebKit service processes attributed to the browser)" : lines.joined(separator: "\n"))
    }
}
