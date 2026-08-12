import XCTest

final class ChromeExtensionManifestTests: XCTestCase {

    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeExtensionDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ChromeExtensionManifest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    private func writeManifest(_ json: [String: Any], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func writeLocaleMessages(_ json: [String: Any], locale: String, in directory: URL) throws {
        let localeDirectory = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
        try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: localeDirectory.appendingPathComponent("messages.json"))
    }

    // MARK: - Toolbar action: MV3 `action` and MV2 `browser_action`

    func test_mv3ActionKey_setsHasToolbarAction() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV3 Extension", "version": "1.0", "manifest_version": 3,
            "action": [:],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertTrue(manifest.hasToolbarAction)
    }

    func test_mv2BrowserActionKey_setsHasToolbarAction() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Extension", "version": "1.0", "manifest_version": 2,
            "browser_action": [:],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertTrue(manifest.hasToolbarAction)
    }

    func test_neitherActionKey_hasToolbarActionIsFalse() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "Background Only", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertFalse(manifest.hasToolbarAction)
    }

    // MARK: - `__MSG_x__` name resolution

    func test_msgNamePlaceholder_resolvesThroughDefaultLocaleMessages() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "__MSG_extName__", "version": "1.0", "default_locale": "en",
        ], in: directory)
        try writeLocaleMessages(["extName": ["message": "Resolved Display Name"]], locale: "en", in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.name, "Resolved Display Name")
    }

    func test_msgNamePlaceholder_resolvesCaseInsensitively() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "__MSG_extName__", "version": "1.0", "default_locale": "en",
        ], in: directory)
        try writeLocaleMessages(["ExtName": ["message": "Case Insensitive Match"]], locale: "en", in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.name, "Case Insensitive Match")
    }

    func test_msgNamePlaceholder_fallsBackToRawPlaceholder_whenLocaleFileIsMissing() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "__MSG_extName__", "version": "1.0", "default_locale": "en",
        ], in: directory)
        // Deliberately no _locales/en/messages.json written at all.

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.name, "__MSG_extName__")
    }

    func test_msgNamePlaceholder_fallsBackToRawPlaceholder_whenNoDefaultLocaleDeclared() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "__MSG_extName__", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.name, "__MSG_extName__")
    }

    func test_ordinaryName_isNotTreatedAsAPlaceholder() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "An Ordinary Extension", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.name, "An Ordinary Extension")
    }

    // MARK: - Icons

    func test_largestIconSizeWins() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Icon Extension", "version": "1.0",
            "icons": ["16": "icon16.png", "128": "icon128.png", "48": "icon48.png"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.iconRelativePath, "icon128.png")
    }

    func test_noIconsKey_iconRelativePathIsNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Icons", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.iconRelativePath)
    }

    // MARK: - Required fields

    func test_missingName_throwsManifestInvalid() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["version": "1.0"], in: directory)

        XCTAssertThrowsError(try ChromeExtensionManifest.read(fromDirectory: directory)) { error in
            guard case ExtensionStoreError.manifestInvalid = error else {
                return XCTFail("Expected .manifestInvalid, got \(error)")
            }
        }
    }

    func test_emptyName_throwsManifestInvalid() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "", "version": "1.0"], in: directory)

        XCTAssertThrowsError(try ChromeExtensionManifest.read(fromDirectory: directory)) { error in
            guard case ExtensionStoreError.manifestInvalid = error else {
                return XCTFail("Expected .manifestInvalid, got \(error)")
            }
        }
    }

    func test_missingVersion_throwsManifestInvalid() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Version"], in: directory)

        XCTAssertThrowsError(try ChromeExtensionManifest.read(fromDirectory: directory)) { error in
            guard case ExtensionStoreError.manifestInvalid = error else {
                return XCTFail("Expected .manifestInvalid, got \(error)")
            }
        }
    }

    func test_missingManifestFile_throwsManifestMissing() {
        let directory = makeExtensionDirectory()
        // No manifest.json written at all.

        XCTAssertThrowsError(try ChromeExtensionManifest.read(fromDirectory: directory)) { error in
            guard case ExtensionStoreError.manifestMissing(let url) = error else {
                return XCTFail("Expected .manifestMissing, got \(error)")
            }
            XCTAssertEqual(url, directory.appendingPathComponent("manifest.json"))
        }
    }

    // MARK: - manifest_version and key

    func test_manifestVersionDefaultsToThree_whenAbsent() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Manifest Version", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.manifestVersion, 3)
    }

    func test_manifestVersionIsReadWhenPresent() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "MV2", "version": "1.0", "manifest_version": 2], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.manifestVersion, 2)
    }

    func test_keyFieldIsReadVerbatimWhenPresent_andNilWhenAbsent() throws {
        let signedDirectory = makeExtensionDirectory()
        try writeManifest(["name": "Signed", "version": "1.0", "key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="], in: signedDirectory)
        let signedManifest = try ChromeExtensionManifest.read(fromDirectory: signedDirectory)
        XCTAssertEqual(signedManifest.key, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

        let unsignedDirectory = makeExtensionDirectory()
        try writeManifest(["name": "Unsigned", "version": "1.0"], in: unsignedDirectory)
        let unsignedManifest = try ChromeExtensionManifest.read(fromDirectory: unsignedDirectory)
        XCTAssertNil(unsignedManifest.key)
    }

    // MARK: - `description`, including `__MSG_…__` resolution

    func test_ordinaryDescription_isReadVerbatim() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "Has Description", "version": "1.0", "description": "Does a thing."], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.description, "Does a thing.")
    }

    func test_msgDescriptionPlaceholder_resolvesThroughDefaultLocaleMessages() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Localized Description Extension", "version": "1.0",
            "description": "__MSG_extDesc__", "default_locale": "en",
        ], in: directory)
        try writeLocaleMessages(["extDesc": ["message": "Resolved Description Text"]], locale: "en", in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.description, "Resolved Description Text")
    }

    func test_msgDescriptionPlaceholder_fallsBackToRawPlaceholder_whenLocaleFileIsMissing() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "No Locale File", "version": "1.0",
            "description": "__MSG_extDesc__", "default_locale": "en",
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.description, "__MSG_extDesc__")
    }

    func test_noDescriptionKey_descriptionIsNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Description", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.description)
    }

    // MARK: - Permissions: MV3 shape (clean separation)

    func test_mv3Permissions_readsPermissionsAndHostPermissionsSeparately() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV3 Permissions", "version": "1.0", "manifest_version": 3,
            "permissions": ["storage", "tabs", "scripting"],
            "host_permissions": ["https://*.example.com/*", "<all_urls>"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.permissions, ["storage", "tabs", "scripting"])
        XCTAssertEqual(manifest.hostPermissions, ["https://*.example.com/*", "<all_urls>"])
    }

    func test_mv3OptionalPermissions_readsSeparately() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV3 Optional Permissions", "version": "1.0", "manifest_version": 3,
            "optional_permissions": ["geolocation"],
            "optional_host_permissions": ["https://*.dropbox.com/*"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.optionalPermissions, ["geolocation"])
        XCTAssertEqual(manifest.optionalHostPermissions, ["https://*.dropbox.com/*"])
        XCTAssertTrue(manifest.permissions.isEmpty)
        XCTAssertTrue(manifest.hostPermissions.isEmpty)
    }

    // MARK: - Permissions: MV2 shape (mixed key, must be split)

    func test_mv2Permissions_splitsMixedArrayIntoPermissionsAndHostPermissions() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Mixed Permissions", "version": "1.0", "manifest_version": 2,
            "permissions": ["storage", "tabs", "https://*.example.com/*", "<all_urls>", "http://*/*"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.permissions, ["storage", "tabs"])
        XCTAssertEqual(manifest.hostPermissions, ["https://*.example.com/*", "<all_urls>", "http://*/*"])
    }

    func test_mv2OptionalPermissions_splitsMixedArray() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Mixed Optional Permissions", "version": "1.0", "manifest_version": 2,
            "optional_permissions": ["clipboardRead", "*://*.example.com/*"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.optionalPermissions, ["clipboardRead"])
        XCTAssertEqual(manifest.optionalHostPermissions, ["*://*.example.com/*"])
    }

    func test_mv2Permissions_allAPIPermissions_yieldsEmptyHostPermissions() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 API Only", "version": "1.0", "manifest_version": 2,
            "permissions": ["storage", "contextMenus"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.permissions, ["storage", "contextMenus"])
        XCTAssertTrue(manifest.hostPermissions.isEmpty)
    }

    // MARK: - Content script matches

    func test_contentScriptMatches_unionsAcrossEntries_dedupingAndPreservingOrder() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Content Scripts", "version": "1.0",
            "content_scripts": [
                ["matches": ["https://a.example.com/*", "https://b.example.com/*"], "js": ["a.js"]],
                ["matches": ["https://b.example.com/*", "https://c.example.com/*"], "js": ["b.js"]],
            ],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.contentScriptMatches, [
            "https://a.example.com/*", "https://b.example.com/*", "https://c.example.com/*",
        ])
    }

    func test_noContentScriptsKey_contentScriptMatchesIsEmpty() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Content Scripts", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertTrue(manifest.contentScriptMatches.isEmpty)
    }

    // MARK: - Action: popup, title, icon — MV3 `action` and MV2 `browser_action`

    func test_mv3Action_readsPopupTitleAndIcon() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV3 Action", "version": "1.0", "manifest_version": 3,
            "action": [
                "default_popup": "popup.html",
                "default_title": "My Extension",
                "default_icon": ["16": "icon16.png", "48": "icon48.png"],
            ],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.actionPopupPath, "popup.html")
        XCTAssertEqual(manifest.actionTitle, "My Extension")
        XCTAssertEqual(manifest.actionIconRelativePath, "icon48.png")
    }

    func test_mv2BrowserAction_readsPopupTitleAndIcon() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Browser Action", "version": "1.0", "manifest_version": 2,
            "browser_action": [
                "default_popup": "popup.html",
                "default_title": "My MV2 Extension",
                "default_icon": ["19": "icon19.png", "38": "icon38.png"],
            ],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.actionPopupPath, "popup.html")
        XCTAssertEqual(manifest.actionTitle, "My MV2 Extension")
        XCTAssertEqual(manifest.actionIconRelativePath, "icon38.png")
    }

    func test_actionDefaultIcon_asBareString_isReadDirectly() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Bare String Icon", "version": "1.0",
            "action": ["default_icon": "action-icon.png"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.actionIconRelativePath, "action-icon.png")
    }

    func test_actionTitle_resolvesMsgPlaceholder() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Action Title I18n", "version": "1.0", "default_locale": "en",
            "action": ["default_title": "__MSG_actionTitle__"],
        ], in: directory)
        try writeLocaleMessages(["actionTitle": ["message": "Resolved Action Title"]], locale: "en", in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.actionTitle, "Resolved Action Title")
    }

    func test_actionIconRelativePath_isDistinctFromExtensionIconRelativePath() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Distinct Icons", "version": "1.0",
            "icons": ["128": "general-icon.png"],
            "action": ["default_icon": "toolbar-icon.png"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.iconRelativePath, "general-icon.png")
        XCTAssertEqual(manifest.actionIconRelativePath, "toolbar-icon.png")
    }

    func test_noActionKey_actionFieldsAreNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Action", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.actionPopupPath)
        XCTAssertNil(manifest.actionTitle)
        XCTAssertNil(manifest.actionIconRelativePath)
    }

    // MARK: - Options page: `options_ui` vs legacy `options_page`

    func test_optionsUIPage_isPreferred() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Options UI", "version": "1.0",
            "options_ui": ["page": "options.html", "open_in_tab": true],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.optionsPagePath, "options.html")
        XCTAssertTrue(manifest.optionsOpenInTab)
    }

    func test_legacyOptionsPage_isReadWhenNoOptionsUI() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Legacy Options Page", "version": "1.0",
            "options_page": "legacy-options.html",
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.optionsPagePath, "legacy-options.html")
    }

    func test_optionsOpenInTab_defaultsToFalse_whenAbsent() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "Options No Open In Tab", "version": "1.0",
            "options_ui": ["page": "options.html"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertFalse(manifest.optionsOpenInTab)
    }

    func test_noOptionsKey_optionsPagePathIsNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Options", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.optionsPagePath)
        XCTAssertFalse(manifest.optionsOpenInTab)
    }

    // MARK: - Background context

    func test_mv3BackgroundServiceWorker_isReadVerbatim() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV3 Background", "version": "1.0", "manifest_version": 3,
            "background": ["service_worker": "sw.js"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.backgroundServiceWorkerPath, "sw.js")
    }

    func test_mv2BackgroundPage_isReadVerbatim() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Background Page", "version": "1.0", "manifest_version": 2,
            "background": ["page": "background.html"],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.backgroundServiceWorkerPath, "background.html")
    }

    func test_mv2BackgroundScripts_usesFirstEntry() throws {
        let directory = makeExtensionDirectory()
        try writeManifest([
            "name": "MV2 Background Scripts", "version": "1.0", "manifest_version": 2,
            "background": ["scripts": ["first.js", "second.js"]],
        ], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.backgroundServiceWorkerPath, "first.js")
    }

    func test_noBackgroundKey_backgroundServiceWorkerPathIsNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Background", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.backgroundServiceWorkerPath)
    }

    // MARK: - `minimum_chrome_version`

    func test_minimumChromeVersion_isReadVerbatimWhenPresent() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "Min Version", "version": "1.0", "minimum_chrome_version": "116"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertEqual(manifest.minimumChromeVersion, "116")
    }

    func test_noMinimumChromeVersionKey_isNil() throws {
        let directory = makeExtensionDirectory()
        try writeManifest(["name": "No Min Version", "version": "1.0"], in: directory)

        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        XCTAssertNil(manifest.minimumChromeVersion)
    }
}
