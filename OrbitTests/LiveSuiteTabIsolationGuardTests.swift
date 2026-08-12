//  Host-less: reads only the live suites' own sources. Live suites share one process,
//  engine and OrbitTabRegistry, so closing a tab without subclassing LiveEnvironmentTestCase
//  leaks live tabs into every later suite's chrome.tabs.query count.

import XCTest

final class LiveSuiteTabIsolationGuardTests: XCTestCase {

    private static let liveTestsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("OrbitAppTests")

    /// The same marker Scripts/live-engine-tests uses to decide a file is a
    /// live suite, so a suite cannot be one for the runner and not for this.
    private static let liveGateMarker = "LiveChromiumEngineHost.isEnabled"

    private static let tabMutations = [".openTab(", ".closeTab(", ".closeTabKeepingBookmark(", ".archiveTab("]

    private static let isolatedBases = [": LiveEnvironmentTestCase {", ": CorpusLiveTestCase {"]

    /// file name -> source, for every live suite that drives AppEnvironment's own tabs.
    private func liveSuitesDrivingTabs() throws -> [(name: String, text: String)] {
        var found: [(name: String, text: String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.liveTestsDirectory.path).sorted()
        where name.hasSuffix(".swift") {
            let text = try String(
                contentsOf: Self.liveTestsDirectory.appendingPathComponent(name), encoding: .utf8
            )
            guard text.contains(Self.liveGateMarker) else { continue }
            guard Self.tabMutations.contains(where: { text.contains($0) }) else { continue }
            found.append((name, text))
        }
        return found
    }

    func test_everyLiveSuiteThatOpensOrClosesTabsIsIsolatedFromTheRestOfThePass() throws {
        let suites = try liveSuitesDrivingTabs()
        XCTAssertGreaterThan(
            suites.count, 8,
            "found only \(suites.count) live suites driving AppEnvironment tabs, so discovery has stopped matching and this guard tests nothing"
        )

        let unisolated = suites
            .filter { suite in !Self.isolatedBases.contains(where: { suite.text.contains($0) }) }
            .map { $0.name }
        XCTAssertEqual(
            unisolated, [],
            """
            these live suites open or close AppEnvironment tabs without subclassing LiveEnvironmentTestCase. \
            Closing a tab materialises the successor BrowserStore picks, so such a suite brings the demo \
            document's own tabs to life against real sites and leaves them in the process-wide \
            OrbitTabRegistry, where every later suite's chrome.tabs.query counts them and fails instead. \
            Declare the class `: LiveEnvironmentTestCase` (or `: CorpusLiveTestCase`, which is one) and use its `env`.
            """
        )
    }

    func test_noLiveSuiteBuildsItsOwnDemoEnvironmentAlongsideTheIsolatedOne() throws {
        let ownEnvironment = try liveSuitesDrivingTabs()
            .filter { $0.text.contains("AppEnvironment.demo") }
            .map { $0.name }
        XCTAssertEqual(
            ownEnvironment, [],
            """
            these live suites build their own AppEnvironment.demo. Its document ships spaces already full of \
            tabs pointing at real sites, and the first close in the suite activates one of them, so the suite \
            measures — and leaves behind — tabs it never opened. Use LiveEnvironmentTestCase's `env`, whose \
            document starts with no open tabs at all.
            """
        )
    }

    func test_corpusSuitesInheritTheSameIsolation() throws {
        let text = try String(
            contentsOf: Self.liveTestsDirectory.appendingPathComponent("Support/CorpusLiveTestCase.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            text.contains("class CorpusLiveTestCase: LiveEnvironmentTestCase {"),
            "CorpusLiveTestCase no longer inherits LiveEnvironmentTestCase, so every corpus suite has quietly lost the tab, window and content-blocker isolation the rest of the pass relies on"
        )
    }
}
