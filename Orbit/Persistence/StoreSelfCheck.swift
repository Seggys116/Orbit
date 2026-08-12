#if DEBUG
import Foundation
import OSLog

enum StoreSelfCheck {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "StoreSelfCheck")

    private static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        guard !condition() else { return }
        let text = message()
        logger.fault("Self-check FAILED: \(text, privacy: .public)")
    }

    private static func fail(_ message: @autoclosure () -> String) {
        let text = message()
        logger.fault("Self-check FAILED: \(text, privacy: .public)")
    }

    static func run() {
        checkPinnedNodeTree()
        checkSchemaMigration()
        checkStateStoreRoundTrip()
        checkFrecencyRanking()
        logger.log("Synchronous persistence self-checks complete — any failure above is logged at fault level.")

        Task {
            await checkHistoryStoreRoundTrip()
        }
    }

    // MARK: - PinnedNodeTree

    private static func checkPinnedNodeTree() {
        let leafA = TabID()
        let leafB = TabID()
        let leafC = TabID()
        let leafD = TabID()

        var innerFolder = Folder(name: "Inner")
        innerFolder.children = [.tab(leafC)]
        let outerFolder = Folder(id: FolderID(), name: "Outer", children: [.tab(leafA), .folder(innerFolder)])

        var forest: [SidebarNode] = [.folder(outerFolder), .tab(leafB)]

        check(PinnedNodeTree.find(leafC, in: forest) != nil, "leafC should be discoverable two folders deep")
        guard let pathToC = PinnedNodeTree.path(to: leafC, in: forest) else {
            fail("path(to:) should locate leafC"); return
        }
        check(pathToC == [0, 1, 0], "leafC should resolve to [outer, inner, 0], got \(pathToC)")
        check(PinnedNodeTree.node(at: pathToC, in: forest)?.id == leafC, "node(at:) should round-trip with path(to:)")

        forest = PinnedNodeTree.inserting(.tab(leafD), parentFolderID: outerFolder.id, at: 0, into: forest)
        guard let outerAfterInsert = PinnedNodeTree.findFolder(outerFolder.id, in: forest) else {
            fail("Outer folder vanished after insert"); return
        }
        check(outerAfterInsert.children.first?.id == leafD, "leafD should be Outer's new first child")

        forest = PinnedNodeTree.moveNode(leafD, toParent: innerFolder.id, atIndex: 0, in: forest)
        guard let innerAfterMove = PinnedNodeTree.findFolder(innerFolder.id, in: forest) else {
            fail("Inner folder vanished after move"); return
        }
        check(innerAfterMove.children.contains(where: { $0.id == leafD }), "leafD should now live inside Inner")
        check(PinnedNodeTree.parentFolderID(of: leafD, in: forest) == innerFolder.id, "parentFolderID(of:) should report Inner as leafD's parent")

        let beforeSelfNest = forest
        forest = PinnedNodeTree.moveNode(outerFolder.id, toParent: outerFolder.id, atIndex: 0, in: forest)
        check(forest == beforeSelfNest, "Moving a folder into itself must be a no-op")

        let beforeDescendantNest = forest
        forest = PinnedNodeTree.moveNode(outerFolder.id, toParent: innerFolder.id, atIndex: 0, in: forest)
        check(forest == beforeDescendantNest, "Moving a folder into its own descendant must be a no-op")

        let (afterRemoval, removed) = PinnedNodeTree.removing(leafB, from: forest)
        check(removed?.id == leafB, "removing(_:from:) should find and return leafB")
        check(PinnedNodeTree.find(leafB, in: afterRemoval) == nil, "leafB should be gone after removal")

        let hoisted = PinnedNodeTree.hoistingChildren(ofFolder: outerFolder.id, in: forest)
        check(PinnedNodeTree.findFolder(outerFolder.id, in: hoisted) == nil, "Outer itself should be gone after a hoisting delete")
        check(PinnedNodeTree.find(leafA, in: hoisted) != nil, "Outer's direct child leafA should survive hoisting")
        check(PinnedNodeTree.findFolder(innerFolder.id, in: hoisted) != nil, "Outer's folder child Inner should survive hoisting")
    }

    // MARK: - SchemaMigration

    private static func checkSchemaMigration() {
        let v1Document: [String: Any] = ["schemaVersion": 1, "profiles": [], "spaces": []]
        do {
            let migrated = try SchemaMigration.migrate(v1Document)
            check((migrated["schemaVersion"] as? Int) == SchemaMigration.currentVersion, "A v1 document should migrate to the current schema version")
        } catch {
            fail("v1 -> current migration should not throw: \(error)")
        }

        let futureDocument: [String: Any] = ["schemaVersion": SchemaMigration.currentVersion + 1]
        do {
            _ = try SchemaMigration.migrate(futureDocument)
            fail("Migrating a document from a future schema version should throw")
        } catch SchemaMigration.Error.futureSchemaVersion {
        } catch {
            fail("Expected .futureSchemaVersion, got \(error)")
        }
    }

    // MARK: - StateStore atomic save/load round-trip + backup recovery

    private static func checkStateStoreRoundTrip() {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitSelfCheck-State-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let store = StateStore(rootDirectory: scratchRoot, maxBackups: 3)

        let profile = Profile(name: "Self-Check Profile")
        let space = Space(name: "Self-Check Space", profileID: profile.id)
        var firstState = OrbitState()
        firstState.profiles = [profile]
        firstState.spaces = [space]
        firstState.activeSpaceID = space.id

        do {
            try store.saveNow(firstState)
            let loaded = try store.load()
            check(loaded.profiles.first?.id == profile.id, "Round-tripped state should preserve the profile id")
            check(loaded.spaces.first?.name == "Self-Check Space", "Round-tripped state should preserve the space name")
            check(loaded.activeSpaceID == space.id, "Round-tripped state should preserve the active space id")
        } catch {
            fail("StateStore save/load round-trip should not throw: \(error)")
        }

        var secondState = firstState
        secondState.spaces[0].name = "Self-Check Space, Renamed"
        do {
            try store.saveNow(secondState)
        } catch {
            fail("Second save should not throw: \(error)")
        }

        let corruptData = Data("this is not valid JSON {{{".utf8)
        do {
            try corruptData.write(to: store.stateFileURL, options: .atomic)
        } catch {
            fail("Corrupting the scratch state file for the recovery test should not itself fail: \(error)")
        }

        do {
            let recovered = try store.load()
            check(recovered.spaces.first != nil, "Recovery from backup should still yield a usable state after primary corruption")
        } catch {
            fail("Recovery from backup should not throw: \(error)")
        }
    }

    // MARK: - Frecency ranking

    private static func checkFrecencyRanking() {
        let now = Date()

        let frequentButOld = HistoryStore.frecencyScore(
            visitCount: 200, typedCount: 40, lastVisit: now.addingTimeInterval(-30 * 86_400), now: now
        )
        let rareButRecent = HistoryStore.frecencyScore(
            visitCount: 1, typedCount: 0, lastVisit: now.addingTimeInterval(-60), now: now
        )
        let frequentAndRecent = HistoryStore.frecencyScore(
            visitCount: 200, typedCount: 40, lastVisit: now.addingTimeInterval(-60), now: now
        )

        check(frequentAndRecent > frequentButOld, "A page visited just as often but more recently should score higher")
        check(frequentAndRecent > rareButRecent, "A page visited far more often, at equal recency, should score higher")
        check(frequentButOld > 0, "Frecency should never fully decay to zero, however old the last visit")

        let neverVisited = HistoryStore.frecencyScore(visitCount: 0, typedCount: 0, lastVisit: .distantPast, now: now)
        check(neverVisited == 0, "Zero visits, zero typed-visits should score exactly zero")

        let typed = HistoryStore.frecencyScore(visitCount: 5, typedCount: 5, lastVisit: now, now: now)
        let untypedSameCount = HistoryStore.frecencyScore(visitCount: 5, typedCount: 0, lastVisit: now, now: now)
        check(typed > untypedSameCount, "Typed visits should score higher than an equal number of merely-clicked-into visits")
    }

    // MARK: - HistoryStore round-trip (needs the actor, hence async)

    private static func checkHistoryStoreRoundTrip() async {
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitSelfCheck-History-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        do {
            let store = try HistoryStore(databaseURL: scratchURL)
            let profileID = ProfileID()
            let visit = HistoryVisit(
                url: URL(string: "https://example.com/self-check")!,
                title: "Self Check Landing Page",
                profileID: profileID,
                wasTyped: true
            )
            let recorded = try await store.record(visit: visit)
            check(recorded.visitCount == 1, "A single recorded visit should aggregate to visit_count == 1")

            _ = try await store.record(visit: visit)
            let results = try await store.search("self-check")
            guard let match = results.first(where: { $0.url.absoluteString == "https://example.com/self-check" }) else {
                fail("A freshly recorded, twice-visited page should be findable by search")
                return
            }
            check(match.visitCount == 2, "Recording the same URL twice should bump visit_count to 2, got \(match.visitCount)")

            let removed = try await store.deleteEntries(matching: visit.url)
            check(removed, "deleteEntries(matching:) should report removing the row it just deleted")

            logger.log("HistoryStore round-trip complete.")
        } catch {
            fail("HistoryStore round-trip should not throw: \(error)")
        }
    }
}
#endif
