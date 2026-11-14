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
