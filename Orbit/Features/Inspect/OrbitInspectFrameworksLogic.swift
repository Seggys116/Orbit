// Foundation only (no AppKit, SwiftUI or WebKit): compiled into the unit-test bundle alongside OrbitInspectDecode.swift.
import Foundation

struct FWEvidenceBundle: Equatable, Sendable {
    var globals: Set<String> = []
    var globalVersions: [String: String] = [:]
    /// Element ids like "#__next", attribute names like "data-reactroot", tag names like "astro-island".
    var domMarkers: Set<String> = []
    var scriptURLs: [String] = []
    var linkURLs: [String] = []
    var metaGenerators: [String] = []
    var responseHeaders: [String: String] = [:]
    var hostname: String = ""
    var pageURL: String = ""
}


enum FWCategory: String, Equatable, CaseIterable, Sendable {
    case framework = "Framework"
    case metaFramework = "Meta-framework"
    case buildTool = "Build & Dev"
    case hosting = "Hosting & CDN"
    case library = "Library"
    case cms = "CMS"

    var sortOrder: Int {
        switch self {
        case .framework: return 0
        case .metaFramework: return 1
        case .buildTool: return 2
        case .library: return 3
        case .cms: return 4
        case .hosting: return 5
        }
    }
}

enum FWConfidence: Int, Comparable, Equatable, Sendable {
    case certain = 3
    case likely = 2
    case possible = 1

    static func < (lhs: FWConfidence, rhs: FWConfidence) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .certain: return "Certain"
        case .likely: return "Likely"
        case .possible: return "Possible"
        }
    }
}

struct FWDetected: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String?
    var category: FWCategory
    var confidence: FWConfidence
    var evidence: [String]

    init(id: String? = nil, name: String, version: String? = nil,
         category: FWCategory, confidence: FWConfidence, evidence: [String]) {
        self.id = id ?? name
        self.name = name
        self.version = version
        self.category = category
        self.confidence = confidence
        self.evidence = evidence
    }

    var displayName: String {
        version.map { "\(name) \($0)" } ?? name
    }
}


struct FWComponentNode: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String = "?"
    var isHost: Bool = false
    var key: String? = nil
    var domNodeID: Int? = nil
    var sourceFile: String? = nil
    var sourceLine: Int? = nil
    var sourceCol: Int? = nil
    var ownerName: String? = nil
    var props: [String: String] = [:]
    var hooks: [FWHookItem] = []
    var childIDs: [Int] = []
    var framework: String = "react"
    var minified: Bool = false
}

struct FWHookItem: Equatable, Sendable {
    var index: Int
    var label: String
    var value: String
    var approximate: Bool = true
}


enum FWDataKind: String, Equatable, Sendable {
    case json
    case flight
    case globals
    case scripts
}

struct FWDataItem: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var kind: FWDataKind
    var rawJSON: String? = nil
    var flightRows: [FWFlightRow] = []
    var globals: [FWGlobalEntry] = []
    var scripts: [FWScriptEntry] = []
    var framework: String? = nil
}

struct FWGlobalEntry: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var preview: String
}

struct FWScriptEntry: Identifiable, Equatable, Sendable {
    var id: String
    var scriptType: String
    var content: String
}

enum FWFlightRowType: Equatable, Sendable {
    case moduleRef
    case htmlLinkHint  // HL
    case htmlLink      // H
    case text          // T
    case error         // E
    case json
    case routerState   // JSON that looks like a router state tree
    case unknown
}

struct FWFlightRow: Identifiable, Equatable, Sendable {
    var id: Int
    var rowID: String
    var rowType: FWFlightRowType
    var rawContent: String
    var moduleURL: String? = nil
    var moduleExport: String? = nil
    var jsonPreview: String? = nil
}


struct FWRoute: Identifiable, Equatable, Sendable {
    var id: String
    var path: String
    var isCurrent: Bool = false
    var isDynamic: Bool = false
    var params: [String: String] = [:]
    var source: String
    var prefetch: Bool = false
}


struct FWHMRStatus: Equatable, Sendable {
    var kind: String? = nil
    var wsURL: String? = nil
    var connected: Bool = false
}

struct FWOverlayInfo: Equatable, Sendable {
    var message: String
    var file: String? = nil
    var line: Int? = nil
    var col: Int? = nil
    var stackText: String? = nil
    var source: String
}


