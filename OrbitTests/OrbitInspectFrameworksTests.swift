// Logic tests for OrbitInspectFrameworksLogic.swift, which is compiled directly (no @testable import).
import XCTest
import Foundation

// MARK: - Test helpers

private func evidence(
    globals: Set<String> = [],
    globalVersions: [String: String] = [:],
    domMarkers: Set<String> = [],
    scriptURLs: [String] = [],
    linkURLs: [String] = [],
    metaGenerators: [String] = [],
    responseHeaders: [String: String] = [:],
    hostname: String = "localhost"
) -> FWEvidenceBundle {
    FWEvidenceBundle(
        globals: globals,
        globalVersions: globalVersions,
        domMarkers: domMarkers,
        scriptURLs: scriptURLs,
        linkURLs: linkURLs,
        metaGenerators: metaGenerators,
        responseHeaders: responseHeaders,
        hostname: hostname
    )
}

// MARK: - Detection tests

class FWDetectionTests: XCTestCase {

    func testReactDevToolsHook() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__REACT_DEVTOOLS_GLOBAL_HOOK__"]))
        let react = d.first { $0.name == "React" }
        XCTAssertNotNil(react)
        XCTAssertEqual(react?.confidence, .certain)
    }

    func testReactVersion() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["__REACT_DEVTOOLS_GLOBAL_HOOK__"],
            globalVersions: ["React.version": "18.3.1"]
        ))
        XCTAssertEqual(d.first { $0.name == "React" }?.version, "18.3.1")
    }

    func testNextJSPagesRouter() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__NEXT_DATA__", "__REACT_DEVTOOLS_GLOBAL_HOOK__"]))
        let next = d.first { $0.name == "Next.js" }
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.confidence, .certain)
        XCTAssertTrue(next?.evidence.contains(where: { $0.contains("Pages Router") }) == true)
    }

    func testNextJSAppRouter() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__next_f"]))
        let next = d.first { $0.name == "Next.js" }
        XCTAssertNotNil(next)
        XCTAssertTrue(next?.evidence.contains(where: { $0.contains("App Router") }) == true)
    }

    func testNextJSResponseHeader() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(responseHeaders: ["x-nextjs-cache": "HIT"]))
        XCTAssertNotNil(d.first { $0.name == "Next.js" })
    }

    func testVue3Detection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__vue_app__"]))
        let vue = d.first { $0.name == "Vue" }
        XCTAssertNotNil(vue)
        XCTAssertEqual(vue?.confidence, .certain)
    }

    func testSvelteDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(domMarkers: ["data-svelte-h"]))
        XCTAssertNotNil(d.first { $0.name == "Svelte" })
        XCTAssertEqual(d.first { $0.name == "Svelte" }?.confidence, .certain)
    }

    func testAngularDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globalVersions: ["ng.version.full": "17.1.0"], domMarkers: ["ng-version"]))
        let ng = d.first { $0.name == "Angular" }
        XCTAssertNotNil(ng)
        XCTAssertEqual(ng?.version, "17.1.0")
    }

    func testRemixDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__remixContext"]))
        XCTAssertNotNil(d.first { $0.name == "Remix" })
        XCTAssertEqual(d.first { $0.name == "Remix" }?.confidence, .certain)
    }

    func testSvelteKitDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__sveltekit_dev"]))
        XCTAssertNotNil(d.first { $0.name == "SvelteKit" })
    }

    func testAstroDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(domMarkers: ["astro-island"]))
        XCTAssertNotNil(d.first { $0.name == "Astro" })
        XCTAssertEqual(d.first { $0.name == "Astro" }?.confidence, .certain)
    }

    func testViteDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(scriptURLs: ["http://localhost:5173/@vite/client"]))
        XCTAssertNotNil(d.first { $0.name == "Vite" })
        XCTAssertEqual(d.first { $0.name == "Vite" }?.confidence, .certain)
    }

    func testWebpackDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__webpack_require__"]))
        XCTAssertNotNil(d.first { $0.name == "webpack" })
    }

    func testWordPressDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(scriptURLs: ["https://example.com/wp-content/themes/mytheme/js/app.js"]))
        XCTAssertNotNil(d.first { $0.name == "WordPress" })
    }

    func testVercelDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(responseHeaders: ["x-vercel-id": "iad1::abc123"]))
        XCTAssertNotNil(d.first { $0.name == "Vercel" })
        XCTAssertEqual(d.first { $0.name == "Vercel" }?.category, .hosting)
    }

    func testCloudflareDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(responseHeaders: ["cf-ray": "7abc123-IAD"]))
        XCTAssertNotNil(d.first { $0.name == "Cloudflare" })
    }

    func testGatsbyDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["___gatsby"]))
        XCTAssertNotNil(d.first { $0.name == "Gatsby" })
    }

    func testJQueryDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["jQuery"],
            globalVersions: ["jQuery.fn.jquery": "3.7.1"]
        ))
        let jq = d.first { $0.name == "jQuery" }
        XCTAssertNotNil(jq)
        XCTAssertEqual(jq?.version, "3.7.1")
    }

    func testPlainHTMLNoFalsePositives() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence())
        XCTAssertTrue(d.isEmpty, "Plain page should produce zero detections, got: \(d.map(\.name))")
    }

    func testDollarGlobalAloneNotJQuery() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["$"]))
        // $ alone without jQuery.fn.jquery → not detected ($ is too ambiguous)
        let jq = d.first { $0.name == "jQuery" }
        XCTAssertNil(jq, "Bare $ global should not produce a jQuery detection")
    }

    func testNuxtDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__NUXT__"]))
        XCTAssertNotNil(d.first { $0.name == "Nuxt" })
        XCTAssertEqual(d.first { $0.name == "Nuxt" }?.confidence, .certain)
    }

    func testLaravelDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(responseHeaders: ["set-cookie": "laravel_session=abc; Path=/"]))
        XCTAssertNotNil(d.first { $0.name == "Laravel" })
    }

    func testTurbopackDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__turbopack_require__"]))
        XCTAssertNotNil(d.first { $0.name == "Turbopack" })
    }

    func testAlpineDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["Alpine"],
            globalVersions: ["Alpine.version": "3.13.5"]
        ))
        let alpine = d.first { $0.name == "Alpine.js" }
        XCTAssertNotNil(alpine)
        XCTAssertEqual(alpine?.version, "3.13.5")
    }

    func testQwikDetection() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(domMarkers: ["q:container"]))
        XCTAssertNotNil(d.first { $0.name == "Qwik" })
        XCTAssertEqual(d.first { $0.name == "Qwik" }?.confidence, .certain)
    }

    func testPrimaryNameNextOverReact() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["__NEXT_DATA__", "__REACT_DEVTOOLS_GLOBAL_HOOK__"],
            globalVersions: ["next.version": "15.1.0"]
        ))
        let primary = OrbitFrameworksLogic.primary(among: d)
        XCTAssertNotNil(primary)
        XCTAssertTrue(primary?.contains("Next.js") == true)
    }

    func testCategoryOrder() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["__REACT_DEVTOOLS_GLOBAL_HOOK__", "__webpack_require__"]
        ))
        let categories = d.map(\.category)
        let reactIdx = d.firstIndex { $0.name == "React" } ?? 0
        let wpIdx = d.firstIndex { $0.name == "webpack" } ?? 0
        XCTAssertLessThan(reactIdx, wpIdx, "React (framework) should appear before webpack (build tool)")
    }

    func testDeduplication() {
        // Both __NEXT_DATA__ and /_next/ script URL would independently suggest Next.js
        let d = OrbitFrameworksLogic.detect(evidence: evidence(
            globals: ["__NEXT_DATA__"],
            domMarkers: ["#__next"],
            scriptURLs: ["http://localhost:3000/_next/static/chunks/main.js"]
        ))
        let nextCount = d.filter { $0.name == "Next.js" }.count
        XCTAssertEqual(nextCount, 1, "Should deduplicate Next.js to a single entry")
    }
}

// MARK: - Version extraction tests

class FWVersionExtractionTests: XCTestCase {

    func testSimpleVersion() {
        XCTAssertEqual(OrbitFrameworksLogic.extractVersion(from: "18.2.0"), "18.2.0")
    }

    func testVersionWithV() {
        XCTAssertEqual(OrbitFrameworksLogic.extractVersion(from: "v3.4.1"), "3.4.1")
    }

    func testVersionInSentence() {
        XCTAssertEqual(OrbitFrameworksLogic.extractVersion(from: "WordPress 6.4.1"), "6.4.1")
    }

    func testVersionWithPrerelease() {
        XCTAssertEqual(OrbitFrameworksLogic.extractVersion(from: "15.0.0-canary.1"), "15.0.0-canary.1")
    }

    func testNoVersionReturnsNil() {
        XCTAssertNil(OrbitFrameworksLogic.extractVersion(from: "no version here"))
    }

    func testTwoPartVersion() {
        XCTAssertEqual(OrbitFrameworksLogic.extractVersion(from: "3.4"), "3.4")
    }
}

// MARK: - Flight payload parser tests

class FWFlightPayloadTests: XCTestCase {

    func testModuleRefRow() {
        // Module refs with a string path in position 0
        let row = OrbitFrameworksLogic.parseFlightRow("1:I[\"react-server-dom-webpack/client.browser\",[\"createFromFetch\"],\"createFromFetch\"]", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .moduleRef)
        XCTAssertEqual(row?.rowID, "1")
        XCTAssertEqual(row?.moduleURL, "react-server-dom-webpack/client.browser")
        XCTAssertEqual(row?.moduleExport, "createFromFetch")
    }

    func testModuleRefRowNumericID() {
        // Module refs can also use a numeric chunk ID — type still resolves to moduleRef
        let row = OrbitFrameworksLogic.parseFlightRow("5:I[1234,[\"react\"],\"\"]", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .moduleRef)
        XCTAssertEqual(row?.rowID, "5")
        // moduleURL will be nil when the first element is a number — that is expected
    }

