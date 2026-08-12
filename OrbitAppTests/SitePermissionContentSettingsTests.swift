import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class SitePermissionContentSettingsTests: XCTestCase {

    // MARK: - Origin normalisation

    func test_originNormalisationMatchesHowABrowserKeysARule() {
        XCTAssertEqual(
            ContentSettingOrigin.normalize(URL(string: "https://EXAMPLE.com/a/b?c=d#e")!)?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            ContentSettingOrigin.normalize(URL(string: "https://example.com:443/")!)?.absoluteString,
            "https://example.com",
            "The default port must be dropped, or https://example.com and https://example.com:443 would hold separate rules."
        )
        XCTAssertEqual(
            ContentSettingOrigin.normalize(URL(string: "https://example.com:8443/")!)?.absoluteString,
            "https://example.com:8443",
            "A non-default port must be kept: a different port is a different origin."
        )
        XCTAssertNil(ContentSettingOrigin.normalize(URL(string: "about:blank")!))
        XCTAssertNil(
            ContentSettingOrigin.normalize(URL(string: "orbit://settings")!),
            "Orbit's own chrome parses to a host but is not a site; it must not be given site permissions."
        )
        XCTAssertNil(
            ContentSettingOrigin.normalize(URL(string: "file:///Users/me/page.html")!),
            "A local file is not a web origin — every file on the disk would otherwise share one set of site permissions."
        )
    }

    func test_aPageThatIsNotAWebOriginHasNothingToKeyARuleOn() {
        for string in ["about:blank", "orbit://settings", "file:///Users/me/page.html", "data:text/html,hi"] {
            XCTAssertNil(
                ContentSettingOrigin.normalize(URL(string: string)!),
                "\(string) produced a site-permission key; Orbit would store a rule nothing can ever apply."
            )
        }
    }

    // MARK: - TCC usage descriptions (the layer above all of the above)

    // Orbit is unsandboxed under the hardened runtime, so camera, microphone, location and ~/Downloads are gated by TCC, which terminates (not merely denies) a process that touches a protected resource with no usage description; Bundle.main here is Orbit.app (this target is hosted), so these read the real shipped Info.plist.
    func test_everyTCCGatedCapabilityOrbitReachesHasAUsageDescription() {
        let required: [(key: String, reachedBy: String)] = [
            (
                "NSCameraUsageDescription",
                "PermissionKind.camera — the engine's media-access permission "
                    + "request for a video capture device raises it"
            ),
            (
                "NSMicrophoneUsageDescription",
                "PermissionKind.microphone — same call site"
            ),
            (
                "NSLocationWhenInUseUsageDescription",
                "PermissionKind.geolocation — CEF_PERMISSION_TYPE_GEOLOCATION; "
                    + "Chromium's macOS position provider is CoreLocation"
            ),
            (
                "NSLocationUsageDescription",
                "the older macOS location key, consulted alongside the "
                    + "when-in-use one"
            ),
            (
                "NSDownloadsFolderUsageDescription",
                "AppEnvironment+WebContentsDelegate.willBeginDownload resolves "
                    + "FileManager .downloadsDirectory and writes the file there"
            ),
            (
                "NSCalendarsFullAccessUsageDescription",
                "LiveCalendarStore.connect — EKEventStore.requestFullAccessToEvents"
            ),
        ]

        for entry in required {
            let value = Bundle.main.object(forInfoDictionaryKey: entry.key) as? String
            XCTAssertNotNil(
                value,
                """
                Orbit.app declares no \(entry.key), but Orbit reaches that \
                capability: \(entry.reachedBy). TCC terminates a process that \
                touches a protected resource with no usage description, so \
                this is a crash on ordinary use, not a missing prompt. Arc \
                declared this key.
                """
            )
            XCTAssertFalse(
                (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(entry.key) is present but empty — macOS shows this string verbatim in the permission panel."
            )
        }
    }

    func test_noUsageDescriptionIsDeclaredForACapabilityOrbitDoesNotHave() throws {
        let mustBeAbsent: [(key: String, why: String)] = [
            (
                "NSDesktopFolderUsageDescription",
                "Arc read ~/Desktop for its own file surfaces. Nothing in "
                    + "Orbit reads or writes it."
            ),
            (
                "NSDocumentsFolderUsageDescription",
                "Nothing in Orbit reads or writes ~/Documents; downloads go to "
                    + "~/Downloads and every other file the user picks comes "
                    + "through NSOpenPanel, which needs no declaration."
            ),
            (
                "NSContactsUsageDescription",
                "Orbit has no address-book code at all."
            ),
            (
                "NSPhotoLibraryUsageDescription",
                "Orbit has no Photos code at all."
            ),
        ]

        for entry in mustBeAbsent {
            XCTAssertNil(
                Bundle.main.object(forInfoDictionaryKey: entry.key),
                """
                Orbit.app declares \(entry.key), which gives the user a \
                privacy control over a capability Orbit does not have. \(entry.why)
                """
            )
        }

        let source = try Self.orbitSourceText()

        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription"),
            """
            NSBluetoothAlwaysUsageDescription is missing. The embedded Orbit \
            Framework links CoreBluetooth and ships the Web Bluetooth API, so a \
            page calling navigator.bluetooth crashes Orbit without it. Do not \
            remove it on the grounds that Orbit's own source has no Bluetooth \
            code — that was the original error this assertion replaced.
            """
        )

        XCTAssertFalse(
            source.contains(".desktopDirectory"),
            "Orbit gained ~/Desktop access — NSDesktopFolderUsageDescription is now required and the exemption above is wrong."
        )
    }

    func test_downloadsStillGoToTheProtectedDownloadsFolder() throws {
        let delegate = try Self.orbitSourceText(named: "AppEnvironment+WebContentsDelegate.swift")
        XCTAssertTrue(
            delegate.contains(".downloadsDirectory"),
            "willBeginDownload no longer resolves FileManager's .downloadsDirectory, so NSDownloadsFolderUsageDescription may no longer be needed."
        )
    }

    // MARK: - Source lookup

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func orbitSourceText() throws -> String {
        let root = repositoryRoot.appendingPathComponent("Orbit")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(root.path) — this guard's own source walk is broken.")
            return ""
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            ["swift", "mm", "m", "h", "hpp"].contains($0.pathExtension)
        }
        XCTAssertFalse(files.isEmpty, "Found no source files under \(root.path) — this guard's own source walk is broken.")
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private static func orbitSourceText(named fileName: String) throws -> String {
        let root = repositoryRoot.appendingPathComponent("Orbit")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let match = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == fileName })
        else {
            XCTFail("Could not find \(fileName) under \(root.path).")
            return ""
        }
        return try String(contentsOf: match, encoding: .utf8)
    }
}
