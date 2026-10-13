import MachO
import XCTest
@testable import Orbit

@MainActor
final class WebKitEngineLaunchTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach {
            $0.contentView = nil
            $0.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    func testShippedEngineLoadsFixtureTextAsWebKit() async throws {
        let fixture = "orbit-webkit-fixture-text"
        let html = "<!doctype html><html><body><p id=\"fixture\">\(fixture)</p></body></html>"
        let engine = EngineFactory.makeEngine(storage: .ephemeral)
        XCTAssertEqual(type(of: engine).kind, .webkit)
        XCTAssertTrue(engine.versionDescription.contains("WebKit"))
        let contents = try engine.makeWebContents(session: engine.defaultSession, initialURL: nil)
        host(contents)
        contents.loadHTML(html, baseURL: URL(string: "https://orbit.test/"))
        let text = try await waitForText(contents, script: "document.getElementById('fixture') ? document.getElementById('fixture').textContent : ''", equals: fixture)
        XCTAssertEqual(text, fixture)
        assertNoChromiumLinked()
        engine.shutdown()
    }

    func testAppTargetDoesNotFetchOrLinkChromium() throws {
        let project = try String(contentsOf: repositoryFile("Orbit.xcodeproj/project.pbxproj"), encoding: .utf8)
        for needle in [
            "embed-chromium-framework",
            "ensure-chromium-engine",
            "Chromium.xcconfig",
            "Orbit Framework.framework",
        ] {
            XCTAssertFalse(project.contains(needle), needle)
        }
    }

    private func host(_ contents: WebContents) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = false
        window.contentView = contents.view
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    private func waitForText(_ contents: WebContents, script: String, equals expected: String) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        var latest = ""
        while Date() < deadline {
            if let value = try? await contents.evaluateJavaScript(script), let text = value as? String {
                latest = text
                if text == expected { return text }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
    }

    private func assertNoChromiumLinked() {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            XCTAssertFalse(path.contains("Orbit Framework.framework"), path)
            XCTAssertFalse(path.contains("Chromium Framework"), path)
        }
    }

    private func repositoryFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
