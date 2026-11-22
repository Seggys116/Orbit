//  A file dragged in from another app must reach the page the way it reaches any browser: a site's drop zone sees the
//  dragenter, dragover and drop events and the file itself. Each test drops a real file on a real page in a real window.

import AppKit
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class PageFileDropLiveTests: LiveEnvironmentTestCase {

    private var server: LiveHTTPTestServer!
    private var spaceID: SpaceID!
    private var window: NSWindow?
    private var scratch: URL?
    private var pasteboards: [NSPasteboard] = []

    private static let dropPage = """
    <!doctype html><title>drop</title>
    <style>html,body{margin:0;height:100%}#zone{position:fixed;inset:0;background:#cde}</style>
    <div id="zone"></div>
    <script>
    window.__log = [];
    const zone = document.getElementById('zone');
    for (const type of ['dragenter', 'dragover', 'dragleave']) {
      zone.addEventListener(type, e => { e.preventDefault(); window.__log.push(type); });
    }
    zone.addEventListener('drop', async e => {
      e.preventDefault();
      const files = Array.from(e.dataTransfer.files);
      const texts = await Promise.all(files.map(f => f.text()));
      window.__log.push('drop:' + files.map((f, i) => f.name + '=' + texts[i]).join(','));
    });
    </script>
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try LiveHTTPTestServer(routes: ["/drop": .init(contentType: "text/html; charset=utf-8", body: Self.dropPage)])
        let profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(name: "File Drop", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        env.selectSpace(spaceID)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out: \(what)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The page as the app lays it out: the page's view in a slot, with the link drop target laid over it. The target is registered for files, links and text, so it is offered every one of those drags.
    private func openDropPage() async throws -> (contents: WebKitWebContents, window: NSWindow, catcher: LinkDropCatcherView) {
        env._test_engineOverride = await WebKitLiveEngineHost.sharedEngine()
        let address = URL(string: "/drop", relativeTo: server.baseURL)!.absoluteURL
        let tabID = env.openTab(url: address, in: spaceID)
        try await waitUntil("the drop page loaded") {
            (self.env.webContents[tabID] as? WebKitWebContents)?.webView.url == address && self.env.navigationState(for: tabID)?.isLoading == false
        }
        let contents = try XCTUnwrap(env.webContents[tabID] as? WebKitWebContents)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let slot = NSView(frame: host.bounds)
        contents.webView.frame = slot.bounds
        contents.webView.autoresizingMask = [.width, .height]
        slot.addSubview(contents.webView)
        host.addSubview(slot)
        let catcher = LinkDropCatcherView(frame: host.bounds)
        catcher.environment = env
        catcher.targetTabID = tabID
        host.addSubview(catcher)
        window.contentView = host
        window.orderFront(nil)
        contents.setVisible(true)
        self.window = window
        try await waitUntil("the zone exists") { (try await contents.evaluateJavaScript("typeof window.__log") as? String) == "object" }
        return (contents, window, catcher)
    }

    private func finderStylePasteboard(fileNamed name: String, contents: String) throws -> NSPasteboard {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-file-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratch = directory
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PageFileDropLiveTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func log(of contents: WebKitWebContents) async throws -> [String] {
        try await contents.evaluateJavaScript("window.__log") as? [String] ?? []
    }

    func test_aFileDroppedOnThePageReachesTheSitesDropZone() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let (contents, window, _) = try await self.openDropPage()
            let pasteboard = try self.finderStylePasteboard(fileNamed: "upload.txt", contents: "hello")
            let info = StandInDraggingInfo(location: NSPoint(x: 300, y: 200), pasteboard: pasteboard, window: window)
            let view = contents.webView

            let entered = view.draggingEntered(info)
            XCTAssertFalse(entered.isEmpty, "The page refused the file when it was dragged over it.")
            _ = view.draggingUpdated(info)
            XCTAssertTrue(view.prepareForDragOperation(info))
            XCTAssertTrue(view.performDragOperation(info), "The page refused the drop.")
            view.concludeDragOperation(info)

            try await self.waitUntil("the drop reached the page") { try await self.log(of: contents).contains { $0.hasPrefix("drop:") } }
            let events = try await self.log(of: contents)
            XCTAssertTrue(events.contains("dragenter"), "The site never saw dragenter: \(events)")
            XCTAssertTrue(events.contains("dragover"), "The site never saw dragover: \(events)")
            XCTAssertTrue(events.contains("drop:upload.txt=hello"), "The site did not receive the file: \(events)")
        }
    }

    private func linkPasteboard(_ link: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PageFileDropLiveTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(link, forType: NSPasteboard.PasteboardType(UTType.url.identifier))
        pasteboards.append(pasteboard)
        return pasteboard
    }

    // The link drop target is what a drag is offered to when it is registered for the types the drag carries, so a file has to pass through it to the page.
    func test_aFileOfferedToTheLinkDropTarget_isPassedOnToTheSitesDropZone() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let (contents, window, catcher) = try await self.openDropPage()
            let pasteboard = try self.finderStylePasteboard(fileNamed: "upload.txt", contents: "hello")
            let info = StandInDraggingInfo(location: NSPoint(x: 300, y: 200), pasteboard: pasteboard, window: window)

            XCTAssertFalse(catcher.draggingEntered(info).isEmpty, "The file was turned away when it was dragged over the page.")
            _ = catcher.draggingUpdated(info)
            XCTAssertTrue(catcher.prepareForDragOperation(info))
            XCTAssertTrue(catcher.performDragOperation(info), "The drop was refused.")
            catcher.concludeDragOperation(info)

            try await self.waitUntil("the drop reached the page") { try await self.log(of: contents).contains { $0.hasPrefix("drop:") } }
            let events = try await self.log(of: contents)
            XCTAssertTrue(events.contains("dragenter"), "The site never saw dragenter: \(events)")
            XCTAssertTrue(events.contains("drop:upload.txt=hello"), "The site did not receive the file: \(events)")
        }
    }

    func test_aFileLeavingTheLinkDropTarget_leavesTheSitesDropZoneToo() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let (contents, window, catcher) = try await self.openDropPage()
            let pasteboard = try self.finderStylePasteboard(fileNamed: "upload.txt", contents: "hello")
            let info = StandInDraggingInfo(location: NSPoint(x: 300, y: 200), pasteboard: pasteboard, window: window)

            _ = catcher.draggingEntered(info)
            catcher.draggingExited(info)

            try await self.waitUntil("the site saw the drag leave") { try await self.log(of: contents).contains("dragleave") }
        }
    }

    // A link is the target's own: in the middle of the page it opens nothing, and the page must not be handed it to navigate to.
    func test_aLinkLetGoInTheMiddleOfThePage_isNotPassedToTheSite() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let (contents, window, catcher) = try await self.openDropPage()
            let info = StandInDraggingInfo(location: NSPoint(x: 300, y: 200), pasteboard: self.linkPasteboard("https://example.com/dropped"), window: window)

            XCTAssertTrue(catcher.draggingEntered(info).isEmpty, "A link in the middle of the page was accepted.")
            XCTAssertFalse(catcher.performDragOperation(info), "A link in the middle of the page was dropped.")
            try await Task.sleep(for: .milliseconds(300))

            let events = try await self.log(of: contents)
            XCTAssertEqual(events, [], "The page was handed a drag that belongs to the link drop target: \(events)")
        }
    }
}
