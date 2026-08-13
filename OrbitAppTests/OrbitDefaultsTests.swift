import Foundation
import XCTest
@testable import Orbit

@MainActor
final class OrbitDefaultsTests: XCTestCase {

    /// Above PID_MAX (99999 on macOS), so no process can ever hold it.
    private static let unusableProcessID: pid_t = 2_000_000_000

    private var scratchRoot: URL!
    private var writtenKeys: [(UserDefaults, String)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitDefaultsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for (defaults, key) in writtenKeys {
            defaults.removeObject(forKey: key)
        }
        writtenKeys.removeAll()
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try FileManager.default.removeItem(at: scratchRoot)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Which defaults each scope gets

    func testStandardUnderXCTestIsNotTheRealBrowsersDefaults() throws {
        let defaults = OrbitDefaults.standard
        try requireScoped(defaults, what: "OrbitDefaults.standard")

        let key = write("probe", through: defaults)

        XCTAssertEqual(defaults.string(forKey: key), "probe", "a scoped suite still has to store what it is given")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "a value written under XCTest reached the real browser's own preferences"
        )
    }

    func testOnlyTheInstalledBrowserGetsTheRealPreferences() {
        XCTAssertTrue(
            OrbitDefaults.make(for: .production) === UserDefaults.standard,
            "the shipping browser must keep reading and writing the preferences it always has"
        )
    }

    func testDevelopmentGetsOneStableSuiteOfItsOwn() throws {
        try requireScoped(OrbitDefaults.make(for: .development), what: "the development suite")

        XCTAssertEqual(
            OrbitDefaults.developmentSuiteName(bundleIdentifier: "com.example.probe.OrbitStabilityProbe"),
            OrbitRuntimeScope.productionBundleIdentifier + ".development-OrbitStabilityProbe",
            "a build launched from Xcode keeps its settings across relaunches, so the name is fixed by the identifier and nothing else"
        )
        XCTAssertNotEqual(
            OrbitDefaults.developmentSuiteName(bundleIdentifier: "com.example.probe.OrbitStabilityProbe"),
            OrbitRuntimeScope.productionBundleIdentifier,
            "the development suite must never be the installed browser's own domain"
        )
    }

    func testTwoBundlesGetTwoDevelopmentSuites() {
        let prefix = OrbitRuntimeScope.productionBundleIdentifier + ".development-"
        let orbit = OrbitDefaults.developmentSuiteName(bundleIdentifier: "com.example.probe.Orbit")
        let demo = OrbitDefaults.developmentSuiteName(bundleIdentifier: "com.example.probe.OrbitDemo")

        XCTAssertNotEqual(
            orbit, demo,
            "the demo and an Xcode-run Orbit are two browsers and must not write each other's settings"
        )
        XCTAssertEqual(orbit, prefix + "Orbit", "the same identifier has to name the same suite every launch")
        XCTAssertEqual(demo, prefix + "OrbitDemo", "the same identifier has to name the same suite every launch")

        XCTAssertEqual(
            OrbitDefaults.developmentSuiteName(bundleIdentifier: nil),
            prefix + "Orbit",
            "a bundle with no identifier falls back to the real browser's last path component"
        )
        XCTAssertEqual(
            OrbitDefaults.developmentSuiteName(bundleIdentifier: ""),
            prefix + OrbitRuntimeScope.productionBundleIdentifier,
            "an empty identifier has no last component to name the suite after"
        )
    }

