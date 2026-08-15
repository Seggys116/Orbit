//  chrome.bookmarks end to end, cross-checked against the real BrowserStore.
//
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getTreeReportsOrbitsRealSpacesFavouritesAndPinnedTabs
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_getChildrenAndGetSubTreeAgreeWithGetTree
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_idsAreStableAcrossCallsAndAcrossAnUnrelatedMutation
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_searchMatchesTitleAndUrlAndExcludesFolders
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_createMakesARealPinnedBookmarkAndFiresOnCreated
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_createWithoutUrlMakesARealPinnedFolder
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_updateRewritesTheRealTitleAndFiresOnChanged
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_moveReparentsTheRealNodeAndFiresOnMoved
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_removeDeletesTheRealBookmarkAndFiresOnRemoved
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_removeRefusesANonEmptyFolderButRemoveTreeTakesItAll
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theSpaceAndSectionFoldersCannotBeModified
//  ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anExtensionWithoutThePermissionCannotSeeTheNamespace

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionBookmarksLiveTests: LiveEnvironmentTestCase {

    private var temporaryDirectories: [URL] = []
    private var previousProcessRoot: AppEnvironment?

    override func tearDown() {
        if let previousProcessRoot {
            AppEnvironment.processRoot = previousProcessRoot
            // Re-arm, or the bridge keeps observing this suite's scratch store and
            // pushes its tree into every later suite's engine.
            OrbitChromiumBookmarksBridge.shared.install()
        }
        previousProcessRoot = nil
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeFixture(named name: String, permissions: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [\(permissions)],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var orbitEvents = [];
        if (typeof chrome.bookmarks !== 'undefined') {
          chrome.bookmarks.onCreated.addListener(function (id, node) {
            orbitEvents.push({ event: 'onCreated', id: id, node: node });
          });
          chrome.bookmarks.onRemoved.addListener(function (id, info) {
            orbitEvents.push({ event: 'onRemoved', id: id, info: info });
          });
          chrome.bookmarks.onChanged.addListener(function (id, info) {
            orbitEvents.push({ event: 'onChanged', id: id, info: info });
          });
          chrome.bookmarks.onMoved.addListener(function (id, info) {
            orbitEvents.push({ event: 'onMoved', id: id, info: info });
          });
        }

        function reply(sendResponse, promise) {
          promise.then(function (result) {
            sendResponse(JSON.stringify({ result: result === undefined ? null : result, error: null }));
          }, function (error) {
            sendResponse(JSON.stringify({ result: null, error: String(error && error.message || error) }));
          });
        }

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          var call = JSON.parse(message);
          if (call.method === 'namespaceDefined') {
            sendResponse(JSON.stringify({ result: typeof chrome.bookmarks, error: null }));
            return false;
          }
          if (call.method === 'events') {
            sendResponse(JSON.stringify({ result: orbitEvents, error: null }));
            return false;
          }
          if (call.method === 'clearEvents') {
            orbitEvents = [];
            sendResponse(JSON.stringify({ result: true, error: null }));
            return false;
          }
          reply(sendResponse, chrome.bookmarks[call.method].apply(chrome.bookmarks, call.args));
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Bookmarks Probe</title></head>
        <body><div id="orbit-bookmarks-probe">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitOut = null;
        window.orbitAsk = function (message) {
          window.__orbitOut = null;
          chrome.runtime.sendMessage(message, function (response) {
            window.__orbitOut = String(response);
          });
        };
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private struct Harness {
        var engine: ChromiumEngine
        var extensionID: String
        var probe: ChromiumWebContents
        var spaceID: SpaceID
    }

    private static func pollUntil(
        _ waitingFor: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Returns the worker's `{result, error}` envelope for one chrome.bookmarks call.
    @discardableResult
    private func call(
        _ harness: Harness, _ method: String, _ args: [Any] = []
    ) async throws -> (result: Any?, error: String?) {
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "args": args])
        let message = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        _ = try await harness.probe.evaluateJavaScript("window.orbitAsk('\(escaped)'); 'sent'")
        try await Self.pollUntil("the worker to answer \(method)") {
            try await harness.probe.evaluateJavaScript("window.__orbitOut !== null") as? Bool == true
        }
        let raw = try await harness.probe.evaluateJavaScript("window.__orbitOut") as? String ?? ""
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(raw.data(using: .utf8))) as? [String: Any],
            "chrome.bookmarks.\(method) did not answer with an envelope; it answered \(raw)"
        )
        return (envelope["result"] is NSNull ? nil : envelope["result"],
                envelope["error"] as? String)
    }

    private func succeed(
        _ harness: Harness, _ method: String, _ args: [Any] = []
    ) async throws -> Any? {
        let answer = try await call(harness, method, args)
        XCTAssertNil(answer.error, "chrome.bookmarks.\(method) failed with \(answer.error ?? "")")
        return answer.result
    }

    private func events(_ harness: Harness) async throws -> [[String: Any]] {
        let result = try await succeed(harness, "events")
        return result as? [[String: Any]] ?? []
    }

    private func withLoadedFixture(
        permissions: String = "\"bookmarks\"",
        _ body: (Harness) async throws -> Void
    ) async throws {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        let env = self.env
        env._test_engineOverride = engine

        // The bridge resolves processRoot per call; without this it would rewrite the real user's bookmarks.
        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
        OrbitChromiumBookmarksBridge.shared.install()

        let bridge = OrbitChromiumTabsBridge.shared
        if !bridge.isWindowRegistered(env) {
            bridge.windowCreated(owner: env, focused: false)
        }
        bridge.windowFocusChanged(owner: env)
        let spaceID = try XCTUnwrap(env.activeSpace?.id)

        seedBookmarks(in: env, spaceID: spaceID)

        let directory = try writeFixture(named: "Orbit Bookmarks", permissions: permissions)
        let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
        defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

        let probe = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { probe.close() }
        probe.load(URL(string: "chrome-extension://\(loaded.id)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(probe)
        try await Self.pollUntil("the probe page to load") {
            try await probe.evaluateJavaScript("typeof window.orbitAsk === 'function'") as? Bool == true
        }

        try await body(Harness(engine: engine, extensionID: loaded.id, probe: probe, spaceID: spaceID))
    }

    /// A known pinned forest so every assertion below names something real:
    /// Reading (folder) > Orbit Docs, plus a top-level Orbit Home.
    private func seedBookmarks(in env: AppEnvironment, spaceID: SpaceID) {
        let store = env.store
        let folderID = store.createFolder(name: "Reading", in: spaceID)
        let nested = store.openTab(
            url: URL(string: "https://orbit-browser.app/docs")!, in: spaceID, section: .pinned, activate: false)
        store.renameTab(nested, to: "Orbit Docs")
        store.moveNode(nested, toParent: folderID, atIndex: 0, in: spaceID)
        // A stale origin title plus a navigation away from the pinned URL: the only shape
        // that tells "reports displayTitle" apart from "reports pinnedTitle".
        store.state.tabs[nested]?.pinnedTitle = "Documentation (origin)"
        store.state.tabs[nested]?.url = URL(string: "https://orbit-browser.app/docs/api")!
        let home = store.openTab(
            url: URL(string: "https://orbit-browser.app/")!, in: spaceID, section: .pinned, activate: false)
        store.renameTab(home, to: "Orbit Home")
        store.moveNode(home, toParent: nil, atIndex: 1, in: spaceID)
    }

    private func node(_ tree: Any?, atPath path: [Int]) -> [String: Any]? {
        var current: [String: Any]?
        var children = (tree as? [[String: Any]]) ?? []
        for index in path {
            guard children.indices.contains(index) else { return nil }
            current = children[index]
            children = (current?["children"] as? [[String: Any]]) ?? []
        }
        return current
    }

    private func flatten(_ nodes: [[String: Any]]) -> [[String: Any]] {
        nodes.flatMap { node -> [[String: Any]] in
            [node] + flatten((node["children"] as? [[String: Any]]) ?? [])
        }
    }

    // MARK: - Reading the real tree

    func test_getTreeReportsOrbitsRealSpacesFavouritesAndPinnedTabs() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let tree = try await self.succeed(harness, "getTree")
            let root = try XCTUnwrap(
                self.node(tree, atPath: [0]),
                "getTree must resolve with a one-element array holding the root"
            )
            XCTAssertEqual(root["id"] as? String, "0", "the root node's id is the documented ROOT_NODE_ID")
            XCTAssertNil(root["parentId"], "the root must omit parentId")
            XCTAssertNil(root["url"], "the root is a folder and must have no url")

            let spaces = try XCTUnwrap(root["children"] as? [[String: Any]])
            XCTAssertEqual(
                spaces.count, self.env.state.spaces.count,
                "every Orbit Space must appear as a top-level folder, and only those"
            )
            let active = try XCTUnwrap(
                spaces.first { $0["id"] as? String == "s:\(harness.spaceID.uuidString.lowercased())" },
                "the active Space is missing from the tree"
            )
            XCTAssertEqual(active["title"] as? String, self.env.activeSpace?.name)

            let sections = try XCTUnwrap(active["children"] as? [[String: Any]])
            XCTAssertEqual(
                sections.compactMap { $0["id"] as? String },
                ["f:\(harness.spaceID.uuidString.lowercased())", "p:\(harness.spaceID.uuidString.lowercased())"],
                "a Space folder holds exactly its Favourites and Pinned sections, in that order"
            )

            let pinned = try XCTUnwrap(sections.last?["children"] as? [[String: Any]])
            XCTAssertEqual(
                pinned.compactMap { $0["title"] as? String }, ["Reading", "Orbit Home"],
                "the pinned section must report the real sidebar forest, in its real order"
            )
            let reading = try XCTUnwrap(pinned.first)
            XCTAssertNil(reading["url"], "a pinned folder is a folder and must carry no url")
            let docs = try XCTUnwrap((reading["children"] as? [[String: Any]])?.first)
            XCTAssertEqual(
                docs["title"] as? String, "Orbit Docs",
                "the title is what the sidebar row shows (displayTitle); pinnedTitle only labels the reset affordance"
            )
            XCTAssertEqual(
                docs["url"] as? String, "https://orbit-browser.app/docs",
                "a bookmark's url is the pinned origin, not wherever the tab has since navigated"
            )
            XCTAssertEqual(docs["index"] as? Int, 0)

            let favourites = try XCTUnwrap(sections.first?["children"] as? [[String: Any]])
            XCTAssertEqual(
                favourites.compactMap { $0["url"] as? String },
                self.env.store.favorites(for: harness.spaceID).map(\.url.absoluteString),
                "the favourites section must report the Space's real favourites, in order"
            )
        }
    }

    func test_getChildrenAndGetSubTreeAgreeWithGetTree() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"

            let childrenRaw = try await self.succeed(harness, "getChildren", [pinnedID])
            let children = try XCTUnwrap(childrenRaw as? [[String: Any]])
            XCTAssertEqual(children.compactMap { $0["title"] as? String }, ["Reading", "Orbit Home"])
            XCTAssertTrue(
                children.allSatisfy { $0["children"] == nil },
                "getChildren returns flat nodes; upstream never populates children there"
            )

            let subtreeRaw = try await self.succeed(harness, "getSubTree", [pinnedID])
            let subtree = try XCTUnwrap(subtreeRaw as? [[String: Any]])
            let reading = try XCTUnwrap((subtree.first?["children"] as? [[String: Any]])?.first)
            XCTAssertEqual(
                (reading["children"] as? [[String: Any]])?.count, 1,
                "getSubTree must populate children all the way down"
            )

            let fetchedRaw = try await self.succeed(harness, "get", [pinnedID])
            let fetched = try XCTUnwrap(fetchedRaw as? [[String: Any]])
            XCTAssertEqual(fetched.first?["id"] as? String, pinnedID)

            let missing = try await self.call(harness, "get", ["t:\(UUID().uuidString.lowercased())"])
            XCTAssertEqual(
                missing.error, "Can't find bookmark for id.",
                "an unknown id must fail with upstream's own message, not resolve empty"
            )
        }
    }

    func test_idsAreStableAcrossCallsAndAcrossAnUnrelatedMutation() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let firstRaw = try await self.succeed(harness, "getTree")
            let first = try XCTUnwrap(firstRaw as? [[String: Any]])
            let before = self.flatten(first).compactMap { $0["id"] as? String }

            let againRaw = try await self.succeed(harness, "getTree")
            let again = try XCTUnwrap(againRaw as? [[String: Any]])
            XCTAssertEqual(
                self.flatten(again).compactMap { $0["id"] as? String }, before,
                "two getTree calls in a row must report identical ids"
            )

            // A real Orbit-side mutation elsewhere in the tree.
            let extra = self.env.store.openTab(
                url: URL(string: "https://orbit-browser.app/changelog")!,
                in: harness.spaceID, section: .pinned, activate: false)
            try await Task.sleep(for: .milliseconds(300))

            let afterRaw = try await self.succeed(harness, "getTree")
            let after = try XCTUnwrap(afterRaw as? [[String: Any]])
            let afterIDs = self.flatten(after).compactMap { $0["id"] as? String }
            XCTAssertTrue(
                before.allSatisfy { afterIDs.contains($0) },
                "adding a pinned tab must not renumber any existing node; ids that churn break every extension"
            )
            XCTAssertTrue(afterIDs.contains("t:\(extra.uuidString.lowercased())"))
        }
    }

    func test_searchMatchesTitleAndUrlAndExcludesFolders() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let byTitleRaw = try await self.succeed(harness, "search", ["Orbit Docs"])
            let byTitle = try XCTUnwrap(byTitleRaw as? [[String: Any]])
            XCTAssertEqual(byTitle.compactMap { $0["title"] as? String }, ["Orbit Docs"])

            let byURLRaw = try await self.succeed(harness, "search", [["url": "https://orbit-browser.app/docs"]])
            let byURL = try XCTUnwrap(byURLRaw as? [[String: Any]])
            XCTAssertEqual(
                byURL.compactMap { $0["title"] as? String }, ["Orbit Docs"],
                "the object form must match a url verbatim"
            )

            let folderByURLRaw = try await self.succeed(harness, "search", [["url": "Reading"]])
            let folderByURL = try XCTUnwrap(folderByURLRaw as? [[String: Any]])
            XCTAssertTrue(folderByURL.isEmpty, "folders have no url and can never match a url query")

            let noneRaw = try await self.succeed(harness, "search", ["zzz-no-such-bookmark"])
            let none = try XCTUnwrap(noneRaw as? [[String: Any]])
            XCTAssertTrue(none.isEmpty)
        }
    }

    // MARK: - Mutating the real model

    func test_createMakesARealPinnedBookmarkAndFiresOnCreated() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            _ = try await self.succeed(harness, "clearEvents")
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"
            let createdRaw = try await self.succeed( harness, "create", [["parentId": pinnedID, "title": "Orbit Blog", "url": "https://orbit-browser.app/blog"]] )
            let created = try XCTUnwrap(createdRaw as? [String: Any])
            let newID = try XCTUnwrap(created["id"] as? String)
            XCTAssertTrue(newID.hasPrefix("t:"), "a pinned bookmark is a real Orbit tab, so its id is a t: node")
            XCTAssertEqual(created["parentId"] as? String, pinnedID)

            let tabID = try XCTUnwrap(UUID(uuidString: String(newID.dropFirst(2))))
            let tab = try XCTUnwrap(
                self.env.state.tabs[tabID],
                "chrome.bookmarks.create reported a node that does not exist in BrowserStore"
            )
            XCTAssertEqual(tab.section, .pinned, "the created bookmark must really be pinned")
            XCTAssertEqual(tab.url.absoluteString, "https://orbit-browser.app/blog")
            XCTAssertEqual(tab.displayTitle, "Orbit Blog")
            XCTAssertTrue(
                self.env.store.pinnedNodes(in: harness.spaceID).contains { $0.id == tabID },
                "the new bookmark must be in the Space's real pinned forest"
            )

            let fired = try await self.events(harness)
            let onCreated = try XCTUnwrap(
                fired.first { $0["event"] as? String == "onCreated" },
                "creating a bookmark must fire bookmarks.onCreated"
            )
            XCTAssertEqual(onCreated["id"] as? String, newID)
            XCTAssertEqual((onCreated["node"] as? [String: Any])?["title"] as? String, "Orbit Blog")
        }
    }

    func test_createWithoutUrlMakesARealPinnedFolder() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"
            let createdRaw = try await self.succeed(harness, "create", [["parentId": pinnedID, "title": "Later"]])
            let created = try XCTUnwrap(createdRaw as? [String: Any])
            let newID = try XCTUnwrap(created["id"] as? String)
            XCTAssertTrue(newID.hasPrefix("d:"), "a bookmark with no url is a folder, which in Orbit is a pinned Folder")
            XCTAssertNil(created["url"], "a folder node must carry no url")

            let folderID = try XCTUnwrap(UUID(uuidString: String(newID.dropFirst(2))))
            XCTAssertNotNil(
                self.env.store.folder(folderID, in: harness.spaceID),
                "chrome.bookmarks.create reported a folder BrowserStore does not have"
            )

            let favouritesID = "f:\(harness.spaceID.uuidString.lowercased())"
            let refused = try await self.call(harness, "create", [["parentId": favouritesID, "title": "Nope"]])
            XCTAssertEqual(
                refused.error, "Orbit favourites cannot contain folders.",
                "Orbit's favourites grid holds no folders, and the API must say so rather than silently succeeding"
            )
        }
    }

    func test_updateRewritesTheRealTitleAndFiresOnChanged() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedRaw = try await self.succeed(harness, "getChildren", ["p:\(harness.spaceID.uuidString.lowercased())"])
            let pinned = try XCTUnwrap(pinnedRaw as? [[String: Any]])
            let home = try XCTUnwrap(pinned.first { $0["title"] as? String == "Orbit Home" })
            let homeID = try XCTUnwrap(home["id"] as? String)
            let tabID = try XCTUnwrap(UUID(uuidString: String(homeID.dropFirst(2))))

            _ = try await self.succeed(harness, "clearEvents")
            let updatedRaw = try await self.succeed(harness, "update", [homeID, ["title": "Orbit Start"]])
            let updated = try XCTUnwrap(updatedRaw as? [String: Any])
            XCTAssertEqual(updated["title"] as? String, "Orbit Start")
            XCTAssertEqual(
                self.env.state.tabs[tabID]?.displayTitle, "Orbit Start",
                "update must rewrite the real tab, not just the reported node"
            )

            let fired = try await self.events(harness)
            let onChanged = try XCTUnwrap(
                fired.first { $0["event"] as? String == "onChanged" },
                "a title change must fire bookmarks.onChanged"
            )
            XCTAssertEqual(onChanged["id"] as? String, homeID)
            XCTAssertEqual((onChanged["info"] as? [String: Any])?["title"] as? String, "Orbit Start")

            let folderURL = try await self.call(
                harness, "update",
                [try XCTUnwrap(pinned.first { $0["title"] as? String == "Reading" }?["id"] as? String),
                 ["url": "https://orbit-browser.app/"]]
            )
            XCTAssertEqual(folderURL.error, "Can't set URL of a bookmark folder.")
        }
    }

    func test_moveReparentsTheRealNodeAndFiresOnMoved() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"
            let pinnedRaw = try await self.succeed(harness, "getChildren", [pinnedID])
            let pinned = try XCTUnwrap(pinnedRaw as? [[String: Any]])
            let readingID = try XCTUnwrap(pinned.first { $0["title"] as? String == "Reading" }?["id"] as? String)
            let homeID = try XCTUnwrap(pinned.first { $0["title"] as? String == "Orbit Home" }?["id"] as? String)
            let tabID = try XCTUnwrap(UUID(uuidString: String(homeID.dropFirst(2))))
            let folderID = try XCTUnwrap(UUID(uuidString: String(readingID.dropFirst(2))))

            _ = try await self.succeed(harness, "clearEvents")
            let movedRaw = try await self.succeed(harness, "move", [homeID, ["parentId": readingID, "index": 0]])
            let moved = try XCTUnwrap(movedRaw as? [String: Any])
            XCTAssertEqual(moved["parentId"] as? String, readingID)
            XCTAssertEqual(moved["index"] as? Int, 0)

            let folder = try XCTUnwrap(self.env.store.folder(folderID, in: harness.spaceID))
            XCTAssertEqual(
                folder.children.first?.id, tabID,
                "move must reparent the real node in BrowserStore's own pinned forest"
            )

            let fired = try await self.events(harness)
            let onMoved = try XCTUnwrap(
                fired.first { $0["event"] as? String == "onMoved" },
                "reparenting must fire bookmarks.onMoved"
            )
            let info = try XCTUnwrap(onMoved["info"] as? [String: Any])
            XCTAssertEqual(info["parentId"] as? String, readingID)
            XCTAssertEqual(info["oldParentId"] as? String, pinnedID)

            XCTAssertFalse(
                fired.contains { $0["event"] as? String == "onRemoved" },
                "a move is not a removal; firing onRemoved would make every listener drop the node"
            )
        }
    }

    func test_removeDeletesTheRealBookmarkAndFiresOnRemoved() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"
            let pinnedRaw = try await self.succeed(harness, "getChildren", [pinnedID])
            let pinned = try XCTUnwrap(pinnedRaw as? [[String: Any]])
            let homeID = try XCTUnwrap(pinned.first { $0["title"] as? String == "Orbit Home" }?["id"] as? String)
            let tabID = try XCTUnwrap(UUID(uuidString: String(homeID.dropFirst(2))))

            _ = try await self.succeed(harness, "clearEvents")
            _ = try await self.succeed(harness, "remove", [homeID])

            XCTAssertFalse(
                self.env.store.pinnedNodes(in: harness.spaceID).contains { $0.id == tabID },
                "remove must take the bookmark out of the Space's real pinned forest"
            )

            let fired = try await self.events(harness)
            let onRemoved = try XCTUnwrap(
                fired.first { $0["event"] as? String == "onRemoved" },
                "removing a bookmark must fire bookmarks.onRemoved"
            )
            XCTAssertEqual(onRemoved["id"] as? String, homeID)
            XCTAssertEqual((onRemoved["info"] as? [String: Any])?["parentId"] as? String, pinnedID)

            let gone = try await self.call(harness, "get", [homeID])
            XCTAssertEqual(gone.error, "Can't find bookmark for id.")
        }
    }

    func test_removeRefusesANonEmptyFolderButRemoveTreeTakesItAll() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"
            let pinnedRaw = try await self.succeed(harness, "getChildren", [pinnedID])
            let pinned = try XCTUnwrap(pinnedRaw as? [[String: Any]])
            let readingID = try XCTUnwrap(pinned.first { $0["title"] as? String == "Reading" }?["id"] as? String)
            let folderID = try XCTUnwrap(UUID(uuidString: String(readingID.dropFirst(2))))
            let nestedTabID = try XCTUnwrap(
                self.env.store.folder(folderID, in: harness.spaceID)?.children.first?.id)

            let refused = try await self.call(harness, "remove", [readingID])
            XCTAssertEqual(
                refused.error, "Can't remove non-empty folder (use recursive to force).",
                "remove() on a folder with children must refuse, exactly as upstream does"
            )
            XCTAssertNotNil(
                self.env.store.folder(folderID, in: harness.spaceID),
                "the refused remove must have left the real folder alone"
            )

            _ = try await self.succeed(harness, "clearEvents")
            _ = try await self.succeed(harness, "removeTree", [readingID])

            XCTAssertNil(
                self.env.store.folder(folderID, in: harness.spaceID),
                "removeTree must delete the real folder"
            )
            XCTAssertFalse(
                self.env.store.pinnedNodes(in: harness.spaceID).flatMap(\.allTabIDs).contains(nestedTabID),
                "removeTree must delete the folder's contents too"
            )

            let fired = try await self.events(harness)
            let removals = fired.filter { $0["event"] as? String == "onRemoved" }
            XCTAssertEqual(
                removals.count, 1,
                "a recursive removal fires one notification for the folder and none for its contents"
            )
            XCTAssertEqual(removals.first?["id"] as? String, readingID)
        }
    }

    func test_theSpaceAndSectionFoldersCannotBeModified() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture { harness in
            let spaceName = self.env.activeSpace?.name
            let spaceID = "s:\(harness.spaceID.uuidString.lowercased())"
            let pinnedID = "p:\(harness.spaceID.uuidString.lowercased())"

            for (id, label) in [(spaceID, "a Space"), (pinnedID, "a section"), ("0", "the root")] {
                let renamed = try await self.call(harness, "update", [id, ["title": "Hijacked"]])
                XCTAssertEqual(
                    renamed.error, "Can't modify the root bookmark folders.",
                    "\(label) folder must refuse update"
                )
                let removed = try await self.call(harness, "removeTree", [id])
                XCTAssertEqual(
                    removed.error, "Can't modify the root bookmark folders.",
                    "\(label) folder must refuse removeTree"
                )
            }

            XCTAssertEqual(
                self.env.activeSpace?.name, spaceName,
                "the refused update must not have renamed the real Space"
            )
            XCTAssertEqual(
                self.env.state.spaces.count, self.env.store.state.spaces.count,
                "the refused removeTree must not have deleted a Space"
            )

            let created = try await self.call(harness, "create", [["parentId": "0", "title": "New Space"]])
            XCTAssertEqual(
                created.error, "Can't modify the root bookmark folders.",
                "an extension must not be able to conjure a Space through chrome.bookmarks"
            )
        }
    }

    // MARK: - Negative control

    func test_anExtensionWithoutThePermissionCannotSeeTheNamespace() async throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try await withLoadedFixture(permissions: "\"storage\"") { harness in
            let answer = try await self.call(harness, "namespaceDefined")
            XCTAssertEqual(
                answer.result as? String, "undefined",
                "chrome.bookmarks must be gated on the bookmarks permission; reachable without it is a real leak"
            )
        }
    }
}
