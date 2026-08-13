import Foundation
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class DeveloperModePersistenceTests: XCTestCase {

    private var suiteName: String!
    private var writingStore: UserDefaults!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-DeveloperMode-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        DeveloperModeSettings.defaults = writingStore
    }

    override func tearDown() {
        writingStore?.removePersistentDomain(forName: suiteName)
        DeveloperModeSettings.defaults = OrbitDefaults.standard
        writingStore = nil
        suiteName = nil
        super.tearDown()
    }

    private func reloadedStore() -> UserDefaults {
        writingStore.synchronize()
        guard let reloaded = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not construct a second UserDefaults over suite \(suiteName!).")
            return .standard
        }
        return reloaded
    }

    // MARK: - The defect itself

    func test_togglingDeveloperMode_writesThroughToPersistentStorage() {
        XCTAssertNil(
            writingStore.object(forKey: DeveloperModeSettings.defaultsKey),
            "test precondition: the scratch suite starts with nothing stored"
        )

        DeveloperModeSettings.toggle()

        XCTAssertEqual(
            reloadedStore().object(forKey: DeveloperModeSettings.defaultsKey) as? Bool, true,
            """
            Turning Developer Mode on stored nothing. This is the reported defect: the row flipped a \
            local @State only, so the setting vanished when the popover closed.
            """
        )
    }

    func test_developerModeOn_survivesAReload() {
        DeveloperModeSettings.toggle()
        XCTAssertTrue(DeveloperModeSettings.isEnabled, "test precondition: it is on before the reload")

        DeveloperModeSettings.defaults = reloadedStore()

        XCTAssertTrue(
            DeveloperModeSettings.isEnabled,
            "Developer Mode was on when it was stored and must still be on after a reload."
        )
    }

    func test_developerModeOff_survivesAReload() {
        DeveloperModeSettings.toggle()
        DeveloperModeSettings.defaults = reloadedStore()
        XCTAssertTrue(DeveloperModeSettings.isEnabled, "test precondition: on, and persisted")

        DeveloperModeSettings.toggle()
        DeveloperModeSettings.defaults = reloadedStore()

        XCTAssertFalse(
            DeveloperModeSettings.isEnabled,
            "Turning Developer Mode off must persist as off, not fall back to whatever was stored before."
        )
        XCTAssertEqual(
            DeveloperModeSettings.defaults.object(forKey: DeveloperModeSettings.defaultsKey) as? Bool, false,
            "\"Off\" must be an explicitly stored false, not an absent key that only looks false by default."
        )
    }

    func test_toggleReturnsThePersistedValue() {
        let afterFirst = DeveloperModeSettings.toggle()
        XCTAssertEqual(
            afterFirst,
            reloadedStore().bool(forKey: DeveloperModeSettings.defaultsKey),
            "toggle()'s return value must be what was stored — the row displays it."
        )

        let afterSecond = DeveloperModeSettings.toggle()
        XCTAssertEqual(afterSecond, reloadedStore().bool(forKey: DeveloperModeSettings.defaultsKey))
        XCTAssertNotEqual(afterFirst, afterSecond, "Two toggles must land on two different values.")
    }

    func test_captureOverlaysDeveloperModeReadIsTheSamePersistedValue() {
        DeveloperModeSettings.toggle()
        DeveloperModeSettings.defaults = reloadedStore()

        XCTAssertTrue(
            DeveloperModeSettings.isEnabled,
            """
            The capture overlay reads DeveloperModeSettings.isEnabled to decide whether to snap the \
            selection to a DOM element. If that read does not see the persisted value, the row can \
            say "On" while element-snapping capture stays off.
            """
        )
    }

    func test_untouchedDeveloperMode_defaultsToOff() {
        XCTAssertNil(writingStore.object(forKey: DeveloperModeSettings.defaultsKey))
        XCTAssertFalse(DeveloperModeSettings.isEnabled)
    }

    // MARK: - The popover actually reads the persisted value

    private func renderPopoverPNG() -> Data? {
        guard let tab = env.activeTab else {
            XCTFail("renderPopoverPNG: expected AppEnvironment.demo's env.activeTab to be non-nil.")
            return nil
        }
        let rendered = render(
            SiteControlPopoverView(tab: tab).environment(env),
            size: CGSize(width: 300, height: 520)
        )
        return rendered.bitmap.representation(using: .png, properties: [:])
    }

    func test_siteControlPopover_rendersTheStoredDeveloperModeValue() throws {
        let offA = try XCTUnwrap(renderPopoverPNG(), "ImageRenderer produced no image for SiteControlPopoverView.")
        let offB = try XCTUnwrap(renderPopoverPNG())
        XCTAssertEqual(
            offA, offB,
            "Two renders of the same state differ — this test's own comparison is not a reliable signal."
        )

        DeveloperModeSettings.toggle()
        DeveloperModeSettings.defaults = reloadedStore()
        XCTAssertTrue(DeveloperModeSettings.isEnabled, "test precondition: Developer Mode is persisted as on")

        let on = try XCTUnwrap(renderPopoverPNG())

        XCTAssertNotEqual(
            on, offA,
            """
            The Site Control Center popover renders identically whether Developer Mode is persisted on \
            or off, so its Developer Mode row is not reading the stored value — the reported defect, \
            where the row always came back showing "Off".
            """
        )
    }
}