    func testEveryTestScopeGetsItsOwnThrowawaySuite() throws {
        let first = OrbitDefaults.make(for: .test)
        let second = OrbitDefaults.make(for: .test)
        try requireScoped(first, what: "the first test suite")
        try requireScoped(second, what: "the second test suite")
        XCTAssertFalse(first === second)

        let key = write("probe", through: first)

        XCTAssertEqual(first.string(forKey: key), "probe")
        XCTAssertNil(second.string(forKey: key), "each test run is named after its pid and a fresh UUID, so no two share a domain")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    // MARK: - Ownership parsing

    func testOwnerProcessIDReadsThePidOutOfANameThisTypeProduced() {
        let name = "\(OrbitDefaults.testSuitePrefix)\(getpid())-\(UUID().uuidString)"
        XCTAssertEqual(OrbitDefaults.ownerProcessID(ofSuiteNamed: name), getpid())

        let other = "\(OrbitDefaults.testSuitePrefix)\(Self.unusableProcessID)-\(UUID().uuidString)"
        XCTAssertEqual(OrbitDefaults.ownerProcessID(ofSuiteNamed: other), Self.unusableProcessID)
    }

    func testOwnerProcessIDRejectsAnythingThisTypeDidNotProduce() {
        let uuid = UUID().uuidString
        let prefix = OrbitDefaults.testSuitePrefix
        for name in [
            "",
            "com.apple.something",
            OrbitRuntimeScope.productionBundleIdentifier,
            OrbitDefaults.developmentSuiteName(),
            OrbitDefaults.developmentSuiteName(bundleIdentifier: "com.example.probe.OrbitDemo"),
            "\(OrbitRuntimeScope.productionBundleIdentifier).test\(getpid())-\(uuid)",
            "\(prefix)\(uuid)",
            "\(prefix)notanumber-\(uuid)",
            "\(prefix)0-\(uuid)",
            "\(prefix)-1-\(uuid)",
            "\(prefix)\(getpid())",
            "\(prefix)\(getpid())-not-a-uuid",
            "\(prefix)\(getpid())-",
        ] {
            XCTAssertNil(
                OrbitDefaults.ownerProcessID(ofSuiteNamed: name),
                "\(name) is not one of this type's suites and must never be a deletion candidate"
            )
        }
    }

    // MARK: - Cleanup

    func testAnImpossiblePidIsNotAlive() {
        XCTAssertTrue(OrbitProcessLiveness.isAlive(getpid()))
        XCTAssertFalse(OrbitProcessLiveness.isAlive(Self.unusableProcessID))
    }

    func testAbandonedTestSuitesAreRemovedAndEverythingElseIsKept() throws {
        try XCTSkipIf(OrbitProcessLiveness.isAlive(Self.unusableProcessID), "pid \(Self.unusableProcessID) is alive")

        let fileManager = FileManager.default
        let uuid = UUID().uuidString
        let prefix = OrbitDefaults.testSuitePrefix

        let abandoned = try makeScratchPlist(named: "\(prefix)\(Self.unusableProcessID)-\(uuid).plist")
        let mine = try makeScratchPlist(named: "\(prefix)\(getpid())-\(uuid).plist")
        let development = try makeScratchPlist(named: "\(OrbitDefaults.developmentSuiteName()).plist")
        let foreign = try makeScratchPlist(named: "com.example.SomeoneElse.plist")
        let notAPlist = try makeScratchPlist(named: "\(prefix)\(Self.unusableProcessID)-\(uuid).txt")
        let directory = scratchRoot.appendingPathComponent(
            "\(prefix)\(Self.unusableProcessID)-\(UUID().uuidString).plist", isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        OrbitDefaults.removeAbandonedTestSuites(in: scratchRoot)

        XCTAssertFalse(fileManager.fileExists(atPath: abandoned.path), "a dead process's suite is dead weight")
        XCTAssertTrue(fileManager.fileExists(atPath: mine.path), "this process is still using its own suite")
        XCTAssertTrue(fileManager.fileExists(atPath: development.path), "the development suite outlives every run")
        XCTAssertTrue(fileManager.fileExists(atPath: foreign.path), "nothing outside this type's naming may be touched")
        XCTAssertTrue(fileManager.fileExists(atPath: notAPlist.path), "only .plist entries are candidates")

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            "a directory named like an abandoned suite is not a preferences file and must never be deleted"
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Helpers

    private struct NotScoped: Error {}

    /// Fails rather than skips: defaults that are still `UserDefaults.standard`
    /// are the bug, and every caller returns without writing when this throws.
    private func requireScoped(_ defaults: UserDefaults, what: String) throws {
        guard defaults === UserDefaults.standard else { return }
        XCTFail("\(what) is UserDefaults.standard — refusing to write through it")
        throw NotScoped()
    }

    private func write(_ value: String, through defaults: UserDefaults) -> String {
        let key = "OrbitDefaultsTests-\(UUID().uuidString)"
        defaults.set(value, forKey: key)
        writtenKeys.append((defaults, key))
        return key
    }

    private func makeScratchPlist(named name: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent(name, isDirectory: false)
        let contents = try PropertyListSerialization.data(
            fromPropertyList: ["probe": true], format: .binary, options: 0
        )
        try contents.write(to: url)
        return url
    }
}