struct FWHydrationDiff: Equatable, Sendable {
    var summary: String
    var rawMessage: String
    var serverTree: String? = nil
    var clientTree: String? = nil
    var reactVersion: Int? = nil
}


enum OrbitFrameworksLogic {


    static func detect(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var results: [FWDetected] = []

        let hookPresent = e.globals.contains("__REACT_DEVTOOLS_GLOBAL_HOOK__")
        let reactGlobal = e.globals.contains("React")
        let dataReactroot = e.domMarkers.contains("data-reactroot")
        let reactScript = e.scriptURLs.contains(where: { $0.contains("react") && ($0.hasSuffix(".js") || $0.contains(".js?") || $0.contains(".mjs")) })
        if hookPresent || dataReactroot {
            var ev: [String] = []
            if hookPresent { ev.append("global __REACT_DEVTOOLS_GLOBAL_HOOK__") }
            if dataReactroot { ev.append("DOM attr data-reactroot") }
            let version = e.globalVersions["React.version"] ?? e.globalVersions["react.version"]
            results.append(FWDetected(name: "React", version: version, category: .framework, confidence: .certain, evidence: ev))
        } else if reactGlobal {
            let version = e.globalVersions["React.version"] ?? e.globalVersions["react.version"]
            results.append(FWDetected(name: "React", version: version, category: .framework, confidence: .likely, evidence: ["global React"]))
        } else if reactScript {
            results.append(FWDetected(name: "React", category: .framework, confidence: .possible, evidence: ["react in script URL"]))
        }

        if e.globals.contains("__PREACT_DEVTOOLS__") {
            results.append(FWDetected(name: "Preact", category: .framework, confidence: .certain, evidence: ["global __PREACT_DEVTOOLS__"]))
        } else if e.scriptURLs.contains(where: { $0.contains("/preact") || $0.contains("preact@") }) {
            results.append(FWDetected(name: "Preact", category: .framework, confidence: .possible, evidence: ["preact in script URL"]))
        }

        if e.globals.contains("__vue_app__") || e.globals.contains("__VUE__") {
            var ev: [String] = []
            if e.globals.contains("__vue_app__") { ev.append("global __vue_app__ (Vue 3)") }
            if e.globals.contains("__VUE__") { ev.append("global __VUE__") }
            let version = e.globalVersions["Vue.version"] ?? e.globalVersions["vue.version"]
            results.append(FWDetected(name: "Vue", version: version, category: .framework, confidence: .certain, evidence: ev))
        } else if e.domMarkers.contains(where: { $0.hasPrefix("data-v-") }) {
            results.append(FWDetected(name: "Vue", category: .framework, confidence: .likely, evidence: ["DOM attr data-v-* (SFC scoped styles)"]))
        }

        if e.domMarkers.contains("data-svelte-h") {
            let version = e.globalVersions["__svelte.version"] ?? e.globalVersions["svelte.version"]
            results.append(FWDetected(name: "Svelte", version: version, category: .framework, confidence: .certain, evidence: ["DOM attr data-svelte-h"]))
        }

        if e.domMarkers.contains("ng-version") || e.globals.contains("ng") {
            var ev: [String] = []
            if e.domMarkers.contains("ng-version") { ev.append("DOM attr ng-version") }
            if e.globals.contains("ng") { ev.append("global ng") }
            let version = e.globalVersions["ng.version.full"] ?? e.globalVersions["ng-version"]
            results.append(FWDetected(name: "Angular", version: version, category: .framework, confidence: .certain, evidence: ev))
        }

        if e.globals.contains("Solid") || e.globals.contains("_$getOwner") {
            let key = e.globals.contains("Solid") ? "Solid" : "_$getOwner"
            results.append(FWDetected(name: "Solid", category: .framework, confidence: .certain, evidence: ["global \(key)"]))
        }

        if e.domMarkers.contains("q:container") {
            results.append(FWDetected(name: "Qwik", category: .framework, confidence: .certain, evidence: ["DOM attr q:container"]))
        }

        if e.globals.contains("Alpine") {
            let version = e.globalVersions["Alpine.version"]
            results.append(FWDetected(name: "Alpine.js", version: version, category: .library, confidence: .certain, evidence: ["global Alpine"]))
        } else if e.domMarkers.contains("x-data") {
            results.append(FWDetected(name: "Alpine.js", category: .library, confidence: .likely, evidence: ["DOM attr x-data"]))
        }

        if e.globals.contains("htmx") {
            let version = e.globalVersions["htmx.version"]
            results.append(FWDetected(name: "htmx", version: version, category: .library, confidence: .certain, evidence: ["global htmx"]))
        } else if e.domMarkers.contains("hx-get") || e.domMarkers.contains("hx-post") {
            results.append(FWDetected(name: "htmx", category: .library, confidence: .likely, evidence: ["DOM attrs hx-get/hx-post"]))
        }

        let jqVersion = e.globalVersions["jQuery.fn.jquery"] ?? e.globalVersions["$.fn.jquery"]
        if e.globals.contains("jQuery") || jqVersion != nil {
            var ev: [String] = []
            if e.globals.contains("jQuery") { ev.append("global jQuery") }
            if let v = jqVersion { ev.append("jQuery.fn.jquery = \(v)") }
            results.append(FWDetected(name: "jQuery", version: jqVersion, category: .library,
                                      confidence: e.globals.contains("jQuery") ? .certain : .likely, evidence: ev))
        }

        if e.globals.contains("litElementVersions") {
            let version = e.globalVersions["litElementVersions"]
            results.append(FWDetected(name: "Lit", version: version, category: .library, confidence: .certain, evidence: ["global litElementVersions"]))
        }

        let hasNextData = e.globals.contains("__NEXT_DATA__")
        let hasNextF = e.globals.contains("__next_f")
        let hasNextScript = e.scriptURLs.contains(where: { $0.contains("/_next/") })
        let nextHeaders = e.responseHeaders.keys.contains(where: { $0.hasPrefix("x-nextjs") })
        if hasNextData || hasNextF || nextHeaders {
            var ev: [String] = []
            if hasNextData { ev.append("global __NEXT_DATA__ (Pages Router)") }
            if hasNextF { ev.append("global __next_f (App Router)") }
            if hasNextScript { ev.append("script URL /_next/") }
            if nextHeaders { ev.append("response header x-nextjs-*") }
            let version = e.globalVersions["next.version"]
            results.append(FWDetected(id: "nextjs", name: "Next.js", version: version,
                                      category: .metaFramework, confidence: .certain, evidence: ev))
        } else if e.domMarkers.contains("#__next") && hasNextScript {
            results.append(FWDetected(id: "nextjs", name: "Next.js", category: .metaFramework,
                                      confidence: .likely, evidence: ["DOM #__next", "script URL /_next/"]))
        }

        if e.globals.contains("__NUXT__") || e.globals.contains("$nuxt") {
            var ev: [String] = []
            if e.globals.contains("__NUXT__") { ev.append("global __NUXT__") }
            if e.globals.contains("$nuxt") { ev.append("global $nuxt") }
            let version = e.globalVersions["__NUXT__.versions.nuxt"]
            results.append(FWDetected(name: "Nuxt", version: version, category: .metaFramework, confidence: .certain, evidence: ev))
        } else if e.domMarkers.contains("#__nuxt") || e.scriptURLs.contains(where: { $0.contains("/_nuxt/") }) {
            var ev: [String] = []
            if e.domMarkers.contains("#__nuxt") { ev.append("DOM #__nuxt") }
            if e.scriptURLs.contains(where: { $0.contains("/_nuxt/") }) { ev.append("script URL /_nuxt/") }
            results.append(FWDetected(name: "Nuxt", category: .metaFramework, confidence: .likely, evidence: ev))
        }

        if e.globals.contains("__remixContext") || e.globals.contains("__remixManifest") {
            var ev: [String] = []
            if e.globals.contains("__remixContext") { ev.append("global __remixContext") }
            if e.globals.contains("__remixManifest") { ev.append("global __remixManifest") }
            results.append(FWDetected(name: "Remix", category: .metaFramework, confidence: .certain, evidence: ev))
        } else if e.scriptURLs.contains(where: { $0.contains("/build/") && $0.contains("entry.client") }) {
            results.append(FWDetected(name: "Remix", category: .metaFramework, confidence: .possible, evidence: ["script URL /build/entry.client"]))
        }

        if let sk = e.globals.first(where: { $0.hasPrefix("__sveltekit") }) {
            results.append(FWDetected(name: "SvelteKit", category: .metaFramework, confidence: .certain, evidence: ["global \(sk)"]))
        }

        if e.domMarkers.contains("astro-island") {
            results.append(FWDetected(name: "Astro", category: .metaFramework, confidence: .certain, evidence: ["custom element <astro-island>"]))
        } else if e.scriptURLs.contains(where: { $0.contains("/_astro/") }) {
            results.append(FWDetected(name: "Astro", category: .metaFramework, confidence: .likely, evidence: ["script URL /_astro/"]))
        }

        if e.globals.contains("___gatsby") {
            results.append(FWDetected(name: "Gatsby", category: .metaFramework, confidence: .certain, evidence: ["global ___gatsby"]))
        }

        let hasViteClient = e.scriptURLs.contains(where: { $0.contains("/@vite/client") })
        let hasReactRefresh = e.scriptURLs.contains(where: { $0.contains("/@react-refresh") })
        if hasViteClient || hasReactRefresh {
            var ev: [String] = []
            if hasViteClient { ev.append("script URL /@vite/client") }
            if hasReactRefresh { ev.append("script URL /@react-refresh") }
            results.append(FWDetected(name: "Vite", category: .buildTool, confidence: .certain, evidence: ev))
        }

        if e.globals.contains("__webpack_require__") || e.globals.contains(where: { $0.hasPrefix("webpackChunk") }) {
            var ev: [String] = []
            if e.globals.contains("__webpack_require__") { ev.append("global __webpack_require__") }
            if let wc = e.globals.first(where: { $0.hasPrefix("webpackChunk") }) { ev.append("global \(wc)") }
            results.append(FWDetected(name: "webpack", category: .buildTool, confidence: .certain, evidence: ev))
        }

        if let tp = e.globals.first(where: { $0.hasPrefix("__turbopack") }) {
            results.append(FWDetected(name: "Turbopack", category: .buildTool, confidence: .certain, evidence: ["global \(tp)"]))
        }

        if e.globals.contains("parcelRequire") || e.globals.contains(where: { $0.hasPrefix("$parcel$") }) {
            let key = e.globals.first(where: { $0.hasPrefix("$parcel$") }) ?? "parcelRequire"
            results.append(FWDetected(name: "Parcel", category: .buildTool, confidence: .certain, evidence: ["global \(key)"]))
        }

        if e.responseHeaders.keys.contains(where: { $0.hasPrefix("x-vercel") }) {
            let key = e.responseHeaders.keys.first(where: { $0.hasPrefix("x-vercel") }) ?? "x-vercel-*"
            results.append(FWDetected(name: "Vercel", category: .hosting, confidence: .certain, evidence: ["response header \(key)"]))
        }

        if e.responseHeaders["x-nf-request-id"] != nil {
            results.append(FWDetected(name: "Netlify", category: .hosting, confidence: .certain, evidence: ["response header x-nf-request-id"]))
        }

        if e.responseHeaders["cf-ray"] != nil {
            results.append(FWDetected(name: "Cloudflare", category: .hosting, confidence: .certain, evidence: ["response header cf-ray"]))
        }

        if e.responseHeaders.keys.contains(where: { $0.hasPrefix("x-amz") || $0 == "x-amzn-requestid" }) {
            let key = e.responseHeaders.keys.first(where: { $0.hasPrefix("x-amz") || $0 == "x-amzn-requestid" }) ?? "x-amz*"
            results.append(FWDetected(name: "AWS", category: .hosting, confidence: .certain, evidence: ["response header \(key)"]))
        }

        let wpScript = e.scriptURLs.contains(where: { $0.contains("wp-content") || $0.contains("wp-includes") })
        let wpGenerator = e.metaGenerators.contains(where: { $0.lowercased().contains("wordpress") })
        let pb = e.responseHeaders["x-powered-by"] ?? ""
        let wpHeader = pb.lowercased().contains("wordpress")
        if wpScript || wpGenerator || wpHeader {
            var ev: [String] = []
            if wpScript { ev.append("script URL wp-content/wp-includes") }
            if wpGenerator { ev.append("meta generator: WordPress") }
            if wpHeader { ev.append("x-powered-by: \(pb)") }
            let version = e.metaGenerators.first(where: { $0.lowercased().contains("wordpress") })
                .flatMap { extractVersion(from: $0) }
            results.append(FWDetected(name: "WordPress", version: version, category: .cms, confidence: .certain, evidence: ev))
        }

        let shopifyHeader = e.responseHeaders.keys.contains(where: { $0.hasPrefix("x-shopify") })
        let shopifyScript = e.scriptURLs.contains(where: { $0.contains("cdn.shopify.com") || $0.contains("shopifycloud.com") })
        if shopifyHeader || shopifyScript {
            var ev: [String] = []
            if shopifyHeader { ev.append("response header x-shopify-*") }
            if shopifyScript { ev.append("script URL cdn.shopify.com") }
            results.append(FWDetected(name: "Shopify", category: .cms, confidence: .certain, evidence: ev))
        }

        if e.responseHeaders["set-cookie"]?.contains("csrftoken") == true {
            results.append(FWDetected(name: "Django", category: .cms, confidence: .likely, evidence: ["set-cookie csrftoken"]))
        }

        if e.responseHeaders["set-cookie"]?.contains("laravel_session") == true {
            results.append(FWDetected(name: "Laravel", category: .cms, confidence: .certain, evidence: ["set-cookie laravel_session"]))
        }

        // Possible only: the _session cookie pattern is common.
        if let cookie = e.responseHeaders["set-cookie"],
           (cookie.contains("_session") || cookie.contains("rack.session")),
           !cookie.contains("laravel_session") {
            results.append(FWDetected(name: "Rails/Rack", category: .cms, confidence: .possible, evidence: ["set-cookie contains _session / rack.session"]))
        }

        for gen in e.metaGenerators {
            let lower = gen.lowercased()
            guard !lower.contains("wordpress") && !lower.contains("shopify") else { continue }
            if lower.contains("drupal") {
                results.append(FWDetected(name: "Drupal", version: extractVersion(from: gen), category: .cms, confidence: .certain, evidence: ["meta generator: \(gen)"]))
            } else if lower.contains("joomla") {
                results.append(FWDetected(name: "Joomla", version: extractVersion(from: gen), category: .cms, confidence: .certain, evidence: ["meta generator: \(gen)"]))
            } else if lower.contains("ghost") {
                results.append(FWDetected(name: "Ghost", version: extractVersion(from: gen), category: .cms, confidence: .certain, evidence: ["meta generator: \(gen)"]))
            } else if lower.contains("wix") {
                results.append(FWDetected(name: "Wix", category: .cms, confidence: .certain, evidence: ["meta generator: \(gen)"]))
            } else if lower.contains("squarespace") {
                results.append(FWDetected(name: "Squarespace", category: .cms, confidence: .certain, evidence: ["meta generator: \(gen)"]))
            }
        }

        if !pb.isEmpty {
            if pb.lowercased().contains("php") {
                let v = extractVersion(from: pb)
                results.append(FWDetected(name: "PHP", version: v, category: .cms, confidence: .certain, evidence: ["x-powered-by: \(pb)"]))
            } else if pb.lowercased().contains("asp.net") || pb.lowercased().contains("aspnet") {
                results.append(FWDetected(name: "ASP.NET", category: .cms, confidence: .certain, evidence: ["x-powered-by: \(pb)"]))
            } else if pb.lowercased().contains("express") {
                results.append(FWDetected(name: "Express.js", category: .library, confidence: .certain, evidence: ["x-powered-by: Express"]))
            }
        }

        var deduped: [String: FWDetected] = [:]
        for d in results {
            if let existing = deduped[d.name] {
                if d.confidence > existing.confidence { deduped[d.name] = d }
            } else {
                deduped[d.name] = d
            }
        }

        return Array(deduped.values).sorted { a, b in
            if a.category.sortOrder != b.category.sortOrder { return a.category.sortOrder < b.category.sortOrder }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            return a.name < b.name
        }
    }

