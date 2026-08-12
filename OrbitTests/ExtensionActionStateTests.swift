// The chrome.action relay's Swift half. Payloads are written by hand in exactly the
// shape orbit_extension_action_dispatcher.cc's ActionToDict/StateForTab produce.

import XCTest

@MainActor
final class ExtensionActionStateTests: XCTestCase {

    private let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    // MARK: - Colour parsing

    func test_extensionActionColor_parsesTheHexRGBAShapeTheDispatcherWrites() throws {
        let color = try XCTUnwrap(ExtensionActionColor(hexRGBA: "#1A2B3CFF"))
        XCTAssertEqual(color.red, 0x1A)
        XCTAssertEqual(color.green, 0x2B)
        XCTAssertEqual(color.blue, 0x3C)
        XCTAssertEqual(color.alpha, 0xFF)
        XCTAssertFalse(color.isUnset)
    }

    func test_extensionActionColor_treatsAFullyTransparentColourAsUnset() throws {
        // extensions::ExtensionAction has no default entry for either badge
        // colour, so GetValue returns a value-initialised SkColor -- alpha 0.
        let color = try XCTUnwrap(ExtensionActionColor(hexRGBA: "#00000000"))
        XCTAssertTrue(color.isUnset, "alpha 0 is how the engine reports 'the extension never set this'")
    }

    func test_extensionActionColor_rejectsMalformedInput() {
        XCTAssertNil(ExtensionActionColor(hexRGBA: "#FFF"))
        XCTAssertNil(ExtensionActionColor(hexRGBA: "not a colour"))
        XCTAssertNil(ExtensionActionColor(hexRGBA: ""))
    }

    // MARK: - Wire format

    private func payload(defaultsBadge: String, tabs: [(Int32, String)]) -> String {
        let tabObjects = tabs.map { tabID, text in
            """
            {"tabId":\(tabID),"badgeText":"\(text)","badgeBackgroundColor":"#00000000",\
            "badgeTextColor":"#00000000","title":"Fixture","isEnabled":true,"popupUrl":""}
            """
        }
        return """
        {"extensionId":"\(extensionID)","defaults":{"badgeText":"\(defaultsBadge)",\
        "badgeBackgroundColor":"#00000000","badgeTextColor":"#00000000","title":"Fixture",\
        "isEnabled":true,"popupUrl":""},"tabs":[\(tabObjects.joined(separator: ","))]}
        """
    }

