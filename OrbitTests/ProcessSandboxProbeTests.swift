//  Proves the sandbox_check detector itself: if it stopped discriminating, SandboxInvariantTests
//  would go green on an unsandboxed browser. Starts one confined and one unconfined process and checks it tells them apart.

import XCTest

final class ProcessSandboxProbeTests: XCTestCase {

    private var started: [Process] = []

    override func tearDown() {
        for process in started where process.isRunning {
            process.terminate()
        }
        started.removeAll()
        super.tearDown()
    }

    /// `settledImage` matters: sandbox-exec applies the profile and then execs the real binary in the same pid, so probing before that image lands measures the wrong moment.
    private func launch(_ path: String, _ arguments: [String], settledImage: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        started.append(process)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              !ProcessSandboxProbe.executablePath(of: process.processIdentifier).hasSuffix(settledImage) {
            usleep(20_000)
        }
        return process
    }

    func testSandboxCheckIsReachableWithoutAnyPermissionGrant() {
        XCTAssertTrue(
            ProcessSandboxProbe.isAvailable,
            "libSystem no longer exports sandbox_check, so every sandbox invariant in this "
            + "repository has stopped being checked. That is a broken detector, not a passing "
            + "one: nothing else here can tell a confined child process from an unconfined one. "
            + "Find the replacement API before trusting any other result in this suite."
        )
    }

    func testTheProbeTellsAConfinedProcessFromAnUnconfinedOne() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
            "/usr/bin/sandbox-exec is absent, so this machine cannot produce a known-confined "
            + "process to calibrate the probe against."
        )

        let confined = try launch(
            "/usr/bin/sandbox-exec",
            ["-p", "(version 1)(allow default)", "/bin/sleep", "30"],
            settledImage: "/sleep"
        )
        let unconfined = try launch("/bin/sleep", ["30"], settledImage: "/sleep")

        XCTAssertEqual(
            ProcessSandboxProbe.isSandboxed(pid: confined.processIdentifier), true,
            "sandbox_check reported a process started under sandbox-exec as unconfined. The probe "
            + "is no longer measuring what it claims to; every sandbox assertion built on it is void."
        )
        XCTAssertEqual(
            ProcessSandboxProbe.isSandboxed(pid: unconfined.processIdentifier), false,
            "sandbox_check reported a plain /bin/sleep as sandboxed. A probe that answers yes to "
            + "everything would make SandboxInvariantTests pass on a browser whose "
            + "renderers run with --no-sandbox."
        )
    }

    func testTheProbeReadsTheRealArgumentsOfARunningProcess() throws {
        let process = try launch("/bin/sh", ["-c", "sleep 30", "orbit-probe", "--no-sandbox"], settledImage: "/sh")
        let arguments = ProcessSandboxProbe.arguments(of: process.processIdentifier)

        XCTAssertTrue(
            arguments.contains("--no-sandbox"),
            "KERN_PROCARGS2 did not hand back the arguments a process was launched with (got "
            + "\(arguments)). The dangerous-switch invariant reads argv this way precisely so it "
            + "sees what was really passed rather than what the source appears to pass; without it "
            + "that check silently inspects nothing."
        )
        XCTAssertEqual(
            SandboxDisablingSwitch.found(in: arguments), [.noSandbox],
            "the switch matcher did not recognise --no-sandbox in a real process's argv."
        )
    }

    func testEveryDescendantProcessIsFound() throws {
        let child = try launch("/bin/sleep", ["30"], settledImage: "/sleep")
        let descendants = ProcessSandboxProbe.descendants(of: getpid())

        XCTAssertTrue(
            descendants.contains { $0.pid == child.processIdentifier },
            "a process this test host started itself did not appear in the descendant census. The "
            + "live invariant enumerates helper processes the same way, so a census that misses "
            + "children would report an unsandboxed renderer as 'no renderers to check'."
        )
    }

    func testTheBrowserProcessRoleIsReadFromTheTypeSwitchNotTheBundleName() {
        XCTAssertEqual(EngineProcessRole(arguments: ["/path/Orbit"]), .browser)
        XCTAssertEqual(EngineProcessRole(arguments: ["/path/Helper", "--type=renderer"]), .renderer)
        XCTAssertEqual(EngineProcessRole(arguments: ["/path/Helper", "--type=gpu-process"]), .gpu)
        XCTAssertEqual(
            EngineProcessRole(arguments: ["/path/Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]),
            .utility(service: "network.mojom.NetworkService"),
            "roles are classified from Chromium's own --type= switch, so this classification keeps "
            + "working without being taught new bundle names."
        )
        XCTAssertFalse(
            EngineProcessRole.browser.mustBeSandboxed,
            "the browser process is deliberately unconfined in every Chromium browser: it owns the "
            + "profile and the window server connection, and its protection is that it renders no "
            + "untrusted content."
        )
        for role in [EngineProcessRole.renderer, .gpu, .utility(service: nil), .other("zygote")] {
            XCTAssertTrue(role.mustBeSandboxed, "\(role.description) must be confined")
        }
    }

    func testTheHostProcessSeesItsOwnCommandLine() {
        let current = ProcessSandboxProbe.current()
        XCTAssertEqual(current.pid, getpid())
        XCTAssertFalse(
            current.arguments.isEmpty,
            "the probe could not read its own argv, so it cannot read the browser process's either."
        )
    }
}