    func testHTMLLinkHintRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("0:HL[\"/_next/static/css/app.css\",\"style\"]", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .htmlLinkHint)
    }

    func testHTMLLinkRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("2:H\"/_next/static/css/app.css\"", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .htmlLink)
    }

    func testJSONRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("3:{\"user\":\"alice\",\"id\":42}", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .json)
    }

    func testReactElementRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("4:[\"$\",\"div\",null,{\"className\":\"container\"}]", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .json)
    }

    func testErrorRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("5:E{\"message\":\"Something went wrong\"}", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .error)
    }

    func testRouterStateRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("6:[\"layout\",{\"children\":[\"page\",{},\"page\",\"default\"]},\"/app/page.tsx\",\"layout\"]", rowIndex: 0)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .routerState)
    }

    func testMissingColonReturnsNil() {
        let row = OrbitFrameworksLogic.parseFlightRow("notarow", rowIndex: 0)
        XCTAssertNil(row)
    }

    func testEmptyContentRow() {
        let row = OrbitFrameworksLogic.parseFlightRow("7:", rowIndex: 0)
        // Should produce an unknown row, not crash
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.rowType, .unknown)
    }

    func testMultiChunkPayload() {
        let chunks = [
            "0:HL[\"/_next/static/css/app.css\",\"style\"]\n",
            "1:I[1234,[\"react\"],\"\"]\n",
            "2:{\"page\":\"home\"}\n"
        ]
        let rows = OrbitFrameworksLogic.parseFlightPayload(chunks)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].rowType, .htmlLinkHint)
        XCTAssertEqual(rows[1].rowType, .moduleRef)
        XCTAssertEqual(rows[2].rowType, .json)
    }

    func testFRefDecoding() {
        let decoded = OrbitFrameworksLogic.decodeFRefs("[\"$\",\"div\",null,{}]")
        XCTAssertTrue(decoded.contains("<element>"), "Should replace \"$\" with <element>")
    }

    func testSuspenseRefDecoding() {
        let decoded = OrbitFrameworksLogic.decodeFRefs("[\"$S\",[[\"$\",\"div\",null,{}]]]")
        XCTAssertTrue(decoded.contains("<Suspense>"))
    }
}

// MARK: - Route tree parser tests

class FWRouteTreeTests: XCTestCase {

    func testSimplePageRoute() {
        let tree: [Any] = ["blog", ["children": ["__PAGE__", [:], "/blog", "page"]]]
        let routes = OrbitFrameworksLogic.parseNextRouteTree(tree)
        XCTAssertTrue(routes.contains { $0.path.contains("blog") })
    }

    func testNestedRoutes() {
        let tree: [Any] = [
            "",
            ["children": [
                "dashboard",
                ["children": ["__PAGE__", [:], "/dashboard", "page"]]
            ]]
        ]
        let routes = OrbitFrameworksLogic.parseNextRouteTree(tree)
        XCTAssertFalse(routes.isEmpty)
    }

    func testRouteGroupTransparent() {
        // (auth) group should not appear in the URL path
        let tree: [Any] = [
            "(auth)",
            ["children": ["login", ["children": ["__PAGE__", [:], "/login", "page"]]]]
        ]
        let routes = OrbitFrameworksLogic.parseNextRouteTree(tree)
        let paths = routes.map(\.path)
        XCTAssertFalse(paths.contains(where: { $0.contains("(auth)") }), "Route groups should be stripped from paths")
    }

    func testEmptyTreeReturnsEmpty() {
        XCTAssertTrue(OrbitFrameworksLogic.parseNextRouteTree(nil).isEmpty)
        XCTAssertTrue(OrbitFrameworksLogic.parseNextRouteTree([]).isEmpty)
    }

    func testDynamicSegmentDetected() {
        let tree: [Any] = ["[id]", ["children": ["__PAGE__", [:], "/[id]", "page"]]]
        let routes = OrbitFrameworksLogic.parseNextRouteTree(tree)
        let hasDynamic = routes.contains { $0.isDynamic }
        XCTAssertTrue(hasDynamic, "Dynamic routes should be marked as dynamic")
    }
}

// MARK: - Hydration diff parser tests

class FWHydrationDiffTests: XCTestCase {

    func testReact18HydrationDiff() {
        let msg = """
        Warning: Text content did not match. Server: "Hello" Client: "World"
        Server: <div>Hello</div>
        Client: <div>World</div>
        """
        let diff = OrbitFrameworksLogic.parseHydrationDiff(msg)
        XCTAssertNotNil(diff)
        XCTAssertNotNil(diff?.serverTree)
        XCTAssertNotNil(diff?.clientTree)
    }

    func testNonHydrationMessageReturnsNil() {
        let result = OrbitFrameworksLogic.parseHydrationDiff("This is a regular log message.")
        XCTAssertNil(result)
    }

    func testHydrationSummaryTruncation() {
        let long = "Hydration failed because the initial UI does not match what was rendered on the server. " + String(repeating: "x", count: 300)
        let diff = OrbitFrameworksLogic.parseHydrationDiff(long)
        XCTAssertNotNil(diff)
        XCTAssertTrue((diff?.summary.count ?? 0) <= 201, "Summary should be at most 200 chars + ellipsis")
    }
}

// MARK: - JSON path building tests

class FWJSONPathTests: XCTestCase {

    func testEmptyComponents() {
        XCTAssertEqual(OrbitFrameworksLogic.buildJSONPath([]), "$")
    }

    func testSingleKey() {
        XCTAssertEqual(OrbitFrameworksLogic.buildJSONPath(["user"]), "$.user")
    }

    func testNumericIndex() {
        XCTAssertEqual(OrbitFrameworksLogic.buildJSONPath(["items", "0", "name"]), "$.items[0].name")
    }

    func testKeyWithSpaces() {
        XCTAssertEqual(OrbitFrameworksLogic.buildJSONPath(["my key"]), "$.my key")
    }

    func testKeyWithQuotes() {
        let path = OrbitFrameworksLogic.buildJSONPath(["key\"with\"quotes"])
        XCTAssertTrue(path.contains("\\\""), "Should escape double quotes")
    }

    func testDeepPath() {
        XCTAssertEqual(OrbitFrameworksLogic.buildJSONPath(["a", "b", "c"]), "$.a.b.c")
    }
}

// MARK: - Source path normalisation tests

class FWSourcePathTests: XCTestCase {

    func testWebpackInternalPath() {
        let (file, line, col) = OrbitFrameworksLogic.normalizeSourcePath("webpack-internal:///(app-pages-browser)/./app/page.tsx:10:3")
        XCTAssertTrue(file.contains("page.tsx"), "Should extract the file path, got: \(file)")
        XCTAssertEqual(line, 10)
        XCTAssertEqual(col, 3)
    }

    func testViteFsPath() {
        let (file, line, col) = OrbitFrameworksLogic.normalizeSourcePath("/@fs/Users/me/project/src/App.tsx?t=1234:5:2")
        // After stripping /@fs, should have an absolute path
        XCTAssertTrue(file.contains("App.tsx"), "Should extract App.tsx, got: \(file)")
        XCTAssertEqual(line, 5)
    }

    func testFileURLPath() {
        let (file, _, _) = OrbitFrameworksLogic.normalizeSourcePath("file:///Users/me/project/src/Component.tsx")
        XCTAssertTrue(file.contains("Component.tsx"), "Should extract path from file URL, got: \(file)")
    }

    func testPlainRelativePath() {
        let (file, line, col) = OrbitFrameworksLogic.normalizeSourcePath("src/utils/helpers.ts:42:7")
        XCTAssertTrue(file.contains("helpers.ts"), "Should extract filename, got: \(file)")
        XCTAssertEqual(line, 42)
        XCTAssertEqual(col, 7)
    }

    func testPathWithQueryStripped() {
        let (file, _, _) = OrbitFrameworksLogic.normalizeSourcePath("http://localhost:5173/src/App.tsx?t=16900")
        XCTAssertTrue(file.contains("App.tsx"), "Query string should be stripped, got: \(file)")
    }
}

// MARK: - Dev server: wire decoding

private func decode(_ protocolID: FWWireProtocol, _ text: String) -> [FWDevWireEvent] {
    FWDevWire.decode(protocolID: protocolID, text: text)
}

private func issue(_ severity: FWDevIssue.Severity = .error, _ message: String, file: String? = nil, line: Int? = nil,
                   column: Int? = nil, origin: FWDevIssue.Origin = .build) -> FWDevIssue {
    FWDevIssue(severity: severity, origin: origin, message: message, file: file, line: line, column: column, source: "test")
}

class FWDevNextWireTests: XCTestCase {

