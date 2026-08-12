//  Runtime process-model invariants, proven against synthetic process trees — no engine required.
//  The last test applies the same evaluator to a real running Orbit and skips loudly until the engine can spawn children.

import XCTest

final class SandboxInvariantTests: XCTestCase {

    // MARK: - Synthetic process trees

    private func browser(_ arguments: [String] = []) -> ProbedProcess {
        ProbedProcess(
            pid: 100,
            parentPID: 1,
            executablePath: "/Applications/Orbit.app/Contents/MacOS/Orbit",
            arguments: ["/Applications/Orbit.app/Contents/MacOS/Orbit"] + arguments,
            isSandboxed: false
        )
    }

    /// Shaped on argv measured from shipping Chromium browsers on this machine, including the --seatbelt-client descriptor the browser appends once it has compiled a profile.
    private func child(
        pid: pid_t,
        type: String,
        bundle: String,
        sandboxed: Bool = true,
        seatbeltClient: Bool = true,
        extra: [String] = []
    ) -> ProbedProcess {
        let path = "/Applications/Orbit.app/Contents/Frameworks/Orbit Framework.framework/Helpers/"
            + "\(bundle).app/Contents/MacOS/\(bundle)"
        var arguments = [path, "--type=\(type)"] + extra
        if seatbeltClient { arguments.append("--seatbelt-client=7") }
        return ProbedProcess(
            pid: pid,
            parentPID: 100,
            executablePath: path,
            arguments: arguments,
            isSandboxed: sandboxed
        )
    }

    private func healthyChildren() -> [ProbedProcess] {
        [
            child(pid: 101, type: "renderer", bundle: "Orbit Helper (Renderer)"),
            child(pid: 102, type: "gpu-process", bundle: "Orbit Helper (GPU)"),
            child(pid: 103, type: "utility", bundle: "Orbit Helper",
                  extra: ["--utility-sub-type=network.mojom.NetworkService", "--service-sandbox-type=network"]),
            child(pid: 104, type: "utility", bundle: "Orbit Helper",
                  extra: ["--utility-sub-type=storage.mojom.StorageService", "--service-sandbox-type=service"]),
        ]
    }

    private func evaluate(
        browser: ProbedProcess? = nil,
        children: [ProbedProcess],
        renderedAPage: Bool = true
    ) -> [ProcessModelViolation] {
        ProcessModelInvariant.violations(
            browser: browser ?? self.browser(),
            children: children,
            renderedAPage: renderedAPage
        )
    }

    // MARK: - The healthy case

    func testACorrectlyConfinedProcessTreeProducesNoViolations() {
        let violations = evaluate(children: healthyChildren())
        XCTAssertEqual(
            violations, [],
            "a process tree matching what a correctly configured Chromium browser really looks like "
            + "was reported as broken, so these invariants would fire on a healthy build and be "
            + "deleted the first time they did: \(violations.map(\.description).joined(separator: "\n"))"
        )
    }

    func testABrowserThatHasNotRenderedAnythingIsNotAccusedOfBeingSingleProcess() {
        XCTAssertEqual(
            evaluate(children: [], renderedAPage: false), [],
            "an idle browser with no children yet was reported as single-process. The renderer and GPU "
            + "presence invariants are conditional on a page having actually rendered, because before "
            + "that there is legitimately nothing to see."
        )
    }

    // MARK: - Every silent regression from section 2.3 of the design

    func testSingleProcessIsCaughtByTheAbsenceOfAnyRendererProcess() {
        let violations = evaluate(children: [], renderedAPage: true)
        XCTAssertTrue(
            violations.contains { $0.invariant.contains("separate renderer process") },
            "a page rendered with no child processes at all and nothing objected. That is exactly what "
            + "--single-process looks like from outside, and it is the total loss of the security "
            + "model: \(violations)"
        )
    }

    func testInProcessGPUIsCaughtByTheAbsenceOfAGPUProcess() {
        let children = healthyChildren().filter { $0.role != .gpu }
        XCTAssertTrue(
            evaluate(children: children).contains { $0.invariant.contains("GPU work runs in its own sandboxed process") },
            "a page rendered with no --type=gpu-process anywhere and nothing objected."
        )
    }

