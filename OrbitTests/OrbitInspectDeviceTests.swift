// Unit tests for the device toolbar's pure logic; OrbitInspectDeviceLogic.swift and OrbitInspectDevicePresets.swift are compiled in directly.

import CoreGraphics
import XCTest

final class OrbitInspectDeviceTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "orbit.tests.device.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fit scale

    func testFitScaleShrinksToTheTighterAxis() {
        let scale = OrbitDeviceGeometry.fitScale(content: CGSize(width: 1000, height: 500), available: CGSize(width: 500, height: 500))
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
        let heightBound = OrbitDeviceGeometry.fitScale(content: CGSize(width: 400, height: 1000), available: CGSize(width: 800, height: 250))
        XCTAssertEqual(heightBound, 0.25, accuracy: 0.0001)
    }

    func testFitScaleNeverEnlarges() {
        let scale = OrbitDeviceGeometry.fitScale(content: CGSize(width: 100, height: 100), available: CGSize(width: 900, height: 900))
        XCTAssertEqual(scale, 1)
    }

    func testFitScaleWithoutAUsableAreaIsOne() {
        XCTAssertEqual(OrbitDeviceGeometry.fitScale(content: CGSize(width: 100, height: 100), available: .zero), 1)
        XCTAssertEqual(OrbitDeviceGeometry.fitScale(content: .zero, available: CGSize(width: 100, height: 100)), 1)
        XCTAssertEqual(OrbitDeviceGeometry.fitScale(content: CGSize(width: 100, height: 100), available: CGSize(width: -5, height: 100)), 1)
    }

    func testFixedZoomIgnoresTheAvailableSpace() {
        let content = CGSize(width: 1000, height: 1000)
        let tiny = CGSize(width: 100, height: 100)
        XCTAssertEqual(OrbitDeviceGeometry.scale(zoom: .percent(125), content: content, available: tiny), 1.25, accuracy: 0.0001)
        XCTAssertEqual(OrbitDeviceGeometry.scale(zoom: .percent(50), content: content, available: tiny), 0.5, accuracy: 0.0001)
        XCTAssertEqual(OrbitDeviceGeometry.scale(zoom: .fit, content: content, available: tiny), 0.1, accuracy: 0.0001)
    }

    func testLayoutReservesRoomForReadoutAndHandles() {
        let stage = CGSize(width: 600, height: 500)
        let room = OrbitDeviceLayout.available(forFrameIn: stage)
        XCTAssertEqual(room.width, 600 - 32 - OrbitDeviceLayout.gripSpace, accuracy: 0.0001)
        XCTAssertEqual(room.height, 500 - 32 - OrbitDeviceLayout.gripSpace - OrbitDeviceLayout.readoutHeight, accuracy: 0.0001)

        let layout = OrbitDeviceLayout.make(content: CGSize(width: 1200, height: 400), zoom: .fit, stage: stage)
        XCTAssertEqual(layout.frame.width, room.width, accuracy: 0.001)
        XCTAssertLessThanOrEqual(layout.frame.height, room.height + 0.001)
        XCTAssertFalse(layout.overflows(stage: stage), "a fitted frame never needs scrolling")
    }

    func testAZoomLargerThanTheStageOverflows() {
        let stage = CGSize(width: 400, height: 400)
        let layout = OrbitDeviceLayout.make(content: CGSize(width: 800, height: 600), zoom: .percent(100), stage: stage)
        XCTAssertEqual(layout.scale, 1)
        XCTAssertTrue(layout.overflows(stage: stage))
    }

    func testZoomStorageRoundTripsAndUnknownValuesFallBackToFit() {
        for choice in OrbitDeviceZoom.choices {
            XCTAssertEqual(OrbitDeviceZoom(storageValue: choice.storageValue), choice)
        }
        XCTAssertEqual(OrbitDeviceZoom(storageValue: 137), .fit)
        XCTAssertEqual(OrbitDeviceZoom.choices.compactMap(\.factor), [0.5, 0.75, 1, 1.25, 1.5])
    }

    // MARK: - Rotation

    func testRotationSwapsWidthAndHeightAndKeepsTheDevice() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "iphone-16-pro" })
        let portrait = OrbitDeviceSettings(profile: profile)
        XCTAssertFalse(portrait.isLandscape)
        let landscape = portrait.rotated()
        XCTAssertEqual(landscape.width, 874)
        XCTAssertEqual(landscape.height, 402)
        XCTAssertTrue(landscape.isLandscape)
        XCTAssertEqual(landscape.profileID, "iphone-16-pro")
        XCTAssertEqual(landscape.dpr, 3)
        XCTAssertEqual(landscape.rotated(), portrait)
    }

    func testRotatingASquareViewportChangesNothing() {
        let square = OrbitDeviceSettings.responsiveDefault.resized(width: 500, height: 500)
        XCTAssertEqual(square.rotated(), square)
    }

    // MARK: - Drag resizing

    func testDragResizeClampsToTheMinimum() {
        let result = OrbitDeviceGeometry.resized(
            width: 120, height: 120, translation: CGSize(width: -500, height: -500), scale: 1, handle: .corner
        )
        XCTAssertEqual(result.width, 50)
        XCTAssertEqual(result.height, 50)
    }

    func testDragResizeClampsToTheMaximum() {
        let result = OrbitDeviceGeometry.resized(
            width: 9000, height: 9000, translation: CGSize(width: 50_000, height: 50_000), scale: 1, handle: .corner
        )
        XCTAssertEqual(result.width, 9999)
        XCTAssertEqual(result.height, 9999)
    }

    func testDragResizeConvertsScreenPointsToCSSPixels() {
        let result = OrbitDeviceGeometry.resized(
            width: 400, height: 300, translation: CGSize(width: 100, height: 50), scale: 0.5, handle: .corner
        )
        XCTAssertEqual(result.width, 600)
        XCTAssertEqual(result.height, 400)
    }

    func testEdgeHandlesMoveOnlyTheirOwnAxis() {
        let right = OrbitDeviceGeometry.resized(
            width: 400, height: 300, translation: CGSize(width: 80, height: 80), scale: 1, handle: .right
        )
        XCTAssertEqual(right.width, 480)
        XCTAssertEqual(right.height, 300)
        let bottom = OrbitDeviceGeometry.resized(
            width: 400, height: 300, translation: CGSize(width: 80, height: 80), scale: 1, handle: .bottom
        )
        XCTAssertEqual(bottom.width, 400)
        XCTAssertEqual(bottom.height, 380)
    }

    func testClampHandlesNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(OrbitDeviceLimits.clamp(-3), 50)
        XCTAssertEqual(OrbitDeviceLimits.clamp(10_000), 9999)
        XCTAssertEqual(OrbitDeviceLimits.clamp(Double.nan), 50)
        XCTAssertEqual(OrbitDeviceLimits.clamp(Double.infinity), 9999)
        XCTAssertEqual(OrbitDeviceLimits.clamp(Double.greatestFiniteMagnitude), 9999)
        XCTAssertEqual(OrbitDeviceLimits.clamp(412.6), 413)
    }

    func testResizingADeviceLeavesItButKeepsItsRatioAndAgent() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "pixel-9" })
        let resized = OrbitDeviceSettings(profile: profile).resized(width: 500, height: 20_000)
        XCTAssertNil(resized.profileID)
        XCTAssertEqual(resized.width, 500)
        XCTAssertEqual(resized.height, 9999)
        XCTAssertEqual(resized.dpr, 2.625)
        XCTAssertEqual(resized.userAgent, profile.userAgent)
        XCTAssertNil(resized.emulation.screenWidth, "a responsive window is not a screen")
    }

    // MARK: - Presets

    func testEveryPresetIsValid() {
        XCTAssertFalse(OrbitDevicePresets.all.isEmpty)
        for profile in OrbitDevicePresets.all {
            XCTAssertTrue(profile.isValid, "\(profile.name) is not valid")
            XCTAssertGreaterThanOrEqual(profile.width, OrbitDeviceLimits.minimum, profile.name)
            XCTAssertLessThanOrEqual(profile.width, OrbitDeviceLimits.maximum, profile.name)
            XCTAssertGreaterThanOrEqual(profile.height, OrbitDeviceLimits.minimum, profile.name)
            XCTAssertLessThanOrEqual(profile.height, OrbitDeviceLimits.maximum, profile.name)
            XCTAssertFalse(profile.userAgent.isEmpty, "\(profile.name) has no user agent")
            XCTAssertGreaterThan(profile.dpr, 0, profile.name)
            XCTAssertFalse(profile.isCustom, profile.name)
        }
    }

    func testPresetIDsAreUniqueAndTheRequestedDevicesArePresent() {
        let ids = OrbitDevicePresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let names = Set(OrbitDevicePresets.all.map(\.name))
        for expected in [
            "iPhone SE", "iPhone 15 Pro", "iPhone 15 Pro Max", "iPhone 16 Pro", "iPhone 16 Pro Max", "Pixel 8", "Pixel 9",
            "Galaxy S24", "iPad mini", "iPad Air", "iPad Pro 11", "iPad Pro 13", "Surface Pro", "Nest Hub",
            "Laptop 1280", "Laptop 1440", "Laptop 1920",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
    }

    func testPhonesAndTabletsAreMobileTouchAndComputersAreNot() {
        for profile in OrbitDevicePresets.all where profile.category == .phone || profile.category == .tablet {
            XCTAssertTrue(profile.mobile && profile.touch, profile.name)
        }
        for profile in OrbitDevicePresets.all where profile.category == .computer && profile.id.hasPrefix("laptop") {
            XCTAssertFalse(profile.mobile || profile.touch, profile.name)
        }
    }

    func testSectionsFollowTheMenuOrderAndDropEmptyGroups() throws {
        XCTAssertEqual(OrbitDeviceCatalog.sections(custom: []).map(\.category), [.phone, .tablet, .computer])
        let custom = try XCTUnwrap(makeCustom(name: "Kiosk"))
        let sections = OrbitDeviceCatalog.sections(custom: [custom])
        XCTAssertEqual(sections.map(\.category), [.phone, .tablet, .computer, .custom])
        XCTAssertEqual(sections.last?.profiles, [custom])
    }

    func testDeviceTypeFollowsTheMobileAndTouchFlags() {
        XCTAssertEqual(OrbitDeviceType(mobile: true, touch: true), .mobile)
        XCTAssertEqual(OrbitDeviceType(mobile: true, touch: false), .mobileNoTouch)
        XCTAssertEqual(OrbitDeviceType(mobile: false, touch: true), .desktopTouch)
        XCTAssertEqual(OrbitDeviceType(mobile: false, touch: false), .desktop)
        XCTAssertNil(OrbitDeviceType.desktop.userAgent, "desktop keeps the browser's own agent")
        XCTAssertNotNil(OrbitDeviceType.mobile.userAgent)
    }

    // MARK: - Custom devices

    private func makeCustom(name: String = "Test phone", id: String = "custom-test") -> OrbitDeviceProfile? {
        OrbitDeviceProfile.makeCustom(
            id: id, name: name, width: 360, height: 640, dpr: 2.5,
            userAgent: "TestAgent/1.0", mobile: true, touch: true
        )
    }

    func testCustomDeviceIsSanitised() throws {
        let profile = try XCTUnwrap(OrbitDeviceProfile.makeCustom(
            name: "  Big one  ", width: 20_000, height: 3, dpr: 40, userAgent: "   ", mobile: false, touch: false
        ))
        XCTAssertEqual(profile.name, "Big one")
        XCTAssertEqual(profile.width, 9999)
        XCTAssertEqual(profile.height, 50)
        XCTAssertEqual(profile.dpr, 8)
        XCTAssertEqual(profile.userAgent, OrbitDeviceUserAgents.macSafari)
        XCTAssertEqual(profile.category, .custom)
        XCTAssertTrue(profile.id.hasPrefix("custom-"))
        XCTAssertTrue(profile.isValid)
    }

    func testCustomDeviceNeedsANameAndAPositiveRatio() {
        XCTAssertNil(OrbitDeviceProfile.makeCustom(name: "  ", width: 300, height: 300, dpr: 2, userAgent: "x", mobile: true, touch: true))
        XCTAssertNil(OrbitDeviceProfile.makeCustom(name: "A", width: 300, height: 300, dpr: 0, userAgent: "x", mobile: true, touch: true))
        XCTAssertNil(OrbitDeviceProfile.makeCustom(name: "A", width: 300, height: 300, dpr: -1, userAgent: "x", mobile: true, touch: true))
        XCTAssertNil(OrbitDeviceProfile.makeCustom(name: "A", width: 300, height: 300, dpr: .nan, userAgent: "x", mobile: true, touch: true))
    }

    func testMobileCustomDeviceWithoutAgentGetsAPhoneAgent() throws {
        let profile = try XCTUnwrap(OrbitDeviceProfile.makeCustom(
            name: "Phone", width: 300, height: 600, dpr: 2, userAgent: "", mobile: true, touch: true
        ))
        XCTAssertEqual(profile.userAgent, OrbitDeviceUserAgents.iPhone)
    }

    func testCustomDevicesRoundTripThroughPreferences() throws {
        let preferences = OrbitDevicePreferences(defaults: defaults)
        XCTAssertEqual(preferences.customDevices, [])
        let first = try XCTUnwrap(makeCustom(name: "One", id: "custom-1"))
        let second = try XCTUnwrap(makeCustom(name: "Two", id: "custom-2"))
        preferences.customDevices = [first, second]

        let reloaded = OrbitDevicePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.customDevices, [first, second])
        XCTAssertEqual(reloaded.customDevices.first?.userAgent, "TestAgent/1.0")
        XCTAssertEqual(reloaded.customDevices.first?.dpr, 2.5)
    }

    func testUpsertReplacesByIDAndRemoveDrops() throws {
        let first = try XCTUnwrap(makeCustom(name: "One", id: "custom-1"))
        let renamed = try XCTUnwrap(makeCustom(name: "Uno", id: "custom-1"))
        let second = try XCTUnwrap(makeCustom(name: "Two", id: "custom-2"))
        var list = OrbitDeviceCatalog.upserting(first, into: [])
        list = OrbitDeviceCatalog.upserting(second, into: list)
        list = OrbitDeviceCatalog.upserting(renamed, into: list)
        XCTAssertEqual(list.map(\.name), ["Uno", "Two"])
        XCTAssertEqual(OrbitDeviceCatalog.removing(id: "custom-1", from: list).map(\.id), ["custom-2"])
    }

    func testCorruptOrInvalidStoredDevicesAreIgnored() throws {
        defaults.set(Data("not json".utf8), forKey: OrbitDevicePreferences.customDevicesKey)
        XCTAssertEqual(OrbitDevicePreferences(defaults: defaults).customDevices, [])

        var broken = try XCTUnwrap(makeCustom())
        broken.userAgent = ""
        let good = try XCTUnwrap(makeCustom(name: "Good", id: "custom-good"))
        let data = try JSONEncoder().encode([broken, good])
        defaults.set(data, forKey: OrbitDevicePreferences.customDevicesKey)
        XCTAssertEqual(OrbitDevicePreferences(defaults: defaults).customDevices, [good])
    }

    func testZoomAndSelectionRoundTrip() throws {
        let preferences = OrbitDevicePreferences(defaults: defaults)
        XCTAssertEqual(preferences.zoom, .fit)
        preferences.zoom = .percent(75)
        XCTAssertEqual(OrbitDevicePreferences(defaults: defaults).zoom, .percent(75))

        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "ipad-air" })
        let rotated = OrbitDeviceSettings(profile: profile).rotated()
        preferences.saveSelection(rotated)
        XCTAssertEqual(OrbitDevicePreferences(defaults: defaults).restoredSettings(), rotated)

        let responsive = OrbitDeviceSettings.responsiveDefault.resized(width: 333, height: 444)
        preferences.saveSelection(responsive)
        XCTAssertEqual(OrbitDevicePreferences(defaults: defaults).restoredSettings(), responsive)
    }

    func testSelectedCustomDeviceRestoresAndADeletedOneFallsBackToResponsive() throws {
        let preferences = OrbitDevicePreferences(defaults: defaults)
        let custom = try XCTUnwrap(makeCustom(name: "Mine", id: "custom-mine"))
        preferences.customDevices = [custom]
        preferences.saveSelection(OrbitDeviceSettings(profile: custom))
        XCTAssertEqual(preferences.restoredSettings().profileID, "custom-mine")

        preferences.customDevices = []
        let fallback = preferences.restoredSettings()
        XCTAssertNil(fallback.profileID)
        XCTAssertEqual(fallback.width, 360)
        XCTAssertEqual(fallback.height, 640)
    }

    // MARK: - Reload prompt

    func testReloadIsNeededOnlyWhenTheAgentOrFlagsDiffer() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "iphone-se" })
        let target = OrbitDeviceSettings(profile: profile).applied
        XCTAssertTrue(OrbitDeviceAppliedState.needsReload(document: .untouched, target: target))
        XCTAssertFalse(OrbitDeviceAppliedState.needsReload(document: target, target: target))

        var otherAgent = target
        otherAgent.userAgent = "Other"
        XCTAssertTrue(OrbitDeviceAppliedState.needsReload(document: target, target: otherAgent))
        var noTouch = target
        noTouch.touch = false
        XCTAssertTrue(OrbitDeviceAppliedState.needsReload(document: target, target: noTouch))
        XCTAssertFalse(
            OrbitDeviceAppliedState.needsReload(document: .untouched, target: OrbitDeviceSettings.responsiveDefault.applied),
            "a plain responsive window changes nothing the page loaded with"
        )
    }

    func testResizingTheViewportNeverAsksForAReload() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "pixel-8" })
        let before = OrbitDeviceSettings(profile: profile)
        XCTAssertEqual(before.applied, before.resized(width: 500, height: 700).applied)
        XCTAssertEqual(before.applied, before.rotated().applied)
    }

    // MARK: - Emulation script

    func testScriptForAPresetCarriesItsRatioTouchAndScreen() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "iphone-16-pro" })
        let config = OrbitDeviceSettings(profile: profile).emulation
        XCTAssertEqual(OrbitDeviceEmulationScript.configJSON(config), #"{"dpr":3,"on":true,"screenHeight":874,"screenWidth":402,"touch":true}"#)

        let script = OrbitDeviceEmulationScript.install(config)
        XCTAssertTrue(script.hasPrefix(OrbitDeviceEmulationScript.marker))
        XCTAssertTrue(script.contains(#"})({"dpr":3,"on":true,"screenHeight":874,"screenWidth":402,"touch":true});"#))
        for override in ["devicePixelRatio", "maxTouchPoints", "matchMedia", "ontouchstart", "availWidth"] {
            XCTAssertTrue(script.contains(override), "script does not touch \(override)")
        }
        XCTAssertTrue(script.contains("__orbitDeviceEmu"))
    }

    func testScriptKeepsFractionalRatiosAndOmitsWhatIsNotEmulated() throws {
        let pixel = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "pixel-8" })
        XCTAssertTrue(OrbitDeviceEmulationScript.configJSON(OrbitDeviceSettings(profile: pixel).emulation).contains(#""dpr":2.625"#))

        let plain = OrbitDeviceEmulationConfig(dpr: nil, touch: false, screenWidth: nil, screenHeight: nil)
        XCTAssertTrue(plain.isEmpty)
        XCTAssertEqual(OrbitDeviceEmulationScript.configJSON(plain), #"{"on":true,"touch":false}"#)
    }

    func testLaptopPresetEmulatesNoTouch() throws {
        let laptop = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "laptop-1440" })
        let config = OrbitDeviceSettings(profile: laptop).emulation
        XCTAssertFalse(config.touch)
        XCTAssertTrue(OrbitDeviceEmulationScript.configJSON(config).contains(#""touch":false"#))
        XCTAssertFalse(config.isEmpty, "a laptop still emulates its ratio and screen")
    }

    func testRemoveScriptSwitchesTheOverridesOff() {
        XCTAssertTrue(OrbitDeviceEmulationScript.remove.contains("apply({ on: false })"))
    }

    func testScriptIsBalancedJavaScript() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "galaxy-s24" })
        let script = OrbitDeviceEmulationScript.install(OrbitDeviceSettings(profile: profile).emulation)
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]")] {
            XCTAssertEqual(
                script.filter { String($0) == open }.count,
                script.filter { String($0) == close }.count,
                "unbalanced \(open)\(close)"
            )
        }
    }

    // MARK: - Text

    func testEmulationSummaryNamesTheEmulationHonestly() throws {
        let profile = try XCTUnwrap(OrbitDevicePresets.all.first { $0.id == "iphone-se" })
        XCTAssertEqual(OrbitDeviceFormat.emulationSummary(for: OrbitDeviceSettings(profile: profile)), "DPR 2, touch, emulated (JS)")
        XCTAssertEqual(OrbitDeviceFormat.emulationSummary(for: .responsiveDefault), "")
        XCTAssertEqual(OrbitDeviceFormat.number(2.625), "2.625")
        XCTAssertEqual(OrbitDeviceFormat.number(3), "3")
        XCTAssertEqual(OrbitDeviceFormat.percentText(0.666), "67%")
    }
}
