import XCTest

final class UpdaterPreferencesTests: XCTestCase {

    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitTests-UpdaterPreferences-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        UpdaterPreferences.defaults = scratchDefaults
    }

    override func tearDown() {
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        UpdaterPreferences.defaults = OrbitDefaults.standard
        super.tearDown()
    }

    func test_freshInstall_isPrereleaseChannelEnabled_defaultsToFalse() {
        XCTAssertFalse(UpdaterPreferences.isPrereleaseChannelEnabled)
    }

    func test_settingTrue_persistsAndReadsBackTrue() {
        UpdaterPreferences.isPrereleaseChannelEnabled = true
        XCTAssertTrue(UpdaterPreferences.isPrereleaseChannelEnabled)

        UpdaterPreferences.isPrereleaseChannelEnabled = false
        XCTAssertFalse(UpdaterPreferences.isPrereleaseChannelEnabled, "toggling back off must actually clear the stored value, not just the in-memory read")
    }

    func test_theStoredKey_isTheRealExportedConstant() {
        XCTAssertEqual(UpdaterPreferences.prereleaseChannelEnabledKey, "OrbitUpdaterPrereleaseChannelEnabled")

        UpdaterPreferences.isPrereleaseChannelEnabled = true

        XCTAssertTrue(
            scratchDefaults.bool(forKey: UpdaterPreferences.prereleaseChannelEnabledKey),
            "UpdaterPreferences.isPrereleaseChannelEnabled must write under its own exported key, or a reader binding to the constant (as the real app does) would never see this write."
        )
    }

    func test_theValue_survivesAReadBackFromAFreshDefaultsHandle() {
        UpdaterPreferences.isPrereleaseChannelEnabled = true

        let reopened = UserDefaults(suiteName: defaultsSuiteName)!
        XCTAssertTrue(reopened.bool(forKey: UpdaterPreferences.prereleaseChannelEnabledKey))
    }

    func test_writingThePreference_touchesNoSparkleOwnedKey() {
        UpdaterPreferences.isPrereleaseChannelEnabled = true
        for sparkleOwnedKey in ["SUEnableAutomaticChecks", "SULastCheckTime", "SUHasLaunchedBefore"] {
            XCTAssertNil(
                scratchDefaults.object(forKey: sparkleOwnedKey),
                "UpdaterPreferences wrote to \(sparkleOwnedKey), a key Sparkle itself owns — this file's header is explicit that automatic-check and last-check-date state must stay a pass-through to SPUUpdater, never a second, driftable copy."
            )
        }
    }
}
