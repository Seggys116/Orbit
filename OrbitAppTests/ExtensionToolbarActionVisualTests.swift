//  SiteControlPopoverVisualTests.swift's FakeEngine.loadedExtensions always
//  returns [], so the toolbar icon grid was never exercised against a real extension.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ExtensionToolbarActionVisualTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture: a real, on-disk extension directory

    private static let mismatchedKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    @discardableResult
    private func makeExtensionDirectory(
        name: String = "Fixture Extension",
        manifestKey: String?,
        hasToolbarActionInManifest: Bool = true,
        hasActionIcon: Bool = true,
        hasExtensionIcon: Bool = false,
        actionPopupPath: String? = "popup.html",
        optionsPagePath: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ToolbarActionFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        var manifest: [String: Any] = [
            "manifest_version": 3,
            "name": name,
            "version": "1.0",
        ]
        if let manifestKey { manifest["key"] = manifestKey }
        if hasToolbarActionInManifest {
            var action: [String: Any] = [:]
            if let actionPopupPath { action["default_popup"] = actionPopupPath }
            if hasActionIcon { action["default_icon"] = "action_icon.png" }
            manifest["action"] = action
        }
        if hasExtensionIcon { manifest["icons"] = ["128": "extension_icon.png"] }
        if let optionsPagePath { manifest["options_page"] = optionsPagePath }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        try data.write(to: directory.appendingPathComponent("manifest.json"))

        if hasActionIcon {
            try Self.writePNG(color: .systemBlue, to: directory.appendingPathComponent("action_icon.png"))
        }
        if hasExtensionIcon {
            try Self.writePNG(color: .systemRed, to: directory.appendingPathComponent("extension_icon.png"))
        }
        if let actionPopupPath {
            try "<html><body>popup</body></html>".write(
                to: directory.appendingPathComponent(actionPopupPath), atomically: true, encoding: .utf8
            )
        }
        if let optionsPagePath {
            try "<html><body>options</body></html>".write(
                to: directory.appendingPathComponent(optionsPagePath), atomically: true, encoding: .utf8
            )
        }
        return directory
    }

    private static func pngData(color: NSColor, size: Int = 48) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ExtensionToolbarActionVisualTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        return data
    }

    private static func writePNG(color: NSColor, to url: URL, size: Int = 48) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ExtensionToolbarActionVisualTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: url)
    }

    private func makeLoadedExtension(
        directory: URL,
        id: String = "abcdefghijklmnopabcdefghijklmnop",
        isEnabled: Bool = true,
        hasToolbarAction: Bool = true,
        isActivated: Bool = true,
        idIsEngineAssigned: Bool = false
    ) -> LoadedExtension {
        LoadedExtension(
            id: id, name: "Fixture Extension", version: "1.0", directory: directory,
            iconURL: nil, hasToolbarAction: hasToolbarAction, manifestVersion: 3,
            isEnabled: isEnabled, isActivated: isActivated, idIsEngineAssigned: idIsEngineAssigned
        )
    }

    // MARK: - extensionActionEntries: addressability (honesty requirement 2)

    func test_extensionActionEntries_includesAnExtensionWhoseManifestKeyRecomputesToItsOwnID() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.contains { $0.id == id }, "an extension whose manifest key recomputes to its own id must get a toolbar entry")
    }

    // "Load Unpacked Extension" never writes a "key" into manifest.json;
    // Chromium derives such an extension's id from its own directory path instead. This used to assert the opposite.
    func test_extensionActionEntries_includesAPathDerivedExtensionWithNoManifestKeyDeclaringAPopup() throws {
        let directory = try makeExtensionDirectory(manifestKey: nil)
        let id = ChromeExtensionID.id(forUnpackedPath: directory)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        let entry = try XCTUnwrap(
            entries.first { $0.id == id },
            "a keyless, path-derived unpacked extension (Orbit's own supported 'Load Unpacked Extension' flow) declaring a popup must get a toolbar icon"
        )
        XCTAssertEqual(entry.popupURL, URL(string: "chrome-extension://\(id)/popup.html"))
    }

    // The other half of the same fix: an id that is neither key-derived nor path-derived is
    // still refused, so the rule did not degrade into "trust anything".
    func test_extensionActionEntries_excludesAKeylessExtensionWhoseIDIsNotItsPathDerivedID() throws {
        let directory = try makeExtensionDirectory(manifestKey: nil)
        let engine = StubEngine(extensions: [
            makeLoadedExtension(directory: directory, id: "abcdefghijklmnopabcdefghijklmnop"),
        ])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.isEmpty, "a keyless id that does not match its own directory path must not be treated as addressable")
    }

    // The engine's own id needs no recomputation at all: orbit_extension_loader.cc reports
    // extension.id() verbatim, and that is the only id its chrome-extension:// origin answers to.
    func test_extensionActionEntries_includesAnEngineAssignedIDThatMatchesNeitherKeyNorPath() throws {
        let directory = try makeExtensionDirectory(manifestKey: nil)
        let id = "ponmlkjihgfedcbaponmlkjihgfedcba"
        let engine = StubEngine(extensions: [
            makeLoadedExtension(directory: directory, id: id, idIsEngineAssigned: true),
        ])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.contains { $0.id == id })
    }

    func test_extensionActionEntries_excludesAnExtensionWhoseManifestKeyDoesNotMatchItsOwnID() throws {
        let directory = try makeExtensionDirectory(manifestKey: Self.mismatchedKey)
        // Deliberately NOT the id the key recomputes to.
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: "abcdefghijklmnopabcdefghijklmnop")])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.isEmpty, "an id that does not match its own manifest key must never get a toolbar entry")
    }

    // MARK: - extensionActionEntries: the other gates

    func test_extensionActionEntries_excludesADisabledExtension() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id, isEnabled: false)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.isEmpty, "a disabled extension must never show a toolbar action icon")
    }

    func test_extensionActionEntries_excludesAnExtensionWithNoToolbarActionDeclared() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key, hasToolbarActionInManifest: false)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id, hasToolbarAction: false)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.isEmpty)
    }

    func test_extensionActionEntries_excludesAnExtensionWithAnUnreadableManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ToolbarActionFixture-NoManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        XCTAssertTrue(entries.isEmpty, "a directory with no readable manifest.json must be skipped, not crash the whole list")
    }

    func test_extensionActionEntries_resolvesTheRealActionIconFileFromDisk() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key, hasActionIcon: true)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id)])

        let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
        let entry = try XCTUnwrap(entries.first { $0.id == id })
        let iconURL = try XCTUnwrap(entry.actionIconFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path), "actionIconFileURL must point at a real file, not just a constructed path")
    }

    func test_extensionActionEntries_optionsURLIsNilWhenNoOptionsPageIsDeclared() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key, optionsPagePath: nil)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id)])

        let entry = try XCTUnwrap(SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession).first)
        XCTAssertNil(entry.optionsURL)
    }

    func test_extensionActionEntries_optionsURLIsPresentWhenDeclared() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key, optionsPagePath: "options.html")
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id)])

        let entry = try XCTUnwrap(SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession).first)
        XCTAssertNotNil(entry.optionsURL)
    }

    func test_extensionActionEntries_returnsEmptyForANilEngineOrSession() {
        XCTAssertTrue(SiteControlPopoverView.extensionActionEntries(engine: nil, session: nil).isEmpty)
    }

    // MARK: - Popup open/close toggle semantics

    func test_nextOpenExtensionPopup_requestingTheCurrentlyOpenPopupClosesIt() {
        let identity = SiteControlPopoverView.OpenExtensionPopup(extensionID: "abcdefghijklmnopabcdefghijklmnop", kind: .action)
        XCTAssertNil(SiteControlPopoverView.nextOpenExtensionPopup(current: identity, requesting: identity))
    }

    func test_nextOpenExtensionPopup_requestingADifferentPopupReplacesTheOpenOne() {
        let first = SiteControlPopoverView.OpenExtensionPopup(extensionID: "abcdefghijklmnopabcdefghijklmnop", kind: .action)
        let second = SiteControlPopoverView.OpenExtensionPopup(extensionID: "abcdefghijklmnopabcdefghijklmnop", kind: .options)
        XCTAssertEqual(SiteControlPopoverView.nextOpenExtensionPopup(current: first, requesting: second), second)
    }

    func test_nextOpenExtensionPopup_requestingAnyPopupWhenNoneIsOpenOpensIt() {
        let target = SiteControlPopoverView.OpenExtensionPopup(extensionID: "abcdefghijklmnopabcdefghijklmnop", kind: .action)
        XCTAssertEqual(SiteControlPopoverView.nextOpenExtensionPopup(current: nil, requesting: target), target)
    }

    func test_presentation_isPendingActivationForAnExtensionNotYetActivatedInTheRunningEngine() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id, isActivated: false)])
        let entry = try XCTUnwrap(SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession).first)

        XCTAssertEqual(SiteControlPopoverView.presentation(for: entry, url: entry.popupURL), .pendingActivation)
    }

    func test_presentation_isLiveForAnActivatedExtension() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(extensions: [makeLoadedExtension(directory: directory, id: id, isActivated: true)])
        let entry = try XCTUnwrap(SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession).first)

        XCTAssertEqual(SiteControlPopoverView.presentation(for: entry, url: entry.popupURL), .live(url: entry.popupURL))
    }

    func test_enabledExtensionCount_countsOnlyEnabledExtensions() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let secondDirectory = try makeExtensionDirectory(name: "Second", manifestKey: key)
        let engine = StubEngine(extensions: [
            makeLoadedExtension(directory: directory, id: id, isEnabled: true),
            makeLoadedExtension(directory: secondDirectory, id: "abcdefghijklmnopabcdefghijklmnoq", isEnabled: false),
        ])
        XCTAssertEqual(SiteControlPopoverView.enabledExtensionCount(engine: engine), 1)
    }

    // MARK: - Visual: the icon grid actually paints a real manifest icon, not just the generic glyph

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private static let canvasSize = CGSize(width: 420, height: 760)

    @discardableResult
    private func seedPopover(
        loadedExtensions: [LoadedExtension],
        actionSnapshots: [ExtensionActionSnapshot] = []
    ) -> (tab: Orbit.Tab, session: MockEngineSession)? {
        OrbitScreenshotFixtures.configure(env)
        guard let tab = env.activeTab, tab.url.host() != nil else {
            XCTFail("expected OrbitState.demo's active tab to carry a real, hosted URL")
            return nil
        }
        let session = MockEngineSession(identifier: "toolbar-action-visual-fixture", isPersistent: true)
        let webContents = MockWebContents(session: session)
        webContents.navigationState = NavigationState(
            url: tab.url, title: tab.title, canGoBack: true, canGoForward: false, isLoading: false, progress: 1, security: .secure
        )
        env._test_attachWebContents(webContents, for: tab.id)
        env._test_engineOverride = StubEngine(
            session: session, extensions: loadedExtensions, actionSnapshots: actionSnapshots
        )
        return (tab, session)
    }

    func test_extensionActionIcon_rendersARealManifestIconFile_differentlyFromTheGenericGlyphFallback() throws {
        let keyA = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        let idA = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyA))
        let withRealIcon = try makeExtensionDirectory(name: "Real Icon", manifestKey: keyA, hasActionIcon: true)

        guard let (tab, _) = seedPopover(loadedExtensions: [
            makeLoadedExtension(directory: withRealIcon, id: idA),
        ]) else { return }
        let withIcon = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        let keyB = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHw=="
        let idB = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyB))
        let withoutIcon = try makeExtensionDirectory(name: "No Icon", manifestKey: keyB, hasActionIcon: false, hasExtensionIcon: false)
        guard let (tab2, _) = seedPopover(loadedExtensions: [
            makeLoadedExtension(directory: withoutIcon, id: idB),
        ]) else { return }
        let withGenericGlyph = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withIcon, withGenericGlyph, size: Self.canvasSize),
            "an extension with a real action icon file rendered pixel-identical to one with no icon at all (generic glyph fallback) -- the toolbar icon is not actually drawing the extension's own manifest icon"
        )
    }

    func test_extensionsRow_withARealAddressableExtension_rendersDifferentlyFromNoExtensions() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)

        guard let (tab, _) = seedPopover(loadedExtensions: []) else { return }
        let withNoExtensions = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        guard let (tab2, _) = seedPopover(loadedExtensions: [makeLoadedExtension(directory: directory, id: id)]) else { return }
        let withOneExtension = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withNoExtensions, withOneExtension, size: Self.canvasSize),
            "a real, addressable, enabled extension declaring a toolbar action rendered identically to having none installed"
        )
    }

    func test_extensionOptionsAffordance_appearsOnlyWhenAnOptionsPageIsDeclared() throws {
        let keyA = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        let idA = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyA))
        let withOptions = try makeExtensionDirectory(name: "With Options", manifestKey: keyA, optionsPagePath: "options.html")
        guard let (tab, _) = seedPopover(loadedExtensions: [makeLoadedExtension(directory: withOptions, id: idA)]) else { return }
        let rendered1 = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        let keyB = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHw=="
        let idB = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyB))
        let withoutOptions = try makeExtensionDirectory(name: "Without Options", manifestKey: keyB, optionsPagePath: nil)
        guard let (tab2, _) = seedPopover(loadedExtensions: [makeLoadedExtension(directory: withoutOptions, id: idB)]) else { return }
        let rendered2 = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(rendered1, rendered2, size: Self.canvasSize),
            "declaring options_page did not change anything rendered in the toolbar action icon -- the gear affordance is not reflecting real manifest state"
        )
    }

    // MARK: - chrome.action: badge, per-tab isolation, enable/disable

    private func snapshot(
        extensionID: String,
        defaults: ExtensionActionState = ExtensionActionState(),
        perTab: [Int32: ExtensionActionState] = [:]
    ) -> ExtensionActionSnapshot {
        ExtensionActionSnapshot(extensionID: extensionID, defaults: defaults, perTab: perTab)
    }

    func test_extensionActionEntries_carryTheBadgeTextTheEngineRelayedForThisTab() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(
            extensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, perTab: [1: ExtensionActionState(badgeText: "12")])]
        )

        let onTabOne = SiteControlPopoverView.extensionActionEntries(
            engine: engine, session: engine.defaultSession, tabID: 1
        )
        XCTAssertEqual(try XCTUnwrap(onTabOne.first).badgeText, "12")
    }

    func test_extensionActionEntries_aBadgeSetOnOneTabDoesNotAppearOnAnother() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(
            extensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, perTab: [1: ExtensionActionState(badgeText: "12")])]
        )

        let onTabTwo = SiteControlPopoverView.extensionActionEntries(
            engine: engine, session: engine.defaultSession, tabID: 2
        )
        XCTAssertNil(
            try XCTUnwrap(onTabTwo.first).badgeText,
            "chrome.action.setBadgeText({tabId: 1}) leaked onto tab 2 -- badges are per-tab in Chrome's model"
        )
    }

    func test_extensionActionEntries_reportTheDisabledStateChromeActionDisableSetForThisTab() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(
            extensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(
                extensionID: id,
                perTab: [1: ExtensionActionState(isEnabled: false)]
            )]
        )

        let disabled = SiteControlPopoverView.extensionActionEntries(
            engine: engine, session: engine.defaultSession, tabID: 1
        )
        XCTAssertFalse(try XCTUnwrap(disabled.first).actionState.isEnabled)

        let enabled = SiteControlPopoverView.extensionActionEntries(
            engine: engine, session: engine.defaultSession, tabID: 2
        )
        XCTAssertTrue(
            try XCTUnwrap(enabled.first).actionState.isEnabled,
            "chrome.action.disable({tabId: 1}) must not disable the icon on every other tab"
        )
    }

    func test_extensionActionEntries_useTheEngineReportedPopupWhenChromeActionSetPopupChangedIt() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)
        let engine = StubEngine(
            extensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(
                extensionID: id,
                defaults: ExtensionActionState(popupURLString: "chrome-extension://\(id)/other.html")
            )]
        )

        let entry = try XCTUnwrap(
            SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession).first
        )
        XCTAssertEqual(entry.popupURL, URL(string: "chrome-extension://\(id)/other.html"))
    }

    // MARK: - Visual: the badge and the disabled state actually reach the pixels

    func test_extensionActionIcon_withABadge_rendersDifferentlyFromTheSameIconWithout() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)

        guard let (tab, _) = seedPopover(loadedExtensions: [makeLoadedExtension(directory: directory, id: id)]) else { return }
        let withoutBadge = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        guard let (tab2, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, defaults: ExtensionActionState(badgeText: "12"))]
        ) else { return }
        let withBadge = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withoutBadge, withBadge, size: Self.canvasSize),
            "chrome.action.setBadgeText produced no pixel difference in the toolbar -- the badge is not being drawn"
        )
    }

    func test_extensionActionIcon_badgeBackgroundColourReachesThePixels() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)

        let green = ExtensionActionColor(red: 0, green: 200, blue: 0, alpha: 255)
        let blue = ExtensionActionColor(red: 0, green: 0, blue: 200, alpha: 255)

        guard let (tab, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(
                extensionID: id,
                defaults: ExtensionActionState(badgeText: "12", badgeBackgroundColor: green)
            )]
        ) else { return }
        let greenBadge = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        guard let (tab2, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(
                extensionID: id,
                defaults: ExtensionActionState(badgeText: "12", badgeBackgroundColor: blue)
            )]
        ) else { return }
        let blueBadge = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(greenBadge, blueBadge, size: Self.canvasSize),
            "chrome.action.setBadgeBackgroundColor made no pixel difference -- the badge colour is being ignored"
        )
    }

    func test_extensionActionIcon_disabledRendersDifferentlyFromEnabled() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        let directory = try makeExtensionDirectory(manifestKey: key)

        guard let (tab, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, defaults: ExtensionActionState(isEnabled: true))]
        ) else { return }
        let enabled = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        guard let (tab2, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, defaults: ExtensionActionState(isEnabled: false))]
        ) else { return }
        let disabled = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(enabled, disabled, size: Self.canvasSize),
            "chrome.action.disable() left the toolbar icon looking identical -- the disabled state is not rendered"
        )
    }

    func test_extensionActionIcon_dynamicSetIconOverridesTheManifestIconFile() throws {
        let key = Self.mismatchedKey
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
        // The manifest icon is solid blue (see makeExtensionDirectory); the dynamic one is green.
        let directory = try makeExtensionDirectory(manifestKey: key, hasActionIcon: true)
        let dynamicIcon = try Self.pngData(color: .systemGreen)

        guard let (tab, _) = seedPopover(loadedExtensions: [makeLoadedExtension(directory: directory, id: id)]) else { return }
        let manifestIcon = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        guard let (tab2, _) = seedPopover(
            loadedExtensions: [makeLoadedExtension(directory: directory, id: id)],
            actionSnapshots: [snapshot(extensionID: id, defaults: ExtensionActionState(iconPNG: dynamicIcon))]
        ) else { return }
        let dynamic = render(SiteControlPopoverView(tab: tab2).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(manifestIcon, dynamic, size: Self.canvasSize),
            "chrome.action.setIcon's bitmap did not replace the manifest's own default_icon in the toolbar"
        )
    }

    // MARK: - A minimal, mutable BrowserEngine stand-in whose loadedExtensions is fully controlled

    private final class StubEngine: BrowserEngine {
        static let kind: EngineKind = .chromium
        var capabilities: EngineCapabilities = [.extensions]
        var manageableContentSettings: Set<PermissionKind> = []
        var extensionActivation: ExtensionActivation = .nextLaunch
        var versionDescription = "StubEngine (ExtensionToolbarActionVisualTests -- no real engine is running)"

        private let session: EngineSession
        private let extensions: [LoadedExtension]
        let extensionActionStates = ExtensionActionStateStore()

        init(
            session: EngineSession? = nil,
            extensions: [LoadedExtension],
            actionSnapshots: [ExtensionActionSnapshot] = []
        ) {
            self.session = session ?? MockEngineSession(identifier: "toolbar-action-stub", isPersistent: true)
            self.extensions = extensions
            extensionActionStates.replaceAll(actionSnapshots)
        }

        func start() throws {}
        func shutdown() -> Bool { true }
        func tick() {}
        func session(identifier: String, persistent: Bool) throws -> EngineSession { session }
        var defaultSession: EngineSession { session }
        func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
            throw EngineError(code: .engineUnavailable)
        }
        func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
        func addUserScript(_ script: UserScript, session: EngineSession) {}
        func removeUserScript(id: UUID, session: EngineSession) {}
        func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}
        func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
            throw EngineError(code: .engineUnavailable)
        }
        func unloadExtension(id: String, session: EngineSession) {}
        func loadedExtensions(session: EngineSession) -> [LoadedExtension] { extensions }
    }

    // MARK: - Colour distance

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 6
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}
