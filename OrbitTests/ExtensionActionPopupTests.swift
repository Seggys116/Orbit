import XCTest

final class ExtensionActionPopupTests: XCTestCase {

    private let fixedPublicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private lazy var addressableID: String = ChromeExtensionID.id(fromPublicKeyBase64: fixedPublicKey)!
    private let pathDerivedID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    // MARK: - Session persistence gate (honesty requirement 1)

    func test_canHostExtensionSurfaces_requiresAPersistentSession() {
        XCTAssertTrue(ExtensionActionPopupSupport.canHostExtensionSurfaces(sessionIsPersistent: true))
        XCTAssertFalse(
            ExtensionActionPopupSupport.canHostExtensionSurfaces(sessionIsPersistent: false),
            "A non-persistent (incognito-shaped) session must refuse — ChromiumExtensionRuntimeLiveTests measured the identical chrome-extension:// navigation failing with ERR_BLOCKED_BY_CLIENT in exactly this session shape."
        )
    }

    func test_canShowActionIcon_refusesInANonPersistentSessionEvenWhenEverythingElseQualifies() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: fixedPublicKey,
                actionPopupPath: "popup.html",
                sessionIsPersistent: false
            ),
            "An otherwise-perfectly-eligible extension must still get no icon in a non-persistent session."
        )
    }

    func test_canShowOptionsControl_refusesInANonPersistentSessionEvenWhenEverythingElseQualifies() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowOptionsControl(
                extensionID: addressableID,
                isEnabled: true,
                manifestKey: fixedPublicKey,
                optionsPagePath: "options.html",
                sessionIsPersistent: false
            )
        )
    }

    // MARK: - Path-derived id refusal (honesty requirement 2)

    func test_isExtensionIDAddressable_trueWhenTheManifestKeyReproducesTheID() {
        XCTAssertTrue(ExtensionActionPopupSupport.isExtensionIDAddressable(extensionID: addressableID, manifestKey: fixedPublicKey))
    }

    func test_isExtensionIDAddressable_falseWithNoManifestKeyAtAll() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(extensionID: pathDerivedID, manifestKey: nil),
            "No key at all is exactly ExtensionStore's own idIsPathDerived == true case: the id came from the install directory's path, not from any key."
        )
    }

    func test_isExtensionIDAddressable_falseWithAMalformedManifestKey() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(extensionID: pathDerivedID, manifestKey: "not valid base64!!"),
            "A key that does not even base64-decode cannot have produced this id, so it must be refused exactly like no key at all."
        )
    }

    func test_isExtensionIDAddressable_falseWhenTheKeyDerivesADifferentID() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.isExtensionIDAddressable(extensionID: pathDerivedID, manifestKey: fixedPublicKey),
            "fixedPublicKey derives addressableID, not pathDerivedID — a mismatched key must be refused exactly as if there were none, since the id on record still is not the one Chromium would compute from this manifest."
        )
    }

    func test_canShowActionIcon_refusesAPathDerivedID() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: pathDerivedID,
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: nil,
                actionPopupPath: "popup.html",
                sessionIsPersistent: true
            ),
            "A path-derived id is not addressable at chrome-extension://<id>/ — no icon, even with an otherwise-perfect action declaration and a persistent session."
        )
    }

    func test_canShowOptionsControl_refusesAPathDerivedID() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowOptionsControl(
                extensionID: pathDerivedID,
                isEnabled: true,
                manifestKey: nil,
                optionsPagePath: "options.html",
                sessionIsPersistent: true
            )
        )
    }

    // MARK: - Action icon eligibility: the other gates

    func test_canShowActionIcon_refusesADisabledExtension() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: false,
                hasToolbarAction: true,
                manifestKey: fixedPublicKey,
                actionPopupPath: "popup.html",
                sessionIsPersistent: true
            ),
            "A disabled extension is not actually loaded into the running engine at all — its chrome-extension:// origin answers nothing."
        )
    }

    func test_canShowActionIcon_refusesAnExtensionWithNoToolbarAction() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: true,
                hasToolbarAction: false,
                manifestKey: fixedPublicKey,
                actionPopupPath: "popup.html",
                sessionIsPersistent: true
            )
        )
    }

    func test_canShowActionIcon_refusesAToolbarActionWithNoPopupPath() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: fixedPublicKey,
                actionPopupPath: nil,
                sessionIsPersistent: true
            )
        )
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: fixedPublicKey,
                actionPopupPath: "",
                sessionIsPersistent: true
            ),
            "An empty default_popup string must be treated exactly like no popup at all, not as a URL to chrome-extension://<id>/."
        )
    }

    func test_canShowActionIcon_trueWhenEveryGateIsSatisfied() {
        XCTAssertTrue(
            ExtensionActionPopupSupport.canShowActionIcon(
                extensionID: addressableID,
                isEnabled: true,
                hasToolbarAction: true,
                manifestKey: fixedPublicKey,
                actionPopupPath: "popup.html",
                sessionIsPersistent: true
            )
        )
    }

    // MARK: - Action popup URL construction

    func test_actionPopupURL_buildsTheExpectedChromeExtensionURL() {
        let url = ExtensionActionPopupSupport.actionPopupURL(
            extensionID: addressableID,
            isEnabled: true,
            hasToolbarAction: true,
            manifestKey: fixedPublicKey,
            actionPopupPath: "popup.html",
            sessionIsPersistent: true
        )
        XCTAssertEqual(url, URL(string: "chrome-extension://\(addressableID)/popup.html"))
    }

    func test_actionPopupURL_percentEncodesAndPreservesSubdirectoryPaths() throws {
        let url = try XCTUnwrap(ExtensionActionPopupSupport.actionPopupURL(
            extensionID: addressableID,
            isEnabled: true,
            hasToolbarAction: true,
            manifestKey: fixedPublicKey,
            actionPopupPath: "ui/action popup.html",
            sessionIsPersistent: true
        ))
        XCTAssertEqual(url.absoluteString, "chrome-extension://\(addressableID)/ui/action%20popup.html")
        XCTAssertEqual(url.path, "/ui/action popup.html")
    }

    func test_actionPopupURL_nilWheneverCanShowActionIconIsFalse() {
        XCTAssertNil(ExtensionActionPopupSupport.actionPopupURL(
            extensionID: addressableID, isEnabled: true, hasToolbarAction: true,
            manifestKey: fixedPublicKey, actionPopupPath: "popup.html", sessionIsPersistent: false
        ))
        XCTAssertNil(ExtensionActionPopupSupport.actionPopupURL(
            extensionID: pathDerivedID, isEnabled: true, hasToolbarAction: true,
            manifestKey: nil, actionPopupPath: "popup.html", sessionIsPersistent: true
        ))
        XCTAssertNil(ExtensionActionPopupSupport.actionPopupURL(
            extensionID: addressableID, isEnabled: false, hasToolbarAction: true,
            manifestKey: fixedPublicKey, actionPopupPath: "popup.html", sessionIsPersistent: true
        ))
        XCTAssertNil(ExtensionActionPopupSupport.actionPopupURL(
            extensionID: addressableID, isEnabled: true, hasToolbarAction: true,
            manifestKey: fixedPublicKey, actionPopupPath: nil, sessionIsPersistent: true
        ))
    }

    func test_extensionResourceURL_nilForAnInvalidExtensionIDShape() {
        XCTAssertNil(ExtensionActionPopupSupport.extensionResourceURL(extensionID: "not-a-real-id", path: "popup.html"))
        XCTAssertNil(ExtensionActionPopupSupport.extensionResourceURL(extensionID: "", path: "popup.html"))
    }

    func test_extensionResourceURL_nilForAnEmptyPath() {
        XCTAssertNil(ExtensionActionPopupSupport.extensionResourceURL(extensionID: addressableID, path: ""))
    }

    // MARK: - Options page: presentation decision

    func test_optionsPagePresentation_mirrorsOpenInTabExactly() {
        XCTAssertEqual(ExtensionActionPopupSupport.optionsPagePresentation(optionsOpenInTab: true), .tab)
        XCTAssertEqual(
            ExtensionActionPopupSupport.optionsPagePresentation(optionsOpenInTab: false),
            .panel,
            "false is Chrome's own default for options_ui.open_in_tab (and the only behaviour a legacy options_page has ever had) — it must map to the embedded panel, not a tab."
        )
    }

    // MARK: - Options page: eligibility and URL, independent of hasToolbarAction

    func test_canShowOptionsControl_isIndependentOfToolbarAction() {
        XCTAssertTrue(
            ExtensionActionPopupSupport.canShowOptionsControl(
                extensionID: addressableID,
                isEnabled: true,
                manifestKey: fixedPublicKey,
                optionsPagePath: "options.html",
                sessionIsPersistent: true
            ),
            "An extension can declare options_page/options_ui with no toolbar action at all; canShowOptionsControl must not require hasToolbarAction the way canShowActionIcon does."
        )
    }

    func test_canShowOptionsControl_refusesWithNoOptionsPagePath() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowOptionsControl(
                extensionID: addressableID,
                isEnabled: true,
                manifestKey: fixedPublicKey,
                optionsPagePath: nil,
                sessionIsPersistent: true
            )
        )
    }

    func test_canShowOptionsControl_refusesADisabledExtension() {
        XCTAssertFalse(
            ExtensionActionPopupSupport.canShowOptionsControl(
                extensionID: addressableID,
                isEnabled: false,
                manifestKey: fixedPublicKey,
                optionsPagePath: "options.html",
                sessionIsPersistent: true
            )
        )
    }

    func test_optionsPageURL_buildsTheExpectedChromeExtensionURL() throws {
        let url = try XCTUnwrap(ExtensionActionPopupSupport.optionsPageURL(
            extensionID: addressableID,
            isEnabled: true,
            manifestKey: fixedPublicKey,
            optionsPagePath: "options.html",
            sessionIsPersistent: true
        ))
        XCTAssertEqual(url, URL(string: "chrome-extension://\(addressableID)/options.html"))
    }

    func test_optionsPageURL_nilWheneverCanShowOptionsControlIsFalse() {
        XCTAssertNil(ExtensionActionPopupSupport.optionsPageURL(
            extensionID: pathDerivedID, isEnabled: true, manifestKey: nil,
            optionsPagePath: "options.html", sessionIsPersistent: true
        ))
        XCTAssertNil(ExtensionActionPopupSupport.optionsPageURL(
            extensionID: addressableID, isEnabled: true, manifestKey: fixedPublicKey,
            optionsPagePath: "options.html", sessionIsPersistent: false
        ))
    }

    // MARK: - Settings options entry

    func test_settingsOptionsPageURL_nilForAnExtensionTheRunningEngineHasNotActivated() {
        XCTAssertNil(
            ExtensionActionPopupSupport.settingsOptionsPageURL(
                extensionID: addressableID, isEnabled: true, isActivatedInRunningEngine: false,
                manifestKey: fixedPublicKey, optionsPagePath: "options.html", sessionIsPersistent: true
            ),
            "its chrome-extension:// origin answers nothing until Orbit restarts, so Settings must not offer the link"
        )
    }

    func test_settingsOptionsPageURL_matchesOptionsPageURLOnceActivated() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.settingsOptionsPageURL(
                extensionID: addressableID, isEnabled: true, isActivatedInRunningEngine: true,
                manifestKey: fixedPublicKey, optionsPagePath: "options.html", sessionIsPersistent: true
            ),
            ExtensionActionPopupSupport.optionsPageURL(
                extensionID: addressableID, isEnabled: true, manifestKey: fixedPublicKey,
                optionsPagePath: "options.html", sessionIsPersistent: true
            )
        )
    }

    func test_settingsOptionsPageURL_stillRefusesAPathDerivedID() {
        XCTAssertNil(ExtensionActionPopupSupport.settingsOptionsPageURL(
            extensionID: pathDerivedID, isEnabled: true, isActivatedInRunningEngine: true,
            manifestKey: nil, optionsPagePath: "options.html", sessionIsPersistent: true
        ))
    }

    func test_settingsOptionsPageURL_nilForAnExtensionWithNoOptionsPage() {
        XCTAssertNil(ExtensionActionPopupSupport.settingsOptionsPageURL(
            extensionID: addressableID, isEnabled: true, isActivatedInRunningEngine: true,
            manifestKey: fixedPublicKey, optionsPagePath: nil, sessionIsPersistent: true
        ))
    }

    // MARK: - Restart-to-activate gate

    func test_requiresRestartToActivate_falseWhenTheEngineHasActuallyLoadedIt() {
        XCTAssertFalse(ExtensionActionPopupSupport.requiresRestartToActivate(isActivatedInRunningEngine: true))
    }

    func test_requiresRestartToActivate_trueForAJustInstalledExtensionTheRunningEngineNeverLoaded() {
        XCTAssertTrue(
            ExtensionActionPopupSupport.requiresRestartToActivate(isActivatedInRunningEngine: false),
            "A just-installed extension is enabled in the store but --load-extension is only read at browser start-up, so it is not actually running — its action must not be treated as live."
        )
    }

    // MARK: - Popup sizing clamps

    func test_clampedPopupSize_returnsTheDefaultWhenNothingHasBeenMeasuredYet() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.clampedPopupSize(nil),
            ExtensionActionPopupSupport.popupDefaultSize
        )
    }

    func test_clampedPopupSize_passesThroughASizeAlreadyInsideChromesBounds() {
        let size = CGSize(width: 300, height: 250)
        XCTAssertEqual(ExtensionActionPopupSupport.clampedPopupSize(size), size)
    }

    func test_clampedPopupSize_clampsBelowChromesMinimum() {
        let clamped = ExtensionActionPopupSupport.clampedPopupSize(CGSize(width: 1, height: 1))
        XCTAssertEqual(clamped, ExtensionActionPopupSupport.popupMinimumSize)
    }

    func test_clampedPopupSize_clampsAboveChromesMaximum() {
        let clamped = ExtensionActionPopupSupport.clampedPopupSize(CGSize(width: 4000, height: 4000))
        XCTAssertEqual(clamped, ExtensionActionPopupSupport.popupMaximumSize)
    }

    func test_clampedPopupSize_clampsEachDimensionIndependently() {
        let clamped = ExtensionActionPopupSupport.clampedPopupSize(CGSize(width: 4000, height: 100))
        XCTAssertEqual(clamped.width, ExtensionActionPopupSupport.popupMaximumSize.width)
        XCTAssertEqual(clamped.height, 100)
    }

    // MARK: - Icon fallback chain

    func test_actionIconChoice_prefersTheActionIconFirst() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: true, hasExtensionIcon: true),
            .actionIcon
        )
    }

    func test_actionIconChoice_fallsBackToTheExtensionIcon() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: false, hasExtensionIcon: true),
            .extensionIcon
        )
    }

    func test_actionIconChoice_fallsBackToTheGenericGlyphWhenNeitherExists() {
        XCTAssertEqual(
            ExtensionActionPopupSupport.actionIconChoice(hasActionIcon: false, hasExtensionIcon: false),
            .genericGlyph
        )
    }

    func test_actionIconFileURL_joinsTheRelativePathOntoTheExtensionDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/ExtensionActionPopupTests-fixture", isDirectory: true)
        XCTAssertEqual(
            ExtensionActionPopupSupport.actionIconFileURL(extensionDirectory: directory, relativePath: "icons/action-128.png"),
            directory.appendingPathComponent("icons/action-128.png")
        )
    }

    func test_actionIconFileURL_nilWithNoRelativePath() {
        let directory = URL(fileURLWithPath: "/tmp/ExtensionActionPopupTests-fixture", isDirectory: true)
        XCTAssertNil(ExtensionActionPopupSupport.actionIconFileURL(extensionDirectory: directory, relativePath: nil))
        XCTAssertNil(ExtensionActionPopupSupport.actionIconFileURL(extensionDirectory: directory, relativePath: ""))
    }
}
