import XCTest
@testable import Orbit

final class OrbitProcessMonitorTests: XCTestCase {

    // MARK: - Sampling the real tree

    func test_samplingFindsThisProcessWithARealMemoryFootprint() throws {
        let sample = OrbitProcessMonitor.sample()

        let ownProcess = try XCTUnwrap(
            sample.processes.first { $0.processID == getpid() },
            "The sample does not contain the process doing the sampling; \(sample.processes.count) rows were returned."
        )

        XCTAssertTrue(ownProcess.isBrowserProcess)
        XCTAssertEqual(ownProcess.role, .browser)
        XCTAssertGreaterThan(
            ownProcess.memoryFootprintBytes, 0,
            "phys_footprint came back as zero, which no running process has — proc_pid_rusage is not being read."
        )
        XCTAssertGreaterThan(
            ownProcess.cpuTimeNanoseconds, 0,
            "A process that has executed test code has consumed CPU time."
        )
    }

    func test_theFirstSampleReportsNoCPURateAtAll() {
        let sample = OrbitProcessMonitor.sample()

        for process in sample.processes {
            XCTAssertEqual(
                process.cpuPercent, 0,
                "Process \(process.processID) reported \(process.cpuPercent)% from a single sample, with nothing to have measured it against."
            )
        }
        XCTAssertFalse(sample.baseline.isEmpty, "The first sample must still hand back a baseline for the second to use.")
    }

    func test_asecondSampleMeasuresCPUActuallyConsumedBetweenTheTwo() throws {
        let first = OrbitProcessMonitor.sample()

        var accumulator = 0.0
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            for value in 0..<5_000 { accumulator += Double(value).squareRoot() }
        }
        XCTAssertGreaterThan(accumulator, 0, "Kept the optimiser from eliding the work above.")

        let second = OrbitProcessMonitor.sample(against: first.baseline)
        let ownProcess = try XCTUnwrap(second.processes.first { $0.processID == getpid() })

        XCTAssertGreaterThan(
            ownProcess.cpuPercent, 0,
            "This process spun a core for 150ms between the two samples and the monitor reported \(ownProcess.cpuPercent)%."
        )
        XCTAssertGreaterThan(
            ownProcess.cpuTimeNanoseconds,
            try XCTUnwrap(first.baseline.cpuTimeByProcessID[getpid()]),
            "The absolute CPU counter did not advance across the two samples."
        )
    }

    // MARK: - The rate arithmetic

    func test_cpuPercentReportsNothingRatherThanGuessingWhenItCannotBeMeasured() {
        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: nil, currentCPUTime: 5_000_000, elapsedNanoseconds: 1_000_000_000), 0,
            "With no previous reading there is nothing to difference."
        )
        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: 0, currentCPUTime: 5_000_000, elapsedNanoseconds: 0), 0,
            "Zero elapsed time would divide by zero."
        )
        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: 9_000_000, currentCPUTime: 1_000_000, elapsedNanoseconds: 1_000_000_000), 0,
            "A counter that went backwards means the pid was recycled; the difference is meaningless, not negative."
        )
    }

    func test_cpuPercentIsAShareOfOneCoreAndIsNotClampedAtOneHundred() {
        let oneSecond: UInt64 = 1_000_000_000

        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: 0, currentCPUTime: oneSecond, elapsedNanoseconds: oneSecond),
            100, accuracy: 0.0001
        )
        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: 0, currentCPUTime: oneSecond / 2, elapsedNanoseconds: oneSecond),
            50, accuracy: 0.0001
        )
        XCTAssertEqual(
            OrbitProcessMonitor.cpuPercent(previousCPUTime: 0, currentCPUTime: oneSecond * 2, elapsedNanoseconds: oneSecond),
            200, accuracy: 0.0001,
            "A multi-threaded renderer genuinely exceeds one core, and clamping it would hide exactly the case this window is for."
        )
    }

    // MARK: - Roles

    func test_helperBundleNamesClassifyIntoTheirRoles() {
        let expected: [(String, OrbitProcessInfo.Role)] = [
            ("Orbit Helper (Renderer)", .renderer),
            ("Orbit Helper (GPU)", .gpu),
            ("Orbit Helper (Plugin)", .plugin),
            ("Orbit Helper (Alerts)", .alerts),
            ("Orbit Helper", .helper),
            ("some-other-binary", .other),
        ]

        for (name, role) in expected {
            XCTAssertEqual(
                OrbitProcessInfo.Role.forExecutableName(name, isBrowserProcess: false), role,
                "\(name) classified as \(OrbitProcessInfo.Role.forExecutableName(name, isBrowserProcess: false)) rather than \(role)."
            )
        }
    }

    func test_theBrowserProcessIsClassifiedByItsIdentityNotItsName() {
        XCTAssertEqual(
            OrbitProcessInfo.Role.forExecutableName("Orbit Helper (Renderer)", isBrowserProcess: true), .browser
        )
    }

    // MARK: - Ordering

    func test_orderingPutsTheBrowserFirstThenTheHeaviest() {
        func process(_ pid: pid_t, _ role: OrbitProcessInfo.Role, memory: UInt64) -> OrbitProcessInfo {
            OrbitProcessInfo(
                processID: pid,
                executableName: "x",
                role: role,
                memoryFootprintBytes: memory,
                cpuTimeNanoseconds: 0,
                cpuPercent: 0
            )
        }

        let sorted = OrbitProcessMonitor.sorted([
            process(30, .renderer, memory: 100),
            process(10, .browser, memory: 1),
            process(20, .gpu, memory: 900),
        ])

        XCTAssertEqual(sorted.map(\.processID), [10, 20, 30])
    }

    // MARK: - End Process

    /// This calls the real endProcess, which really would SIGKILL; it is safe
    /// only because the refusal is checked first — if that guard regressed,
    /// this test would kill the test runner.
    func test_endingTheBrowserProcessIsRefusedAndNothingIsSignalled() {
        XCTAssertEqual(OrbitProcessMonitor.refusalForEndingProcess(getpid()), .isBrowserProcess)
        XCTAssertEqual(OrbitProcessMonitor.endProcess(getpid()), .isBrowserProcess)
        XCTAssertNotEqual(getpid(), 0, "Still running, so nothing was signalled.")
    }

    /// `1` is launchd, which this process could not kill even if the guard
    /// were gone, so a regression here cannot damage the machine.
    func test_endingAProcessOrbitDoesNotOwnIsRefused() {
        XCTAssertEqual(OrbitProcessMonitor.refusalForEndingProcess(1), .notAnOrbitProcess)
        XCTAssertEqual(OrbitProcessMonitor.endProcess(1), .notAnOrbitProcess)
    }

    func test_theProcessListAlwaysContainsThisProcessAndNotLaunchd() {
        let identifiers = OrbitProcessMonitor.processIdentifiers()

        XCTAssertTrue(identifiers.contains(getpid()))
        XCTAssertFalse(identifiers.contains(1), "launchd is not a child of Orbit and must never be offered for ending.")
    }

    // MARK: - Formatting

    /// Asserted only as "names a unit and a non-zero figure", never an exact
    /// string — ByteCountFormatter is locale-sensitive.
    func test_memoryFootprintIsFormattedInBinaryUnits() {
        let process = OrbitProcessInfo(
            processID: 42,
            executableName: "Orbit Helper (GPU)",
            role: .gpu,
            memoryFootprintBytes: 512 * 1024 * 1024,
            cpuTimeNanoseconds: 0,
            cpuPercent: 0
        )

        let text = process.memoryFootprintText
        XCTAssertTrue(text.contains("MB") || text.contains("GB"), "Unexpected unit in \(text).")
        XCTAssertTrue(text.contains(where: \.isNumber), "No figure in \(text).")
    }

    func test_smallCPUSharesAreNotRoundedAwayToZero() {
        let process = OrbitProcessInfo(
            processID: 42,
            executableName: "Orbit Helper (Renderer)",
            role: .renderer,
            memoryFootprintBytes: 0,
            cpuTimeNanoseconds: 0,
            cpuPercent: 0.4
        )

        XCTAssertNotEqual(process.cpuPercentText, "0.0%", "0.4% was rounded down to nothing.")
        XCTAssertTrue(process.cpuPercentText.hasSuffix("%"))
    }
}

