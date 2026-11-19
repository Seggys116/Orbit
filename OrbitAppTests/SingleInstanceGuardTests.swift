import XCTest

@testable import Orbit

final class SingleInstanceGuardTests: XCTestCase {

    private let bundleID = OrbitRuntimeScope.productionBundleIdentifier
    private let installed = URL(fileURLWithPath: "/Applications/Orbit.app")

    func testAnotherCopyOfTheSameBundleIsAConflict() {
        let other = SingleInstanceGuard.Instance(processIdentifier: 200, bundleIdentifier: bundleID, bundleURL: installed)
        XCTAssertEqual(
            SingleInstanceGuard.conflictingInstance(selfPID: 100, bundleIdentifier: bundleID, bundleURL: installed, running: [other]),
            other
        )
    }

    func testItselfIsNeverAConflict() {
        let me = SingleInstanceGuard.Instance(processIdentifier: 100, bundleIdentifier: bundleID, bundleURL: installed)
        XCTAssertNil(SingleInstanceGuard.conflictingInstance(selfPID: 100, bundleIdentifier: bundleID, bundleURL: installed, running: [me]))
    }

    func testADevelopmentBuildElsewhereMayRunAlongsideTheInstalledApp() {
        let devBuild = SingleInstanceGuard.Instance(
            processIdentifier: 200, bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/Orbit.app")
        )
        XCTAssertNil(SingleInstanceGuard.conflictingInstance(selfPID: 100, bundleIdentifier: bundleID, bundleURL: installed, running: [devBuild]))
    }

    func testTrailingSlashAndDotSegmentsStillMatch() {
        let other = SingleInstanceGuard.Instance(
            processIdentifier: 200, bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/./Orbit.app/")
        )
        XCTAssertNotNil(SingleInstanceGuard.conflictingInstance(selfPID: 100, bundleIdentifier: bundleID, bundleURL: installed, running: [other]))
    }

    func testAnUnidentifiedBundleNeverBlocksLaunch() {
        let other = SingleInstanceGuard.Instance(processIdentifier: 200, bundleIdentifier: nil, bundleURL: installed)
        XCTAssertNil(SingleInstanceGuard.conflictingInstance(selfPID: 100, bundleIdentifier: nil, bundleURL: installed, running: [other]))
    }
}
