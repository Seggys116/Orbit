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
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            XCTFail(
                "/usr/bin/sandbox-exec is absent, so this machine cannot produce a known-confined "
                    + "process to calibrate the probe against."
            )
            return
        }

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
            + "everything would make SandboxInvariantTests pass on a WebContent process "
            + "that is not confined."
        )
    }

    func testAttributionOfWebKitServicesIsReachable() {
        XCTAssertTrue(
            ProcessSandboxProbe.canAttributeServices,
            "libSystem no longer exports responsibility_get_pid_responsible_for_pid, so WebKit's "
            + "WebContent, Networking and GPU services can no longer be tied to the browser that owns "
            + "them. Without that, the live sandbox invariant has nothing to inspect."
        )
    }

    func testTheProbeReadsTheEntitlementsOfARunningProcess() {
        XCTAssertNotNil(
            ProcessSandboxProbe.entitlements(of: getpid()),
            "the code signature of this test host could not be read, so the browser process's "
            + "entitlements cannot be audited either."
        )
    }

    func testRolesAreReadFromTheXPCServiceExecutableName() {
        let services = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"
        XCTAssertEqual(WebKitProcessRole(executablePath: "/Applications/Orbit.app/Contents/MacOS/Orbit"), .browser)
        XCTAssertEqual(
            WebKitProcessRole(executablePath: "\(services)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            .webContent
        )
        XCTAssertEqual(
            WebKitProcessRole(executablePath: "\(services)/com.apple.WebKit.WebContent.Development.xpc/Contents/MacOS/com.apple.WebKit.WebContent.Development"),
            .webContent
        )
        XCTAssertEqual(
            WebKitProcessRole(executablePath: "\(services)/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"),
            .networking
        )
        XCTAssertEqual(
            WebKitProcessRole(executablePath: "\(services)/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"),
            .gpu
        )
        XCTAssertEqual(
            WebKitProcessRole(executablePath: "\(services)/com.apple.WebKit.Plugin.64.xpc/Contents/MacOS/com.apple.WebKit.Plugin.64"),
            .other("com.apple.WebKit.Plugin.64"),
            "an unknown WebKit service must still be classified as one so it is checked for confinement"
        )
        XCTAssertFalse(
            WebKitProcessRole.browser.mustBeSandboxed,
            "the browser process is not App Sandboxed: it owns the profile and the window server "
            + "connection, and its protection is that it renders no untrusted content."
        )
        for role in [WebKitProcessRole.webContent, .networking, .gpu, .other("x")] {
            XCTAssertTrue(role.mustBeSandboxed, "\(role.description) must be confined")
        }
    }

    func testTheHostProcessIsAProbeableBrowserProcess() {
        let current = ProcessSandboxProbe.current()
        XCTAssertEqual(current.pid, getpid())
        XCTAssertEqual(current.role, .browser)
        XCTAssertFalse(current.executablePath.isEmpty, "the probe could not resolve its own executable path")
    }
}
