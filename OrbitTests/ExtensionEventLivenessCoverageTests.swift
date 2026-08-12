// The schema diff proves a member is declared, not that it's dispatched. Every declared
// event needs a row in EventLiveness.json naming a real cause; this enforces the table
// is complete and honest. Host-less: reads only files in this repository.

import XCTest

final class ExtensionEventLivenessCoverageTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    private struct Entry {
        var status: String
        var cause: String
        var payload: String?
        var blockedBy: String?
        var why: String?
    }

    private func readTable() throws -> [String: Entry] {
        let object = try Schema.readObject(Schema.eventLivenessFile)
        guard let events = object["events"] as? [String: [String: Any]] else {
            throw Schema.SchemaError.malformed(Schema.eventLivenessFile, "missing \"events\" object")
        }
        return events.mapValues {
            Entry(
                status: $0["status"] as? String ?? "",
                cause: $0["cause"] as? String ?? "",
                payload: $0["payload"] as? String,
                blockedBy: $0["blockedBy"] as? String,
                why: $0["why"] as? String
            )
        }
    }

    // MARK: - Completeness

    func test_everyEventOrbitDeclaresHasALivenessEntry() throws {
        let declared = try Schema.orbitDeclaredEvents()
        XCTAssertGreaterThan(declared.count, 15, "parsed only \(declared.count) events out of Orbit's schemas; the parse is wrong and every check below would pass vacuously")
        let table = try readTable()
        let uncovered = declared.subtracting(table.keys).sorted()
        XCTAssertEqual(
            uncovered, [],
            "these events are declared in Chromium/Embedder/common/api and nothing observes them firing. An extension can register a listener for each and wait forever. Add a row to OrbitTests/Fixtures/EventLiveness.json naming the real cause and a payload shape assertion, and implement the cause in ChromiumExtensionEventLivenessLiveTests."
        )
    }

    func test_theLivenessTableNamesNoEventOrbitDoesNotDeclare() throws {
        let declared = try Schema.orbitDeclaredEvents()
        let table = try readTable()
        let phantom = Set(table.keys).subtracting(declared).sorted()
        XCTAssertEqual(
            phantom, [],
            "EventLiveness.json covers events Orbit's schemas no longer declare. Either the event was removed — which the schema diff should also be failing on — or it was renamed and this table was not updated, in which case the live suite is asserting on an event that can never fire."
        )
    }

    // MARK: - Honesty

    func test_everyEntryHasAKnownStatus() throws {
        let allowed: Set<String> = ["observed", "notDispatched", "blocked"]
        for (event, entry) in try readTable().sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(
                allowed.contains(entry.status),
                "\(event) has status \"\(entry.status)\"; allowed statuses are \(allowed.sorted())"
            )
        }
    }

    func test_everyObservedEventNamesACauseAndAssertsPayloadShape() throws {
        for (event, entry) in try readTable().sorted(by: { $0.key < $1.key }) where entry.status == "observed" {
            XCTAssertFalse(
                entry.cause.isEmpty || entry.cause == "none",
                "\(event) is marked observed but names no real cause. \"The listener registered\" is not \"the event works\"."
            )
            let payload = entry.payload ?? ""
            XCTAssertFalse(
                payload.isEmpty,
                "\(event) is marked observed with no payload assertion, which reduces it to an invocation count"
            )
            XCTAssertTrue(
                payload.contains("args"),
                "\(event)'s payload assertion does not reference `args`, the real argument list it is supposed to inspect"
            )
            XCTAssertTrue(
                payload.contains("typeof") || payload.contains("Array.isArray"),
                "\(event)'s payload assertion checks presence rather than shape. tabs.onCreated was dispatched with an entirely wrong argument list and a presence check passes that; assert the type of each argument."
            )
        }
    }

    func test_everyBlockedEventExplainsWhatBlocksIt() throws {
        for (event, entry) in try readTable().sorted(by: { $0.key < $1.key }) where entry.status == "blocked" {
            XCTAssertFalse(
                (entry.blockedBy ?? "").isEmpty,
                "\(event) is marked blocked with no blockedBy. \"blocked\" is the one status that excuses an event from being observed, so it has to name the mechanical reason — otherwise it is just an untested event with a nicer label."
            )
        }
    }

    // MARK: - The two files agree

    func test_notDispatchedEventsAreExactlyTheOnesExpectedAPIGapsRecords() throws {
        let table = try readTable()
        let tableSays = Set(table.filter { $0.value.status == "notDispatched" }.keys)
        let gapsSay = Set(try Schema.readExpectations().neverDispatchedEvents)

        XCTAssertEqual(
            tableSays.subtracting(gapsSay).sorted(), [],
            "EventLiveness.json marks these events notDispatched but ExpectedAPIGaps.json's neverDispatchedEvents does not list them. A dead event has to be recorded in both places, because the schema diff cannot see it — the member is present."
        )
        XCTAssertEqual(
            gapsSay.subtracting(tableSays).sorted(), [],
            "ExpectedAPIGaps.json lists these events as never dispatched but EventLiveness.json does not. Either they now fire — delete them from ExpectedAPIGaps.json and give them a cause and payload here — or the table is out of date."
        )
    }

    func test_everyNotDispatchedEntryExplainsWhy() throws {
        for (event, entry) in try readTable().sorted(by: { $0.key < $1.key }) where entry.status == "notDispatched" {
            XCTAssertFalse(
                (entry.why ?? "").isEmpty,
                "\(event) is recorded as declared-but-dead with no explanation of what would have to fire it"
            )
        }
    }

    /// The three this table was written for. Named explicitly so that quietly
    /// flipping one to `observed` without a live cause fails here by name.
    func test_theThreeKnownDeadEventsAreStillRecordedAsDead() throws {
        let table = try readTable()
        for event in ["action.onClicked", "tabs.onReplaced", "webNavigation.onTabReplaced"] {
            let entry = try XCTUnwrap(table[event], "\(event) lost its liveness entry")
            XCTAssertTrue(
                entry.status == "notDispatched" || entry.status == "observed",
                "\(event) must be either still dead or genuinely observed, not \(entry.status)"
            )
            if entry.status == "observed" {
                XCTAssertFalse(
                    (entry.payload ?? "").isEmpty,
                    "\(event) was promoted to observed with no payload assertion, which is how it stayed broken in the first place"
                )
            }
        }
    }
}