    func testAnUnconfinedRendererIsCaught() {
        var children = healthyChildren()
        children[0] = child(pid: 101, type: "renderer", bundle: "Orbit Helper (Renderer)", sandboxed: false)
        let violations = evaluate(children: children)
        XCTAssertTrue(
            violations.contains { $0.invariant.contains("inside a Seatbelt sandbox") },
            "a renderer reporting sandbox_check == 0 was accepted. That is the single most valuable "
            + "assertion in this file: a renderer executes attacker-controlled JavaScript."
        )
    }

    func testAnUnconfinedGPUProcessIsCaught() {
        var children = healthyChildren()
        children[1] = child(pid: 102, type: "gpu-process", bundle: "Orbit Helper (GPU)", sandboxed: false)
        XCTAssertTrue(
            evaluate(children: children).contains { $0.invariant.contains("inside a Seatbelt sandbox") },
            "--disable-gpu-sandbox leaves exactly this trace and was not caught."
        )
    }

    func testAnUnconfinedUtilityProcessIsCaught() {
        var children = healthyChildren()
        children[2] = child(pid: 103, type: "utility", bundle: "Orbit Helper", sandboxed: false,
                            extra: ["--utility-sub-type=network.mojom.NetworkService"])
        XCTAssertTrue(
            evaluate(children: children).contains { $0.invariant.contains("inside a Seatbelt sandbox") },
            "the network service, which handles every byte an attacker sends, was accepted unconfined."
        )
    }

    func testAServiceAnnotatedKNoSandboxIsCaught() {
        var children = healthyChildren()
        children[3] = child(pid: 104, type: "utility", bundle: "Orbit Helper",
                            extra: ["--utility-sub-type=orbit.mojom.SomeService", "--service-sandbox-type=none"])
        let violations = evaluate(children: children)
        XCTAssertTrue(
            violations.contains { $0.invariant.contains("annotated kNoSandbox") },
            "a service running with --service-sandbox-type=none was accepted. That switch is the only "
            + "outward trace of a kNoSandbox annotation written in a .mojom file."
        )
    }

    func testTheUpstreamUnsandboxedServiceExceptionIsNamedAndNarrow() {
        var children = healthyChildren()
        children.append(child(pid: 105, type: "utility", bundle: "Orbit Helper", sandboxed: false,
                              seatbeltClient: false,
                              extra: ["--utility-sub-type=video_capture.mojom.VideoCaptureService",
                                      "--service-sandbox-type=none"]))
        XCTAssertEqual(
            evaluate(children: children), [],
            "the one service upstream Chromium itself runs unconfined on macOS was reported as a "
            + "violation. A guard that fires on a correctly configured build is a guard that gets "
            + "deleted, and this exception is named with its reason rather than inferred."
        )

        var impostor = healthyChildren()
        impostor.append(child(pid: 106, type: "utility", bundle: "Orbit Helper", sandboxed: false,
                              seatbeltClient: false,
                              extra: ["--utility-sub-type=orbit.mojom.FastPath",
                                      "--service-sandbox-type=none"]))
        XCTAssertFalse(
            evaluate(children: impostor).isEmpty,
            "the exception is not narrow: another service also escaped it. Only the services named "
            + "in ProcessModelInvariant.upstreamUnsandboxedServices may run unconfined."
        )
        XCTAssertEqual(
            ProcessModelInvariant.upstreamUnsandboxedServices.count, 1,
            "the list of services allowed to run unconfined has grown. Each entry is a process "
            + "outside the sandbox for the life of the product; adding one is a security decision "
            + "that needs the reason written next to it, not a test edit."
        )
    }

    func testAConfinedChildThatWasNeverHandedAProfileIsCaught() {
        var children = healthyChildren()
        children[0] = child(pid: 101, type: "renderer", bundle: "Orbit Helper (Renderer)",
                            sandboxed: true, seatbeltClient: false)
        XCTAssertTrue(
            evaluate(children: children).contains { $0.invariant.contains("hands a Seatbelt profile") },
            "the second, independent reading of confinement did not fire. Measured on this machine, "
            + "every sandboxed Chromium child of seven shipping apps carried --seatbelt-client and "
            + "every unsandboxed one did not, so a child missing it while claiming to be confined is "
            + "a contradiction worth failing on."
        )
    }

