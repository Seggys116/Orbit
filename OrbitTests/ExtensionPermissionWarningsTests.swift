// Fixtures are real manifest JSON read through ChromeExtensionManifest, never a
// hand-built manifest literal.

import XCTest

final class ExtensionPermissionWarningsTests: XCTestCase {

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
            .appendingPathComponent("OrbitTests-ExtensionPermissionWarnings-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    private func writeManifest(_ json: [String: Any], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func warnings(for json: [String: Any]) throws -> [ExtensionPermissionWarning] {
        let directory = makeExtensionDirectory()
        try writeManifest(json, in: directory)
        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        return ExtensionPermissionWarnings.warnings(for: manifest)
    }

    // MARK: - `<all_urls>` / `*://*/*` collapse

    func test_allURLsHostPermission_collapsesToSingleAllSitesWarning() throws {
        let result = try warnings(for: [
            "name": "All URLs", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["<all_urls>"],
        ])

        let hostWarnings = result.filter { $0.text.contains("all your data on all websites") }
        XCTAssertEqual(hostWarnings.count, 1)
        XCTAssertEqual(hostWarnings.first?.severity, .critical)
        XCTAssertEqual(hostWarnings.first?.isGrantedAtInstall, true)
    }

    func test_wildcardSchemeAndHostPattern_collapsesToSingleAllSitesWarning() throws {
        let result = try warnings(for: [
            "name": "Wildcard Scheme", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["*://*/*"],
        ])

        let hostWarnings = result.filter { $0.text.contains("all your data on all websites") }
        XCTAssertEqual(hostWarnings.count, 1)
        XCTAssertEqual(hostWarnings.first?.severity, .critical)
    }

    func test_allURLsMixedWithSpecificHosts_stillCollapsesToOneWarning() throws {
        let result = try warnings(for: [
            "name": "Mixed With All URLs", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["<all_urls>", "https://example.com/*"],
        ])

        let hostWarnings = result.filter { $0.text.contains("all your data on") }
        XCTAssertEqual(hostWarnings.count, 1)
    }

    // MARK: - Single host

    func test_singleSpecificHost_namesTheHostDirectly() throws {
        let result = try warnings(for: [
            "name": "Single Host", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["https://*.github.com/*"],
        ])

        XCTAssertTrue(result.contains { $0.text == "Read and change your data on github.com" })
        XCTAssertFalse(result.contains { $0.text.contains("all websites") })
    }

    // MARK: - Many hosts

    func test_manyDistinctHosts_collapsesToCountedWarning() throws {
        let result = try warnings(for: [
            "name": "Many Hosts", "version": "1.0", "manifest_version": 3,
            "host_permissions": [
                "https://mail.google.com/*",
                "https://docs.google.com/*",
                "https://drive.google.com/*",
            ],
        ])

        XCTAssertTrue(result.contains { $0.text == "Read and change your data on 3 websites" })
        XCTAssertEqual(result.filter { $0.text.hasPrefix("Read and change your data on") }.count, 1)
    }

    func test_contentScriptMatches_countAsHostAccess_evenWithNoHostPermissionsDeclared() throws {
        let result = try warnings(for: [
            "name": "Content Script Only", "version": "1.0", "manifest_version": 3,
            "content_scripts": [
                ["matches": ["https://example.com/*"], "js": ["content.js"]],
            ],
        ])

        XCTAssertTrue(result.contains { $0.text == "Read and change your data on example.com" && $0.isGrantedAtInstall })
    }

    func test_contentScriptMatchOverlappingHostPermissions_foldsIntoOneWarning() throws {
        let result = try warnings(for: [
            "name": "Overlapping Host Access", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["https://example.com/*"],
            "content_scripts": [
                ["matches": ["https://example.com/*"], "js": ["content.js"]],
            ],
        ])

        XCTAssertEqual(result.filter { $0.text.hasPrefix("Read and change your data on") }.count, 1)
    }

    // MARK: - Unknown permission falls through to raw string

    func test_unknownPermission_fallsThroughToRawPermissionString() throws {
        let result = try warnings(for: [
            "name": "Unknown Permission", "version": "1.0", "manifest_version": 3,
            "permissions": ["someBrandNewPermissionOrbitDoesNotKnowAbout"],
        ])

        XCTAssertTrue(result.contains { $0.text == "someBrandNewPermissionOrbitDoesNotKnowAbout" })
    }

    func test_knownPermission_doesNotFallThroughToRawString() throws {
        let result = try warnings(for: [
            "name": "Known Permission", "version": "1.0", "manifest_version": 3,
            "permissions": ["tabs"],
        ])

        XCTAssertFalse(result.contains { $0.text == "tabs" })
        XCTAssertTrue(result.contains { $0.text == "Read your browsing history" })
    }

