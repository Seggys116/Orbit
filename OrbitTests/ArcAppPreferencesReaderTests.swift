// Real fixture files (binary plist, StorableLinkRouting.json/StorableWindows.json) in
// Arc's own shapes. An unrecognised autoArchiveTimeThreshold must map to nil, not be guessed.

import Foundation
import XCTest

final class ArcAppPreferencesReaderTests: XCTestCase {

    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArcPrefs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        super.tearDown()
    }

    // MARK: - Absence

    func testAnEmptyHomeDirectoryYieldsEmptyPreferencesRatherThanThrowing() throws {
        let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)

        XCTAssertNil(preferences.autoArchiveThreshold)
        XCTAssertNil(preferences.unrecognisedAutoArchiveValue)
        XCTAssertNil(preferences.appearance)
        XCTAssertNil(preferences.showsToolbar)
        XCTAssertNil(preferences.showsFullURLs)
        XCTAssertNil(preferences.tidyTabsEnabled)
        XCTAssertNil(preferences.instantLinksEnabled)
        XCTAssertNil(preferences.sidebarWidth)
        XCTAssertNil(preferences.lastFocusedSpaceID)
        XCTAssertTrue(preferences.routingRules.isEmpty)
        XCTAssertNil(preferences.defaultRoutingDestination)
    }

    // MARK: - The defaults plist

    func testReadsEverySettingOutOfARealBinaryPropertyList() throws {
        let url = try writePreferences([
            "autoArchiveTimeThreshold": "thirtyDays",
            "appearance": "NSAppearanceNameDarkAqua",
            "topBarURLEnabled": 1,
            "toolbarShowFullURLsEnabledPreference": 0,
            "tidyTabsEnabled": 0,
            "instantLinksEnabled": 1,
        ])

        let magic = try Data(contentsOf: url).prefix(8)
        XCTAssertEqual(String(decoding: magic, as: UTF8.self), "bplist00", "Fixture is not a binary property list.")

        let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)

        XCTAssertEqual(preferences.autoArchiveThreshold, .thirtyDays)
        XCTAssertNil(preferences.unrecognisedAutoArchiveValue)
        XCTAssertEqual(preferences.appearance, .dark)
        XCTAssertEqual(preferences.showsToolbar, true)
        XCTAssertEqual(preferences.showsFullURLs, false, "An NSNumber 0 must read as false, not as nil.")
        XCTAssertEqual(preferences.tidyTabsEnabled, false)
        XCTAssertEqual(preferences.instantLinksEnabled, true)
    }

    func testEveryAutoArchiveThresholdArcCanWriteIsRecognised() throws {
        let cases: [(String, ArcAutoArchiveThreshold)] = [
            ("never", .never),
            ("twelveHours", .twelveHours),
            ("twentyFourHours", .twentyFourHours),
            ("sevenDays", .sevenDays),
            ("thirtyDays", .thirtyDays),
            ("ThirtyDays", .thirtyDays),
        ]
        for (raw, expected) in cases {
            _ = try writePreferences(["autoArchiveTimeThreshold": raw])
            let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)
            XCTAssertEqual(preferences.autoArchiveThreshold, expected, "Arc's \"\(raw)\" was not recognised.")
            XCTAssertNil(preferences.unrecognisedAutoArchiveValue)
        }
    }

    func testAnUnrecognisedThresholdIsReportedAndNeverGuessedAt() throws {
        _ = try writePreferences(["autoArchiveTimeThreshold": "everySecondTuesday"])

        let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)

        XCTAssertNil(preferences.autoArchiveThreshold)
        XCTAssertEqual(preferences.unrecognisedAutoArchiveValue, "everySecondTuesday")
    }

    func testAppearanceMapsArcsThreeStates() throws {
        _ = try writePreferences(["appearance": "NSAppearanceNameAqua"])
        XCTAssertEqual(try ArcAppPreferencesReader.read(homeDirectory: home).appearance, .light)

        _ = try writePreferences(["appearance": "NSAppearanceNameDarkAqua"])
        XCTAssertEqual(try ArcAppPreferencesReader.read(homeDirectory: home).appearance, .dark)

        _ = try writePreferences(["appearance": "something else entirely"])
        XCTAssertEqual(try ArcAppPreferencesReader.read(homeDirectory: home).appearance, .system)
    }

    func testACorruptPreferencesFileThrowsUnreadableRatherThanBeingIgnored() throws {
        let url = ArcAppPreferencesReader.preferencesURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("this is not a property list".utf8).write(to: url)

        do {
            _ = try ArcAppPreferencesReader.read(homeDirectory: home)
            XCTFail("A corrupt plist must not be silently treated as absent.")
        } catch let error as BrowserImportError {
            guard case .unreadable(let browser, _) = error else {
                return XCTFail("Expected .unreadable, got \(error).")
            }
            XCTAssertEqual(browser, .arc)
        }
    }

    // MARK: - Windows

    func testSidebarWidthAndLastFocusedSpaceComeOutOfStorableWindows() throws {
        try writeArcJSON("StorableWindows.json", """
        { "version": 1,
          "sidebarViewPreferences": { "sidebarMode": "noChrome", "sidebarWidth": 279 },
          "lastFocusedSpaceID": "D96A6D70-4987-443B-B90C-A3F199D8CC50",
          "windows": [] }
        """)

        let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)

        XCTAssertEqual(try XCTUnwrap(preferences.sidebarWidth), 279, accuracy: 0.001)
        XCTAssertEqual(preferences.lastFocusedSpaceID, UUID(uuidString: "D96A6D70-4987-443B-B90C-A3F199D8CC50"))
    }

    // MARK: - Link routing

    func testArcsGoogleMeetRuleIsReadInItsRealNestedShape() throws {
        try writeArcJSON("StorableLinkRouting.json", """
        { "version": 1,
          "defaultDestination": { "space": { "_0": { "mostRecent": {} } } },
          "rules": [ {
            "id": "CC0AE774-4D68-4598-B9C2-381538078D95",
            "destination": { "space": { "_0": { "mostRecent": {} } } },
            "sourceComponents": [ {
              "id": "4F0F0B47-F17E-4E61-8A3A-62E2DBFC8082",
              "componentType": { "urlMatch": { "_0": { "contains": {} }, "_1": "meet.google.com" } }
            } ] } ] }
        """)

        let preferences = try ArcAppPreferencesReader.read(homeDirectory: home)

        XCTAssertEqual(preferences.routingRules.count, 1)
        let rule = try XCTUnwrap(preferences.routingRules.first)
        XCTAssertEqual(rule.arcID, UUID(uuidString: "CC0AE774-4D68-4598-B9C2-381538078D95"))
        XCTAssertEqual(rule.match, .contains("meet.google.com"))
        XCTAssertEqual(rule.match.pattern, "meet.google.com")
        XCTAssertEqual(rule.destination, .mostRecentSpace)
        XCTAssertEqual(preferences.defaultRoutingDestination, .mostRecentSpace)
    }

    func testAConcreteSpaceDestinationIsReadAsThatSpace() throws {
        let spaceID = "B9E3E61E-D7F1-4517-B7F7-DFED52B80134"
        try writeArcJSON("StorableLinkRouting.json", """
        { "version": 1,
          "rules": [ {
            "id": "11111111-2222-3333-4444-555555555555",
            "destination": { "space": { "_0": "\(spaceID)" } },
            "sourceComponents": [ {
              "id": "66666666-7777-8888-9999-000000000000",
              "componentType": { "urlMatch": { "_0": { "equals": {} }, "_1": "linear.app" } }
            } ] } ] }
        """)

        let rule = try XCTUnwrap(try ArcAppPreferencesReader.read(homeDirectory: home).routingRules.first)

        XCTAssertEqual(rule.match, .equals("linear.app"))
        XCTAssertEqual(rule.destination, .space(UUID(uuidString: spaceID)!))
    }

    func testAMatchKindThisReaderDoesNotKnowIsKeptVerbatimRatherThanDropped() throws {
        try writeArcJSON("StorableLinkRouting.json", """
        { "version": 1,
          "rules": [ {
            "id": "11111111-2222-3333-4444-555555555555",
            "destination": { "space": { "_0": { "mostRecent": {} } } },
            "sourceComponents": [ {
              "id": "66666666-7777-8888-9999-000000000000",
              "componentType": { "urlMatch": { "_0": { "regexMatches": {} }, "_1": "^https://.*\\\\.dev/" } }
            } ] } ] }
        """)

        let rule = try XCTUnwrap(try ArcAppPreferencesReader.read(homeDirectory: home).routingRules.first)

        guard case .unsupported(let kind, let pattern) = rule.match else {
            return XCTFail("Expected .unsupported, got \(rule.match).")
        }
        XCTAssertEqual(kind, "regexMatches")
        XCTAssertEqual(pattern, "^https://.*\\.dev/")
    }

    func testARuleWithSeveralSourceComponentsBecomesSeveralRulesSharingADestination() throws {
        try writeArcJSON("StorableLinkRouting.json", """
        { "version": 1,
          "rules": [ {
            "id": "11111111-2222-3333-4444-555555555555",
            "destination": { "space": { "_0": { "mostRecent": {} } } },
            "sourceComponents": [
              { "id": "A1111111-1111-1111-1111-111111111111",
                "componentType": { "urlMatch": { "_0": { "contains": {} }, "_1": "figma.com" } } },
              { "id": "A2222222-2222-2222-2222-222222222222",
                "componentType": { "urlMatch": { "_0": { "contains": {} }, "_1": "linear.app" } } }
            ] } ] }
        """)

        let rules = try ArcAppPreferencesReader.read(homeDirectory: home).routingRules

        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.map(\.match.pattern), ["figma.com", "linear.app"])
        XCTAssertTrue(rules.allSatisfy { $0.destination == .mostRecentSpace })
    }

    func testMalformedRoutingJSONThrowsUnreadable() throws {
        try writeArcJSON("StorableLinkRouting.json", "{ not json")

        do {
            _ = try ArcAppPreferencesReader.read(homeDirectory: home)
            XCTFail("Malformed routing JSON must not be silently ignored.")
        } catch let error as BrowserImportError {
            guard case .unreadable = error else { return XCTFail("Expected .unreadable, got \(error).") }
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func writePreferences(_ contents: [String: Any]) throws -> URL {
        let url = ArcAppPreferencesReader.preferencesURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
        try data.write(to: url)
        return url
    }

    private func writeArcJSON(_ name: String, _ contents: String) throws {
        let root = home.appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
    }
}
