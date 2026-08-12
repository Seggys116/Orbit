//  Writes a real, minimal MV3 unpacked extension: content script that marks the
//  DOM and round-trips a message to its worker, plus an options page. Nothing mocked.

import Foundation

enum LiveExtensionFixture {

    struct Built {
        let directory: URL
        let contentScriptMarkerAttribute = "data-orbit-live-test-content-script-ran"
        let backgroundResponseMarkerAttribute = "data-orbit-live-test-background-responded"
        let optionsPageTitle = "Orbit Live Test Options"
    }

    /// `matchHost` must be the bare host content_scripts should run on
    /// (no scheme, no port -- match patterns ignore port).
    static func write(named name: String, matchHost: String) throws -> Built {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-LiveExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            {
              "matches": ["http://\(matchHost)/*"],
              "js": ["content.js"],
              "run_at": "document_idle"
            }
          ],
          "options_page": "options.html"
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          if (message === 'orbit-live-test-ping') {
            sendResponse('orbit-live-test-pong');
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        document.documentElement.setAttribute('data-orbit-live-test-content-script-ran', 'true');
        chrome.runtime.sendMessage('orbit-live-test-ping', function(response) {
          if (response === 'orbit-live-test-pong') {
            document.documentElement.setAttribute('data-orbit-live-test-background-responded', 'true');
          }
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let options = """
        <!DOCTYPE html>
        <html><head><title>Orbit Live Test Options</title></head>
        <body><div id="marker">orbit-live-test-options-page</div></body></html>
        """
        try options.write(to: directory.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)

        return Built(directory: directory)
    }
}