    static func primary(among detections: [FWDetected]) -> String? {
        let candidates = detections.filter { $0.confidence >= .likely &&
            ($0.category == .metaFramework || $0.category == .framework) }
        // A meta-framework (Next.js, Nuxt) is the more specific answer, so it wins over the framework it is built on.
        guard let top = candidates.first(where: { $0.category == .metaFramework }) ?? candidates.first else { return nil }
        var name = top.displayName
        if top.name == "Next.js" {
            let ev = top.evidence.joined()
            if ev.contains("Pages Router") { name += " · Pages Router" }
            else if ev.contains("App Router") { name += " · App Router" }
        }
        return name
    }


    static func extractVersion(from text: String) -> String? {
        let pattern = #"v?(\d+\.\d+(?:\.\d+)?(?:[.-][a-zA-Z0-9.]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }


    static func hmrStatus(from records: [OrbitNetworkRecord]) -> FWHMRStatus {
        let wsRecords = records.filter { $0.resourceType == "websocket" || $0.resourceType == "eventsource" }
        for record in wsRecords.reversed() {
            let url = record.url
            if url.contains("/_next/turbopack-hmr") {
                return FWHMRStatus(kind: "Turbopack", wsURL: url, connected: !record.failed)
            }
            if url.contains("/_next/webpack-hmr") || url.contains("/_next/hmr") {
                return FWHMRStatus(kind: "Next.js (webpack)", wsURL: url, connected: !record.failed)
            }
            if url.contains("vite-hmr") || (url.contains("?token=") && url.contains("/@vite")) {
                return FWHMRStatus(kind: "Vite", wsURL: url, connected: !record.failed)
            }
            if url.contains("/__webpack_hmr") {
                return FWHMRStatus(kind: "webpack-dev-server", wsURL: url, connected: !record.failed)
            }
            if url.hasSuffix("/hmr") || url.contains("/parcel-hmr") {
                return FWHMRStatus(kind: "Parcel", wsURL: url, connected: !record.failed)
            }
            // Generic WebSocket on a localhost dev-server port
            if url.hasPrefix("ws://localhost") || url.hasPrefix("ws://127.0.0.1") {
                return FWHMRStatus(kind: "Dev server (WebSocket)", wsURL: url, connected: !record.failed)
            }
        }
        return FWHMRStatus()
    }

    static func responseHeaders(from records: [OrbitNetworkRecord]) -> [String: String] {
        guard let doc = records.first(where: { $0.resourceType == "document" && $0.isMainFrame }) else {
            return [:]
        }
        var result: [String: String] = [:]
        for h in doc.responseHeaders {
            result[h.name.lowercased()] = h.value
        }
        return result
    }

    static func parseFlightPayload(_ chunks: [String]) -> [FWFlightRow] {
        let combined = chunks.joined(separator: "")
        var rows: [FWFlightRow] = []
        var rowIndex = 0
        for line in combined.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            if let row = parseFlightRow(line, rowIndex: rowIndex) {
                rows.append(row)
                rowIndex += 1
            }
        }
        return rows
    }

