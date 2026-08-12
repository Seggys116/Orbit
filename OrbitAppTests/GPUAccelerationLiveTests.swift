//  Proves WebGL/WebGPU are backed by the Metal GPU, not SwiftShader (which still
//  renders, just wrongly). Served over LiveHTTPTestServer since navigator.gpu needs a secure context.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class GPUAccelerationLiveTests: XCTestCase {

    // Distinct from any UI colour, and distinct from each other, so a capture
    // proves which API painted it.
    private static let webGLClear = (red: 17, green: 136, blue: 68)
    private static let webGPUClear = (red: 204, green: 17, blue: 153)

    // MARK: - WebGL

    func testWebGLAndWebGL2AreBackedByTheRealGPUAndReadBackWhatTheyDrew() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let report = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> [String: Any] in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: GPUAccelerationLiveTests.webGLPage),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return try await GPUAccelerationLiveTests.pageProbeResult(contents)
        }

        for version in ["webgl", "webgl2"] {
            let info = try XCTUnwrap(report[version] as? [String: Any], "no report for \(version)")
            XCTAssertEqual(
                info["hasContext"] as? Bool, true,
                "canvas.getContext(\"\(version)\") returned null — the engine cannot make a \(version) context at all"
            )
            let renderer = (info["unmaskedRenderer"] as? String) ?? ""
            XCTAssertFalse(
                renderer.isEmpty,
                "WEBGL_debug_renderer_info gave no unmasked renderer for \(version) — the extension is unavailable, which is itself a GPU-stack failure"
            )
            // SwiftShader is Chromium's CPU fallback; a page that lands on it
            // renders, so nothing fails loudly on its own.
            XCTAssertFalse(
                renderer.lowercased().contains("swiftshader"),
                "\(version) fell back to SwiftShader (software) instead of the GPU: \(renderer)"
            )
            XCTAssertTrue(
                renderer.contains("Metal"),
                "\(version) is not on the Metal backend — hardware acceleration is not actually in use: \(renderer)"
            )
            let pixel = try XCTUnwrap(info["pixel"] as? [Int], "\(version) reported no readPixels result")
            XCTAssertEqual(pixel.count, 4)
            XCTAssertEqual(pixel[0], GPUAccelerationLiveTests.webGLClear.red, accuracy: 2, "\(version) readPixels red")
            XCTAssertEqual(pixel[1], GPUAccelerationLiveTests.webGLClear.green, accuracy: 2, "\(version) readPixels green")
            XCTAssertEqual(pixel[2], GPUAccelerationLiveTests.webGLClear.blue, accuracy: 2, "\(version) readPixels blue")
        }
    }

    func testWebGLCanvasReachesTheCompositorAsNonBlankPixels() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let sampled = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> (Int, Int, Int)? in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: GPUAccelerationLiveTests.webGLPage),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            _ = try await GPUAccelerationLiveTests.pageProbeResult(contents)
            return await GPUAccelerationLiveTests.centrePixel(of: contents)
        }

        let pixel = try XCTUnwrap(sampled, "capturePreview returned nothing for a page whose only content is a WebGL canvas")
        // The page's own background is white and the canvas covers it entirely,
        // so anything near-white is a canvas that never painted.
        GPUAccelerationLiveTests.assertNotBlank(pixel, api: "WebGL")
        // Exact channels not asserted: the captured surface passed through
        // the display's colour space, but channel ordering does not move.
        XCTAssertTrue(
            pixel.1 > pixel.2 && pixel.2 > pixel.0,
            "composited WebGL pixel \(pixel) is not the green-dominant clear colour the canvas drew"
        )
    }

    // MARK: - WebGPU

    func testWebGPUExposesAnAdapterAndDeviceOnTheRealGPU() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let report = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> [String: Any] in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: GPUAccelerationLiveTests.webGPUPage),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return try await GPUAccelerationLiveTests.pageProbeResult(contents)
        }

        XCTAssertEqual(
            report["hasNavigatorGPU"] as? Bool, true,
            "navigator.gpu is undefined — WebGPU is not exposed to pages at all"
        )
        XCTAssertNil(report["adapterError"], "requestAdapter() threw: \(report["adapterError"] ?? "")")
        XCTAssertEqual(
            report["hasAdapter"] as? Bool, true,
            "navigator.gpu.requestAdapter() resolved to null — no adapter is available to pages"
        )
        let vendor = (report["adapterVendor"] as? String) ?? ""
        let architecture = (report["adapterArchitecture"] as? String) ?? ""
        XCTAssertFalse(
            (vendor + architecture).lowercased().contains("swiftshader"),
            "WebGPU adapter is the software fallback, not the GPU: vendor=\(vendor) architecture=\(architecture)"
        )
        XCTAssertFalse(vendor.isEmpty, "adapter.info reported no vendor")
        XCTAssertNil(report["deviceError"], "requestDevice() threw: \(report["deviceError"] ?? "")")
        XCTAssertEqual(report["hasDevice"] as? Bool, true, "adapter.requestDevice() produced no device")
        XCTAssertEqual(
            report["hasCanvasContext"] as? Bool, true,
            "canvas.getContext(\"webgpu\") returned null — a page can get a device but cannot present with it"
        )
        XCTAssertEqual(
            report["submitted"] as? Bool, true,
            "a WebGPU render pass never completed: \(report["submitError"] ?? "no error reported")"
        )
    }

    func testWebGPUCanvasReachesTheCompositorAsNonBlankPixels() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let sampled = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> (Int, Int, Int)? in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: GPUAccelerationLiveTests.webGPUPage),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            _ = try await GPUAccelerationLiveTests.pageProbeResult(contents)
            return await GPUAccelerationLiveTests.centrePixel(of: contents)
        }

        let pixel = try XCTUnwrap(sampled, "capturePreview returned nothing for a page whose only content is a WebGPU canvas")
        GPUAccelerationLiveTests.assertNotBlank(pixel, api: "WebGPU")
        XCTAssertTrue(
            pixel.0 > pixel.2 && pixel.2 > pixel.1,
            "composited WebGPU pixel \(pixel) is not the magenta clear colour the render pass wrote"
        )
    }

    /// The fixture pages paint white until their canvas does anything, so
    /// this tells "the API worked" apart from "it silently did nothing".
    private static func assertNotBlank(
        _ pixel: (Int, Int, Int),
        api: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let isNearWhite = pixel.0 > 235 && pixel.1 > 235 && pixel.2 > 235
        XCTAssertFalse(
            isNearWhite,
            "\(api) canvas composited as the page's blank white background \(pixel) — nothing was ever drawn",
            file: file, line: line
        )
    }

    // MARK: - Fixtures

    // evaluateJavaScript doesn't resolve promises, and requestAdapter/
    // requestDevice are async, so each page parks its answer on window.__orbitProbe to poll for.
    private static let probeTail = "window.__orbitProbe = JSON.stringify(out);"

    private static let webGLPage = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;height:100%;background:#ffffff}canvas{display:block;width:100vw;height:100vh}
    </style></head><body><canvas id="c"></canvas><script>
    (function () {
      var out = {};
      var clear = [17 / 255, 136 / 255, 68 / 255, 1];
      function probe(name, canvas) {
        var info = { hasContext: false };
        var gl = canvas.getContext(name);
        if (!gl) { return info; }
        info.hasContext = true;
        info.version = gl.getParameter(gl.VERSION);
        var debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
        info.unmaskedRenderer = debugInfo ? gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL) : '';
        gl.clearColor(clear[0], clear[1], clear[2], clear[3]);
        gl.clear(gl.COLOR_BUFFER_BIT);
        var px = new Uint8Array(4);
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
        info.pixel = [px[0], px[1], px[2], px[3]];
        return info;
      }
      // Separate canvases: a canvas only ever hands out one context type.
      out.webgl = probe('webgl', document.createElement('canvas'));
      out.webgl2 = probe('webgl2', document.createElement('canvas'));

      // The on-screen one, redrawn every frame so what the compositor holds is
      // always a freshly cleared buffer rather than whatever survived a swap.
      var canvas = document.getElementById('c');
      canvas.width = 320;
      canvas.height = 240;
      var gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
      if (gl) {
        (function draw() {
          gl.viewport(0, 0, canvas.width, canvas.height);
          gl.clearColor(clear[0], clear[1], clear[2], clear[3]);
          gl.clear(gl.COLOR_BUFFER_BIT);
          requestAnimationFrame(draw);
        })();
      }
      \(probeTail)
    })();
    </script></body></html>
    """

    private static let webGPUPage = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;height:100%;background:#ffffff}canvas{display:block;width:100vw;height:100vh}
    </style></head><body><canvas id="c"></canvas><script>
    (async function () {
      var out = { hasNavigatorGPU: !!navigator.gpu, hasAdapter: false, hasDevice: false,
                  hasCanvasContext: false, submitted: false };
      try {
        if (navigator.gpu) {
          var adapter = await navigator.gpu.requestAdapter();
          out.hasAdapter = !!adapter;
          if (adapter) {
            var info = adapter.info || {};
            out.adapterVendor = info.vendor || '';
            out.adapterArchitecture = info.architecture || '';
            out.adapterFeatures = Array.from(adapter.features || []).length;
            try {
              var device = await adapter.requestDevice();
              out.hasDevice = !!device;
              var canvas = document.getElementById('c');
              canvas.width = 320;
              canvas.height = 240;
              var context = canvas.getContext('webgpu');
              out.hasCanvasContext = !!context;
              if (device && context) {
                var format = navigator.gpu.getPreferredCanvasFormat();
                context.configure({ device: device, format: format, alphaMode: 'opaque' });
                var draw = function () {
                  var encoder = device.createCommandEncoder();
                  var pass = encoder.beginRenderPass({
                    colorAttachments: [{
                      view: context.getCurrentTexture().createView(),
                      clearValue: { r: 204 / 255, g: 17 / 255, b: 153 / 255, a: 1 },
                      loadOp: 'clear',
                      storeOp: 'store'
                    }]
                  });
                  pass.end();
                  device.queue.submit([encoder.finish()]);
                };
                draw();
                await device.queue.onSubmittedWorkDone();
                out.submitted = true;
                (function loop() { draw(); requestAnimationFrame(loop); })();
              }
            } catch (deviceError) {
              out.deviceError = String(deviceError);
            }
          }
        }
      } catch (adapterError) {
        out.adapterError = String(adapterError);
      }
      \(probeTail)
    })();
    </script></body></html>
    """

    /// Polls for the page's own `window.__orbitProbe`, which every fixture
    /// above sets once its async work is finished.
    private static func pageProbeResult(
        _ contents: ChromiumWebContents,
        timeout: Duration = .seconds(30)
    ) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let raw = try? await contents.evaluateJavaScript("window.__orbitProbe || ''")
            if let json = raw as? String, !json.isEmpty,
               let data = json.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parsed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EngineError(
            code: .engineUnavailable,
            underlyingDescription: "the page never set window.__orbitProbe — its GPU probe never finished"
        )
    }

    private static func centrePixel(of contents: ChromiumWebContents) async -> (Int, Int, Int)? {
        // The compositor is one or two frames behind the JS that queued the
        // draw, and capturePreview reads the latest surface, not the DOM.
        try? await Task.sleep(for: .milliseconds(500))
        guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: 320, height: 240)),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let colour = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                  .usingColorSpace(.deviceRGB)
        else { return nil }
        return (
            Int((colour.redComponent * 255).rounded()),
            Int((colour.greenComponent * 255).rounded()),
            Int((colour.blueComponent * 255).rounded())
        )
    }
}