    func testBuildingUsesActionKeyInNext15() {
        let events = decode(.next, #"{"action":"building"}"#)
        XCTAssertEqual(events.first?.kind, .building)
        XCTAssertEqual(events.first?.buildState, .building)
    }

    func testBuildingUsesTypeKeyInNext16() {
        let events = decode(.next, #"{"type":"building"}"#)
        XCTAssertEqual(events.first?.kind, .building)
    }

    func testBuiltWithoutErrorsIsAnUpdateAndMarksWebpack() {
        let events = decode(.next, #"{"action":"built","hash":"7c1e4f0a9b2d","errors":[],"warnings":[]}"#)
        let event = events.first
        XCTAssertEqual(event?.kind, .built)
        XCTAssertEqual(event?.isUpdate, true)
        XCTAssertEqual(event?.buildState, .ok)
        XCTAssertEqual(event?.bundler, .webpack)
        XCTAssertEqual(event?.detail, "hash 7c1e4f0a9b")
    }

    func testBuiltWithCompilationErrorsParsesLocationFromMessageHeader() {
        let json = #"{"action":"built","hash":"abc","errors":[{"moduleName":"./app/page.tsx","message":"./app/page.tsx:12:5\nModule not found: Can't resolve './missing'","details":"  10 | import x\n> 12 | import y"}],"warnings":[]}"#
        let event = decode(.next, json).first
        XCTAssertEqual(event?.buildState, .failed)
        XCTAssertEqual(event?.isUpdate, false)
        guard case .replaceAll(let issues)? = event?.issueUpdate else { return XCTFail("expected replaceAll") }
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].file, "./app/page.tsx")
        XCTAssertEqual(issues[0].line, 12)
        XCTAssertEqual(issues[0].column, 5)
        XCTAssertEqual(issues[0].frame, "  10 | import x\n> 12 | import y")
    }

    func testSyncCarriesVersionInfoAndIsNotAnUpdate() {
        let json = #"{"type":"sync","hash":"","errors":[],"warnings":[],"versionInfo":{"installed":"16.4.6","staleness":"fresh"},"devIndicator":{"disabledUntil":0}}"#
        let event = decode(.next, json).first
        XCTAssertEqual(event?.frameworkVersion, "16.4.6")
        XCTAssertEqual(event?.staleness, "fresh")
        XCTAssertEqual(event?.isUpdate, false)
        // An empty hash is how Turbopack syncs, so it must not claim webpack.
        XCTAssertNil(event?.bundler)
    }

    func testTurbopackConnectedAndMessage() {
        let connected = decode(.next, #"{"type":"turbopack-connected","data":{"sessionId":8432194,"hmrVersion":"0"}}"#).first
        XCTAssertEqual(connected?.bundler, .turbopack)
        XCTAssertEqual(connected?.session, "8432194")
        let update = #"{"type":"turbopack-message","data":{"type":"partial","instruction":{"type":"ChunkListUpdate","merged":[{"type":"EcmascriptMergedUpdate","entries":{"a":{"code":"x"},"b":{"code":"y"}}}]}}}"#
        let message = decode(.next, update).first
        XCTAssertEqual(message?.kind, .update)
        XCTAssertEqual(message?.detail, "2 modules")
        XCTAssertEqual(message?.bundler, .turbopack)
        XCTAssertEqual(message?.isUpdate, true)
    }

    func testServerComponentChangesAndReloadPage() {
        XCTAssertEqual(decode(.next, #"{"action":"serverComponentChanges","hash":"x"}"#).first?.isUpdate, true)
        let reload = decode(.next, #"{"action":"reloadPage","data":"client hmr"}"#).first
        XCTAssertEqual(reload?.kind, .reload)
        XCTAssertEqual(reload?.detail, "client hmr")
    }

    func testMiddlewareChangesUsesEventKey() {
        XCTAssertEqual(decode(.next, #"{"event":"middlewareChanges"}"#).first?.title, "Middleware changed")
    }

    func testIsrManifestFeedsStaticRoutesAndStaysOutOfTheTimeline() {
        let event = decode(.next, #"{"type":"isrManifest","data":{"/":true,"/dashboard":false}}"#).first
        XCTAssertEqual(event?.staticRoutes, ["/": true, "/dashboard": false])
        XCTAssertEqual(event?.inTimeline, false)
    }

    func testRuntimeErrorsMessage() {
        let json = #"{"type":"runtimeErrors","errors":[{"type":"runtime","errorName":"TypeError","message":"x is undefined","fatal":true,"stack":[{"file":"app/page.tsx","methodName":"Page","line":9,"column":3}]}]}"#
        guard case .append(let issues)? = decode(.next, json).first?.issueUpdate else { return XCTFail("expected append") }
        XCTAssertEqual(issues.first?.origin, .runtime)
        XCTAssertEqual(issues.first?.message, "TypeError: x is undefined")
        XCTAssertEqual(issues.first?.file, "app/page.tsx")
        XCTAssertEqual(issues.first?.line, 9)
    }

    func testServerErrorDecodesErrorJSON() {
        let json = #"{"action":"serverError","errorJSON":"{\"message\":\"Boom\",\"stack\":\"at f (file.js:1:1)\"}"}"#
        guard case .append(let issues)? = decode(.next, json).first?.issueUpdate else { return XCTFail("expected append") }
        XCTAssertEqual(issues.first?.message, "Boom")
        XCTAssertEqual(issues.first?.frame, "at f (file.js:1:1)")
    }

    func testUnknownActionAndNonJSONAreUnrecognised() {
        XCTAssertTrue(decode(.next, #"{"action":"somethingNew"}"#).isEmpty)
        XCTAssertTrue(decode(.next, "not json").isEmpty)
        XCTAssertTrue(decode(.next, "").isEmpty)
    }
}

class FWDevViteWireTests: XCTestCase {

    func testConnected() {
        XCTAssertEqual(decode(.vite, #"{"type":"connected"}"#).first?.kind, .connection)
    }

    func testJSUpdateClearsErrorsAndCounts() {
        let json = #"{"type":"update","updates":[{"type":"js-update","timestamp":1731700000000,"path":"/src/App.tsx","acceptedPath":"/src/App.tsx","explicitImportRequired":false,"isWithinCircularImport":false}]}"#
        let event = decode(.vite, json).first
        XCTAssertEqual(event?.title, "Updated 1 module")
        XCTAssertEqual(event?.detail, "App.tsx")
        XCTAssertEqual(event?.isUpdate, true)
        XCTAssertEqual(event?.buildState, .ok)
        XCTAssertEqual(event?.issueUpdate, .replaceAll([]))
    }

    func testCSSUpdateIsNamedAsStylesheet() {
        let json = #"{"type":"update","updates":[{"type":"css-update","timestamp":1,"path":"/src/a.css","acceptedPath":"/src/a.css"}]}"#
        XCTAssertEqual(decode(.vite, json).first?.title, "Updated 1 stylesheet")
    }

    func testMixedUpdateReportsCSSCount() {
        let json = #"{"type":"update","updates":[{"type":"js-update","path":"/a.ts"},{"type":"css-update","path":"/b.css"},{"type":"js-update","path":"/c.ts"}]}"#
        let event = decode(.vite, json).first
        XCTAssertEqual(event?.title, "Updated 3 modules (1 CSS)")
        XCTAssertEqual(event?.detail, "a.ts, b.css, ...")
    }

    func testFullReload() {
        let event = decode(.vite, #"{"type":"full-reload","triggeredBy":"/abs/root/vite.config.ts","path":"*"}"#).first
        XCTAssertEqual(event?.kind, .reload)
        XCTAssertEqual(event?.detail, "vite.config.ts")
        XCTAssertEqual(event?.isUpdate, true)
    }

    func testErrorUsesLocAndStripsQueryFromId() {
        let json = #"{"type":"error","err":{"message":"Failed to parse source for import analysis","stack":"","id":"/proj/src/App.tsx?t=17","frame":"  4 | const a =\n    |          ^","plugin":"vite:import-analysis","pluginCode":"x","loc":{"file":"/proj/src/App.tsx","line":4,"column":11}}}"#
        let event = decode(.vite, json).first
        XCTAssertEqual(event?.buildState, .failed)
        guard case .replaceAll(let issues)? = event?.issueUpdate else { return XCTFail("expected replaceAll") }
        XCTAssertEqual(issues.first?.file, "/proj/src/App.tsx")
        XCTAssertEqual(issues.first?.line, 4)
        XCTAssertEqual(issues.first?.column, 11)
        XCTAssertEqual(issues.first?.source, "Vite vite:import-analysis")
        XCTAssertEqual(issues.first?.frame, "  4 | const a =\n    |          ^")
    }

    func testErrorFallsBackToIdWithoutLoc() {
        let json = #"{"type":"error","err":{"message":"Bad","id":"/proj/x.css?direct"}}"#
        guard case .replaceAll(let issues)? = decode(.vite, json).first?.issueUpdate else { return XCTFail("expected replaceAll") }
        XCTAssertEqual(issues.first?.file, "/proj/x.css")
    }

    func testReactRouterHMRCustomEvent() {
        let event = decode(.vite, #"{"type":"custom","event":"react-router:hmr","data":{"route":null}}"#).first
        XCTAssertEqual(event?.title, "Route module updated")
        XCTAssertEqual(event?.kind, .update)
    }

    func testAngularComponentUpdateCustomEvent() {
        XCTAssertEqual(decode(.vite, #"{"type":"custom","event":"angular:component-update","data":{"id":"src%2Fapp.ts%40App","timestamp":1}}"#).first?.title, "Component updated")
    }

    func testNuxtDevErrorEventBecomesRuntimeIssue() {
        let json = #"{"type":"custom","event":"nuxt:dev:error","data":{"id":"x","url":"/","message":"Hydration failed","reloadOnClear":false}}"#
        guard case .append(let issues)? = decode(.vite, json).first?.issueUpdate else { return XCTFail("expected append") }
        XCTAssertEqual(issues.first?.origin, .runtime)
        XCTAssertEqual(issues.first?.source, "Nuxt")
    }

    func testViteHousekeepingEventsStayOutOfTheTimeline() {
        XCTAssertEqual(decode(.vite, #"{"type":"custom","event":"vite:forward-console","data":{}}"#).first?.inTimeline, false)
        XCTAssertEqual(decode(.vite, #"{"type":"ping"}"#).first?.inTimeline, false)
    }

    func testPrune() {
        XCTAssertEqual(decode(.vite, #"{"type":"prune","paths":["/a","/b"]}"#).first?.title, "Pruned 2 modules")
    }

    func testBundledDevUpdate() {
        let event = decode(.vite, #"{"type":"bundled-dev-update","changedIds":["a","b","c"],"url":"/x.js","seq":2}"#).first
        XCTAssertEqual(event?.detail, "3 modules")
        XCTAssertEqual(event?.isUpdate, true)
    }

    func testUnknownTypeIsUnrecognised() {
        XCTAssertTrue(decode(.vite, #"{"type":"mystery"}"#).isEmpty)
    }
}

class FWDevWebpackWireTests: XCTestCase {

    func testInvalidStartsABuildAndClearsIssues() {
        let event = decode(.webpackDevServer, #"{"type":"invalid"}"#).first
        XCTAssertEqual(event?.buildState, .building)
        XCTAssertEqual(event?.issueUpdate, .replaceAll([]))
    }

    func testOkIsAnUpdate() {
        let event = decode(.webpackDevServer, #"{"type":"ok"}"#).first
        XCTAssertEqual(event?.kind, .built)
        XCTAssertEqual(event?.isUpdate, true)
        XCTAssertEqual(event?.snapshotIfFirst, true)
    }

    func testErrorsParseStatsErrorFields() {
        let json = #"{"type":"errors","data":[{"moduleIdentifier":"/node_modules/babel-loader/lib/index.js??ruleSet[1]!/proj/src/App.js","moduleName":"./src/App.js","loc":"3:7-8","message":"Module not found: Error: Can't resolve './x' in '/proj/src'","moduleId":"./src/App.js"}]}"#
        let event = decode(.webpackDevServer, json).first
        XCTAssertEqual(event?.buildState, .failed)
        guard case .replace(.error, let issues)? = event?.issueUpdate else { return XCTFail("expected replace(.error)") }
        XCTAssertEqual(issues.first?.file, "/proj/src/App.js")
        XCTAssertEqual(issues.first?.line, 3)
        XCTAssertEqual(issues.first?.column, 7)
        XCTAssertEqual(event?.title, "Compiled with 1 error")
    }

    func testWarningsOnlyReplaceWarnings() {
        let json = #"{"type":"warnings","data":[{"moduleName":"./src/a.js","message":"Unused","loc":"1:1"}],"params":{"preventReloading":true}}"#
        let event = decode(.webpackDevServer, json).first
        XCTAssertEqual(event?.kind, .warning)
        guard case .replace(.warning, _)? = event?.issueUpdate else { return XCTFail("expected replace(.warning)") }
        XCTAssertNil(event?.buildState)
    }

    func testStringErrorsAreAccepted() {
        let json = #"{"type":"errors","data":["./src/index.js:4:2\nSyntax error"]}"#
        guard case .replace(.error, let issues)? = decode(.webpackDevServer, json).first?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.line, 4)
    }

    func testStaticChangedReloads() {
        let event = decode(.webpackDevServer, #"{"type":"static-changed","data":"/proj/public/index.html"}"#).first
        XCTAssertEqual(event?.kind, .reload)
        XCTAssertEqual(event?.detail, "index.html")
    }

    func testNoiseTypesAreRecognisedButSilent() {
        for type in ["hash", "hot", "liveReload", "progress", "overlay", "progress-update", "still-ok"] {
            let event = decode(.webpackDevServer, #"{"type":"\#(type)","data":"x"}"#).first
            XCTAssertEqual(event?.inTimeline, false, type)
        }
    }

    func testSockJSFramingUnwrapsMessages() {
        let events = decode(.webpackDevServer, #"a["{\"type\":\"invalid\"}","{\"type\":\"ok\"}"]"#)
        XCTAssertEqual(events.map(\.kind), [.building, .built])
        XCTAssertTrue(decode(.webpackDevServer, "o").isEmpty)
        XCTAssertTrue(decode(.webpackDevServer, "h").isEmpty)
    }

    func testHotMiddlewareBuiltAndHeartbeat() {
        let built = decode(.webpackHotMiddleware, #"{"name":"","action":"built","time":412,"hash":"abcdef1234567","warnings":[],"errors":[],"modules":{}}"#).first
        XCTAssertEqual(built?.title, "Built in 412 ms")
        XCTAssertEqual(built?.isUpdate, true)
        XCTAssertTrue(decode(.webpackHotMiddleware, "\u{1F493}").isEmpty)
    }

    func testHotMiddlewareErrorsAreHeaderStrings() {
        let json = #"{"action":"built","errors":["./src/pages/index.js 12:5\nModule build failed: SyntaxError"],"warnings":[],"hash":"h"}"#
        let event = decode(.webpackHotMiddleware, json).first
        XCTAssertEqual(event?.buildState, .failed)
        guard case .replaceAll(let issues)? = event?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.file, "./src/pages/index.js")
        XCTAssertEqual(issues.first?.line, 12)
        XCTAssertEqual(issues.first?.column, 5)
    }

    func testHotMiddlewareSyncIsNotAnUpdate() {
        XCTAssertEqual(decode(.webpackHotMiddleware, #"{"action":"sync","hash":"h","warnings":[],"errors":[],"modules":{}}"#).first?.isUpdate, false)
    }
}

class FWDevOtherWireTests: XCTestCase {

    func testParcelUpdateReloadAndError() {
        XCTAssertEqual(decode(.parcel, #"{"type":"update","assets":[{"id":"a","type":"js"},{"id":"b","type":"css"}]}"#).first?.title, "Updated 2 assets")
        XCTAssertEqual(decode(.parcel, #"{"type":"reload"}"#).first?.kind, .reload)
        let error = #"{"type":"error","diagnostics":{"ansi":[],"html":[{"message":"Cannot resolve dependency","stack":"","frames":[{"location":"/proj/src/index.js:3:8","code":"3 | import x"}],"hints":[]}]}}"#
        let event = decode(.parcel, error).first
        XCTAssertEqual(event?.buildState, .failed)
        guard case .replaceAll(let issues)? = event?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.file, "/proj/src/index.js")
        XCTAssertEqual(issues.first?.line, 3)
        XCTAssertEqual(issues.first?.column, 8)
    }

    func testRsbuildMessages() {
        XCTAssertEqual(decode(.rsbuild, #"{"type":"ok"}"#).first?.isUpdate, true)
        let errors = #"{"type":"errors","data":{"text":["File: ./src/index.tsx:3:1\nModule not found"],"html":"<div/>"}}"#
        guard case .replace(.error, let issues)? = decode(.rsbuild, errors).first?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.file, "./src/index.tsx")
        XCTAssertEqual(decode(.rsbuild, #"{"type":"full-reload","data":{"path":"/index.html"}}"#).first?.detail, "/index.html")
        XCTAssertEqual(decode(.rsbuild, #"{"type":"resolved-client-error","data":{"id":"x"}}"#).first?.clearsRuntimeIssues, true)
        XCTAssertEqual(decode(.rsbuild, #"{"type":"hash","data":"abc"}"#).first?.inTimeline, false)
    }

    func testRemixLiveReload() {
        XCTAssertEqual(decode(.remixLiveReload, #"{"type":"RELOAD"}"#).first?.kind, .reload)
        XCTAssertEqual(decode(.remixLiveReload, #"{"type":"LOG","message":"Rebuilt in 80ms"}"#).first?.detail, "Rebuilt in 80ms")
        XCTAssertEqual(decode(.remixLiveReload, #"{"type":"HMR","updates":[{"id":"a"}]}"#).first?.detail, "1 route")
        XCTAssertEqual(decode(.remixLiveReload, #"{"type":"PING"}"#).first?.inTimeline, false)
    }

    func testLiveReloadProtocol() {
        let css = decode(.liveReload, #"{"command":"reload","path":"/css/site.css","originalPath":"","liveCSS":true,"liveImg":true}"#).first
        XCTAssertEqual(css?.title, "Stylesheet reloaded")
        let page = decode(.liveReload, #"{"command":"reload","path":"/index.html","liveCSS":true}"#).first
        XCTAssertEqual(page?.title, "Page reload requested")
        XCTAssertEqual(decode(.liveReload, #"{"command":"hello","protocols":["http://livereload.com/protocols/official-7"],"serverName":"Hugo"}"#).first?.inTimeline, false)
    }

    func testStorybookChannelEvents() {
        XCTAssertEqual(decode(.storybookChannel, #"{"type":"storyRendered","from":"preview","args":["button--primary"]}"#).first?.detail, "button--primary")
        let thrown = #"{"type":"storyThrewException","args":[{"name":"Error","message":"render failed","stack":"at x"}]}"#
        guard case .append(let issues)? = decode(.storybookChannel, thrown).first?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.message, "render failed")
        XCTAssertEqual(issues.first?.origin, .runtime)
        XCTAssertEqual(decode(.storybookChannel, #"{"type":"storyHotUpdated","args":[]}"#).first?.isUpdate, true)
    }

    func testPageEvents() {
        let error = FWDevWire.decodePageEvent(name: "runtimeError", detail: nil, message: "Uncaught TypeError: x is not a function",
                                              file: "http://localhost:3000/_next/static/chunks/app/page.js", line: 12, column: 4, stack: "at f")
        guard case .append(let issues)? = error?.issueUpdate else { return XCTFail() }
        XCTAssertEqual(issues.first?.file, "http://localhost:3000/_next/static/chunks/app/page.js")
        XCTAssertEqual(issues.first?.line, 12)
        XCTAssertEqual(issues.first?.origin, .runtime)
        let nav = FWDevWire.decodePageEvent(name: "next.routeChangeComplete", detail: "/about", message: nil, file: nil, line: nil, column: nil, stack: nil)
        XCTAssertEqual(nav?.kind, .navigation)
        XCTAssertEqual(nav?.detail, "/about")
        XCTAssertNil(FWDevWire.decodePageEvent(name: "nope", detail: nil, message: nil, file: nil, line: nil, column: nil, stack: nil))
        let refresh = FWDevWire.decodePageEvent(name: "nuxt.app:data:refresh", detail: nil, message: nil, file: nil, line: nil, column: nil, stack: nil)
        XCTAssertEqual(refresh?.isUpdate, true)
    }
}

// MARK: - Dev server: socket identification

class FWDevIdentifyTests: XCTestCase {

    private func identify(_ url: String, _ sub: [String] = [], hints: Set<FWWireProtocol> = []) -> (protocolID: FWWireProtocol, strong: Bool)? {
        FWDevWire.identify(url: url, subprotocols: sub, pageHost: "localhost", hints: hints)
    }

    func testViteBySubprotocol() {
        let result = identify("ws://localhost:5173/?token=abc123", ["vite-hmr"])
        XCTAssertEqual(result?.protocolID, .vite)
        XCTAssertEqual(result?.strong, true)
    }

    func testViteConnectivityProbeIsIgnored() {
        XCTAssertNil(identify("ws://localhost:5173/", ["vite-ping"]))
    }

    func testNextOldAndNewPaths() {
        XCTAssertEqual(identify("ws://localhost:3000/_next/webpack-hmr")?.protocolID, .next)
        XCTAssertEqual(identify("ws://localhost:3000/_next/hmr?id=abc")?.protocolID, .next)
        XCTAssertEqual(identify("ws://localhost:3000/base/_next/hmr")?.protocolID, .next)
    }

    func testWebpackDevServerPaths() {
        XCTAssertEqual(identify("ws://localhost:8080/ws")?.protocolID, .webpackDevServer)
        XCTAssertEqual(identify("ws://localhost:8080/ws")?.strong, false)
        XCTAssertEqual(identify("ws://localhost:4200/ng-cli-ws")?.strong, true)
        XCTAssertEqual(identify("ws://localhost:3000/sockjs-node/123/abcdefgh/websocket")?.protocolID, .webpackDevServer)
    }

    func testOtherServers() {
        XCTAssertEqual(identify("ws://localhost:3000/rsbuild-hmr?token=x")?.protocolID, .rsbuild)
        XCTAssertEqual(identify("http://localhost:8000/__webpack_hmr")?.protocolID, .webpackHotMiddleware)
        XCTAssertEqual(identify("ws://localhost:1313/livereload")?.protocolID, .liveReload)
        XCTAssertEqual(identify("ws://localhost:4200/_lr/livereload")?.protocolID, .liveReload)
        XCTAssertEqual(identify("ws://localhost:8002/socket")?.protocolID, .remixLiveReload)
        XCTAssertEqual(identify("ws://localhost:6006/storybook-server-channel?token=t&page=preview")?.protocolID, .storybookChannel)
    }

    func testParcelRootSocketNeedsTheHint() {
        XCTAssertNil(identify("ws://localhost:1234/"))
        XCTAssertEqual(identify("ws://localhost:1234/", hints: [.parcel])?.protocolID, .parcel)
        XCTAssertEqual(identify("ws://localhost:1234/", hints: [.parcel])?.strong, false)
    }

    func testAppSocketsAreNotDevSockets() {
        XCTAssertNil(identify("wss://chat.example.com/socket.io/?EIO=4"))
        XCTAssertNil(identify("ws://localhost:3000/api/stream"))
    }
}

// MARK: - Dev server: state reducer

private func openedState(_ protocolID: FWWireProtocol, url: String, subprotocols: [String] = []) -> FWDevState {
    var state = FWDevState()
    state.socketOpened(id: 1, url: url, subprotocols: subprotocols, transport: "WebSocket", pageHost: "localhost", hints: [], at: 1000)
    state.socketState(id: 1, state: .open, code: nil, at: 1001)
    return state
}

class FWDevStateTests: XCTestCase {

    func testViteErrorThenUpdateClearsTheError() {
        var state = openedState(.vite, url: "ws://localhost:5173/?token=t", subprotocols: ["vite-hmr"])
        state.receiveFrame(socketID: 1, text: #"{"type":"error","err":{"message":"Oops","loc":{"file":"/p/a.ts","line":2,"column":1}}}"#, binaryLength: nil, at: 2000)
        XCTAssertEqual(state.buildState, .failed)
        XCTAssertEqual(state.buildIssues.count, 1)
        XCTAssertEqual(state.errorCount, 1)
        state.receiveFrame(socketID: 1, text: #"{"type":"update","updates":[{"type":"js-update","path":"/a.ts"}]}"#, binaryLength: nil, at: 3000)
        XCTAssertEqual(state.buildState, .ok)
        XCTAssertTrue(state.buildIssues.isEmpty)
        XCTAssertEqual(state.lastUpdateAt, 3000)
        XCTAssertEqual(state.updateCount, 1)
    }

    func testWebpackFirstOkIsInitialSnapshotNotAnUpdate() {
        var state = openedState(.webpackDevServer, url: "ws://localhost:8080/ng-cli-ws")
        state.receiveFrame(socketID: 1, text: #"{"type":"hash","data":"h1"}"#, binaryLength: nil, at: 1100)
        state.receiveFrame(socketID: 1, text: #"{"type":"ok"}"#, binaryLength: nil, at: 1200)
        XCTAssertNil(state.lastUpdateAt)
        XCTAssertEqual(state.updateCount, 0)
        XCTAssertEqual(state.events.last?.title, "Compiled (initial)")
        state.receiveFrame(socketID: 1, text: #"{"type":"invalid"}"#, binaryLength: nil, at: 1300)
        XCTAssertEqual(state.buildState, .building)
        state.receiveFrame(socketID: 1, text: #"{"type":"ok"}"#, binaryLength: nil, at: 1400)
        XCTAssertEqual(state.lastUpdateAt, 1400)
        XCTAssertEqual(state.updateCount, 1)
    }

    func testWebpackErrorsAndWarningsAreKeptSeparately() {
        var state = openedState(.webpackDevServer, url: "ws://localhost:8080/ng-cli-ws")
        state.receiveFrame(socketID: 1, text: #"{"type":"warnings","data":["./a.js 1:1\nwarn"]}"#, binaryLength: nil, at: 2000)
        state.receiveFrame(socketID: 1, text: #"{"type":"errors","data":["./b.js 2:2\nerr"]}"#, binaryLength: nil, at: 2001)
        XCTAssertEqual(state.buildIssues.count, 2)
        XCTAssertEqual(state.buildIssues.filter { $0.severity == .error }.count, 1)
        state.receiveFrame(socketID: 1, text: #"{"type":"invalid"}"#, binaryLength: nil, at: 2002)
        XCTAssertTrue(state.buildIssues.isEmpty)
    }

    func testWeakSocketIsConfirmedByADecodableMessage() {
        var state = openedState(.webpackDevServer, url: "ws://localhost:3000/ws")
        XCTAssertTrue(state.confirmedSockets.isEmpty)
        XCTAssertEqual(state.connection, .noSocket)
        state.receiveFrame(socketID: 1, text: #"{"op":"chat","text":"hi"}"#, binaryLength: nil, at: 1500)
        XCTAssertTrue(state.confirmedSockets.isEmpty)
        state.receiveFrame(socketID: 1, text: #"{"type":"hot"}"#, binaryLength: nil, at: 1600)
        XCTAssertEqual(state.connection, .connected)
    }

    func testConnectionStates() {
        var state = FWDevState()
        XCTAssertEqual(state.connection, .noSocket)
        state.socketOpened(id: 1, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"], transport: "WebSocket", pageHost: "localhost", hints: [], at: 1)
        XCTAssertEqual(state.connection, .connecting)
        state.socketState(id: 1, state: .open, code: nil, at: 2)
        XCTAssertEqual(state.connection, .connected)
        state.socketState(id: 1, state: .closed, code: 1006, at: 3)
        XCTAssertEqual(state.connection, .disconnected(code: 1006))
        XCTAssertEqual(state.events.map(\.title), ["Connected", "Disconnected"])
        XCTAssertEqual(state.events.last?.detail, "code 1006")
    }

    func testBinaryFramesAreCountedButNotDecoded() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/hmr")
        state.receiveFrame(socketID: 1, text: "", binaryLength: 120, at: 1500)
        XCTAssertEqual(state.sockets[0].frames, 1)
        XCTAssertEqual(state.sockets[0].recognisedFrames, 0)
    }

    func testNextTurbopackSessionChangeIsReportedAsRestart() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/hmr")
        state.receiveFrame(socketID: 1, text: #"{"type":"turbopack-connected","data":{"sessionId":1}}"#, binaryLength: nil, at: 1500)
        state.receiveFrame(socketID: 1, text: #"{"type":"turbopack-connected","data":{"sessionId":2}}"#, binaryLength: nil, at: 1600)
        XCTAssertEqual(state.bundlerHint, .turbopack)
        XCTAssertTrue(state.events.contains { $0.title == "Dev server restarted" })
    }

    func testRuntimeIssuesDeduplicateAndClear() {
        var state = FWDevState()
        let event = FWDevWire.decodePageEvent(name: "runtimeError", detail: nil, message: "boom", file: "http://x/a.js", line: 1, column: 1, stack: nil)!
        state.apply(event, at: 1)
        state.apply(event, at: 2)
        XCTAssertEqual(state.runtimeIssues.count, 1)
        state.clearRuntimeIssues()
        XCTAssertTrue(state.runtimeIssues.isEmpty)
    }

    func testTimelineIsCapped() {
        var state = FWDevState()
        for index in 0..<(FWDevState.maxEvents + 30) { state.addEvent(kind: .info, title: "e\(index)", at: Double(index)) }
        XCTAssertEqual(state.events.count, FWDevState.maxEvents)
        XCTAssertEqual(state.events.last?.title, "e\(FWDevState.maxEvents + 29)")
        let ids = state.events.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testResetKeepsHistoryOnlyWhenAsked() {
        var state = openedState(.vite, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"])
        state.receiveFrame(socketID: 1, text: #"{"type":"full-reload"}"#, binaryLength: nil, at: 5000)
        var kept = state
        kept.resetForNewDocument(keepHistory: true)
        XCTAssertTrue(kept.sockets.isEmpty)
        XCTAssertEqual(kept.connection, .noSocket)
        XCTAssertEqual(kept.lastUpdateAt, 5000)
        XCTAssertFalse(kept.events.isEmpty)
        kept.addEvent(kind: .info, title: "next", at: 6000)
        XCTAssertEqual(Set(kept.events.map(\.id)).count, kept.events.count)
        var cleared = state
        cleared.resetForNewDocument(keepHistory: false)
        XCTAssertTrue(cleared.events.isEmpty)
        XCTAssertNil(cleared.lastUpdateAt)
    }

    func testPrimarySocketPrefersAnOpenOne() {
        var state = FWDevState()
        state.socketOpened(id: 1, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"], transport: "WebSocket", pageHost: "localhost", hints: [], at: 1)
        state.socketOpened(id: 2, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"], transport: "WebSocket", pageHost: "localhost", hints: [], at: 2)
        state.socketState(id: 1, state: .open, code: nil, at: 3)
        state.socketState(id: 2, state: .closed, code: 1000, at: 4)
        XCTAssertEqual(state.primarySocket?.id, 1)
    }

    func testSocketTableIsBounded() {
        var state = FWDevState()
        for id in 1...60 {
            state.socketOpened(id: id, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"], transport: "WebSocket", pageHost: "localhost", hints: [], at: 1)
        }
        XCTAssertLessThanOrEqual(state.sockets.count, 24)
    }
}

// MARK: - Dev server: resolution

private func detected(_ name: String, version: String? = nil, category: FWCategory = .metaFramework, confidence: FWConfidence = .certain) -> FWDetected {
    FWDetected(name: name, version: version, category: category, confidence: confidence, evidence: ["test evidence"])
}

class FWDevResolutionTests: XCTestCase {

    func testNextWithWebpackSync() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/webpack-hmr")
        state.receiveFrame(socketID: 1, text: #"{"action":"sync","hash":"abc123","errors":[],"warnings":[]}"#, binaryLength: nil, at: 1500)
        let probe = FWDevProbe(signals: [FWSignal.nextDevGlobal.rawValue, FWSignal.nextApp.rawValue])
        let r = FWDevLogic.resolve(detections: [detected("Next.js", version: "15.1.0"), detected("React", category: .framework), detected("webpack", category: .buildTool)],
                                   probe: probe, state: state)
        XCTAssertEqual(r.adapter?.id, "next")
        XCTAssertEqual(r.bundler, .webpack)
        XCTAssertEqual(r.mode, .development)
        XCTAssertEqual(r.version, "15.1.0")
        XCTAssertTrue(r.conflicts.isEmpty)
    }

    func testNextInstalledVersionFromSyncWinsOverDetection() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/hmr")
        state.receiveFrame(socketID: 1, text: #"{"type":"sync","hash":"","errors":[],"warnings":[],"versionInfo":{"installed":"16.4.6","staleness":"fresh"}}"#, binaryLength: nil, at: 1500)
        let r = FWDevLogic.resolve(detections: [detected("Next.js", version: "16.0.0")], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.version, "16.4.6")
    }

    func testNextTurbopackFromSocketMessages() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/hmr")
        state.receiveFrame(socketID: 1, text: #"{"type":"turbopack-connected","data":{"sessionId":7}}"#, binaryLength: nil, at: 1500)
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.bundler, .turbopack)
    }

    func testNextTurbopackFromPageFlagWithoutSocket() {
        let probe = FWDevProbe(signals: [FWSignal.nextTurbopack.rawValue, FWSignal.nextDevGlobal.rawValue])
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: probe, state: FWDevState())
        XCTAssertEqual(r.bundler, .turbopack)
        XCTAssertEqual(r.mode, .development)
        XCTAssertNil(r.protocolID)
    }

    func testNextProductionBuild() {
        let r = FWDevLogic.resolve(detections: [detected("Next.js", version: "15.1.0"), detected("Vercel", category: .hosting)],
                                   probe: FWDevProbe(), state: FWDevState())
        XCTAssertEqual(r.mode, .production)
        XCTAssertEqual(r.adapter?.id, "next")
        XCTAssertNotNil(FWDevLogic.modeExplanation(r))
        XCTAssertTrue(FWDevLogic.modeExplanation(r)?.contains("production build") == true)
    }

    func testNothingDetected() {
        let r = FWDevLogic.resolve(detections: [], probe: FWDevProbe(), state: FWDevState())
        XCTAssertEqual(r.mode, .notDetected)
        XCTAssertNil(r.adapter)
        XCTAssertTrue(FWDevLogic.modeExplanation(r)?.contains("No dev server detected") == true)
    }

    func testNuxtOverViteSocketKeepsViteAsBundler() {
        let state = openedState(.vite, url: "ws://localhost:3000/_nuxt/?token=t", subprotocols: ["vite-hmr"])
        let r = FWDevLogic.resolve(detections: [detected("Nuxt", version: "4.6.4"), detected("Vue", category: .framework), detected("Vite", category: .buildTool)],
                                   probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.adapter?.id, "nuxt")
        XCTAssertEqual(r.bundler, .vite)
        XCTAssertEqual(r.protocolID, .vite)
        XCTAssertTrue(r.conflicts.isEmpty)
    }

    func testStorybookBeatsTheFrameworkItRenders() {
        let state = openedState(.vite, url: "ws://localhost:6006/", subprotocols: ["vite-hmr"])
        let r = FWDevLogic.resolve(detections: [detected("Storybook", category: .buildTool), detected("React", category: .framework), detected("Vite", category: .buildTool)],
                                   probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.adapter?.id, "storybook")
    }

    func testMetaFrameworkBeatsBundlerOnlyDetection() {
        let r = FWDevLogic.resolve(detections: [detected("Vite", category: .buildTool), detected("Astro")],
                                   probe: FWDevProbe(signals: [FWSignal.viteClient.rawValue]), state: FWDevState())
        XCTAssertEqual(r.adapter?.id, "astro")
        XCTAssertEqual(r.mode, .development)
    }

    func testTwoMetaFrameworksReportAConflict() {
        let r = FWDevLogic.resolve(detections: [detected("Next.js"), detected("Nuxt")], probe: FWDevProbe(), state: FWDevState())
        XCTAssertEqual(r.adapter?.id, "next")
        XCTAssertEqual(r.conflicts.count, 1)
        XCTAssertTrue(r.conflicts[0].contains("Nuxt"))
    }

    func testReactRouterBeatsRemix() {
        let r = FWDevLogic.resolve(detections: [detected("Remix"), detected("React Router")], probe: FWDevProbe(), state: FWDevState())
        XCTAssertEqual(r.adapter?.id, "reactRouter")
    }

    func testSocketContradictingTheFrameworkIsFlagged() {
        let state = openedState(.vite, url: "ws://localhost:3000/", subprotocols: ["vite-hmr"])
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.adapter?.id, "next")
        XCTAssertEqual(r.bundler, .vite)
        XCTAssertEqual(r.conflicts.count, 1)
        XCTAssertTrue(r.conflicts[0].contains("Vite HMR"))
    }

    func testViteClientOnANonViteFrameworkIsFlagged() {
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: FWDevProbe(signals: [FWSignal.viteClient.rawValue]), state: FWDevState())
        XCTAssertTrue(r.conflicts.contains { $0.contains("/@vite/client") })
    }

    func testAngularWebpackBuilderUsesTheWebpackSocket() {
        let state = openedState(.webpackDevServer, url: "ws://localhost:4200/ng-cli-ws")
        let r = FWDevLogic.resolve(detections: [detected("Angular", category: .framework)], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.adapter?.id, "angular")
        XCTAssertEqual(r.bundler, .webpack)
        XCTAssertTrue(r.conflicts.isEmpty)
        let header = FWDevLogic.header(resolution: r, state: state, probe: FWDevProbe())
        XCTAssertEqual(header.bundlerLabel, "webpack")
    }

    func testAngularViteBuilderLabelsEsbuild() {
        let state = openedState(.vite, url: "ws://localhost:4200/", subprotocols: ["vite-hmr"])
        let r = FWDevLogic.resolve(detections: [detected("Angular", category: .framework)], probe: FWDevProbe(), state: state)
        XCTAssertEqual(FWDevLogic.header(resolution: r, state: state, probe: FWDevProbe()).bundlerLabel, "Vite (esbuild)")
    }

    func testProtocolFallbackAdapterWhenNothingIsDetected() {
        let state = openedState(.rsbuild, url: "ws://localhost:3000/rsbuild-hmr?token=x")
        let r = FWDevLogic.resolve(detections: [], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.adapter?.id, "rsbuild")
        XCTAssertEqual(r.bundler, .rspack)
        XCTAssertEqual(r.mode, .development)
    }

    func testWeakSocketWithoutFramesDoesNotMakeAProductionPageDevelopment() {
        let state = openedState(.webpackDevServer, url: "ws://localhost:3000/ws")
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.mode, .production)
    }

    func testDisconnectedSocketStillMeansDevelopment() {
        var state = openedState(.vite, url: "ws://localhost:5173/", subprotocols: ["vite-hmr"])
        state.socketState(id: 1, state: .closed, code: 1006, at: 2000)
        let r = FWDevLogic.resolve(detections: [detected("Vite", category: .buildTool)], probe: FWDevProbe(), state: state)
        XCTAssertEqual(r.mode, .development)
        let header = FWDevLogic.header(resolution: r, state: state, probe: FWDevProbe())
        XCTAssertEqual(header.connectionLabel, "Disconnected (1006)")
        XCTAssertEqual(header.connectionTone, 3)
    }

    func testPossibleConfidenceDetectionsAreIgnored() {
        let r = FWDevLogic.resolve(detections: [detected("Remix", confidence: .possible)], probe: FWDevProbe(), state: FWDevState())
        XCTAssertNil(r.adapter)
    }

    func testHeaderForNextAppRouterBuildFailure() {
        var state = openedState(.next, url: "ws://localhost:3000/_next/hmr")
        state.receiveFrame(socketID: 1, text: #"{"type":"built","hash":"h","errors":[{"message":"./a.tsx:1:1\nbad"}],"warnings":[]}"#, binaryLength: nil, at: 1500)
        let probe = FWDevProbe(signals: [FWSignal.nextApp.rawValue, FWSignal.nextDevGlobal.rawValue])
        let r = FWDevLogic.resolve(detections: [detected("Next.js", version: "16.4.6")], probe: probe, state: state)
        let header = FWDevLogic.header(resolution: r, state: state, probe: probe)
        XCTAssertEqual(header.title, "Next.js")
        XCTAssertEqual(header.subtitle, "v16.4.6 · App Router")
        XCTAssertEqual(header.modeLabel, "Development")
        XCTAssertEqual(header.buildLabel, "Failed, 1 error")
        XCTAssertEqual(header.buildTone, 3)
    }
}

// MARK: - Dev server: controls and endpoints

class FWDevControlTests: XCTestCase {

    private func resolution(_ name: String, version: String? = nil, signals: [FWSignal] = [], socket: (FWWireProtocol, String, [String])? = nil,
                            category: FWCategory = .metaFramework) -> (FWDevResolution, FWDevProbe) {
        var state = FWDevState()
        if let socket {
            state.socketOpened(id: 1, url: socket.1, subprotocols: socket.2, transport: "WebSocket", pageHost: "localhost", hints: [], at: 1)
            state.socketState(id: 1, state: .open, code: nil, at: 2)
        }
        let probe = FWDevProbe(signals: Set(signals.map(\.rawValue)))
        return (FWDevLogic.resolve(detections: [detected(name, version: version, category: category)], probe: probe, state: state), probe)
    }

    private func control(_ list: [FWDevLogic.ControlState], _ control: FWDevControl) -> FWDevLogic.ControlState? {
        list.first { $0.control == control }
    }

    func testReloadAlwaysAvailable() {
        let (r, p) = resolution("Next.js")
        let list = FWDevLogic.controls(resolution: r, probe: p)
        XCTAssertEqual(control(list, .reload)?.enabled, true)
        XCTAssertEqual(control(list, .hardReload)?.enabled, true)
    }

    func testClearCachesDisabledWithoutAnyCaches() {
        let (r, p) = resolution("Next.js")
        let disabled = control(FWDevLogic.controls(resolution: r, probe: p), .clearCaches)
        XCTAssertEqual(disabled?.enabled, false)
        XCTAssertTrue(disabled?.note.contains("No service workers") == true)
        var withCache = p
        withCache.serviceWorkers = 1
        withCache.cacheEntries = 2
        let enabled = control(FWDevLogic.controls(resolution: r, probe: withCache), .clearCaches)
        XCTAssertEqual(enabled?.enabled, true)
        XCTAssertEqual(enabled?.note, "Remove 1 service worker and 2 caches.")
    }

    func testNextRestartVersionGate() {
        let probe: [FWSignal] = [.nextDevGlobal]
        let (old, p1) = resolution("Next.js", version: "15.3.2", signals: probe)
        let oldState = control(FWDevLogic.controls(resolution: old, probe: p1), .restartServer)
        XCTAssertEqual(oldState?.enabled, false)
        XCTAssertTrue(oldState?.note.contains("15.4.0") == true)
        let (current, p2) = resolution("Next.js", version: "15.4.0", signals: probe)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: current, probe: p2), .restartServer)?.enabled, true)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: current, probe: p2), .restartClearCache)?.enabled, true)
        let (canary, p3) = resolution("Next.js", version: "16.5.0-canary.52", signals: probe)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: canary, probe: p3), .restartServer)?.enabled, true)
        let (unknown, p4) = resolution("Next.js", signals: probe)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: unknown, probe: p4), .restartServer)?.enabled, true)
    }

    func testNextRestartDisabledInProduction() {
        let (r, p) = resolution("Next.js", version: "16.4.6")
        let state = control(FWDevLogic.controls(resolution: r, probe: p), .restartServer)
        XCTAssertEqual(state?.enabled, false)
        XCTAssertEqual(state?.note, "Only a development server can be restarted.")
    }

    func testViteRestartIsExplainedAsUnavailable() {
        let (r, p) = resolution("Vite", signals: [.viteClient], category: .buildTool)
        let state = control(FWDevLogic.controls(resolution: r, probe: p), .restartServer)
        XCTAssertEqual(state?.enabled, false)
        XCTAssertTrue(state?.note.contains("no HTTP route") == true)
    }

    func testEveryAdapterWithoutAnEndpointExplainsItsRestartRow() {
        for adapter in FWDevAdapters.all {
            if case .unavailable(let reason) = adapter.restart { XCTAssertFalse(reason.isEmpty, adapter.id) }
        }
    }

    func testSoftRefreshPerFramework() {
        let (next, np) = resolution("Next.js", signals: [.nextApp, .nextRouterRefresh])
        XCTAssertEqual(FWDevLogic.refreshStrategy(adapterID: next.adapter?.id, probe: np), .nextAppRefresh)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: next, probe: np), .softRefresh)?.enabled, true)
        let (pages, pp) = resolution("Next.js", signals: [.nextPages, .nextRouterReplace])
        XCTAssertEqual(FWDevLogic.refreshStrategy(adapterID: pages.adapter?.id, probe: pp), .nextPagesReplace)
        let (rr, rp) = resolution("React Router", signals: [.routerDataRouter])
        XCTAssertEqual(FWDevLogic.refreshStrategy(adapterID: rr.adapter?.id, probe: rp), .routerRevalidate)
        let (nuxt, xp) = resolution("Nuxt", signals: [.nuxtApp])
        XCTAssertEqual(FWDevLogic.refreshStrategy(adapterID: nuxt.adapter?.id, probe: xp), .nuxtRefreshData)
    }

    func testSoftRefreshUnavailableStatesWhy() {
        let (kit, p) = resolution("SvelteKit", signals: [.sveltekitDev])
        let state = control(FWDevLogic.controls(resolution: kit, probe: p), .softRefresh)
        XCTAssertEqual(state?.enabled, false)
        XCTAssertTrue(state?.note.contains("invalidateAll") == true)
        let (next, np) = resolution("Next.js")
        XCTAssertEqual(control(FWDevLogic.controls(resolution: next, probe: np), .softRefresh)?.enabled, false)
    }

    func testHmrRefreshNeedsTheAppRouterMethod() {
        let (r, p) = resolution("Next.js", signals: [.nextApp, .nextRouterHmrRefresh])
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r, probe: p), .hmrRefresh)?.enabled, true)
        let (r2, p2) = resolution("Next.js", signals: [.nextPages])
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r2, probe: p2), .hmrRefresh)?.enabled, false)
    }

    func testRebuildOnlyWithAWebpackDevServerSocket() {
        let (wds, p) = resolution("webpack", socket: (.webpackDevServer, "ws://localhost:8080/ng-cli-ws", []), category: .buildTool)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: wds, probe: p), .rebuild)?.enabled, true)
        let (none, p2) = resolution("webpack", category: .buildTool)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: none, probe: p2), .rebuild)?.enabled, false)
        let (vite, p3) = resolution("Vite", signals: [.viteClient], category: .buildTool)
        XCTAssertNil(control(FWDevLogic.controls(resolution: vite, probe: p3), .rebuild))
    }

    func testOverlayToggleNeedsAnOverlay() {
        let (r, p) = resolution("Vite", signals: [.viteClient], category: .buildTool)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r, probe: p), .toggleOverlay)?.enabled, false)
        var shown = p
        shown.overlayHosts = ["vite-error-overlay"]
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r, probe: shown), .toggleOverlay)?.enabled, true)
        shown.overlayHidden = true
        XCTAssertTrue(control(FWDevLogic.controls(resolution: r, probe: shown), .toggleOverlay)?.note.contains("Show") == true)
    }

    func testDraftModeNeedsTheCookie() {
        let (r, p) = resolution("Next.js", signals: [.nextDevGlobal])
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r, probe: p), .exitDraftMode)?.enabled, false)
        var withCookie = p
        withCookie.signals.insert(FWSignal.draftModeCookie.rawValue)
        XCTAssertEqual(control(FWDevLogic.controls(resolution: r, probe: withCookie), .exitDraftMode)?.enabled, true)
    }

    func testGatsbyRefreshControl() {
        let (r, p) = resolution("Gatsby", signals: [.whmReporter])
        let state = control(FWDevLogic.controls(resolution: r, probe: p), .refreshSourceData)
        XCTAssertEqual(state?.enabled, true)
        XCTAssertTrue(state?.note.contains("ENABLE_GATSBY_REFRESH_ENDPOINT") == true)
    }

    func testControlRowsAreUnique() {
        let (r, p) = resolution("Next.js", signals: [.nextDevGlobal])
        let ids = FWDevLogic.controls(resolution: r, probe: p).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNavigationStrategies() {
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "next", probe: FWDevProbe(signals: [FWSignal.nextRouterPush.rawValue])), .nextRouter)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "next", probe: FWDevProbe()), .linkClick)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "reactRouter", probe: FWDevProbe(signals: [FWSignal.routerDataRouter.rawValue])), .routerNavigate)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "remix", probe: FWDevProbe(signals: [FWSignal.routerDataRouter.rawValue])), .routerNavigate)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "nuxt", probe: FWDevProbe(signals: [FWSignal.nuxtApp.rawValue])), .nuxtRouter)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "gatsby", probe: FWDevProbe(signals: [FWSignal.gatsbyNavigate.rawValue])), .gatsbyNavigate)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: "sveltekit", probe: FWDevProbe()), .linkClick)
        XCTAssertEqual(FWDevLogic.navigationStrategy(adapterID: nil, probe: FWDevProbe()), .linkClick)
    }

    func testEditorRequestsNext() {
        let adapter = FWDevAdapters.adapter(id: "next")
        let urls = FWDevLogic.editorRequests(adapter: adapter, file: "/proj/app/page.tsx", line: 12, column: 5)
        XCTAssertEqual(urls, ["/__nextjs_launch-editor?file=%2Fproj%2Fapp%2Fpage.tsx&line1=12&column1=5&lineNumber=12&column=5"])
    }

    func testEditorRequestsViteStyleEncodesPathLineColumn() {
        let urls = FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "vite"), file: "/proj/src/My App.tsx", line: 3, column: nil)
        XCTAssertEqual(urls, ["/__open-in-editor?file=%2Fproj%2Fsrc%2FMy%20App.tsx%3A3%3A1"])
    }

    func testEditorRequestsNuxtTriesBothPrefixes() {
        let urls = FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "nuxt"), file: "/p/a.vue", line: 1, column: 1)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].hasPrefix("/__open-in-editor"))
        XCTAssertTrue(urls[1].hasPrefix("/_nuxt/__open-in-editor"))
    }

    func testEditorRequestsForWebpackGatsbyParcelAndNone() {
        XCTAssertEqual(FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "webpack"), file: "/p/a.js", line: 4, column: 2).first,
                       "/webpack-dev-server/open-editor?fileName=%2Fp%2Fa.js")
        XCTAssertEqual(FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "gatsby"), file: "/p/a.js", line: 4, column: 2),
                       ["/__open-stack-frame-in-editor?fileName=%2Fp%2Fa.js&lineNumber=4&colNumber=2"])
        XCTAssertEqual(FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "parcel"), file: "/p/a.js", line: 4, column: 2),
                       ["/__parcel_launch_editor?file=%2Fp%2Fa.js"])
        XCTAssertTrue(FWDevLogic.editorRequests(adapter: FWDevAdapters.adapter(id: "qwik"), file: "/p/a.tsx", line: 1, column: 1).isEmpty)
        XCTAssertTrue(FWDevLogic.editorRequests(adapter: nil, file: "/p/a.tsx", line: 1, column: 1).isEmpty)
    }

    func testRestartRequests() {
        guard case .endpoint(let endpoint) = FWDevAdapters.adapter(id: "next")!.restart else { return XCTFail() }
        XCTAssertEqual(FWDevLogic.restartRequest(endpoint, clearCache: false), "/__nextjs_restart_dev")
        XCTAssertEqual(FWDevLogic.restartRequest(endpoint, clearCache: true),
                       "/__nextjs_restart_dev?invalidateFileSystemCache=1&invalidatePersistentCache=1")
        XCTAssertEqual(endpoint.statusPath, "/__nextjs_server_status")
    }
}

// MARK: - Dev server: tables and helpers

class FWDevTableTests: XCTestCase {

    func testAdapterIDsAreUnique() {
        let ids = FWDevAdapters.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryProtocolMapsToARealAdapter() {
        for protocolID in FWWireProtocol.allCases {
            XCTAssertNotNil(FWDevAdapters.adapter(id: FWDevAdapters.adapterID(for: protocolID)), protocolID.rawValue)
        }
    }

    func testDetectionNamesBelongToOneAdapter() {
        var seen = Set<String>()
        for adapter in FWDevAdapters.all {
            for name in adapter.detectionNames { XCTAssertTrue(seen.insert(name).inserted, name) }
        }
    }

    func testSpecificityOrdersMetaFrameworksAboveBundlers() {
        func spec(_ id: String) -> Int { FWDevAdapters.adapter(id: id)?.specificity ?? -1 }
        XCTAssertGreaterThan(spec("next"), spec("vite"))
        XCTAssertGreaterThan(spec("storybook"), spec("vite"))
        XCTAssertGreaterThan(spec("nuxt"), spec("webpack"))
        XCTAssertGreaterThan(spec("reactRouter"), spec("remix"))
    }

    func testEveryDetectionNameTheAdaptersUseIsProducedByDetect() {
        // Each adapter keys on a name detect() really emits; a typo here silently disables a framework.
        let samples: [String: FWEvidenceBundle] = [
            "Next.js": FWEvidenceBundle(globals: ["__NEXT_DATA__"]),
            "Nuxt": FWEvidenceBundle(globals: ["useNuxtApp"]),
            "SvelteKit": FWEvidenceBundle(globals: ["__sveltekit_dev"]),
            "Astro": FWEvidenceBundle(domMarkers: ["astro-island"]),
            "Gatsby": FWEvidenceBundle(globals: ["___loader"]),
            "Storybook": FWEvidenceBundle(globals: ["__STORYBOOK_PREVIEW__"]),
            "React Router": FWEvidenceBundle(globals: ["__reactRouterContext"]),
            "Remix": FWEvidenceBundle(globals: ["__remixContext"]),
            "Qwik": FWEvidenceBundle(domMarkers: ["q:container"]),
            "Angular": FWEvidenceBundle(domMarkers: ["ng-version"]),
            "Solid": FWEvidenceBundle(globals: ["Solid"]),
            "Parcel": FWEvidenceBundle(globals: ["parcelRequire"]),
            "Vite": FWEvidenceBundle(scriptURLs: ["http://localhost:5173/@vite/client"]),
            "webpack": FWEvidenceBundle(globals: ["__webpack_require__"]),
        ]
        for adapter in FWDevAdapters.all where !adapter.detectionNames.isEmpty {
            for name in adapter.detectionNames {
                guard let sample = samples[name] else { XCTFail("no sample for \(name)"); continue }
                XCTAssertTrue(OrbitFrameworksLogic.detect(evidence: sample).contains { $0.name == name }, name)
            }
        }
    }

    func testStripANSI() {
        XCTAssertEqual(FWDevText.stripANSI("\u{1B}[31mError\u{1B}[0m: bad"), "Error: bad")
    }

    func testLocationExtraction() {
        XCTAssertEqual(FWDevText.location(in: "./src/App.tsx:5:10\nBad")?.file, "./src/App.tsx")
        XCTAssertEqual(FWDevText.location(in: "./src/App.tsx:5:10\nBad")?.column, 10)
        XCTAssertEqual(FWDevText.location(in: "/Users/me/app/page.tsx:3")?.line, 3)
        XCTAssertNil(FWDevText.location(in: "/Users/me/app/page.tsx:3")?.column)
        XCTAssertEqual(FWDevText.location(in: "./src/pages/index.js 12:5\nfail")?.line, 12)
        XCTAssertEqual(FWDevText.location(in: "at f (http://localhost:3000/_next/static/app.js:44:9)")?.file, "http://localhost:3000/_next/static/app.js")
        XCTAssertNil(FWDevText.location(in: "Module not found: Can't resolve './missing'"))
        XCTAssertNil(FWDevText.location(in: ""))
    }

    func testWebpackLocAndModuleFile() {
        XCTAssertEqual(FWDevText.webpackLoc("3:7-8").line, 3)
        XCTAssertEqual(FWDevText.webpackLoc("3:7-8").column, 7)
        XCTAssertEqual(FWDevText.webpackLoc("3:7-5:2").column, 7)
        XCTAssertNil(FWDevText.webpackLoc("").line)
        XCTAssertEqual(FWDevText.moduleFile("/n/babel-loader/index.js??ruleSet[1]!/p/src/a.js?x=1"), "/p/src/a.js")
    }

    func testHugeMessagesAreBounded() {
        let huge = String(repeating: "a", count: 100_000)
        let built = FWDevWire.issue(from: huge, severity: .error, origin: .build, source: "t")
        XCTAssertLessThanOrEqual(built.message.count, 8_000)
    }

    func testVersionComparison() {
        XCTAssertEqual(FWDevLogic.isVersion("15.4.0", atLeast: "15.4.0"), true)
        XCTAssertEqual(FWDevLogic.isVersion("15.3.9", atLeast: "15.4.0"), false)
        XCTAssertEqual(FWDevLogic.isVersion("16.0.0", atLeast: "15.4.0"), true)
        XCTAssertEqual(FWDevLogic.isVersion("v15.4", atLeast: "15.4.0"), true)
        XCTAssertEqual(FWDevLogic.isVersion("15.4.0-canary.3", atLeast: "15.4.0"), true)
        XCTAssertNil(FWDevLogic.isVersion("latest", atLeast: "15.4.0"))
    }

    func testRelativeAge() {
        XCTAssertEqual(FWDevLogic.relativeAge(from: 1000, to: 3000), "just now")
        XCTAssertEqual(FWDevLogic.relativeAge(from: 0, to: 12_000), "12 s ago")
        XCTAssertEqual(FWDevLogic.relativeAge(from: 0, to: 180_000), "3 min ago")
        XCTAssertEqual(FWDevLogic.relativeAge(from: 0, to: 7_200_000), "2 h ago")
        XCTAssertEqual(FWDevLogic.relativeAge(from: 5000, to: 1000), "just now")
        XCTAssertEqual(FWDevLogic.relativeAge(from: 0, to: 1e300), "\(Int.max / 86_400) d ago")
    }
}

// MARK: - Dev server: render and route information

class FWDevRenderInfoTests: XCTestCase {

    func testNextPagesRenderModes() {
        XCTAssertEqual(FWDevLogic.nextPagesRenderMode(facts: ["next.gsp": "true"]), "Statically generated (getStaticProps)")
        XCTAssertEqual(FWDevLogic.nextPagesRenderMode(facts: ["next.gssp": "true"]), "Server-side rendered (getServerSideProps)")
        XCTAssertEqual(FWDevLogic.nextPagesRenderMode(facts: ["next.autoExport": "true"]), "Automatic static optimization")
        XCTAssertEqual(FWDevLogic.nextPagesRenderMode(facts: ["next.gsp": "true", "next.isFallback": "true"]), "Fallback shell (getStaticPaths fallback)")
        XCTAssertNil(FWDevLogic.nextPagesRenderMode(facts: [:]))
    }

    func testCacheHintsForISR() {
        let rows = FWDevLogic.cacheHints(headers: ["cache-control": "s-maxage=60, stale-while-revalidate=31536000", "x-nextjs-cache": "HIT", "x-nextjs-prerender": "1"])
        XCTAssertEqual(rows.map(\.label), ["Cache", "Prerendered", "Revalidate"])
        XCTAssertEqual(rows.last?.value, "every 60 s")
    }

    func testCacheHintsForDynamic() {
        let rows = FWDevLogic.cacheHints(headers: ["cache-control": "private, no-cache, no-store, max-age=0, must-revalidate"])
        XCTAssertEqual(rows.first?.value, "not cached")
        XCTAssertTrue(FWDevLogic.cacheHints(headers: [:]).isEmpty)
    }

    func testNextAppRouterStaticIndicatorFromTheIsrManifest() {
        var state = FWDevState()
        state.apply(FWDevWireEvent(kind: .info, title: "m", inTimeline: false, staticRoutes: ["/": true, "/dash": false]), at: 1)
        let probe = FWDevProbe(signals: [FWSignal.nextApp.rawValue, FWSignal.nextDevGlobal.rawValue], facts: ["next.router": "app"], pathname: "/dash")
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: probe, state: state)
        let rows = FWDevLogic.renderInfo(resolution: r, probe: probe, state: state, headers: [:])
        XCTAssertEqual(rows.first { $0.label == "Router" }?.value, "App Router")
        XCTAssertEqual(rows.first { $0.label == "Route" }?.value, "Dynamic (rendered per request)")
    }

    func testNextPagesRouterRows() {
        let probe = FWDevProbe(signals: [FWSignal.nextPages.rawValue], facts: ["next.router": "pages", "next.gsp": "true", "next.page": "/blog/[slug]"])
        let r = FWDevLogic.resolve(detections: [detected("Next.js")], probe: probe, state: FWDevState())
        let rows = FWDevLogic.renderInfo(resolution: r, probe: probe, state: FWDevState(), headers: [:])
        XCTAssertEqual(rows.first { $0.label == "Rendering" }?.value, "Statically generated (getStaticProps)")
        XCTAssertEqual(rows.first { $0.label == "Page" }?.value, "/blog/[slug]")
    }

    func testNuxtAndReactRouterRows() {
        let nuxtProbe = FWDevProbe(facts: ["nuxt.serverRendered": "false", "vue.version": "3.5.0"])
        let nuxt = FWDevLogic.resolve(detections: [detected("Nuxt")], probe: nuxtProbe, state: FWDevState())
        let rows = FWDevLogic.renderInfo(resolution: nuxt, probe: nuxtProbe, state: FWDevState(), headers: [:])
        XCTAssertEqual(rows.first { $0.label == "Rendering" }?.value, "Client rendered (SPA)")
        XCTAssertEqual(rows.first { $0.label == "Vue" }?.value, "3.5.0")
    }

    func testNoRowsWithoutAFramework() {
        let r = FWDevLogic.resolve(detections: [], probe: FWDevProbe(), state: FWDevState())
        XCTAssertTrue(FWDevLogic.renderInfo(resolution: r, probe: FWDevProbe(), state: FWDevState(), headers: [:]).isEmpty)
    }
}

// MARK: - Detection additions

class FWDevDetectionTests: XCTestCase {

    func testReactRouterV7() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__reactRouterContext"], globalVersions: ["__reactRouterVersion": "7.9.0"]))
        let rr = d.first { $0.name == "React Router" }
        XCTAssertEqual(rr?.confidence, .certain)
        XCTAssertEqual(rr?.version, "7.9.0")
        XCTAssertEqual(rr?.category, .metaFramework)
    }

    func testStorybook() {
        XCTAssertNotNil(OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__STORYBOOK_PREVIEW__"])).first { $0.name == "Storybook" })
    }

    func testGatsbyViaLoaderAndRootElement() {
        XCTAssertEqual(OrbitFrameworksLogic.detect(evidence: evidence(globals: ["___loader"])).first { $0.name == "Gatsby" }?.confidence, .certain)
        XCTAssertEqual(OrbitFrameworksLogic.detect(evidence: evidence(domMarkers: ["#___gatsby"])).first { $0.name == "Gatsby" }?.confidence, .likely)
    }

    func testNuxtSurvivesTheDeletedPayloadGlobal() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["useNuxtApp"], globalVersions: ["__NUXT__.versions.nuxt": "4.6.4"]))
        let nuxt = d.first { $0.name == "Nuxt" }
        XCTAssertEqual(nuxt?.confidence, .certain)
        XCTAssertEqual(nuxt?.version, "4.6.4")
    }

    func testAstroDevToolbarGlobal() {
        let d = OrbitFrameworksLogic.detect(evidence: evidence(globals: ["__astro_dev_toolbar__"], globalVersions: ["__astro_dev_toolbar__.version": "5.1.0"]))
        XCTAssertEqual(d.first { $0.name == "Astro" }?.version, "5.1.0")
    }
}