    static func parseFlightRow(_ text: String, rowIndex: Int) -> FWFlightRow? {
        guard let colonIdx = text.firstIndex(of: ":") else { return nil }
        let rowID = String(text[..<colonIdx])
        let rest = String(text[text.index(after: colonIdx)...])
        guard !rest.isEmpty else {
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .unknown, rawContent: text)
        }
        let first = rest.first!

        if first == "I" {
            let content = String(rest.dropFirst())
            var moduleURL: String?
            var moduleExport: String?
            if let data = content.data(using: .utf8),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
               arr.count >= 1 {
                moduleURL = arr[0] as? String
                if arr.count >= 2, let exports = arr[1] as? [String] {
                    moduleExport = exports.first
                }
            }
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .moduleRef,
                               rawContent: content, moduleURL: moduleURL, moduleExport: moduleExport)
        }

        if rest.hasPrefix("HL") {
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .htmlLinkHint, rawContent: String(rest.dropFirst(2)))
        }

        if first == "H" && rest.count > 1 {
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .htmlLink, rawContent: String(rest.dropFirst()))
        }

        if first == "T" {
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .text, rawContent: String(rest.dropFirst()))
        }

        if first == "E" {
            return FWFlightRow(id: rowIndex, rowID: rowID, rowType: .error, rawContent: String(rest.dropFirst()))
        }

        let isRouterState = rest.contains("\"layout\"") && rest.contains("\"page\"")
        let rowType: FWFlightRowType = isRouterState ? .routerState : .json
        let preview = previewFlightJSON(rest)
        return FWFlightRow(id: rowIndex, rowID: rowID, rowType: rowType,
                           rawContent: rest, jsonPreview: preview)
    }

    private static func previewFlightJSON(_ text: String) -> String {
        let truncated = text.count > 400 ? String(text.prefix(400)) + "…" : text
        return decodeFRefs(truncated)
    }

    static func decodeFRefs(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\"$\"", with: "\"<element>\"")
        s = s.replacingOccurrences(of: "\"$S\"", with: "\"<Suspense>\"")
        s = s.replacingOccurrences(of: "\"$undefined\"", with: "undefined")
        s = s.replacingOccurrences(of: "\"$infinity\"", with: "Infinity")
        s = s.replacingOccurrences(of: "\"$NaN\"", with: "NaN")
        return s
    }


    static func parseHydrationDiff(_ message: String) -> FWHydrationDiff? {
        let lower = message.lowercased()
        guard lower.contains("hydration") || lower.contains("did not match") || lower.contains("server") && lower.contains("client") else {
            return nil
        }
        var diff = FWHydrationDiff(summary: shortSentence(message), rawMessage: message)

        // React 18 format: contains "Server:" and "Client:" headings
        if let sr = message.range(of: "Server:"), let cr = message.range(of: "Client:") {
            let serverStart = message.index(after: sr.upperBound)
            let serverEnd = cr.lowerBound
            if serverStart < serverEnd {
                diff.serverTree = message[serverStart..<serverEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            diff.clientTree = String(message[message.index(after: cr.upperBound)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            diff.reactVersion = 18
        }

        if lower.contains("in the client rendering") {
            diff.reactVersion = 19
        }

        return diff
    }

    private static func shortSentence(_ text: String) -> String {
        let s = text.components(separatedBy: ".").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }

    static func parseNextRouteTree(_ json: Any?) -> [FWRoute] {
        var routes: [FWRoute] = []
        walkRouteNode(json, prefix: "", routes: &routes)
        var seen = Set<String>()
        return routes.filter { seen.insert($0.id).inserted }
    }

    private static func walkRouteNode(_ node: Any?, prefix: String, routes: inout [FWRoute]) {
        guard let arr = node as? [Any], !arr.isEmpty else { return }
        let segment = arr[0] as? String ?? ""
        let isPage = segment == "__PAGE__" || segment == "__DEFAULT__"
        let newPrefix: String
        if isPage || segment.isEmpty {
            newPrefix = prefix.isEmpty ? "/" : prefix
        } else if segment.hasPrefix("(") && segment.hasSuffix(")") {
            // Route group – transparent in URL
            newPrefix = prefix
        } else {
            newPrefix = prefix + "/" + segment
        }
        if isPage {
            let path = newPrefix.isEmpty ? "/" : newPrefix
            let id = arr.count >= 3 ? (arr[2] as? String ?? path) : path
            routes.append(FWRoute(id: id, path: path,
                                  isDynamic: path.contains("["), source: "next-app-router"))
        }
        if arr.count >= 2, let parallel = arr[1] as? [String: Any] {
            for (_, child) in parallel {
                walkRouteNode(child, prefix: newPrefix, routes: &routes)
            }
        }
    }

    static func buildJSONPath(_ components: [String]) -> String {
        if components.isEmpty { return "$" }
        var path = "$"
        for part in components {
            if Int(part) != nil {
                path += "[\(part)]"
            } else if part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == " " }), !part.isEmpty {
                path += ".\(part)"
            } else {
                let escaped = part.replacingOccurrences(of: "\"", with: "\\\"")
                path += "[\"\(escaped)\"]"
            }
        }
        return path
    }

    /// Handles "file.tsx:12:3", webpack:// and vite /@fs paths via OrbitInspectEditorPaths.
    static func normalizeSourcePath(_ rawPath: String) -> (file: String, line: Int?, col: Int?) {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Take the :line:col suffix before the query, since Vite writes "App.tsx?t=1234:5:2".
        var line: Int?
        var col: Int?
        let parts = path.components(separatedBy: ":")
        if parts.count >= 3, let c = Int(parts[parts.count - 1]), let l = Int(parts[parts.count - 2]) {
            col = c; line = l
            path = parts.dropLast(2).joined(separator: ":")
        } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
            line = l
            path = parts.dropLast().joined(separator: ":")
        }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }

        let resolved = OrbitInspectEditorPaths.resolve(path)
        let file = resolved.absolute ?? resolved.relatives.first ?? path
        return (file: file, line: line, col: col)
    }
}
