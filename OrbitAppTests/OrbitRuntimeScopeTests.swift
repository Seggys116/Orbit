import Foundation
import XCTest
@testable import Orbit

@MainActor
final class OrbitRuntimeScopeTests: XCTestCase {

    private static let productionIdentifier = OrbitRuntimeScope.productionBundleIdentifier
    private static let demoIdentifier = "com.zak-noble-clarke.OrbitDemo"
    private static let installedPath = "/Applications/Orbit.app"
    private static let derivedDataPath =
        "/Users/example/Library/Developer/Xcode/DerivedData/Orbit-abcdef/Build/Products/Debug/Orbit.app"
    private static let buildProductsPath = "/Users/example/Orbit/Build/Products/Debug/Orbit.app"

    private func scope(
        identifier: String? = OrbitRuntimeScopeTests.productionIdentifier,
        path: String = OrbitRuntimeScopeTests.installedPath,
        _ environment: [String: String] = [:]
    ) -> OrbitRuntimeScope {
        OrbitRuntimeScope.resolve(
            bundleIdentifier: identifier,
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            environment: environment
        )
    }

    // MARK: - Nothing a test bundle can set reaches production

    func testAHostedTestBundleIsTestNoMatterWhatElseIsSet() {
        XCTAssertEqual(
            scope(["XCTestConfigurationFilePath": "/tmp/probe.xctestconfiguration"]),
            .test,
            "an installed bundle at \(Self.installedPath) still hosts a test bundle here"
        )
        XCTAssertEqual(
            scope([
                "XCTestConfigurationFilePath": "/tmp/probe.xctestconfiguration",
                OrbitRuntimeScope.overrideEnvironmentName: "production",
                "ORBIT_WEBSTORE_PROBE": "1",
                "ORBIT_PROBE_REAL_PROFILE": "1",
            ]),
            .test,
            "no switch reachable from a test bundle may resolve to the real user's data"
        )
    }

    func testTheSmokeProbeIsTest() {
        XCTAssertEqual(scope(["ORBIT_SMOKE_PROBE": "1"]), .test)
        XCTAssertEqual(
            scope(["ORBIT_SMOKE_PROBE": "1", OrbitRuntimeScope.overrideEnvironmentName: "production"]),
            .test
        )
        XCTAssertEqual(scope(["ORBIT_SMOKE_PROBE": "0"]), .production, "only the exact value arms the probe")
    }

    func testTheWebStoreProbeIsTestUntilItOptsIntoTheRealProfile() {
        XCTAssertEqual(scope(["ORBIT_WEBSTORE_PROBE": "1"]), .test)
        XCTAssertEqual(scope(["ORBIT_WEBSTORE_PROBE": ""]), .test, "the variable being present at all arms the probe")
        XCTAssertEqual(
            scope(["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": "1"]),
            .production,
            "verifying a Web Store install against the profile the user browses with must keep working"
        )
        XCTAssertEqual(
            scope(path: Self.derivedDataPath, ["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": "1"]),
            .production,
            "the opt-in outranks the build-product path, which is where that probe is run from"
        )
        XCTAssertEqual(
            scope(identifier: Self.demoIdentifier, ["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": "1"]),
            .development,
            "the opt-in belongs to the real bundle only"
        )
    }

    func testTheRealProfileOptInTakesOnlyATruthyValue() {
        for value in ["1", "true", "TRUE", "True", "yes", "YES", "on", "  on  ", " True "] {
            XCTAssertEqual(
                scope(["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": value]),
                .production,
                "ORBIT_PROBE_REAL_PROFILE=\(value) is a yes and must reach the real profile"
            )
        }
        for value in ["", " ", "0", "no", "off", "false", "2", "banana", "1 1", "yes please"] {
            XCTAssertEqual(
                scope(["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": value]),
                .test,
                "ORBIT_PROBE_REAL_PROFILE=\(value) is not a yes, and this is the one flag that reaches the user's real data"
            )
        }
    }

    func testTheDataScopeOverrideIsReadBeforeTheWebStoreProbeCanReturnProduction() {
        let probe = ["ORBIT_WEBSTORE_PROBE": "1", "ORBIT_PROBE_REAL_PROFILE": "1"]

        XCTAssertEqual(scope(probe), .production, "the baseline the override has to be able to demote")

        let demotions: [(String, OrbitRuntimeScope)] = [
            ("test", .test),
            ("scratch", .test),
            ("development", .development),
            ("dev", .development),
            ("production", .production),
        ]
        for (value, wanted) in demotions {
            XCTAssertEqual(
                scope(probe.merging([OrbitRuntimeScope.overrideEnvironmentName: value]) { _, new in new }),
                wanted,
                "\(OrbitRuntimeScope.overrideEnvironmentName)=\(value) has to demote a Web Store probe that opted into the real profile"
            )
        }
    }

    // MARK: - Bundle identity

    func testAnyBundleThatIsNotTheRealBrowserIsDevelopment() {
        XCTAssertEqual(scope(identifier: Self.demoIdentifier), .development)
        XCTAssertEqual(
            scope(identifier: Self.demoIdentifier, [OrbitRuntimeScope.overrideEnvironmentName: "production"]),
            .development,
            "a second bundle installed at \(Self.installedPath) still is not the real browser"
        )
        XCTAssertEqual(scope(identifier: nil), .development)
        XCTAssertEqual(scope(identifier: ""), .development)
        XCTAssertEqual(scope(identifier: Self.productionIdentifier + ".helper"), .development)
    }