// MARK: - The window's model

@MainActor
final class TaskManagerModelTests: XCTestCase {

    func test_endProcessIsUnavailableUntilATaskIsSelected() {
        let model = TaskManagerModel()
        model.refresh()

        XCTAssertNil(model.selectedProcess)
        XCTAssertFalse(model.canEndSelectedProcess)
        XCTAssertEqual(model.endProcessRefusal, .notAnOrbitProcess)
    }

    func test_selectingOrbitsOwnRowStillLeavesEndProcessUnavailable() {
        let model = TaskManagerModel()
        model.refresh()

        model.selectedProcessID = getpid()

        XCTAssertEqual(model.selectedProcess?.role, .browser, "Precondition: Orbit's own row is in the list.")
        XCTAssertEqual(model.endProcessRefusal, .isBrowserProcess)
        XCTAssertFalse(model.canEndSelectedProcess)
        XCTAssertEqual(model.endSelectedProcess(), .isBrowserProcess, "The model attempted to end Orbit itself.")
    }

    func test_aSelectionThatNoLongerExistsIsClearedOnRefresh() {
        let model = TaskManagerModel()
        model.refresh()

        model.selectedProcessID = pid_t(Int32.max)
        model.refresh()

        XCTAssertNil(model.selectedProcessID, "A stale selection survived a refresh.")
        XCTAssertFalse(model.canEndSelectedProcess)
    }

    func test_cpuIsReportedAsUnmeasuredUntilASecondRefreshHasHappened() {
        let model = TaskManagerModel()

        model.refresh()
        XCTAssertFalse(model.hasMeasuredCPU, "A single sample cannot have measured a rate.")

        model.refresh()
        XCTAssertTrue(model.hasMeasuredCPU)
    }

    func test_theListIsTheRealProcessTreeWithOrbitFirst() throws {
        let model = TaskManagerModel()
        model.refresh()

        XCTAssertFalse(model.processes.isEmpty)
        XCTAssertEqual(
            model.processes.first?.processID, getpid(),
            "Orbit's own process is not the first row."
        )
        XCTAssertEqual(
            Set(model.processes.map(\.processID)).count, model.processes.count,
            "The same process appears twice."
        )
    }
}