    func test_decode_readsDefaultsAndPerTabOverrides() throws {
        let snapshot = try XCTUnwrap(
            ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "", tabs: [(7, "12")]))
        )
        XCTAssertEqual(snapshot.extensionID, extensionID)
        XCTAssertEqual(snapshot.defaults.badgeText, "")
        XCTAssertEqual(snapshot.perTab[7]?.badgeText, "12")
    }

    func test_decode_readsTheDynamicallySetIconAsRealPNGBytes() throws {
        // A one-pixel PNG, base64'd exactly as gfx::PNGCodec::EncodeBGRASkBitmap's
        // output is before it goes on the wire.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let json = """
        {"extensionId":"\(extensionID)","defaults":{"badgeText":"","badgeBackgroundColor":"#00000000",\
        "badgeTextColor":"#00000000","title":"","isEnabled":true,"popupUrl":"","iconPNG":"\(pngBase64)"},"tabs":[]}
        """
        let snapshot = try XCTUnwrap(ExtensionActionSnapshot.decode(json: json))
        let data = try XCTUnwrap(snapshot.defaults.iconPNG)
        XCTAssertEqual(
            Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "the decoded bytes must be a real PNG, not the base64 text"
        )
    }

    func test_decode_toleratesAMissingTabsArray() throws {
        let json = """
        {"extensionId":"\(extensionID)","defaults":{"badgeText":"9","badgeBackgroundColor":"#FF0000FF",\
        "badgeTextColor":"#FFFFFFFF","title":"","isEnabled":true,"popupUrl":""}}
        """
        let snapshot = try XCTUnwrap(ExtensionActionSnapshot.decode(json: json))
        XCTAssertTrue(snapshot.perTab.isEmpty)
        XCTAssertEqual(snapshot.defaults.badgeText, "9")
    }

    func test_decode_returnsNilForGarbage() {
        XCTAssertNil(ExtensionActionSnapshot.decode(json: "not json"))
        XCTAssertNil(ExtensionActionSnapshot.decode(json: "{}"))
    }

    func test_decodeAll_readsTheFullSnapshotArray() {
        let json = "[\(payload(defaultsBadge: "1", tabs: [])),\(payload(defaultsBadge: "2", tabs: []))]"
        XCTAssertEqual(ExtensionActionSnapshot.decodeAll(json: json).count, 2)
    }

    // MARK: - Per-tab lookup (Chrome's own fallback rule)

    func test_state_perTabValueWinsForThatTabOnly() throws {
        let snapshot = try XCTUnwrap(
            ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "", tabs: [(7, "12")]))
        )
        XCTAssertEqual(snapshot.state(forTabID: 7).badgeText, "12")
        XCTAssertEqual(
            snapshot.state(forTabID: 8).badgeText, "",
            "a badge set for one tab must not appear on another"
        )
        XCTAssertEqual(snapshot.state(forTabID: nil).badgeText, "")
    }

    func test_state_fallsBackToTheDefaultForATabWithNoOverride() throws {
        let snapshot = try XCTUnwrap(
            ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "ALL", tabs: [(7, "12")]))
        )
        XCTAssertEqual(snapshot.state(forTabID: 8).badgeText, "ALL")
        XCTAssertEqual(snapshot.state(forTabID: 7).badgeText, "12", "the tab's own value still wins over the default")
    }

    func test_state_twoTabsCanCarryDifferentBadgesSimultaneously() throws {
        let snapshot = try XCTUnwrap(
            ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "", tabs: [(1, "A"), (2, "B")]))
        )
        XCTAssertEqual(snapshot.state(forTabID: 1).badgeText, "A")
        XCTAssertEqual(snapshot.state(forTabID: 2).badgeText, "B")
    }

    // MARK: - Store

    func test_store_reportsAPlainEnabledUnbadgedActionForAnExtensionItHasNeverHeardOf() {
        let store = ExtensionActionStateStore()
        let state = store.state(extensionID: extensionID, tabID: 3)
        XCTAssertEqual(state.badgeText, "")
        XCTAssertTrue(state.isEnabled, "an extension that never called chrome.action.disable() is enabled")
        XCTAssertNil(state.iconPNG)
    }

    func test_store_applyReplacesTheWholeSnapshotForThatExtension() throws {
        let store = ExtensionActionStateStore()
        store.apply(try XCTUnwrap(ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "", tabs: [(1, "A")]))))
        XCTAssertEqual(store.state(extensionID: extensionID, tabID: 1).badgeText, "A")

        // Exactly what the engine relays after chrome.action.setBadgeText({text: "", tabId: 1}).
        store.apply(try XCTUnwrap(ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "", tabs: []))))
        XCTAssertEqual(
            store.state(extensionID: extensionID, tabID: 1).badgeText, "",
            "a snapshot that no longer lists a tab must clear that tab, not leave the old badge behind"
        )
    }

    func test_store_removeDropsTheExtensionEntirely() throws {
        let store = ExtensionActionStateStore()
        store.apply(try XCTUnwrap(ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "5", tabs: []))))
        store.remove(extensionID: extensionID)
        XCTAssertEqual(store.state(extensionID: extensionID, tabID: nil).badgeText, "")
    }

    func test_store_replaceAllKeepsOnlyTheExtensionsInTheNewSnapshot() throws {
        let store = ExtensionActionStateStore()
        store.apply(try XCTUnwrap(ExtensionActionSnapshot.decode(json: payload(defaultsBadge: "5", tabs: []))))
        store.replaceAll([ExtensionActionSnapshot(extensionID: "ponmlkjihgfedcbaponmlkjihgfedcba")])
        XCTAssertEqual(store.state(extensionID: extensionID, tabID: nil).badgeText, "")
    }

    // MARK: - Badge text shaping

    func test_displayBadgeText_isNilWhenThereIsNothingToDraw() {
        XCTAssertNil(ExtensionActionPopupSupport.displayBadgeText(""))
        XCTAssertNil(ExtensionActionPopupSupport.displayBadgeText("   "))
    }

    func test_displayBadgeText_truncatesToTheSlotWidth() {
        XCTAssertEqual(ExtensionActionPopupSupport.displayBadgeText("1234567"), "1234")
        XCTAssertEqual(ExtensionActionPopupSupport.displayBadgeText("12"), "12")
    }

    // MARK: - chrome.action.setPopup

    func test_effectiveActionPopupPath_prefersTheEngineReportedPopupOverTheManifest() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.effectiveActionPopupPath(
                extensionID: extensionID,
                manifestPopupPath: "popup.html",
                engineReportedPopupURL: "chrome-extension://\(extensionID)/other.html"
            ),
            "other.html"
        )
    }

    func test_effectiveActionPopupPath_fallsBackToTheManifestWhenTheEngineReportsNone() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.effectiveActionPopupPath(
                extensionID: extensionID, manifestPopupPath: "popup.html", engineReportedPopupURL: ""
            ),
            "popup.html"
        )
    }

    func test_effectiveActionPopupPath_ignoresAURLBelongingToADifferentExtension() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.effectiveActionPopupPath(
                extensionID: extensionID,
                manifestPopupPath: "popup.html",
                engineReportedPopupURL: "chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba/other.html"
            ),
            "popup.html"
        )
    }

    // MARK: - Addressability (defect 3)

    func test_isExtensionIDAddressable_acceptsAKeylessIDDerivedFromItsOwnDirectoryPath() {
        let directory = URL(fileURLWithPath: "/tmp/OrbitTests-unpacked-fixture")
        let id = ChromeExtensionID.id(forUnpackedPath: directory)
        XCTAssertTrue(
            ExtensionActionPopupSupport.isExtensionIDAddressable(
                extensionID: id, manifestKey: nil, directory: directory
            ),
            "Chromium derives an unpacked extension's id from its absolute directory path (crx_file::id_util::GenerateIdForPath); Orbit must agree rather than demanding a manifest key"
        )
    }

    func test_isExtensionIDAddressable_rejectsAKeylessIDThatIsNotItsPathDerivedID() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(
                extensionID: "abcdefghijklmnopabcdefghijklmnop",
                manifestKey: nil,
                directory: URL(fileURLWithPath: "/tmp/OrbitTests-unpacked-fixture")
            )
        )
    }

    func test_isExtensionIDAddressable_neverFallsBackToThePathWhenAMismatchedKeyIsPresent() {
        let directory = URL(fileURLWithPath: "/tmp/OrbitTests-unpacked-fixture")
        let id = ChromeExtensionID.id(forUnpackedPath: directory)
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(
                extensionID: id,
                manifestKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
                directory: directory
            ),
            "a manifest key that recomputes to some other id means Orbit and the engine disagree -- refuse, do not silently accept the path instead"
        )
    }

    func test_isExtensionIDAddressable_acceptsAnEngineAssignedIDWithoutRecomputingAnything() {
        XCTAssertTrue(
            ExtensionActionPopupSupport.isExtensionIDAddressable(
                extensionID: "ponmlkjihgfedcbaponmlkjihgfedcba",
                manifestKey: nil,
                directory: nil,
                idIsEngineAssigned: true
            )
        )
    }

    func test_isExtensionIDAddressable_stillRejectsAMalformedID() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(
                extensionID: "not-an-extension-id", manifestKey: nil, directory: nil, idIsEngineAssigned: true
            )
        )
    }
}
