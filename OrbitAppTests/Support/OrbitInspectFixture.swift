// A realistic page that exercises every inspector tool against real WebKit, including a source map and Next.js-style data.

import AppKit
import Foundation
import SwiftUI
@testable import Orbit

@MainActor
enum OrbitInspectFixture {
    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Orbit inspector fixture</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="description" content="A page used to verify Orbit's developer tools against a real WebKit page.">
      <link rel="stylesheet" href="/app.css">
      <style id="inline-style">.badge { color: #c00; padding: 2px 6px; }</style>
      <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"user":{"name":"Ada"},"items":[1,2,3]}},"page":"/blog/[slug]","query":{"slug":"hello"},"buildId":"fixture-build","isFallback":false,"gssp":true}</script>
    </head>
    <body>
      <div id="__next">
        <header class="card" id="top"><h1>Fixture</h1><p class="badge">badge</p></header>
        <main>
          <button id="go" class="btn">Run</button>
          <a href="/other">other</a>
          <img src="/pixel.png" alt="pixel" width="40" height="40">
          <div id="spinner" class="spin">spin</div>
        </main>
      </div>
      <script src="/app.js"></script>
    </body>
    </html>
    """

    static let css = """
    body { margin: 0; font: 14px/1.4 -apple-system, sans-serif; color: #222; }
    .card { padding: 12px 16px; background: #f3f4f6; border: 1px solid #ddd; margin: 8px; }
    .card:hover { background: #e5e7eb; }
    .btn { padding: 6px 12px; border-radius: 6px; background: royalblue; color: white; transition: transform 300ms ease; }
    .btn:hover { transform: scale(1.05); }
    @media (min-width: 400px) { .card { padding: 20px; } }
    .spin { width: 40px; height: 40px; animation: spin 2s linear infinite; }
    @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    """

    static let js = """
    console.log("fixture loaded", { a: 1, nested: { b: [1, 2, 3] } });
    console.warn("a warning");
    console.error("an error", new Error("boom").message);
    console.group("group");
    console.info("inside");
    console.groupEnd();
    console.table([{ x: 1, y: 2 }, { x: 3, y: 4 }]);
    localStorage.setItem("theme", "dark");
    localStorage.setItem("count", "3");
    sessionStorage.setItem("tab", "1");
    performance.mark("fixture-start");
    fetch("/api/data.json", { headers: { "X-Fixture": "yes" } }).then(function (r) { return r.json(); }).then(function (d) { console.log("data", d); });
    var xhr = new XMLHttpRequest(); xhr.open("GET", "/api/xhr.json"); xhr.send();
    setTimeout(function () { throw new Error("late failure"); }, 300);
    //# sourceMappingURL=/app.js.map
    """

    static let sourceMap = """
    {"version":3,"file":"app.js","sources":["src/app.ts"],"sourcesContent":["// original source\\nconsole.log('fixture loaded');\\n"],"names":[],"mappings":"AAAA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA;AACA"}
    """

    static func routes() -> [String: LiveHTTPTestServer.Route] {
        [
            "/": .init(contentType: "text/html; charset=utf-8", body: html, extraHeaders: ["Set-Cookie": "sid=abc123; Path=/; HttpOnly", "X-Powered-By": "Next.js"]),
            "/app.css": .init(contentType: "text/css", body: css),
            "/app.js": .init(contentType: "application/javascript", body: js, extraHeaders: ["Cache-Control": "max-age=60"]),
            "/app.js.map": .init(contentType: "application/json", body: sourceMap),
            "/api/data.json": .init(contentType: "application/json", body: "{\"ok\":true,\"items\":[1,2,3]}"),
            "/api/xhr.json": .init(contentType: "application/json", body: "{\"xhr\":true}"),
            "/pixel.png": .init(contentType: "image/png", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!),
        ]
    }

    /// Renders a SwiftUI view to a PNG on disk so a person (or the agent) can look at it.
    static func snapshot<V: View>(_ view: V, size: CGSize, name: String, appearance: NSAppearance.Name = .darkAqua) -> URL? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let directory = URL(fileURLWithPath: "/tmp/orbit-inspect-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        return url
    }
}
