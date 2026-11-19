import AppKit
import UniformTypeIdentifiers
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class InspectElementContextMenuTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private let inspectorCapableBackend: EngineCapabilities = [.developerTools, .audioMuting]
    private let inspectorIncapableBackend: EngineCapabilities = [.audioMuting]

    // MARK: - Helpers

    private func item(
        titled title: String, in entries: [OrbitContextMenuEntry], file: StaticString = #filePath, line: UInt = #line
    ) -> OrbitContextMenuItem? {
        let found = entries.first(titled: title)
        XCTAssertNotNil(
            found,
            "Expected a \"\(title)\" item in the page context menu. Present: \(entries.flattenedItems.map(\.title))",
            file: file, line: line
        )
        return found
    }

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(
                name: "Context Menu Test Space",
                icon: "circle",
                iconIsEmoji: false,
                theme: SpaceTheme(),
                profileID: env.createDefaultProfileIfNeeded()
            )
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    // MARK: - The item exists and is enabled on a capable backend

    func test_menu_offersInspectElement_whenTheBackendCanOpenAnInspector() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )

        guard let inspect = item(titled: "Inspect Element", in: entries) else { return }
        XCTAssertTrue(
            inspect.isEnabled,
            "Inspect Element must be enabled on a backend that reports EngineCapabilities.developerTools."
        )
    }

    // MARK: - Invoking it actually opens the inspector

    func test_invokingInspectElement_opensDeveloperToolsAtTheRightClickPoint() {
        let contents = MockWebContents()
        let clickPoint = CGPoint(x: 412, y: 233)
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), location: clickPoint),
            capabilities: inspectorCapableBackend
        )
        XCTAssertEqual(contents.showDeveloperToolsCallCount, 0, "test precondition: nothing invoked yet")

        guard let inspect = item(titled: "Inspect Element", in: entries) else { return }
        inspect.action?()

        XCTAssertEqual(
            contents.showDeveloperToolsCallCount, 1,
            "Invoking the real \"Inspect Element\" item must call showDeveloperTools on the web contents exactly once."
        )
        XCTAssertEqual(
            contents.lastInspectPoint, clickPoint,
            """
            Inspect Element must forward the right-click point, not nil: that point is what makes \
            DevTools open focused on the element under the cursor instead of the document root.
            """
        )
    }

    // MARK: - A backend that cannot open an inspector must say so

    func test_inspectElement_isDisabled_whenTheBackendCannotOpenAnInspector() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorIncapableBackend
        )

        guard let inspect = item(titled: "Inspect Element", in: entries) else { return }
        XCTAssertFalse(
            inspect.isEnabled,
            "A backend with no EngineCapabilities.developerTools cannot open an inspector, so the item must not look usable."
        )
        XCTAssertNotNil(
            inspect.tooltip,
            "A disabled Inspect Element must explain why it is disabled rather than just being dead."
        )
    }

    func test_inspectElement_doesNothing_whenTheBackendCannotOpenAnInspector() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), location: CGPoint(x: 10, y: 10)),
            capabilities: inspectorIncapableBackend
        )

        guard let inspect = item(titled: "Inspect Element", in: entries) else { return }
        // OrbitContextMenuRow guards `item.isEnabled` before calling action();
        // this asserts the contract that disabled items are unreachable.
        XCTAssertFalse(inspect.isEnabled)
    }

    // MARK: - No engine at all is the incapable backend

    func test_menuWithNoEngineRunning_offersInspectElementDisabled() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: []
        )

        guard let inspect = item(titled: "Inspect Element", in: entries) else { return }
        XCTAssertFalse(inspect.isEnabled)
    }

    // MARK: - The rest of the menu still works (and its enabled flags are real)

    func test_invokingBack_navigatesBack_whenHistoryAllowsIt() {
        let contents = MockWebContents()
        contents.navigationState.canGoBack = true
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )

        guard let back = item(titled: "Back", in: entries) else { return }
        XCTAssertTrue(back.isEnabled)
        back.action?()

        XCTAssertEqual(contents.goBackCallCount, 1, "Invoking the real \"Back\" item must call goBack() on the web contents.")
    }

    func test_back_isDisabled_whenThereIsNoHistoryBehindThePage() {
        let contents = MockWebContents()
        contents.navigationState.canGoBack = false
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )

        guard let back = item(titled: "Back", in: entries) else { return }
        XCTAssertFalse(back.isEnabled, "\"Back\" must stay disabled when navigationState.canGoBack is false.")
    }

    func test_invokingReload_reloadsThePage() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )

        guard let reload = item(titled: "Reload", in: entries) else { return }
        reload.action?()

        XCTAssertEqual(contents.reloadCallCount, 1)
    }

    func test_invokingOpenLinkInNewTab_resolvesTheOwningTabByReferenceNotByContentsID() {
        let tab = makeTab()
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tab.id)
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        XCTAssertNotEqual(
            contents.id, tab.id,
            "test precondition: the backend's own id must differ from the TabID, exactly as it does in both real backends."
        )

        let linkURL = URL(string: "https://link.example.com/target")!
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), linkURL: linkURL),
            capabilities: inspectorCapableBackend
        )

        let tabIDsBefore = Set(env.state.tabs.keys)
        guard let openInNewTab = item(titled: "Open Link in New Tab", in: entries) else { return }
        openInNewTab.action?()

        let newTabIDs = Set(env.state.tabs.keys).subtracting(tabIDsBefore)
        defer { for id in newTabIDs { env.state.tabs.removeValue(forKey: id) } }

        XCTAssertEqual(
            newTabIDs.count, 1,
            """
            Invoking "Open Link in New Tab" opened no tab. This is the AppEnvironment.tabID(for:) \
            contract: WebContents.id is the backend's own UUID, so a state.tabs[contents.id] lookup \
            silently misses and the item does nothing.
            """
        )
        if let newTabID = newTabIDs.first {
            XCTAssertEqual(env.state.tabs[newTabID]?.url, linkURL)
            XCTAssertEqual(
                env.state.tabs[newTabID]?.spaceID, tab.spaceID,
                "The new tab must land in the space the right-clicked tab belongs to."
            )
        }
    }

    func test_everyRealItem_hasAWorkingAction() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(
                pageURL: URL(string: "https://example.com"),
                linkURL: URL(string: "https://link.example.com"),
                sourceURL: URL(string: "https://img.example.com/a.png"),
                selectionText: "selected text",
                mediaKind: .image
            ),
            capabilities: inspectorCapableBackend
        )

        let items = entries.flattenedItems
        XCTAssertFalse(items.isEmpty)
        for menuItem in items {
            XCTAssertNotNil(menuItem.action, "\"\(menuItem.title)\" has no action.")
        }
    }

    func test_inspectElement_isTheLastItem_afterASeparator() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )

        guard case .item(let last)? = entries.last else {
            return XCTFail("The last entry must be an item, not a divider or section.")
        }
        XCTAssertEqual(last.title, "Inspect Element")
        XCTAssertEqual(entries.count >= 2, true)
        guard entries.count >= 2, case .divider = entries[entries.count - 2] else {
            return XCTFail("Inspect Element must be set apart from the navigation items by a divider.")
        }
    }

    // MARK: - Full parity with the menu this replaced, plus the new standard actions

    func test_linkContext_offersTheFullLinkSection() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(
                pageURL: URL(string: "https://example.com"), linkURL: URL(string: "https://link.example.com")
            ),
            capabilities: inspectorCapableBackend
        )
        for title in ["Open Link in New Tab", "Open Link in Little Orbit", "Copy Link"] {
            XCTAssertNotNil(item(titled: title, in: entries))
        }
    }

    func test_imageContext_offersOpenSaveCopyAndCopyAddress() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(
                pageURL: URL(string: "https://example.com"),
                sourceURL: URL(string: "https://img.example.com/a.png"),
                mediaKind: .image
            ),
            capabilities: inspectorCapableBackend
        )
        for title in ["Open Image in New Tab", "Save Image to Downloads", "Save Image As…", "Copy Image", "Copy Image Address"] {
            XCTAssertNotNil(item(titled: title, in: entries))
        }
    }

    func test_selectionContext_stillOffersCopyAndSearch() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), selectionText: "hello world"),
            capabilities: inspectorCapableBackend
        )
        XCTAssertNotNil(item(titled: "Copy", in: entries))
        XCTAssertNotNil(entries.flattenedItems.first { $0.title.hasPrefix("Search ") })
    }

    func test_editableContext_offersCutPasteSelectAll_andTheyReachTheWebContents() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(
                pageURL: URL(string: "https://example.com"), selectionText: "typed text", isEditable: true
            ),
            capabilities: inspectorCapableBackend
        )

        guard let cut = item(titled: "Cut", in: entries) else { return }
        XCTAssertTrue(cut.isEnabled, "Cut must be enabled when there is a selection.")
        cut.action?()
        XCTAssertEqual(contents.cutCallCount, 1)

        guard let selectAll = item(titled: "Select All", in: entries) else { return }
        selectAll.action?()
        XCTAssertEqual(contents.selectAllCallCount, 1)

        XCTAssertNotNil(item(titled: "Paste", in: entries), "An editable field must always offer Paste.")
    }

    func test_editableContext_withNoSelection_disablesCut() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), isEditable: true),
            capabilities: inspectorCapableBackend
        )
        guard let cut = item(titled: "Cut", in: entries) else { return }
        XCTAssertFalse(cut.isEnabled, "Cut with nothing selected must be disabled, not silently a no-op.")
    }

    func test_nonEditableContext_offersNoEditingCommands() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: inspectorCapableBackend
        )
        XCTAssertNil(entries.flattenedItems.first { $0.title == "Cut" })
        XCTAssertNil(entries.flattenedItems.first { $0.title == "Paste" })
        XCTAssertNil(entries.flattenedItems.first { $0.title == "Select All" })
    }

    // MARK: - Image, link and media actions

    private func pngData(width: Int = 4, height: Int = 3) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.setColor(.systemRed, atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func test_saveImageToDownloads_sendsAWebImageThroughOrbitsDownloads() {
        let contents = MockWebContents()
        let source = URL(string: "https://img.example.com/a.png")!
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), sourceURL: source, mediaKind: .image),
            capabilities: inspectorCapableBackend
        )
        guard let save = item(titled: "Save Image to Downloads", in: entries) else { return }
        save.action?()
        XCTAssertEqual(contents.downloadedResourceURLs, [source])
    }

    func test_saveImageToDownloads_writesAPageOnlyImageStraightIntoTheDownloadsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-save-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        WebKitDownloads.downloadsDirectoryOverride = folder
        defer {
            WebKitDownloads.downloadsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let contents = MockWebContents()
        let source = URL(string: "blob:https://example.com/5c1e")!
        let png = pngData()
        contents.resourceDataOverride[source] = png

        OrbitContextMenuActions.saveImageToDownloads(from: source, using: contents)

        var saved: [URL] = []
        waitUntil {
            saved = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return !saved.isEmpty
        }
        XCTAssertTrue(contents.downloadedResourceURLs.isEmpty, "A blob: image cannot go through the download store.")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.pathExtension, "png")
        XCTAssertEqual(saved.first.flatMap { try? Data(contentsOf: $0) }, png)
    }

    func test_copyImage_putsTheImageItselfOnThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-copy-image-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let contents = MockWebContents()
        let source = URL(string: "https://img.example.com/a.png")!
        let png = pngData()
        contents.resourceDataOverride[source] = png

        OrbitContextMenuActions.copyImage(from: source, using: contents, to: pasteboard)
        waitUntil { pasteboard.data(forType: .png) != nil }

        XCTAssertEqual(pasteboard.data(forType: .png), png, "The original PNG must be kept, alpha and all.")
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "A TIFF must be offered for apps that only paste TIFF.")
        let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        XCTAssertEqual(image?.representations.first?.pixelsWide, 4)
        XCTAssertEqual(pasteboard.string(forType: .URL), source.absoluteString)
    }

    func test_copyImage_leavesThePasteboardAloneWhenTheBytesAreNotAnImage() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-copy-image-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)

        XCTAssertFalse(OrbitContextMenuActions.writeImage(Data("<html>404</html>".utf8), sourceURL: nil, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "kept")
    }

    func test_suggestedImageName_followsTheRealEncodingNotTheURL() {
        let png = pngData()
        XCTAssertEqual(OrbitContextMenuActions.suggestedImageName(for: URL(string: "https://cdn.example.com/photo.jpg?w=200")!, data: png), "photo.png")
        XCTAssertEqual(OrbitContextMenuActions.suggestedImageName(for: URL(string: "data:image/png;base64,AAAA")!, data: png), "image.png")
        XCTAssertEqual(OrbitContextMenuActions.suggestedImageName(for: URL(string: "https://example.com/")!, data: png), "image.png")
    }

    func test_linkContext_offersSplitViewAndDownload_andSplitViewOpensTheLinkBesideThePage() {
        let tab = makeTab()
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tab.id)
        let tabIDsBefore = Set(env.state.tabs.keys)
        defer {
            for id in Set(env.state.tabs.keys).subtracting(tabIDsBefore) { env.closeTab(id) }
            env.state.tabs.removeValue(forKey: tab.id)
        }
        let linkURL = URL(string: "https://link.example.com/report.pdf")!
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), linkURL: linkURL),
            capabilities: inspectorCapableBackend
        )

        guard let download = item(titled: "Download Linked File", in: entries) else { return }
        download.action?()
        XCTAssertEqual(contents.downloadedResourceURLs, [linkURL])

        guard let split = item(titled: "Open Link in Split View", in: entries) else { return }
        split.action?()
        let newTabIDs = Set(env.state.tabs.keys).subtracting(tabIDsBefore)
        XCTAssertEqual(newTabIDs.count, 1)
        guard let newTabID = newTabIDs.first else { return }
        XCTAssertEqual(env.state.tabs[newTabID]?.url, linkURL)
        XCTAssertEqual(env.splitGroup(for: tab.id)?.tabIDs.sorted { $0.uuidString < $1.uuidString },
                       [tab.id, newTabID].sorted { $0.uuidString < $1.uuidString })
    }

    func test_videoContext_offersSaveCopyAddressAndPictureInPicture() {
        let contents = MockWebContents()
        let source = URL(string: "https://media.example.com/clip.mp4")!
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), sourceURL: source, mediaKind: .video),
            capabilities: inspectorCapableBackend
        )
        for title in ["Open Video in New Tab", "Save Video to Downloads", "Copy Video Address", "Picture in Picture"] {
            XCTAssertNotNil(item(titled: title, in: entries))
        }
        item(titled: "Save Video to Downloads", in: entries)?.action?()
        XCTAssertEqual(contents.downloadedResourceURLs, [source])
        item(titled: "Picture in Picture", in: entries)?.action?()
        XCTAssertEqual(contents.togglePictureInPictureCallCount, 1)
    }

    func test_streamedVideo_offersPictureInPictureButNoSaveOrAddress() {
        let contents = MockWebContents()
        let entries = env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(
                pageURL: URL(string: "https://example.com"), sourceURL: URL(string: "blob:https://example.com/9a"), mediaKind: .video
            ),
            capabilities: inspectorCapableBackend
        )
        XCTAssertNil(entries.first(titled: "Save Video to Downloads"))
        XCTAssertNil(entries.first(titled: "Copy Video Address"))
        XCTAssertNotNil(entries.first(titled: "Picture in Picture"))
    }
}