    // MARK: - Optional permissions kept separate

    func test_optionalPermission_isMarkedNotGrantedAtInstall() throws {
        let result = try warnings(for: [
            "name": "Optional Permission", "version": "1.0", "manifest_version": 3,
            "optional_permissions": ["geolocation"],
        ])

        let geolocationWarning = result.first { $0.text == "Detect your physical location" }
        XCTAssertNotNil(geolocationWarning)
        XCTAssertEqual(geolocationWarning?.isGrantedAtInstall, false)
    }

    func test_optionalHostPermission_isMarkedNotGrantedAtInstall() throws {
        let result = try warnings(for: [
            "name": "Optional Host Permission", "version": "1.0", "manifest_version": 3,
            "optional_host_permissions": ["https://*.dropbox.com/*"],
        ])

        let hostWarning = result.first { $0.text == "Read and change your data on dropbox.com" }
        XCTAssertNotNil(hostWarning)
        XCTAssertEqual(hostWarning?.isGrantedAtInstall, false)
    }

    func test_optionalHostPermission_isSuppressed_whenAlreadyCoveredByGrantedAllSites() throws {
        let result = try warnings(for: [
            "name": "Optional Redundant With All Sites", "version": "1.0", "manifest_version": 3,
            "host_permissions": ["<all_urls>"],
            "optional_host_permissions": ["https://*.dropbox.com/*"],
        ])

        XCTAssertFalse(result.contains { $0.text.contains("dropbox.com") })
        XCTAssertTrue(result.contains { $0.text.contains("all websites") && $0.isGrantedAtInstall })
    }

    func test_permissionListedBothAsGrantedAndOptional_isReportedOnceAsGranted() throws {
        let result = try warnings(for: [
            "name": "Duplicate Grant", "version": "1.0", "manifest_version": 3,
            "permissions": ["geolocation"],
            "optional_permissions": ["geolocation"],
        ])

        let geolocationWarnings = result.filter { $0.text == "Detect your physical location" }
        XCTAssertEqual(geolocationWarnings.count, 1)
        XCTAssertEqual(geolocationWarnings.first?.isGrantedAtInstall, true)
    }

    // MARK: - De-duplication

    func test_twoPermissionsProducingIdenticalText_areReportedOnce() throws {
        let result = try warnings(for: [
            "name": "Duplicate Text", "version": "1.0", "manifest_version": 3,
            "permissions": ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"],
        ])

        let matchingWarnings = result.filter { $0.text == "Block or modify network requests on websites you visit" }
        XCTAssertEqual(matchingWarnings.count, 1)
    }

    // MARK: - Severity ordering

    func test_warningsAreOrderedBySeverityDescendingDanger() throws {
        let result = try warnings(for: [
            "name": "Severity Ordering", "version": "1.0", "manifest_version": 3,
            "permissions": ["storage", "management", "history", "nativeMessaging"],
            "host_permissions": ["<all_urls>"],
        ])

        let severities = result.map(\.severity)
        let sortedSeverities = severities.sorted()
        XCTAssertEqual(severities, sortedSeverities, "Warnings must already be sorted by severity, most dangerous first.")

        XCTAssertEqual(result.first?.severity, .critical)
        XCTAssertEqual(result.last?.severity, .low)
    }

    func test_severityOrdering_isStableAcrossRepeatedDerivation() throws {
        let json: [String: Any] = [
            "name": "Stability", "version": "1.0", "manifest_version": 3,
            "permissions": ["bookmarks", "downloads", "cookies"],
        ]
        let directory = makeExtensionDirectory()
        try writeManifest(json, in: directory)
        let manifest = try ChromeExtensionManifest.read(fromDirectory: directory)

        let first = ExtensionPermissionWarnings.warnings(for: manifest).map(\.id)
        let second = ExtensionPermissionWarnings.warnings(for: manifest).map(\.id)
        XCTAssertEqual(first, second)
    }

    // MARK: - Identifiers

    func test_everyWarningHasAUniqueNonEmptyID() throws {
        let result = try warnings(for: [
            "name": "Unique IDs", "version": "1.0", "manifest_version": 3,
            "permissions": ["storage", "tabs", "history", "bookmarks", "downloads"],
            "host_permissions": ["https://example.com/*"],
            "optional_permissions": ["geolocation"],
        ])

        XCTAssertTrue(result.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
    }

    // MARK: - Empty manifest

    func test_manifestWithNoPermissions_producesEmptyWarningList() throws {
        let result = try warnings(for: ["name": "No Permissions", "version": "1.0"])
        XCTAssertTrue(result.isEmpty)
    }
}
