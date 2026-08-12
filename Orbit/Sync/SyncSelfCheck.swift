#if DEBUG

import CloudKit
import CoreGraphics
import Foundation
import OSLog

public enum SyncSelfCheck {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "SyncSelfCheck")

    private static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        guard !condition() else { return }
        let text = message()
        logger.fault("Self-check FAILED: \(text, privacy: .public)")
    }

    private static func fail(_ message: @autoclosure () -> String) {
        let text = message()
        logger.fault("Self-check FAILED: \(text, privacy: .public)")
    }

    public static func run() {
        checkProfileRoundTrip()
        checkSpaceScalarRoundTrip()
        checkFavoriteRoundTrip()
        checkTabRoundTrip()
        checkSidebarNodeRoundTrip()
        checkTodayEntryRoundTrip()
        checkBoostRoundTrip()
        checkEaselRoundTrip()
        checkNoteRoundTrip()
        checkRoutingRuleRoundTrip()
        checkSidebarTreeFlattenRoundTrip()
        checkMergePreservesConcurrentAddition()
        checkMergeRespectsRemoteReorder()
        checkMergeDropsTombstonedID()
        checkMergeWithNoOverlapUnionsBoth()
        checkTombstoneLogRecordsAndPrunes()
        checkContentHashIgnoresClock()
        checkContentHashDetectsRealChange()
        logger.log("Ran \(checkCount, privacy: .public) checks — any failure above is logged at fault level.")
    }

    private static var checkCount = 0
    private static func checkpoint() { checkCount += 1 }

    // MARK: - Record mapping round trips

    private static func checkProfileRoundTrip() {
        checkpoint()
        let profile = Profile(
            name: "Work", symbolName: "briefcase", tint: ThemeColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
            isPersistent: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            archivePolicy: .after7Days // non-default, so a dropped field can't hide behind a default value matching
        )
        let record = SyncRecordMapping.profileRecord(from: profile, clientModifiedAt: Date(), existing: nil)
        let decoded = SyncRecordMapping.profile(from: record)
        check(decoded == profile, "Profile round trip lost data: \(String(describing: decoded)) != \(profile)")
    }

    private static func checkSpaceScalarRoundTrip() {
        checkpoint()
        let space = Space(
            name: "Design", icon: "paintbrush", iconIsEmoji: false,
            theme: SpaceTheme(style: .linear, colors: [ThemeColor(red: 1, green: 0, blue: 0, alpha: 1)], angle: 45, grain: 0.1, followsSystemAppearance: false, prefersDarkContent: true),
            profileID: UUID(), order: 3
        )
        let fields = SpaceScalarFields(from: space)
        guard let record = SyncRecordMapping.spaceRecord(from: fields, clientModifiedAt: Date(), existing: nil) else {
            fail("Space record build unexpectedly failed")
            return
        }
        let decoded = SyncRecordMapping.spaceScalarFields(from: record)
        check(decoded == fields, "Space scalar fields round trip lost data")
    }

    private static func checkFavoriteRoundTrip() {
        checkpoint()
        let spaceID = UUID()
        let favorite = Favorite(url: URL(string: "https://orbit.example/dashboard")!, title: "Dashboard", customIcon: "star", customIconIsEmoji: false, liveTabID: UUID())
        let flat = FlatFavorite(favorite: favorite, spaceID: spaceID, order: 2)
        let record = SyncRecordMapping.favoriteRecord(from: flat, clientModifiedAt: Date(), existing: nil)
        let decoded = SyncRecordMapping.favorite(from: record)
        check(decoded?.favorite == favorite, "Favorite round trip lost data")
        check(decoded?.spaceID == spaceID, "Favorite spaceID context lost")
        check(decoded?.order == 2, "Favorite order context lost")
    }

    private static func checkTabRoundTrip() {
        checkpoint()
        let tab = Tab(
            spaceID: UUID(), section: .pinned, url: URL(string: "https://swift.org")!, title: "Swift.org",
            customTitle: "My Tab", faviconURL: URL(string: "https://swift.org/favicon.ico"),
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_100), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            archivedAt: nil, isUnloaded: false, isMuted: true, zoomFactor: 1.25, splitGroupID: UUID(), splitIndex: 1
        )
        let record = SyncRecordMapping.tabRecord(from: tab, clientModifiedAt: Date(), existing: nil)
        let decoded = SyncRecordMapping.tab(from: record)
        check(decoded == tab, "Tab round trip lost data")
    }

    private static func checkSidebarNodeRoundTrip() {
        checkpoint()
        let spaceID = UUID()
        let node = FlatSidebarNode(id: UUID(), spaceID: spaceID, parentID: UUID(), order: 4, kind: .folder, name: "Reading", isExpanded: false, icon: "book", iconIsEmoji: false)
        let record = SyncRecordMapping.sidebarNodeRecord(from: node, clientModifiedAt: Date(), existing: nil)
        let decoded = SyncRecordMapping.sidebarNode(from: record)
        check(decoded == node, "SidebarNode round trip lost data")
    }

    private static func checkTodayEntryRoundTrip() {
        checkpoint()
        let entry = FlatTodayEntry(spaceID: UUID(), tabID: UUID(), order: 7)
        let record = SyncRecordMapping.todayEntryRecord(from: entry, clientModifiedAt: Date(), existing: nil)
        check(record.recordID.recordName == TodayEntryRecordName.make(spaceID: entry.spaceID, tabID: entry.tabID), "TodayEntry recordName isn't deterministic")
        let decoded = SyncRecordMapping.todayEntry(from: record)
        check(decoded == entry, "TodayEntry round trip lost data")

        let parsed = TodayEntryRecordName.parse(record.recordID.recordName)
        check(parsed?.spaceID == entry.spaceID && parsed?.tabID == entry.tabID, "TodayEntry recordName didn't parse back to its (spaceID, tabID)")
    }

    private static func checkBoostRoundTrip() {
        checkpoint()
        let boost = Boost(
            name: "HN Reader", host: "news.ycombinator.com", isEnabled: true,
            zappedSelectors: [".ad", "#banner"], customCSS: "body { color: red; }", customJavaScript: "console.log(1)",
            backgroundColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1), textColor: nil,
            accentColor: ThemeColor(red: 1, green: 1, blue: 0, alpha: 1), fontFamily: "Menlo",
            createdAt: Date(timeIntervalSince1970: 1_690_000_000), updatedAt: Date(timeIntervalSince1970: 1_695_000_000)
        )
        let record = SyncRecordMapping.boostRecord(from: boost, existing: nil)
        let decoded = SyncRecordMapping.boost(from: record)
        check(decoded == boost, "Boost round trip lost data")
    }

    private static func checkEaselRoundTrip() {
        checkpoint()
        let easel = Easel(
            title: "Moodboard",
            items: [
                EaselItem(frame: CGRect(x: 0, y: 0, width: 100, height: 50), rotation: 0, content: .text("hello"), zIndex: 0),
                EaselItem(frame: CGRect(x: 10, y: 10, width: 40, height: 40), rotation: 12, content: .link(url: URL(string: "https://example.com")!, title: "Example"), zIndex: 1),
            ],
            createdAt: Date(timeIntervalSince1970: 1_680_000_000), updatedAt: Date(timeIntervalSince1970: 1_685_000_000),
            viewportOrigin: CGPoint(x: 12, y: -8), viewportZoom: 1.5
        )
        guard let record = SyncRecordMapping.easelRecord(from: easel, existing: nil) else {
            fail("Easel record build unexpectedly failed")
            return
        }
        let decoded = SyncRecordMapping.easel(from: record)
        check(decoded == easel, "Easel round trip lost data")
    }

    private static func checkNoteRoundTrip() {
        checkpoint()
        let note = Note(title: "Ideas", bodyData: Data("hello world".utf8), createdAt: Date(timeIntervalSince1970: 1_670_000_000), updatedAt: Date(timeIntervalSince1970: 1_675_000_000))
        guard let fileURL = try? SyncRecordMapping.writeNoteAssetFile(note.bodyData, noteID: note.id) else {
            fail("Failed to write Note asset scratch file")
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = SyncRecordMapping.noteRecord(from: note, assetFileURL: fileURL, existing: nil)
        let decoded = SyncRecordMapping.note(from: record)
        check(decoded?.id == note.id && decoded?.title == note.title && decoded?.bodyData == note.bodyData, "Note round trip lost data")
    }

    private static func checkRoutingRuleRoundTrip() {
        checkpoint()
        for destination: RoutingRule.Destination in [.space(UUID()), .profile(UUID()), .application(bundleID: "com.example.app"), .littleOrbit, .mostRecentSpace] {
            let rule = RoutingRule(pattern: "figma.com", destination: destination, isEnabled: false)
            let record = SyncRecordMapping.routingRuleRecord(from: rule, clientModifiedAt: Date(), existing: nil)
            let decoded = SyncRecordMapping.routingRule(from: record)
            check(decoded == rule, "RoutingRule round trip lost data for destination \(destination)")
        }
    }

    // MARK: - Pinned tree flatten / unflatten round trip

    private static func checkSidebarTreeFlattenRoundTrip() {
        checkpoint()
        let spaceID = UUID()
        let leafA = TabID()
        let leafB = TabID()
        let leafC = TabID()
        let innerFolder = Folder(name: "Inner", isExpanded: true, children: [.tab(leafC)])
        let outerFolder = Folder(name: "Outer", isExpanded: false, children: [.tab(leafB), .folder(innerFolder)])
        let tree: [SidebarNode] = [.tab(leafA), .folder(outerFolder)]

        let flat = SidebarTreeFlattening.flatten(tree, spaceID: spaceID)
        check(flat.count == 5, "Expected 5 flattened rows (2 tabs at root + 1 folder + 1 tab + 1 folder + 1 tab), got \(flat.count)")

        let rebuilt = SidebarTreeFlattening.unflatten(flat, spaceID: spaceID)
        check(rebuilt == tree, "Pinned tree didn't survive a flatten/unflatten round trip")
    }

    // MARK: - Ordered-collection merge rule (real conflicting inputs)

    private static func checkMergePreservesConcurrentAddition() {
        checkpoint()
        let x = UUID(), y = UUID(), z = UUID()
        let remote = [y, x]
        let local = [x, y, z]
        let merged = SyncMerge.mergeOrderedIDs(remoteOrder: remote, localOrder: local, tombstoned: [])
        check(merged.contains(z), "New local addition Z was dropped by the merge")
        check(Set(merged) == Set([x, y, z]), "Merge lost or invented an id: \(merged)")
        guard let yIndex = merged.firstIndex(of: y), let zIndex = merged.firstIndex(of: z) else {
            fail("Merged order is missing Y and/or Z entirely, so their relative position can't be checked: \(merged)")
            return
        }
        check(zIndex == yIndex + 1, "Z should be spliced in right after its local neighbour Y, got order \(merged)")
    }

    private static func checkMergeRespectsRemoteReorder() {
        checkpoint()
        let a = UUID(), b = UUID(), c = UUID()
        let remote = [c, a, b]
        let local = [a, b, c]
        let merged = SyncMerge.mergeOrderedIDs(remoteOrder: remote, localOrder: local, tombstoned: [])
        check(merged == remote, "Merge should respect an already-synced reorder with no concurrent additions, got \(merged)")
    }

    private static func checkMergeDropsTombstonedID() {
        checkpoint()
        let survivor = UUID(), deleted = UUID()
        let remote = [survivor]
        let local = [survivor, deleted]
        let merged = SyncMerge.mergeOrderedIDs(remoteOrder: remote, localOrder: local, tombstoned: [deleted])
        check(!merged.contains(deleted), "Tombstoned id resurrected by the merge")
        check(merged == [survivor], "Unexpected merge result with a tombstoned id: \(merged)")
    }

    private static func checkMergeWithNoOverlapUnionsBoth() {
        checkpoint()
        let shared = UUID(), remoteOnly = UUID(), localOnly = UUID()
        let remote = [shared, remoteOnly]
        let local = [shared, localOnly]
        let merged = SyncMerge.mergeOrderedIDs(remoteOrder: remote, localOrder: local, tombstoned: [])
        check(Set(merged) == Set([shared, remoteOnly, localOnly]), "Merge lost a disjoint addition from one side: \(merged)")
    }

    // MARK: - Tombstones

    private static func checkTombstoneLogRecordsAndPrunes() {
        checkpoint()
        var log = SyncTombstoneLog()
        check(!log.contains("some-record"), "Empty tombstone log unexpectedly contains something")

        log.record("some-record", at: Date())
        check(log.contains("some-record"), "Tombstone log didn't record a fresh deletion")

        log.record("ancient-record", at: Date(timeIntervalSinceNow: -(SyncTombstoneLog.retention + 3600)))
        log.prune(now: Date())
        check(!log.contains("ancient-record"), "Tombstone log didn't prune an entry past its retention window")
        check(log.contains("some-record"), "Tombstone log pruned a still-fresh entry")
    }

    // MARK: - Content hashing

    private static func checkContentHashIgnoresClock() {
        checkpoint()
        let profile = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        let recordA = SyncRecordMapping.profileRecord(from: profile, clientModifiedAt: Date(timeIntervalSince1970: 1_700_000_000), existing: nil)
        let recordB = SyncRecordMapping.profileRecord(from: profile, clientModifiedAt: Date(timeIntervalSince1970: 1_800_000_000), existing: nil)
        check(StableHash.contentHash(of: recordA) == StableHash.contentHash(of: recordB), "Content hash changed when only the clock field did")
    }

    private static func checkContentHashDetectsRealChange() {
        checkpoint()
        let profileA = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        var profileB = profileA
        profileB.name = "Work"
        let recordA = SyncRecordMapping.profileRecord(from: profileA, clientModifiedAt: Date(), existing: nil)
        let recordB = SyncRecordMapping.profileRecord(from: profileB, clientModifiedAt: Date(), existing: nil)
        check(StableHash.contentHash(of: recordA) != StableHash.contentHash(of: recordB), "Content hash failed to detect a real field change")
    }
}

#endif