    func testEverySandboxDisablingSwitchIsCaughtOnTheBrowserProcess() {
        for dangerous in SandboxDisablingSwitch.allCases {
            let violations = evaluate(
                browser: browser([dangerous.rawValue]),
                children: healthyChildren()
            )
            XCTAssertTrue(
                violations.contains { $0.offender.contains(dangerous.rawValue) },
                "\(dangerous.rawValue) on the browser command line was not caught, and it is silent: "
                + dangerous.consequence
            )
        }
    }

    func testASwitchWithAValueIsCaughtToo() {
        let violations = evaluate(
            browser: browser(["--remote-debugging-port=9222"]),
            children: healthyChildren()
        )
        XCTAssertTrue(
            violations.contains { $0.offender.contains("--remote-debugging-port") },
            "a switch written with =value escaped the matcher, which would let any of them through "
            + "by adding an argument."
        )
    }

    func testASwitchOnAChildIsCaughtEvenWhenTheBrowserIsClean() {
        var children = healthyChildren()
        children[0] = child(pid: 101, type: "renderer", bundle: "Orbit Helper (Renderer)",
                            extra: ["--disable-web-security"])
        XCTAssertTrue(
            evaluate(children: children).contains { $0.offender.contains("--disable-web-security") },
            "a switch reaching only the renderer was missed. Children do not always inherit the "
            + "browser's command line: some switches are appended per launch."
        )
    }

    func testTheCensusNamesEveryProcessSoAFailureCanBeActedOn() {
        let census = ProcessModelInvariant.census(browser: browser(), children: healthyChildren())
        XCTAssertTrue(census.contains("pid 101"), census)
        XCTAssertTrue(census.contains("NOT SANDBOXED") == false, census)
        XCTAssertTrue(
            ProcessModelInvariant.census(browser: browser(), children: []).contains("no child processes at all"),
            "an empty tree must say so in words: that is the single-process signature and the reader "
            + "needs to see it, not infer it from a blank list."
        )
    }

    // MARK: - The same invariants against a real running Orbit

    /// Skips while Orbit has no engine. It must never pass by finding nothing: a guard that is green because there was nothing to check is worse than no guard.
    func testARunningOrbitBrowserSatisfiesEveryProcessInvariant() throws {
        XCTAssertTrue(
            ProcessSandboxProbe.isAvailable,
            "sandbox_check is unreachable, so nothing below could distinguish a confined helper from "
            + "an unconfined one."
        )

        let override = ProcessInfo.processInfo.environment["ORBIT_SANDBOX_INVARIANT_PID"].flatMap(pid_t.init)
        let browsers = override.map { [ProcessSandboxProbe.probe(pid: $0)] }
            ?? ProcessSandboxProbe.runningOrbitBrowsers()

        let candidates = browsers.map { browser in
            (browser: browser, children: ProcessSandboxProbe.descendants(of: browser.pid))
        }
        guard let subject = candidates.first(where: { !$0.children.filter({ $0.role != .browser }).isEmpty }) else {
            throw XCTSkip(
                "PENDING ENGINE. No running Orbit browser process with engine child processes was found"
                + " (\(browsers.count) Orbit process(es) seen), so the runtime half of the sandbox"
                + " invariants is unverified on this run. This is not a pass. It becomes one, with no"
                + " code change here, as soon as the direct-Chromium engine spawns Helper, Helper"
                + " (Renderer) and Helper (GPU) processes: launch Orbit, load a page, and re-run, or"
                + " set ORBIT_SANDBOX_INVARIANT_PID to the browser process's pid from a harness. Until"
                + " then the invariants themselves are held by the synthetic trees above and by"
                + " Scripts/security-guards."
            )
        }

        // Whether a page really rendered cannot be observed from outside the process, so the
        // renderer and GPU presence checks are asserted only when a harness attests to it.
        let violations = ProcessModelInvariant.violations(
            browser: subject.browser,
            children: subject.children,
            renderedAPage: ProcessInfo.processInfo.environment["ORBIT_SANDBOX_INVARIANT_RENDERED"] == "1"
        )
        XCTAssertEqual(
            violations, [],
            violations.map(\.description).joined(separator: "\n\n")
            + "\n\n" + ProcessModelInvariant.census(browser: subject.browser, children: subject.children)
        )
    }
}