    func testTheInstalledBrowserWithACleanEnvironmentIsProduction() {
        XCTAssertEqual(scope(), .production, "the shipping browser must still find the user's real data")
    }

    // MARK: - Where the bundle was launched from

    func testABundleRunningOutOfABuildDirectoryIsDevelopment() {
        XCTAssertEqual(scope(path: Self.derivedDataPath), .development)
        XCTAssertEqual(scope(path: Self.buildProductsPath), .development)
    }

    func testAnXcodeLaunchIsDevelopmentEvenFromTheInstalledPath() {
        XCTAssertEqual(
            scope(["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/Users/example/Build/Products/Debug"]),
            .development
        )
        XCTAssertEqual(scope(["XCODE_VERSION_ACTUAL": "1640"]), .development)
    }

    func testLaunchdsInheritedDYLDVariablesDoNotDemoteTheInstalledBrowser() {
        XCTAssertEqual(
            scope(["__XPC_DYLD_LIBRARY_PATH": "/usr/local/lib"]),
            .production,
            "a machine-wide launchctl setenv must not hide the user's data behind a development scope"
        )
        XCTAssertEqual(
            scope(["__XPC_DYLD_FRAMEWORK_PATH": "/Library/Frameworks"]),
            .production,
            "a machine-wide launchctl setenv must not hide the user's data behind a development scope"
        )
        let both = [
            "__XPC_DYLD_LIBRARY_PATH": "/usr/local/lib",
            "__XPC_DYLD_FRAMEWORK_PATH": "/Users/example/Build/Products/Debug",
        ]
        XCTAssertEqual(scope(both), .production)
        XCTAssertFalse(
            OrbitRuntimeScope.isLaunchedByXcode(both),
            "only variables Xcode alone sets may count as an Xcode launch"
        )
    }

    func testAnEmptyValuedVariableIsNotAnXcodeLaunch() {
        XCTAssertFalse(OrbitRuntimeScope.isLaunchedByXcode(["XCODE_VERSION_ACTUAL": ""]))
        XCTAssertFalse(OrbitRuntimeScope.isLaunchedByXcode(["__XCODE_BUILT_PRODUCTS_DIR_PATHS": ""]))
        XCTAssertFalse(OrbitRuntimeScope.isLaunchedByXcode([:]))
        XCTAssertFalse(OrbitRuntimeScope.isLaunchedByXcode(["DYLD_FRAMEWORK_PATH": "/somewhere"]))
        XCTAssertEqual(scope(["XCODE_VERSION_ACTUAL": ""]), .production)
    }

    // MARK: - The override

    func testTheOverrideNamesEachScope() {
        let expected: [String: OrbitRuntimeScope] = [
            "production": .production,
            "development": .development,
            "dev": .development,
            "test": .test,
            "scratch": .test,
            "  Development  ": .development,
            "TEST": .test,
        ]
        for (value, wanted) in expected {
            XCTAssertEqual(
                scope([OrbitRuntimeScope.overrideEnvironmentName: value]),
                wanted,
                "\(OrbitRuntimeScope.overrideEnvironmentName)=\(value)"
            )
        }
    }

    func testAnUnrecognisedOverrideFallsThroughToTheNormalRules() {
        XCTAssertEqual(scope([OrbitRuntimeScope.overrideEnvironmentName: "banana"]), .production)
        XCTAssertEqual(scope([OrbitRuntimeScope.overrideEnvironmentName: ""]), .production)
        XCTAssertEqual(
            scope(path: Self.derivedDataPath, [OrbitRuntimeScope.overrideEnvironmentName: "banana"]),
            .development
        )
    }

    func testTheOverrideOutranksABuildProductPath() {
        XCTAssertEqual(
            scope(path: Self.derivedDataPath, [OrbitRuntimeScope.overrideEnvironmentName: "production"]),
            .production,
            "the documented escape hatch for debugging against the real profile"
        )
    }

    // MARK: - Build-product detection

    func testIsBuildProductNeedsBuildFollowedByProducts() {
        XCTAssertTrue(OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: Self.derivedDataPath)))
        XCTAssertTrue(OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: Self.buildProductsPath)))
        XCTAssertTrue(
            OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: "/Users/example/DerivedData/Orbit/Orbit.app"))
        )
        XCTAssertFalse(
            OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: "/Users/example/Build/Debug/Orbit.app")),
            "a directory merely called Build is not an Xcode products directory"
        )
        XCTAssertFalse(
            OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: "/Users/example/Products/Build/Orbit.app")),
            "the order matters: Products then Build is somebody else's layout"
        )
        XCTAssertFalse(OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: Self.installedPath)))
        XCTAssertFalse(OrbitRuntimeScope.isBuildProduct(URL(fileURLWithPath: "/Users/example/Build")))
    }

    // MARK: - The live process

    func testTheLiveScopeInThisProcessIsTest() {
        XCTAssertEqual(
            OrbitRuntimeScope.current,
            .test,
            "every guard that keeps a test run off the user's data hangs off this one value"
        )
        XCTAssertFalse(OrbitRuntimeScope.current.isProduction)
    }
}
