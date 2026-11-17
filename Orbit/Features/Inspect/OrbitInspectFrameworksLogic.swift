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
    /// Distinct class names seen on the page's elements (a sample, not every one).
    var classTokens: Set<String> = []
    /// First segment of every CSS custom property the page's stylesheets define: "tw" for --tw-ring-offset-width.
    var cssVariablePrefixes: Set<String> = []
}


enum FWCategory: String, Equatable, CaseIterable, Sendable {
    case framework = "Framework"
    case metaFramework = "Meta-framework"
    case buildTool = "Build & Dev"
    case styling = "Styling & UI"
    case hosting = "Hosting & CDN"
    case server = "Server"
    case library = "Library"
    case analytics = "Analytics & Monitoring"
    case cms = "CMS"

    var sortOrder: Int {
        switch self {
        case .framework: return 0
        case .metaFramework: return 1
        case .buildTool: return 2
        case .styling: return 3
        case .library: return 4
        case .analytics: return 5
        case .cms: return 6
        case .server: return 7
        case .hosting: return 8
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

        // Nuxt deletes window.__NUXT__ once it has hydrated, so useNuxtApp is the durable global.
        if e.globals.contains("__NUXT__") || e.globals.contains("$nuxt") || e.globals.contains("useNuxtApp") {
            var ev: [String] = []
            if e.globals.contains("__NUXT__") { ev.append("global __NUXT__") }
            if e.globals.contains("$nuxt") { ev.append("global $nuxt") }
            if e.globals.contains("useNuxtApp") { ev.append("global useNuxtApp") }
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
        } else if e.globals.contains("__astro_dev_toolbar__") {
            results.append(FWDetected(name: "Astro", version: e.globalVersions["__astro_dev_toolbar__.version"], category: .metaFramework,
                                      confidence: .certain, evidence: ["global __astro_dev_toolbar__"]))
        } else if e.scriptURLs.contains(where: { $0.contains("/_astro/") }) {
            results.append(FWDetected(name: "Astro", category: .metaFramework, confidence: .likely, evidence: ["script URL /_astro/"]))
        }

        // The real window globals are ___loader and ___emitter; ___gatsby is the id of the root element.
        if e.globals.contains("___gatsby") || e.globals.contains("___loader") || e.globals.contains("___emitter") {
            let key = ["___gatsby", "___loader", "___emitter"].first(where: { e.globals.contains($0) }) ?? "___loader"
            results.append(FWDetected(name: "Gatsby", category: .metaFramework, confidence: .certain, evidence: ["global \(key)"]))
        } else if e.domMarkers.contains("#___gatsby") {
            results.append(FWDetected(name: "Gatsby", category: .metaFramework, confidence: .likely, evidence: ["DOM #___gatsby"]))
        }

        if e.globals.contains("__reactRouterContext") || e.globals.contains("__reactRouterDataRouter") {
            let key = e.globals.contains("__reactRouterContext") ? "__reactRouterContext" : "__reactRouterDataRouter"
            results.append(FWDetected(name: "React Router", version: e.globalVersions["__reactRouterVersion"], category: .metaFramework,
                                      confidence: .certain, evidence: ["global \(key)"]))
        }

        if e.globals.contains("__STORYBOOK_PREVIEW__") {
            results.append(FWDetected(name: "Storybook", category: .buildTool, confidence: .certain, evidence: ["global __STORYBOOK_PREVIEW__"]))
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

        results.append(contentsOf: detectRenderingMarkers(evidence: e))
        results.append(contentsOf: detectStyling(evidence: e))
        results.append(contentsOf: detectLibraries(evidence: e))
        results.append(contentsOf: detectAnalytics(evidence: e))
        results.append(contentsOf: detectGenerators(evidence: e))
        results.append(contentsOf: detectInfrastructure(evidence: e))

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

    // MARK: - Rendering markers (frameworks that leave no global behind in a production build)

    static func detectRenderingMarkers(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let m = e.domMarkers

        // React 17+ keeps its fibre on every DOM node it renders, in development and production alike.
        if m.contains("react-fiber") || m.contains("react-container") {
            var ev: [String] = []
            if m.contains("react-fiber") { ev.append("DOM nodes carry a React fibre (__reactFiber$)") }
            if m.contains("react-container") { ev.append("root container carries __reactContainer$") }
            out.append(FWDetected(name: "React", version: e.globalVersions["React.version"], category: .framework, confidence: .certain, evidence: ev))
        }

        if m.contains("vue3-root") || m.contains("data-v-app") {
            var ev: [String] = []
            if m.contains("vue3-root") { ev.append("root container carries a Vue 3 vnode") }
            if m.contains("data-v-app") { ev.append("DOM attr data-v-app") }
            out.append(FWDetected(name: "Vue", version: e.globalVersions["Vue.version"], category: .framework, confidence: .certain, evidence: ev))
        } else if m.contains("vue2-root") {
            out.append(FWDetected(name: "Vue", version: e.globalVersions["Vue.version"], category: .framework, confidence: .certain, evidence: ["DOM node carries a Vue 2 instance (__vue__)"]))
        } else if m.contains("data-server-rendered") {
            out.append(FWDetected(name: "Vue", category: .framework, confidence: .likely, evidence: ["DOM attr data-server-rendered (Vue 2 SSR)"]))
        }

        if m.contains("preact-root") {
            out.append(FWDetected(name: "Preact", category: .framework, confidence: .certain, evidence: ["root container carries a Preact vnode tree"]))
        }

        let svelteScoped = e.classTokens.filter { matches($0, #"^svelte-[a-z0-9]{4,10}$"#) }
        if m.contains("svelte-meta") || svelteScoped.count >= 2 {
            var ev: [String] = []
            if m.contains("svelte-meta") { ev.append("DOM nodes carry __svelte_meta (development build)") }
            if svelteScoped.count >= 2 { ev.append("\(svelteScoped.count) scoped classes like \(svelteScoped.sorted().first ?? "svelte-xyz")") }
            out.append(FWDetected(name: "Svelte", version: e.globalVersions["svelte.version"], category: .framework,
                                  confidence: m.contains("svelte-meta") || svelteScoped.count >= 4 ? .certain : .likely, evidence: ev))
        }

        if m.contains("ngcontent") || m.contains("ng-reflect") {
            out.append(FWDetected(name: "Angular", version: e.globalVersions["ng.version.full"], category: .framework, confidence: .likely,
                                  evidence: [m.contains("ngcontent") ? "DOM attrs _ngcontent-* / _nghost-*" : "DOM attrs ng-reflect-*"]))
        }

        if e.globals.contains("angular"), let v = e.globalVersions["angular.version.full"] {
            out.append(FWDetected(name: "AngularJS", version: v, category: .framework, confidence: .certain, evidence: ["global angular \(v)"]))
        }

        if m.contains("data-hk") {
            out.append(FWDetected(name: "Solid", category: .framework, confidence: .likely, evidence: ["DOM attr data-hk (hydration keys)"]))
        }

        if e.globals.contains("Ember") || e.classTokens.contains("ember-view") {
            out.append(FWDetected(name: "Ember", version: e.globalVersions["Ember.VERSION"], category: .framework,
                                  confidence: e.globals.contains("Ember") ? .certain : .likely,
                                  evidence: [e.globals.contains("Ember") ? "global Ember" : "class ember-view"]))
        }

        if m.contains("data-page") && (m.contains("#app") || e.scriptURLs.contains(where: { $0.lowercased().contains("inertia") })) {
            out.append(FWDetected(name: "Inertia.js", category: .metaFramework, confidence: .likely, evidence: ["DOM attr data-page on the app root"]))
        }

        if e.globals.contains("Turbo") || m.contains("turbo-frame") {
            out.append(FWDetected(name: "Hotwire Turbo", category: .library, confidence: .certain, evidence: [e.globals.contains("Turbo") ? "global Turbo" : "custom element <turbo-frame>"]))
        }
        if m.contains("data-controller") {
            out.append(FWDetected(name: "Stimulus", category: .library, confidence: .likely, evidence: ["DOM attr data-controller"]))
        }
        if e.globals.contains("Livewire") || m.contains("wire:id") {
            out.append(FWDetected(name: "Livewire", category: .library, confidence: .certain, evidence: [e.globals.contains("Livewire") ? "global Livewire" : "DOM attr wire:id"]))
        }
        if m.contains("lit-element") || e.globals.contains("litHtmlVersions") {
            out.append(FWDetected(name: "Lit", category: .library, confidence: .certain, evidence: ["lit-html / LitElement present"]))
        }
        return out
    }

    // MARK: - Styling and UI kits

    /// Tailwind utility shapes, matched against a class name with any variant prefix (md:, hover:, dark:) removed.
    private static let tailwindUtility: NSRegularExpression? = {
        let scale = #"(?:\d+(?:\.\d+)?|px|auto|full|screen|min|max|fit|\[[^\]]+\])"#
        let pattern = "^(?:"
            + #"-?(?:m|p)[trblxyse]?-"# + scale
            + #"|(?:w|h|min-w|min-h|max-w|max-h|size)-(?:\d+(?:\.\d+)?(?:/\d+)?|full|screen|auto|min|max|fit|px|xs|sm|md|lg|xl|[2-7]xl|prose|\[[^\]]+\])"#
            + #"|text-(?:xs|sm|base|lg|xl|[2-9]xl)"#
            + #"|(?:bg|text|border|ring|from|to|via|fill|stroke|divide|outline|accent|caret|decoration|shadow|placeholder)-(?:[a-z]+-(?:50|100|200|300|400|500|600|700|800|900|950)|white|black|transparent|current)(?:/\d+)?"#
            + #"|rounded(?:-(?:[trbl]|tl|tr|bl|br|s|e))?(?:-(?:none|sm|md|lg|xl|2xl|3xl|full))?"#
            + #"|(?:flex|inline-flex)(?:-(?:row|col|wrap|nowrap|1|auto|none|grow|shrink))?"#
            + #"|grid-(?:cols|rows)-\d+|col-span-\d+|row-span-\d+|order-\d+"#
            + #"|gap-(?:[xy]-)?\d+(?:\.\d+)?|space-[xy]-\d+(?:\.\d+)?"#
            + #"|items-(?:start|end|center|baseline|stretch)|justify-(?:start|end|center|between|around|evenly)|self-(?:auto|start|end|center|stretch)"#
            + #"|font-(?:thin|extralight|light|normal|medium|semibold|bold|extrabold|black)"#
            + #"|leading-(?:none|tight|snug|normal|relaxed|loose|\d+)|tracking-(?:tighter|tight|normal|wide|wider|widest)"#
            + #"|z-(?:\d+|auto)|opacity-\d+|duration-\d+|ease-(?:linear|in|out|in-out)"#
            + #"|overflow-(?:x-|y-)?(?:hidden|auto|scroll|visible)|(?:top|right|bottom|left|inset|inset-x|inset-y)-"# + scale
            + #"|aspect-(?:square|video|auto)|animate-(?:spin|ping|pulse|bounce)|backdrop-blur(?:-\w+)?|sr-only|not-sr-only|line-clamp-\d+"#
            + ")$"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let tailwindVariants: Set<String> = [
        "sm", "md", "lg", "xl", "2xl", "hover", "focus", "active", "dark", "group-hover", "peer", "disabled", "first", "last", "odd",
        "even", "focus-visible", "focus-within", "placeholder", "motion-reduce", "motion-safe", "print", "max-sm", "max-md", "max-lg",
        "visited", "checked", "empty", "group-focus", "aria-selected", "data-[state=open]", "rtl", "ltr",
    ]

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Distinct class names that read as Tailwind utilities. A name with a number, a fraction, an arbitrary value or a variant prefix
    /// ("px-4", "w-1/2", "md:flex") is strong evidence; bare words like "flex" or "hidden" are only counted when a strong one is present.
    static func tailwindEvidence(classTokens: Set<String>) -> (strong: [String], total: Int) {
        guard let regex = tailwindUtility else { return ([], 0) }
        var strong: [String] = []
        var total = 0
        for token in classTokens {
            var base = token
            var hasVariant = false
            if let colon = token.lastIndex(of: ":") {
                let prefix = String(token[token.startIndex..<colon])
                let parts = prefix.split(separator: ":").map(String.init)
                if !parts.isEmpty, parts.allSatisfy({ tailwindVariants.contains($0) || $0.hasPrefix("[") || $0.hasPrefix("group-") || $0.hasPrefix("peer-") }) {
                    hasVariant = true
                    base = String(token[token.index(after: colon)...])
                } else {
                    continue
                }
            }
            let range = NSRange(base.startIndex..., in: base)
            guard regex.firstMatch(in: base, range: range) != nil else { continue }
            total += 1
            let hasScale = base.contains("-") && (base.rangeOfCharacter(from: .decimalDigits) != nil || base.contains("["))
            if hasVariant || hasScale { strong.append(token) }
        }
        return (strong.sorted(), total)
    }

    private static func tokens(_ e: FWEvidenceBundle, withPrefix prefix: String) -> [String] {
        e.classTokens.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private static func anyURL(_ e: FWEvidenceBundle, containing needles: [String]) -> String? {
        let all = e.scriptURLs + e.linkURLs
        for url in all {
            let lower = url.lowercased()
            if needles.contains(where: { lower.contains($0) }) { return url }
        }
        return nil
    }

    private static func shortURL(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return String(url.prefix(60)) }
        return host + u.path
    }

    static func detectStyling(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let prefixes = e.cssVariablePrefixes
        let m = e.domMarkers

        // Tailwind
        let tw = tailwindEvidence(classTokens: e.classTokens)
        let twCDN = anyURL(e, containing: ["cdn.tailwindcss.com", "tailwindcss"])
        let twVars = prefixes.contains("tw")
        var twEvidence: [String] = []
        if twVars { twEvidence.append("CSS custom properties --tw-* in the page's stylesheets") }
        if let twCDN { twEvidence.append("loads \(shortURL(twCDN))") }
        if tw.strong.count >= 4 {
            twEvidence.append("\(tw.strong.count) utility classes, e.g. \(tw.strong.prefix(5).joined(separator: ", "))")
        }
        let twConfidence: FWConfidence? = {
            if twVars || twCDN != nil { return .certain }
            if tw.strong.count >= 8 { return .likely }
            if tw.strong.count >= 4 { return .possible }
            return nil
        }()
        var tailwindPresent = false
        if let twConfidence {
            tailwindPresent = twConfidence >= .likely
            var version: String? = nil
            if let twCDN, let v = firstVersion(in: twCDN) { version = v }
            out.append(FWDetected(name: "Tailwind CSS", version: version, category: .styling, confidence: twConfidence, evidence: twEvidence))
        }

        // Bootstrap
        let bsURL = anyURL(e, containing: ["bootstrap"])
        let bsGrid = e.classTokens.contains("row") && e.classTokens.contains(where: { matches($0, #"^col(?:-(?:sm|md|lg|xl|xxl))?(?:-\d{1,2})?$"#) })
        let bsButtons = e.classTokens.contains("btn") && e.classTokens.contains(where: { matches($0, #"^btn-(?:primary|secondary|success|danger|warning|info|light|dark|outline-\w+)$"#) })
        let bsComponents = ["navbar", "navbar-expand-lg", "card-body", "modal-dialog", "form-control", "container-fluid"].filter { e.classTokens.contains($0) }
        if prefixes.contains("bs") || bsURL != nil || e.globals.contains("bootstrap") || ((bsGrid || bsButtons) && bsComponents.count >= 1 && !tailwindPresent) {
            var ev: [String] = []
            if prefixes.contains("bs") { ev.append("CSS custom properties --bs-*") }
            if let bsURL { ev.append("loads \(shortURL(bsURL))") }
            if e.globals.contains("bootstrap") { ev.append("global bootstrap") }
            if bsGrid || bsButtons { ev.append("grid/button classes (row, col-*, btn-*)") }
            if !bsComponents.isEmpty { ev.append("component classes: \(bsComponents.prefix(4).joined(separator: ", "))") }
            let strong = prefixes.contains("bs") || bsURL != nil || e.globals.contains("bootstrap")
            out.append(FWDetected(name: "Bootstrap", version: e.globalVersions["bootstrap.version"] ?? bsURL.flatMap { firstVersion(in: $0) },
                                  category: .styling, confidence: strong ? .certain : .likely, evidence: ev))
        }

        // Component libraries identified by their own class or variable prefix.
        let kits: [(name: String, tokenPrefix: String, varPrefix: String?, minTokens: Int)] = [
            ("Material UI", "Mui", "mui", 3),
            ("Chakra UI", "chakra-", "chakra", 2),
            ("Ant Design", "ant-", "ant", 3),
            ("Mantine", "mantine-", "mantine", 2),
            ("UIkit", "uk-", nil, 4),
            ("Radix Themes", "rt-", nil, 4),
            ("Element Plus", "el-", "el", 4),
            ("Fluent UI", "fui-", nil, 3),
            ("Carbon Design System", "cds--", nil, 2),
            ("Blueprint", "bp5-", nil, 2),
            ("NextUI / HeroUI", "nextui-", nil, 2),
        ]
        for kit in kits {
            let tokenHits = tokens(e, withPrefix: kit.tokenPrefix)
            let varHit = kit.varPrefix.map { prefixes.contains($0) } ?? false
            guard tokenHits.count >= kit.minTokens || varHit else { continue }
            var ev: [String] = []
            if !tokenHits.isEmpty { ev.append("\(tokenHits.count) classes like \(tokenHits.prefix(3).joined(separator: ", "))") }
            if varHit, let vp = kit.varPrefix { ev.append("CSS custom properties --\(vp)-*") }
            out.append(FWDetected(name: kit.name, category: .styling, confidence: tokenHits.count >= kit.minTokens * 2 || varHit ? .certain : .likely, evidence: ev))
        }
        if e.classTokens.contains("columns") && e.classTokens.contains("column") && (anyURL(e, containing: ["bulma"]) != nil || e.classTokens.contains(where: { $0.hasPrefix("is-") })) {
            out.append(FWDetected(name: "Bulma", category: .styling, confidence: anyURL(e, containing: ["bulma"]) != nil ? .certain : .likely, evidence: ["classes columns/column and is-* modifiers"]))
        }
        if let v = anyURL(e, containing: ["foundation.min", "foundation-sites", "/foundation."]) {
            out.append(FWDetected(name: "Foundation", category: .styling, confidence: .likely, evidence: ["loads \(shortURL(v))"]))
        } else if e.classTokens.contains("grid-x") && e.classTokens.contains("cell") {
            out.append(FWDetected(name: "Foundation", category: .styling, confidence: .likely, evidence: ["classes grid-x / cell"]))
        }
        if e.classTokens.contains("v-application") || e.classTokens.contains("v-btn") || e.classTokens.contains("v-card") {
            out.append(FWDetected(name: "Vuetify", category: .styling, confidence: .certain, evidence: ["classes v-application / v-btn / v-card"]))
        }
        if anyURL(e, containing: ["materialize"]) != nil || e.classTokens.contains("waves-effect") {
            out.append(FWDetected(name: "Materialize", category: .styling, confidence: .likely, evidence: ["materialize asset or waves-effect class"]))
        }
        if let v = anyURL(e, containing: ["semantic.min", "semantic-ui", "fomantic"]) {
            out.append(FWDetected(name: "Semantic UI", category: .styling, confidence: .likely, evidence: ["loads \(shortURL(v))"]))
        }
        if anyURL(e, containing: ["picocss", "pico.min", "/pico."]) != nil {
            out.append(FWDetected(name: "Pico CSS", category: .styling, confidence: .likely, evidence: ["loads a Pico stylesheet"]))
        }
        if anyURL(e, containing: ["tachyons"]) != nil {
            out.append(FWDetected(name: "Tachyons", category: .styling, confidence: .likely, evidence: ["loads a Tachyons stylesheet"]))
        }

        // Radix primitives and the shadcn/ui convention built on them.
        let radix = m.contains("data-radix") || prefixes.contains("radix")
        if radix {
            out.append(FWDetected(name: "Radix UI", category: .styling, confidence: .certain,
                                  evidence: [m.contains("data-radix") ? "DOM attrs data-radix-*" : "CSS custom properties --radix-*"]))
        }
        let shadcnVars: Set<String> = ["background", "foreground", "primary", "radius", "muted", "accent", "border", "ring"]
        if tailwindPresent, shadcnVars.isSubset(of: prefixes) || (radix && shadcnVars.intersection(prefixes).count >= 5) {
            out.append(FWDetected(name: "shadcn/ui", category: .styling, confidence: radix ? .likely : .possible,
                                  evidence: ["Tailwind with the shadcn theme variables (--background, --foreground, --primary, --radius ...)" + (radix ? " and Radix primitives" : "")]))
        }
        let daisyComponents = e.classTokens.contains(where: { matches($0, #"^(?:btn-(?:primary|secondary|accent|ghost|neutral)|card-body|modal-box|drawer-content|navbar-start|badge-\w+)$"#) })
        if tailwindPresent, e.classTokens.contains("btn"), daisyComponents || m.contains("data-theme") {
            out.append(FWDetected(name: "daisyUI", category: .styling, confidence: .likely, evidence: ["Tailwind with daisyUI component classes (btn, card-body, modal-box ...)"]))
        }
        if prefixes.contains("un") {
            out.append(FWDetected(name: "UnoCSS", category: .styling, confidence: .certain, evidence: ["CSS custom properties --un-*"]))
        }
        if prefixes.contains("windi") {
            out.append(FWDetected(name: "Windi CSS", category: .styling, confidence: .certain, evidence: ["CSS custom properties --windi-*"]))
        }

        // CSS-in-JS and scoped-style conventions.
        let scClasses = e.classTokens.filter { matches($0, #"^sc-[A-Za-z]{5,8}$"#) }
        if m.contains("data-styled") || scClasses.count >= 3 {
            out.append(FWDetected(name: "styled-components", category: .styling, confidence: m.contains("data-styled") ? .certain : .likely,
                                  evidence: [m.contains("data-styled") ? "style tag data-styled" : "\(scClasses.count) classes like \(scClasses.sorted().first ?? "sc-abc")"]))
        }
        let emotionClasses = e.classTokens.filter { matches($0, #"^css-[a-z0-9]{5,9}(?:-[A-Za-z0-9]+)?$"#) }
        if m.contains("data-emotion") || emotionClasses.count >= 3 {
            out.append(FWDetected(name: "Emotion", category: .styling, confidence: m.contains("data-emotion") ? .certain : .likely,
                                  evidence: [m.contains("data-emotion") ? "style tag data-emotion" : "\(emotionClasses.count) classes like \(emotionClasses.sorted().first ?? "css-abc123")"]))
        }
        let jsxScoped = e.classTokens.filter { matches($0, #"^jsx-\d{6,12}$"#) }
        if jsxScoped.count >= 2 {
            out.append(FWDetected(name: "styled-jsx", category: .styling, confidence: .certain, evidence: ["\(jsxScoped.count) classes like \(jsxScoped.sorted().first ?? "jsx-123456")"]))
        }
        let cssModules = e.classTokens.filter { matches($0, #"^[A-Za-z][A-Za-z0-9]*_[A-Za-z][A-Za-z0-9-]*__[A-Za-z0-9_-]{4,8}$"#) || matches($0, #"^[a-z][A-Za-z0-9-]*_[a-z][A-Za-z0-9-]*_{1,3}[A-Za-z0-9_-]{5,8}$"#) }
        if cssModules.count >= 4, !tailwindPresent || cssModules.count >= 10 {
            out.append(FWDetected(name: "CSS Modules", category: .styling, confidence: .likely,
                                  evidence: ["\(cssModules.count) hashed local class names like \(cssModules.sorted().first ?? "Button_root__x1y2z")"]))
        }
        if m.contains("data-vite-dev-id") {
            out.append(FWDetected(name: "Vite", category: .buildTool, confidence: .certain, evidence: ["dev style tags with data-vite-dev-id"]))
        }
        if m.contains("data-astro-cid") {
            out.append(FWDetected(name: "Astro", category: .metaFramework, confidence: .likely, evidence: ["scoped style attribute data-astro-cid-*"]))
        }

        // Icons, fonts and motion.
        let faClasses = e.classTokens.filter { ["fa", "fas", "far", "fab", "fal", "fad", "fa-solid", "fa-regular", "fa-brands", "fa-light"].contains($0) }
        if let fa = anyURL(e, containing: ["fontawesome", "font-awesome", "kit.fontawesome"]) {
            out.append(FWDetected(name: "Font Awesome", category: .styling, confidence: .certain, evidence: ["loads \(shortURL(fa))"]))
        } else if !faClasses.isEmpty {
            out.append(FWDetected(name: "Font Awesome", category: .styling, confidence: .likely, evidence: ["icon classes \(faClasses.sorted().prefix(3).joined(separator: ", "))"]))
        }
        if e.classTokens.contains("material-icons") || e.classTokens.contains("material-symbols-outlined") || e.classTokens.contains("material-symbols-rounded") {
            out.append(FWDetected(name: "Material Icons", category: .styling, confidence: .certain, evidence: ["class material-icons / material-symbols-*"]))
        }
        if !tokens(e, withPrefix: "bi-").isEmpty && e.classTokens.contains("bi") {
            out.append(FWDetected(name: "Bootstrap Icons", category: .styling, confidence: .likely, evidence: ["classes bi, bi-*"]))
        }
        if e.classTokens.contains("lucide") || e.classTokens.contains(where: { $0.hasPrefix("lucide-") }) {
            out.append(FWDetected(name: "Lucide", category: .styling, confidence: .likely, evidence: ["svg classes lucide, lucide-*"]))
        }
        if e.classTokens.contains(where: { $0.hasPrefix("animate__") }) {
            out.append(FWDetected(name: "Animate.css", category: .styling, confidence: .certain, evidence: ["classes animate__*"]))
        }
        if m.contains("data-aos") {
            out.append(FWDetected(name: "AOS", category: .styling, confidence: .likely, evidence: ["DOM attr data-aos"]))
        }
        if let gf = anyURL(e, containing: ["fonts.googleapis.com", "fonts.gstatic.com"]) {
            out.append(FWDetected(name: "Google Fonts", category: .styling, confidence: .certain, evidence: ["loads \(shortURL(gf))"]))
        }
        if let tk = anyURL(e, containing: ["use.typekit.net", "fonts.adobe.com"]) {
            out.append(FWDetected(name: "Adobe Fonts", category: .styling, confidence: .certain, evidence: ["loads \(shortURL(tk))"]))
        }
        return out
    }

    // MARK: - Libraries

    static func detectLibraries(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let g = e.globals
        // strict: a short global ("L", "ko") is only believed when its version probe answered too.
        func lib(_ name: String, global: String, versionKey: String? = nil, urls: [String] = [], strict: Bool = false, category: FWCategory = .library) {
            let version = versionKey.flatMap { e.globalVersions[$0] }
            if g.contains(global), !strict || version != nil {
                out.append(FWDetected(name: name, version: version, category: category, confidence: .certain, evidence: ["global \(global)"]))
            } else if let u = anyURL(e, containing: urls), !urls.isEmpty {
                out.append(FWDetected(name: name, version: firstVersion(in: u), category: category, confidence: .likely, evidence: ["loads \(shortURL(u))"]))
            }
        }
        // `_` is lodash or underscore; the version string does not say which, the presence of a lodash-only name does.
        if g.contains("_"), let v = e.globalVersions["_.VERSION"] {
            let isLodash = e.globals.contains("__lodash") || (anyURL(e, containing: ["lodash"]) != nil)
            out.append(FWDetected(name: isLodash ? "Lodash" : "Lodash / Underscore", version: v, category: .library, confidence: isLodash ? .certain : .likely, evidence: ["global _ \(v)"]))
        } else if let u = anyURL(e, containing: ["lodash"]) {
            out.append(FWDetected(name: "Lodash", version: firstVersion(in: u), category: .library, confidence: .likely, evidence: ["loads \(shortURL(u))"]))
        }
        lib("Moment.js", global: "moment", versionKey: "moment.version", urls: ["moment.min", "moment.js", "/moment@"])
        lib("D3", global: "d3", versionKey: "d3.version", urls: ["/d3.v", "d3.min", "/d3@"])
        lib("Three.js", global: "THREE", versionKey: "THREE.REVISION", urls: ["three.min", "three.module", "/three@"])
        lib("GSAP", global: "gsap", versionKey: "gsap.version", urls: ["gsap.min", "/gsap@", "tweenmax"])
        lib("Chart.js", global: "Chart", versionKey: "Chart.version", urls: ["chart.min", "chart.js", "/chart.js@"])
        lib("Leaflet", global: "L", versionKey: "L.version", urls: ["leaflet"], strict: true)
        lib("Mapbox GL", global: "mapboxgl", versionKey: "mapboxgl.version", urls: ["mapbox-gl"])
        lib("Backbone.js", global: "Backbone", versionKey: "Backbone.VERSION", urls: ["backbone"])
        lib("Knockout", global: "ko", versionKey: "ko.version", urls: ["knockout"], strict: true)
        lib("Stripe.js", global: "Stripe", urls: ["js.stripe.com"])
        lib("Firebase", global: "firebase", versionKey: "firebase.SDK_VERSION", urls: ["firebase", "gstatic.com/firebasejs"])
        lib("Modernizr", global: "Modernizr", urls: ["modernizr"])
        lib("Swiper", global: "Swiper", urls: ["swiper"])
        lib("Lottie", global: "lottie", urls: ["lottie"])
        lib("Socket.IO", global: "", urls: ["socket.io"])
        lib("Redux DevTools", global: "__REDUX_DEVTOOLS_EXTENSION__")
        if let u = anyURL(e, containing: ["cdn.jsdelivr.net"]) { out.append(FWDetected(name: "jsDelivr", category: .hosting, confidence: .likely, evidence: ["loads \(shortURL(u))"])) }
        if let u = anyURL(e, containing: ["unpkg.com"]) { out.append(FWDetected(name: "unpkg", category: .hosting, confidence: .likely, evidence: ["loads \(shortURL(u))"])) }
        if let u = anyURL(e, containing: ["cdnjs.cloudflare.com"]) { out.append(FWDetected(name: "cdnjs", category: .hosting, confidence: .likely, evidence: ["loads \(shortURL(u))"])) }
        return out
    }

    // MARK: - Analytics, monitoring and third-party widgets

    static func detectAnalytics(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let g = e.globals
        func tool(_ name: String, globals: [String] = [], urls: [String] = []) {
            var ev: [String] = []
            for global in globals where g.contains(global) { ev.append("global \(global)") }
            if let u = anyURL(e, containing: urls), !urls.isEmpty { ev.append("loads \(shortURL(u))") }
            guard !ev.isEmpty else { return }
            out.append(FWDetected(name: name, category: .analytics, confidence: ev.count > 1 ? .certain : .likely, evidence: ev))
        }
        tool("Google Analytics", globals: ["gtag", "_gaq", "GoogleAnalyticsObject"], urls: ["google-analytics.com", "googletagmanager.com/gtag/js", "/analytics.js"])
        tool("Google Tag Manager", globals: ["google_tag_manager"], urls: ["googletagmanager.com/gtm.js", "googletagmanager.com/ns.html"])
        tool("Meta Pixel", globals: ["fbq", "_fbq"], urls: ["connect.facebook.net"])
        tool("Hotjar", globals: ["hj", "_hjSettings"], urls: ["static.hotjar.com", "hotjar.com"])
        tool("Segment", globals: [], urls: ["cdn.segment.com", "segment.io"])
        tool("Mixpanel", globals: ["mixpanel"], urls: ["cdn.mxpnl.com", "mixpanel.com"])
        tool("Amplitude", globals: ["amplitude"], urls: ["amplitude.com"])
        tool("PostHog", globals: ["posthog"], urls: ["posthog.com", "us.i.posthog", "eu.i.posthog"])
        tool("Plausible", globals: ["plausible"], urls: ["plausible.io"])
        tool("Fathom", globals: ["fathom"], urls: ["usefathom.com"])
        tool("Matomo", globals: ["_paq", "Matomo"], urls: ["matomo", "piwik"])
        tool("Microsoft Clarity", globals: ["clarity"], urls: ["clarity.ms"])
        tool("Sentry", globals: ["Sentry", "__SENTRY__"], urls: ["sentry-cdn.com", "browser.sentry", "sentry.io"])
        tool("Datadog RUM", globals: ["DD_RUM", "DD_LOGS"], urls: ["datadoghq-browser-agent.com"])
        tool("New Relic", globals: ["NREUM", "newrelic"], urls: ["js-agent.newrelic.com", "nr-data.net"])
        tool("LogRocket", globals: ["LogRocket"], urls: ["logrocket"])
        tool("FullStory", globals: ["_fs_namespace"], urls: ["fullstory.com"])
        tool("Bugsnag", globals: ["Bugsnag"], urls: ["bugsnag"])
        tool("Rollbar", globals: ["Rollbar", "_rollbarConfig"], urls: ["rollbar"])
        tool("HubSpot", globals: ["_hsq", "hbspt"], urls: ["js.hs-scripts.com", "hubspot.com", "hs-analytics"])
        tool("Intercom", globals: ["Intercom"], urls: ["widget.intercom.io", "intercomcdn.com"])
        tool("Drift", globals: ["drift"], urls: ["js.driftt.com", "drift.com"])
        tool("Crisp", globals: ["$crisp"], urls: ["client.crisp.chat"])
        tool("Zendesk", globals: ["zE", "zESettings"], urls: ["static.zdassets.com", "zendesk"])
        tool("OneTrust", globals: ["OneTrust", "OptanonWrapper"], urls: ["onetrust.com", "cookielaw.org"])
        tool("Cookiebot", globals: ["Cookiebot"], urls: ["cookiebot.com"])
        tool("reCAPTCHA", globals: ["grecaptcha"], urls: ["google.com/recaptcha", "gstatic.com/recaptcha"])
        tool("hCaptcha", globals: ["hcaptcha"], urls: ["hcaptcha.com"])
        tool("Cloudflare Turnstile", globals: ["turnstile"], urls: ["challenges.cloudflare.com/turnstile"])
        return out
    }

    // MARK: - Generators (static site generators, site builders)

    static func detectGenerators(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let known: [(needle: String, name: String, category: FWCategory)] = [
            ("astro", "Astro", .metaFramework), ("gatsby", "Gatsby", .metaFramework), ("hugo", "Hugo", .metaFramework),
            ("jekyll", "Jekyll", .metaFramework), ("hexo", "Hexo", .metaFramework), ("eleventy", "Eleventy", .metaFramework),
            ("docusaurus", "Docusaurus", .metaFramework), ("vitepress", "VitePress", .metaFramework),
            ("vuepress", "VuePress", .metaFramework), ("nuxt", "Nuxt", .metaFramework), ("next.js", "Next.js", .metaFramework),
            ("mkdocs", "MkDocs", .metaFramework), ("sphinx", "Sphinx", .metaFramework), ("docsy", "Docsy", .metaFramework),
            ("webflow", "Webflow", .cms), ("framer", "Framer", .cms), ("squarespace", "Squarespace", .cms), ("wix", "Wix", .cms),
            ("ghost", "Ghost", .cms), ("drupal", "Drupal", .cms), ("joomla", "Joomla", .cms), ("typo3", "TYPO3", .cms),
            ("prestashop", "PrestaShop", .cms), ("magento", "Magento", .cms), ("bigcommerce", "BigCommerce", .cms),
            ("shopify", "Shopify", .cms), ("wordpress", "WordPress", .cms), ("elementor", "Elementor", .cms),
            ("divi", "Divi", .cms), ("hubspot", "HubSpot CMS", .cms), ("contentful", "Contentful", .cms),
        ]
        for generator in e.metaGenerators {
            let lower = generator.lowercased()
            for entry in known where lower.contains(entry.needle) {
                out.append(FWDetected(name: entry.name, version: extractVersion(from: generator), category: entry.category,
                                      confidence: .certain, evidence: ["meta generator: \(generator)"]))
            }
        }
        if e.domMarkers.contains("data-wf-site") || e.domMarkers.contains("data-wf-page") {
            out.append(FWDetected(name: "Webflow", category: .cms, confidence: .certain, evidence: ["DOM attrs data-wf-site / data-wf-page"]))
        }
        if e.globals.contains("Shopify") {
            out.append(FWDetected(name: "Shopify", category: .cms, confidence: .certain, evidence: ["global Shopify"]))
        }
        if e.classTokens.contains(where: { $0.hasPrefix("wp-block-") }) || e.classTokens.contains("wp-site-blocks") {
            out.append(FWDetected(name: "WordPress", category: .cms, confidence: .likely, evidence: ["block editor classes wp-block-*"]))
        }
        return out
    }

    // MARK: - Servers and hosting, from response headers

    static func detectInfrastructure(evidence e: FWEvidenceBundle) -> [FWDetected] {
        var out: [FWDetected] = []
        let h = Dictionary(uniqueKeysWithValues: e.responseHeaders.map { ($0.key.lowercased(), $0.value) })

        if let server = h["server"], !server.isEmpty {
            let lower = server.lowercased()
            let servers: [(needle: String, name: String)] = [
                ("nginx", "nginx"), ("apache", "Apache"), ("caddy", "Caddy"), ("litespeed", "LiteSpeed"), ("microsoft-iis", "IIS"),
                ("openresty", "OpenResty"), ("envoy", "Envoy"), ("gunicorn", "Gunicorn"), ("uvicorn", "Uvicorn"), ("kestrel", "Kestrel"),
                ("cowboy", "Cowboy"), ("jetty", "Jetty"), ("tomcat", "Tomcat"), ("werkzeug", "Werkzeug"), ("deno", "Deno"),
            ]
            for entry in servers where lower.contains(entry.needle) {
                out.append(FWDetected(name: entry.name, version: extractVersion(from: server), category: .server, confidence: .certain, evidence: ["response header server: \(server)"]))
            }
            let hosts: [(needle: String, name: String)] = [
                ("cloudflare", "Cloudflare"), ("netlify", "Netlify"), ("vercel", "Vercel"), ("amazons3", "Amazon S3"),
                ("cloudfront", "Amazon CloudFront"), ("github.com", "GitHub Pages"), ("gws", "Google Web Server"),
                ("akamaighost", "Akamai"), ("fly.io", "Fly.io"), ("render", "Render"),
            ]
            for entry in hosts where lower.contains(entry.needle) {
                out.append(FWDetected(name: entry.name, category: .hosting, confidence: .certain, evidence: ["response header server: \(server)"]))
            }
        }
        if let via = h["via"]?.lowercased(), via.contains("cloudfront") {
            out.append(FWDetected(name: "Amazon CloudFront", category: .hosting, confidence: .certain, evidence: ["response header via: \(h["via"] ?? "")"]))
        }
        if h["x-github-request-id"] != nil {
            out.append(FWDetected(name: "GitHub Pages", category: .hosting, confidence: .certain, evidence: ["response header x-github-request-id"]))
        }
        if let served = h["x-served-by"], served.lowercased().contains("cache") {
            out.append(FWDetected(name: "Fastly", category: .hosting, confidence: .likely, evidence: ["response header x-served-by: \(served)"]))
        }
        if h["fly-request-id"] != nil {
            out.append(FWDetected(name: "Fly.io", category: .hosting, confidence: .certain, evidence: ["response header fly-request-id"]))
        }
        if h["x-azure-ref"] != nil || h["x-ms-request-id"] != nil {
            out.append(FWDetected(name: "Microsoft Azure", category: .hosting, confidence: .likely, evidence: ["response header x-azure-ref / x-ms-request-id"]))
        }
        if h.keys.contains(where: { $0.hasPrefix("x-goog-") }) {
            out.append(FWDetected(name: "Google Cloud", category: .hosting, confidence: .likely, evidence: ["response header x-goog-*"]))
        }
        if h["x-render-origin-server"] != nil {
            out.append(FWDetected(name: "Render", category: .hosting, confidence: .certain, evidence: ["response header x-render-origin-server"]))
        }
        if h.keys.contains(where: { $0.hasPrefix("x-railway") }) {
            out.append(FWDetected(name: "Railway", category: .hosting, confidence: .certain, evidence: ["response header x-railway-*"]))
        }
        if let poweredBy = h["x-powered-by"], poweredBy.lowercased().contains("next.js") {
            out.append(FWDetected(name: "Next.js", version: extractVersion(from: poweredBy), category: .metaFramework, confidence: .certain, evidence: ["response header x-powered-by: \(poweredBy)"]))
        }
        if let poweredBy = h["x-powered-by"], poweredBy.lowercased().contains("nuxt") {
            out.append(FWDetected(name: "Nuxt", category: .metaFramework, confidence: .certain, evidence: ["response header x-powered-by: \(poweredBy)"]))
        }
        if let cdn = h["x-cdn"] ?? h["x-cache-provider"] {
            out.append(FWDetected(name: cdn, category: .hosting, confidence: .possible, evidence: ["response header x-cdn: \(cdn)"]))
        }
        return out
    }

    /// The first "1.2.3"-shaped version in a URL such as ".../tailwindcss@3.4.1/..." or ".../bootstrap/5.3.2/...".
    static func firstVersion(in url: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:[@/\-v])(\d+\.\d+(?:\.\d+)?)(?=[/\-.@?]|$)"#) else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range), let r = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[r])
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


// MARK: - Dev server control surface

/// Everything below is pure: the page script reports observations (sockets, frames, signals) and these types decide
/// what they mean. Adding a framework is a row in `FWDevAdapters.all`, plus a decoder only if its wire format is new.

enum FWBundler: String, Equatable, Sendable {
    case webpack, turbopack, vite, esbuild, rspack, parcel, unknown

    var title: String {
        switch self {
        case .webpack: return "webpack"
        case .turbopack: return "Turbopack"
        case .vite: return "Vite"
        case .esbuild: return "esbuild"
        case .rspack: return "Rspack"
        case .parcel: return "Parcel"
        case .unknown: return "Unknown"
        }
    }
}

/// The wire formats an HMR socket can speak. One protocol can serve several frameworks (Vite serves Nuxt, Astro, SvelteKit ...).
enum FWWireProtocol: String, Equatable, Sendable, CaseIterable {
    case next
    case vite
    case webpackDevServer
    case webpackHotMiddleware
    case parcel
    case rsbuild
    case remixLiveReload
    case liveReload
    case storybookChannel

    var title: String {
        switch self {
        case .next: return "Next.js HMR"
        case .vite: return "Vite HMR"
        case .webpackDevServer: return "webpack-dev-server"
        case .webpackHotMiddleware: return "webpack-hot-middleware"
        case .parcel: return "Parcel HMR"
        case .rsbuild: return "Rsbuild HMR"
        case .remixLiveReload: return "Remix live reload"
        case .liveReload: return "LiveReload"
        case .storybookChannel: return "Storybook channel"
        }
    }

    /// The bundler a socket of this protocol implies when nothing more specific is known.
    var impliedBundler: FWBundler {
        switch self {
        case .next: return .unknown
        case .vite: return .vite
        case .webpackDevServer, .webpackHotMiddleware: return .webpack
        case .parcel: return .parcel
        case .rsbuild: return .rspack
        case .remixLiveReload: return .esbuild
        case .liveReload, .storybookChannel: return .unknown
        }
    }

    /// Bundlers that frequently serve this protocol; used to flag a socket that contradicts the detected framework.
    var compatibleBundlers: [FWBundler] {
        switch self {
        case .next: return [.webpack, .turbopack, .rspack]
        case .vite: return [.vite, .esbuild]
        case .webpackDevServer, .webpackHotMiddleware: return [.webpack, .rspack]
        case .parcel: return [.parcel]
        case .rsbuild: return [.rspack]
        case .remixLiveReload: return [.esbuild]
        case .liveReload, .storybookChannel: return []
        }
    }
}

/// Names the page script uses for what it observed. The strings are the wire contract with OrbitInspectFrameworksJS.
enum FWSignal: String, Sendable, CaseIterable {
    case nextApp = "next.app"
    case nextPages = "next.pages"
    case nextRouterPush = "next.router.push"
    case nextRouterReplace = "next.router.replace"
    case nextRouterRefresh = "next.router.refresh"
    case nextRouterHmrRefresh = "next.router.hmrRefresh"
    case nextDevGlobal = "next.nd"
    case nextPortal = "next.portal"
    case nextDevBuildID = "next.devBuildId"
    case nextTurbopack = "next.turbopack"
    case viteClient = "vite.client"
    case webpackHMR = "webpack.hmr"
    case whmReporter = "whm.reporter"
    case reactDev = "react.dev"
    case reactProd = "react.prod"
    case sveltekitDev = "sveltekit.dev"
    case angularDev = "angular.dev"
    case routerDataRouter = "rr.dataRouter"
    case nuxtApp = "nuxt.app"
    case astroToolbar = "astro.toolbar"
    case gatsbyNavigate = "gatsby.navigate"
    case gatsbyLoader = "gatsby.loader"
    case storybookPreview = "storybook.preview"
    case qwikDev = "qwik.dev"
    case angularRouter = "angular.router"
    case draftModeCookie = "draft.cookie"
}

enum FWDevControl: String, CaseIterable, Identifiable, Sendable {
    case reload
    case hardReload
    case clearCaches
    case softRefresh
    case hmrRefresh
    case toggleOverlay
    case restartServer
    case restartClearCache
    case rebuild
    case refreshSourceData
    case exitDraftMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reload: return "Reload"
        case .hardReload: return "Hard reload"
        case .clearCaches: return "Clear caches"
        case .softRefresh: return "Refresh data"
        case .hmrRefresh: return "Server refresh"
        case .toggleOverlay: return "Overlay"
        case .restartServer: return "Restart server"
        case .restartClearCache: return "Restart, clear cache"
        case .rebuild: return "Rebuild"
        case .refreshSourceData: return "Refresh sources"
        case .exitDraftMode: return "Exit draft mode"
        }
    }

    var symbol: String {
        switch self {
        case .reload: return "arrow.clockwise"
        case .hardReload: return "arrow.clockwise.circle"
        case .clearCaches: return "trash"
        case .softRefresh: return "arrow.triangle.2.circlepath"
        case .hmrRefresh: return "bolt"
        case .toggleOverlay: return "rectangle.on.rectangle"
        case .restartServer: return "power"
        case .restartClearCache: return "externaldrive.badge.xmark"
        case .rebuild: return "hammer"
        case .refreshSourceData: return "cloud"
        case .exitDraftMode: return "eye.slash"
        }
    }
}

enum FWRefreshStrategy: String, Sendable {
    case nextAppRefresh = "next.app.refresh"
    case nextPagesReplace = "next.pages.replace"
    case routerRevalidate = "rr.revalidate"
    case nuxtRefreshData = "nuxt.refreshData"
    case storybookReRender = "storybook.forceReRender"
}

enum FWNavStrategy: String, Sendable {
    case nextRouter = "next.router.push"
    case routerNavigate = "rr.navigate"
    case nuxtRouter = "nuxt.router.push"
    case gatsbyNavigate = "gatsby.navigate"
    case angularRouter = "angular.router"
    /// A synthesised link click: client routers that delegate link handling (SvelteKit, Astro, Turbo) intercept it.
    case linkClick = "link.click"
}

enum FWEditorStyle: Equatable, Sendable {
    /// Next.js: GET /__nextjs_launch-editor?file=&line1=&column1=
    case nextLaunchEditor
    /// launch-editor-middleware as Vite mounts it: GET <prefix>/__open-in-editor?file=path:line:col
    case openInEditor(prefix: String)
    /// webpack-dev-server: GET /webpack-dev-server/open-editor?fileName= (no line or column)
    case webpackOpenEditor
    /// react-dev-utils and Gatsby: GET /__open-stack-frame-in-editor?fileName=&lineNumber=&colNumber=
    case stackFrame
    /// Parcel: GET /__parcel_launch_editor?file=
    case parcelLaunch
}

struct FWRestartEndpoint: Equatable, Sendable {
    var path: String
    var statusPath: String
    var clearCacheQuery: String
    var minVersion: String
}

enum FWRestart: Equatable, Sendable {
    case endpoint(FWRestartEndpoint)
    case unavailable(String)
}

struct FWDevAdapter: Equatable, Sendable {
    var id: String
    var name: String
    /// Names `OrbitFrameworksLogic.detect` gives this framework.
    var detectionNames: [String]
    /// A meta-framework beats the bundler it runs on when signals disagree.
    var specificity: Int
    var bundlers: [FWBundler]
    /// Page-side observations that only exist while this framework's dev server serves the page.
    var devSignals: [FWSignal]
    var editor: [FWEditorStyle]
    var restart: FWRestart
    var controls: [FWDevControl]
    var softRefreshUnavailable: String
}

enum FWDevAdapters {
    static let viteRestart = FWRestart.unavailable("Vite has no HTTP route to restart the server. Restart it from the terminal.")

    static let all: [FWDevAdapter] = [
        FWDevAdapter(
            id: "next", name: "Next.js", detectionNames: ["Next.js"], specificity: 100,
            bundlers: [.webpack, .turbopack, .rspack],
            devSignals: [.nextDevGlobal, .nextPortal, .nextDevBuildID],
            editor: [.nextLaunchEditor],
            restart: .endpoint(FWRestartEndpoint(
                path: "/__nextjs_restart_dev", statusPath: "/__nextjs_server_status",
                clearCacheQuery: "invalidateFileSystemCache=1&invalidatePersistentCache=1", minVersion: "15.4.0")),
            controls: [.softRefresh, .hmrRefresh, .restartServer, .restartClearCache, .exitDraftMode],
            softRefreshUnavailable: "Needs window.next.router, which exists once the page has hydrated."),
        FWDevAdapter(
            id: "nuxt", name: "Nuxt", detectionNames: ["Nuxt"], specificity: 100,
            bundlers: [.vite, .webpack, .rspack],
            devSignals: [.viteClient, .webpackHMR],
            editor: [.openInEditor(prefix: ""), .openInEditor(prefix: "/_nuxt")],
            restart: .unavailable("Nuxt has no HTTP route to restart the server. Restart nuxt dev from the terminal."),
            controls: [.softRefresh],
            softRefreshUnavailable: "Needs window.useNuxtApp, which Nuxt sets on the client."),
        FWDevAdapter(
            id: "sveltekit", name: "SvelteKit", detectionNames: ["SvelteKit"], specificity: 100,
            bundlers: [.vite],
            devSignals: [.sveltekitDev, .viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: viteRestart,
            controls: [.softRefresh],
            softRefreshUnavailable: "invalidateAll() is a module import from $app/navigation, so page scripts cannot call it."),
        FWDevAdapter(
            id: "astro", name: "Astro", detectionNames: ["Astro"], specificity: 100,
            bundlers: [.vite],
            devSignals: [.astroToolbar, .viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: viteRestart,
            controls: [.softRefresh],
            softRefreshUnavailable: "Astro's navigate() is a module import, so page scripts cannot call it."),
        FWDevAdapter(
            id: "gatsby", name: "Gatsby", detectionNames: ["Gatsby"], specificity: 100,
            bundlers: [.webpack],
            devSignals: [.whmReporter],
            editor: [.stackFrame],
            restart: .unavailable("gatsby develop has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [.refreshSourceData],
            softRefreshUnavailable: "Gatsby has no client-side data refresh; use Refresh sources."),
        FWDevAdapter(
            id: "storybook", name: "Storybook", detectionNames: ["Storybook"], specificity: 95,
            bundlers: [.vite, .webpack],
            devSignals: [],
            editor: [.openInEditor(prefix: "")],
            restart: .unavailable("Storybook has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [.softRefresh],
            softRefreshUnavailable: "Needs the story preview frame (window.__STORYBOOK_PREVIEW__)."),
        FWDevAdapter(
            id: "reactRouter", name: "React Router", detectionNames: ["React Router"], specificity: 90,
            bundlers: [.vite],
            devSignals: [.viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: viteRestart,
            controls: [.softRefresh],
            softRefreshUnavailable: "Needs the data router (window.__reactRouterDataRouter)."),
        FWDevAdapter(
            id: "remix", name: "Remix", detectionNames: ["Remix"], specificity: 85,
            bundlers: [.vite, .esbuild],
            devSignals: [.viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: .unavailable("Remix has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [.softRefresh],
            softRefreshUnavailable: "Needs the data router (window.__remixRouter)."),
        FWDevAdapter(
            id: "qwik", name: "Qwik", detectionNames: ["Qwik"], specificity: 80,
            bundlers: [.vite],
            devSignals: [.qwikDev, .viteClient],
            editor: [],
            restart: viteRestart,
            controls: [],
            softRefreshUnavailable: "Qwik has no client-side refresh API reachable from the page."),
        FWDevAdapter(
            id: "angular", name: "Angular", detectionNames: ["Angular"], specificity: 70,
            bundlers: [.vite, .webpack, .esbuild],
            devSignals: [.angularDev, .viteClient, .webpackHMR],
            editor: [.openInEditor(prefix: ""), .webpackOpenEditor],
            restart: .unavailable("ng serve has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [.rebuild],
            softRefreshUnavailable: "The Angular router is not exposed to page scripts."),
        FWDevAdapter(
            id: "solid", name: "Solid", detectionNames: ["Solid"], specificity: 40,
            bundlers: [.vite],
            devSignals: [.viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: viteRestart,
            controls: [],
            softRefreshUnavailable: "Solid has no client-side refresh API reachable from the page."),
        FWDevAdapter(
            id: "parcel", name: "Parcel", detectionNames: ["Parcel"], specificity: 30,
            bundlers: [.parcel],
            devSignals: [],
            editor: [.parcelLaunch],
            restart: .unavailable("Parcel has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [],
            softRefreshUnavailable: "Parcel has no client-side refresh API."),
        FWDevAdapter(
            id: "rsbuild", name: "Rsbuild", detectionNames: [], specificity: 25,
            bundlers: [.rspack],
            devSignals: [],
            editor: [.openInEditor(prefix: "")],
            restart: .unavailable("Rsbuild has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [],
            softRefreshUnavailable: "Rsbuild has no client-side refresh API."),
        FWDevAdapter(
            id: "vite", name: "Vite", detectionNames: ["Vite"], specificity: 20,
            bundlers: [.vite],
            devSignals: [.viteClient],
            editor: [.openInEditor(prefix: "")],
            restart: viteRestart,
            controls: [],
            softRefreshUnavailable: "Vite itself has no client-side refresh API."),
        FWDevAdapter(
            id: "webpack", name: "webpack", detectionNames: ["webpack"], specificity: 15,
            bundlers: [.webpack],
            devSignals: [.webpackHMR, .whmReporter],
            editor: [.webpackOpenEditor, .stackFrame],
            restart: .unavailable("webpack-dev-server has no HTTP route to restart the server. Restart it from the terminal."),
            controls: [.rebuild],
            softRefreshUnavailable: "webpack has no client-side refresh API."),
        FWDevAdapter(
            id: "livereload", name: "LiveReload", detectionNames: [], specificity: 5,
            bundlers: [],
            devSignals: [],
            editor: [],
            restart: .unavailable("A LiveReload server has no HTTP route to restart it."),
            controls: [],
            softRefreshUnavailable: "LiveReload only reloads the page."),
    ]

    static func adapter(id: String) -> FWDevAdapter? { all.first { $0.id == id } }

    /// The adapter a socket protocol implies when no framework was detected.
    static func adapterID(for protocolID: FWWireProtocol) -> String {
        switch protocolID {
        case .next: return "next"
        case .vite: return "vite"
        case .webpackDevServer, .webpackHotMiddleware: return "webpack"
        case .parcel: return "parcel"
        case .rsbuild: return "rsbuild"
        case .remixLiveReload: return "remix"
        case .liveReload: return "livereload"
        case .storybookChannel: return "storybook"
        }
    }
}

// MARK: Issues and events

struct FWDevIssue: Identifiable, Equatable, Sendable {
    enum Severity: String, Sendable { case error, warning }
    enum Origin: String, Sendable { case build, runtime }

    var severity: Severity
    var origin: Origin
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
    /// A code frame or stack the framework supplied.
    var frame: String?
    var source: String

    var id: String { "\(origin.rawValue)|\(severity.rawValue)|\(file ?? "")|\(line ?? 0)|\(column ?? 0)|\(message.prefix(120))" }

    var locationText: String? {
        guard let file else { return nil }
        var text = file
        if let line { text += ":\(line)" }
        if let column, line != nil { text += ":\(column)" }
        return text
    }
}

enum FWDevEventKind: String, Equatable, Sendable {
    case connection, building, built, update, reload, error, warning, navigation, info

    var tone: Int {
        switch self {
        case .built, .update: return 1
        case .warning: return 2
        case .error: return 3
        default: return 0
        }
    }
}

enum FWBuildState: Equatable, Sendable {
    case unknown, building, ok, failed
}

enum FWDevIssueUpdate: Equatable, Sendable {
    case none
    case replaceAll([FWDevIssue])
    case replace(FWDevIssue.Severity, [FWDevIssue])
    case append([FWDevIssue])
}

/// What one wire message (or page event) means, independent of which socket carried it.
struct FWDevWireEvent: Equatable, Sendable {
    var kind: FWDevEventKind
    var title: String
    var detail: String? = nil
    var inTimeline = true
    var buildState: FWBuildState? = nil
    var issueUpdate: FWDevIssueUpdate = .none
    /// Counts toward "last update".
    var isUpdate = false
    /// Servers that announce the current state on connect (webpack-dev-server, Rsbuild) send the same message for it: the first one is not a change.
    var snapshotIfFirst = false
    var bundler: FWBundler? = nil
    var frameworkVersion: String? = nil
    var staleness: String? = nil
    var session: String? = nil
    var staticRoutes: [String: Bool]? = nil
    var clearsRuntimeIssues = false
}

struct FWDevEvent: Identifiable, Equatable, Sendable {
    var id: Int
    var at: Double
    var kind: FWDevEventKind
    var title: String
    var detail: String?
}

// MARK: Text helpers

enum FWDevText {
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static let locationPatterns: [NSRegularExpression] = {
        let sources = [
            #"(https?://[^\s'"()<>|]+?\.[A-Za-z0-9]{1,8}):(\d+)(?::(\d+))?"#,
            #"((?:[A-Za-z]:)?[^\s:'"()<>|]+?\.[A-Za-z0-9]{1,8}):(\d+)(?::(\d+))?"#,
            #"((?:[A-Za-z]:)?[^\s:'"()<>|]+?\.[A-Za-z0-9]{1,8}) (\d+):(\d+)"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// The first `file:line:col` (or webpack's `file line:col`) in a message.
    static func location(in text: String) -> (file: String, line: Int?, column: Int?)? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in locationPatterns {
            guard let match = regex.firstMatch(in: text, range: range),
                  let fileRange = Range(match.range(at: 1), in: text) else { continue }
            let line = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
            let column = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            return (String(text[fileRange]), line, column)
        }
        return nil
    }

    /// webpack's `loc` is "line:col", "line:col-col" or "line:col-line:col".
    static func webpackLoc(_ loc: String) -> (line: Int?, column: Int?) {
        let parts = loc.split(whereSeparator: { $0 == ":" || $0 == "-" })
        return (parts.first.flatMap { Int($0) }, parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// A webpack module identifier is "loader!loader!/abs/path.js?query": the file is the last segment.
    static func moduleFile(_ identifier: String) -> String {
        var file = identifier.components(separatedBy: "!").last ?? identifier
        if let q = file.firstIndex(of: "?") { file = String(file[..<q]) }
        return file
    }

    static func shortPath(_ path: String) -> String {
        let trimmed = path.split(separator: "?").first.map(String.init) ?? path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    static func plural(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}

// MARK: Wire decoding

enum FWDevWire {

    /// Which protocol a socket speaks, from its URL and subprotocols. `strong` means the URL alone is conclusive.
    static func identify(url: String, subprotocols: [String], pageHost: String, hints: Set<FWWireProtocol> = []) -> (protocolID: FWWireProtocol, strong: Bool)? {
        if subprotocols.contains("vite-hmr") { return (.vite, true) }
        if subprotocols.contains("vite-ping") { return nil }
        let comps = URLComponents(string: url)
        let path = comps?.path ?? url
        let host = comps?.host ?? ""
        if path.contains("/_next/hmr") || path.contains("/_next/webpack-hmr") { return (.next, true) }
        if path.contains("/rsbuild-hmr") { return (.rsbuild, true) }
        if path.contains("/ng-cli-ws") || path.contains("/sockjs-node") { return (.webpackDevServer, true) }
        if path.contains("/__webpack_hmr") { return (.webpackHotMiddleware, true) }
        if path.contains("/livereload") { return (.liveReload, true) }
        if path.contains("/storybook-server-channel") { return (.storybookChannel, true) }
        if path.hasSuffix("/ws") { return (.webpackDevServer, false) }
        if path == "/socket", comps?.port == 8002 { return (.remixLiveReload, false) }
        if hints.contains(.parcel), path.isEmpty || path == "/", host == pageHost || host.isEmpty { return (.parcel, false) }
        return nil
    }

    static func decode(protocolID: FWWireProtocol, text: String) -> [FWDevWireEvent] {
        switch protocolID {
        case .next: return one(object(text).flatMap(decodeNext))
        case .vite: return one(object(text).flatMap(decodeVite))
        case .webpackDevServer: return decodeWebpackDevServer(text)
        case .webpackHotMiddleware: return one(object(text).flatMap(decodeHotMiddleware))
        case .parcel: return one(object(text).flatMap(decodeParcel))
        case .rsbuild: return one(object(text).flatMap(decodeRsbuild))
        case .remixLiveReload: return one(object(text).flatMap(decodeRemix))
        case .liveReload: return one(object(text).flatMap(decodeLiveReload))
        case .storybookChannel: return one(object(text).flatMap(decodeStorybook))
        }
    }

    private static func one(_ event: FWDevWireEvent?) -> [FWDevWireEvent] { event.map { [$0] } ?? [] }

    private static func object(_ text: String) -> [String: Any]? {
        guard text.first == "{", let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    // MARK: Next.js

    /// 13 to 15 key the message `action`, 16 keys it `type`, and a few 15.x messages use `event`.
    private static func decodeNext(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let key = string(o["action"]) ?? string(o["type"]) ?? string(o["event"]) else { return nil }
        switch key {
        case "building":
            return FWDevWireEvent(kind: .building, title: "Compiling", buildState: .building, issueUpdate: .none)
        case "built", "sync":
            let hash = string(o["hash"]) ?? ""
            let errors = compilationIssues(o["errors"], severity: .error)
            let warnings = compilationIssues(o["warnings"], severity: .warning)
            let all = errors + warnings
            var event = FWDevWireEvent(kind: errors.isEmpty ? .built : .error,
                                       title: key == "sync" ? "Synced with server" : "Compiled",
                                       buildState: errors.isEmpty ? .ok : .failed,
                                       issueUpdate: .replaceAll(all))
            if !errors.isEmpty { event.title = key == "sync" ? "Synced with " + plural(errors.count, "error") : "Compiled with " + plural(errors.count, "error") }
            event.isUpdate = key == "built" && errors.isEmpty
            // Turbopack syncs with an empty hash; webpack always has one.
            if !hash.isEmpty { event.bundler = .webpack; event.detail = "hash \(hash.prefix(10))" }
            if let info = o["versionInfo"] as? [String: Any] {
                event.frameworkVersion = string(info["installed"])
                event.staleness = string(info["staleness"])
            }
            return event
        case "serverComponentChanges":
            return FWDevWireEvent(kind: .update, title: "Server components changed", isUpdate: true)
        case "reloadPage":
            return FWDevWireEvent(kind: .reload, title: "Full reload requested", detail: string(o["data"]), isUpdate: true)
        case "serverError":
            var message = "Server error"
            var frame: String?
            if let raw = string(o["errorJSON"]), let data = raw.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                message = string(parsed["message"]) ?? message
                frame = string(parsed["stack"])
            }
            var issue = issue(from: message, severity: .error, origin: .build, source: "Next.js")
            issue.frame = frame
            return FWDevWireEvent(kind: .error, title: "Server error", detail: FWDevText.firstLine(issue.message),
                                  buildState: .failed, issueUpdate: .append([issue]))
        case "addedPage", "removedPage":
            let page = (o["data"] as? [Any])?.first.flatMap { $0 as? String } ?? ""
            return FWDevWireEvent(kind: .info, title: key == "addedPage" ? "Page added" : "Page removed", detail: page.isEmpty ? nil : page)
        case "devPagesManifestUpdate":
            return FWDevWireEvent(kind: .info, title: "Pages manifest updated")
        case "middlewareChanges":
            return FWDevWireEvent(kind: .info, title: "Middleware changed")
        case "clientChanges":
            return FWDevWireEvent(kind: .update, title: "Client files changed", isUpdate: true)
        case "serverOnlyChanges":
            let pages = (o["pages"] as? [Any])?.count ?? 0
            return FWDevWireEvent(kind: .info, title: "Server-only changes", detail: pages > 0 ? plural(pages, "page") : nil)
        case "staticParamsChanged":
            return FWDevWireEvent(kind: .info, title: "Static params changed")
        case "turbopack-connected":
            let data = o["data"] as? [String: Any]
            let session = data?["sessionId"].flatMap { OrbitInspectDecode.integer($0) }.map { String($0) }
            return FWDevWireEvent(kind: .connection, title: "Turbopack connected", bundler: .turbopack, session: session)
        case "turbopack-message":
            return FWDevWireEvent(kind: .update, title: "Turbopack update", detail: turbopackSummary(o["data"]),
                                  buildState: .ok, issueUpdate: .replaceAll([]), isUpdate: true, bundler: .turbopack)
        case "isrManifest":
            var map: [String: Bool] = [:]
            if let raw = o["data"] as? [String: Any] {
                for (path, value) in raw { if let flag = value as? Bool { map[path] = flag } }
            }
            return FWDevWireEvent(kind: .info, title: "Static route manifest", inTimeline: false, staticRoutes: map)
        case "runtimeErrors":
            let errors = (o["errors"] as? [[String: Any]]) ?? []
            let issues = errors.map { runtimeIssue(next: $0) }
            return FWDevWireEvent(kind: .error, title: "Runtime errors", detail: plural(issues.count, "error"),
                                  issueUpdate: .append(issues))
        case "devToolsConfig", "devtoolsConfig", "cacheIndicator", "versionInfo", "requestCurrentErrorState",
             "requestPageMetadata", "requestInsightsUpdate", "vulnerabilityInsight":
            var event = FWDevWireEvent(kind: .info, title: key, inTimeline: false)
            if key == "versionInfo", let info = o["versionInfo"] as? [String: Any] {
                event.frameworkVersion = string(info["installed"])
                event.staleness = string(info["staleness"])
            }
            return event
        default:
            return nil
        }
    }

    private static func plural(_ n: Int, _ noun: String) -> String { FWDevText.plural(n, noun) }

    private static func turbopackSummary(_ data: Any?) -> String? {
        let updates: [[String: Any]]
        if let list = data as? [[String: Any]] { updates = list } else if let one = data as? [String: Any] { updates = [one] } else { return nil }
        var modules = 0
        for update in updates {
            guard let instruction = update["instruction"] as? [String: Any],
                  let merged = instruction["merged"] as? [[String: Any]] else { continue }
            for chunk in merged { modules += (chunk["entries"] as? [String: Any])?.count ?? 0 }
        }
        if modules > 0 { return plural(modules, "module") }
        return updates.count > 1 ? plural(updates.count, "chunk list") : nil
    }

    /// Next's CompilationError: { moduleName?, message, details?, stack? } with a "./file:line:col" header in the message.
    private static func compilationIssues(_ raw: Any?, severity: FWDevIssue.Severity) -> [FWDevIssue] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { item in
            if let text = item as? String { return issue(from: text, severity: severity, origin: .build, source: "Next.js") }
            guard let o = item as? [String: Any] else { return nil }
            var built = issue(from: string(o["message"]) ?? "Compilation problem", severity: severity, origin: .build, source: "Next.js")
            if built.file == nil, let module = string(o["moduleName"]) { built.file = module }
            if let details = string(o["details"]), !details.isEmpty { built.frame = FWDevText.stripANSI(details) }
            else if let stack = string(o["stack"]), !stack.isEmpty { built.frame = FWDevText.stripANSI(stack) }
            return built
        }
    }

    private static func runtimeIssue(next o: [String: Any]) -> FWDevIssue {
        var built = issue(from: (string(o["errorName"]).map { $0 + ": " } ?? "") + (string(o["message"]) ?? "Runtime error"),
                          severity: .error, origin: .runtime, source: "Next.js")
        if let top = (o["stack"] as? [[String: Any]])?.first {
            built.file = string(top["file"])
            built.line = OrbitInspectDecode.integer(top["line"])
            built.column = OrbitInspectDecode.integer(top["column"])
        }
        return built
    }

    /// Builds an issue from free text: the first line with a source location supplies file, line and column.
    static func issue(from message: String, severity: FWDevIssue.Severity, origin: FWDevIssue.Origin, source: String) -> FWDevIssue {
        // A page controls this text, so the work done on it is bounded.
        let clean = String(FWDevText.stripANSI(String(message.prefix(20_000))).trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        var built = FWDevIssue(severity: severity, origin: origin, message: clean, source: source)
        if let loc = FWDevText.location(in: String(clean.prefix(2_000))) {
            built.file = loc.file
            built.line = loc.line
            built.column = loc.column
        }
        return built
    }

    // MARK: Vite

    /// Custom events other tools send over Vite's socket, by name.
    static let viteCustomEvents: [String: (kind: FWDevEventKind, title: String)] = [
        "react-router:hmr": (.update, "Route module updated"),
        "angular:component-update": (.update, "Component updated"),
        "nuxt:dev:error:clear": (.info, "Dev error cleared"),
        "astro:devtoolbar:error:load": (.warning, "Dev toolbar failed to load"),
    ]

    private static func decodeVite(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]) else { return nil }
        switch type {
        case "connected":
            return FWDevWireEvent(kind: .connection, title: "Connected", bundler: .vite)
        case "update":
            let updates = (o["updates"] as? [[String: Any]]) ?? []
            let css = updates.filter { string($0["type"]) == "css-update" }.count
            let names = updates.prefix(2).compactMap { string($0["path"]).map(FWDevText.shortPath) }
            var title = "Updated " + plural(updates.count, updates.count == css ? "stylesheet" : "module")
            if css > 0, css != updates.count { title += " (\(css) CSS)" }
            return FWDevWireEvent(kind: .update, title: title,
                                  detail: names.isEmpty ? nil : names.joined(separator: ", ") + (updates.count > 2 ? ", ..." : ""),
                                  buildState: .ok, issueUpdate: .replaceAll([]), isUpdate: true, clearsRuntimeIssues: false)
        case "bundled-dev-update":
            let ids = (o["changedIds"] as? [Any])?.count ?? 0
            return FWDevWireEvent(kind: .update, title: "Bundle updated", detail: plural(ids, "module"),
                                  buildState: .ok, issueUpdate: .replaceAll([]), isUpdate: true)
        case "full-reload":
            let path = string(o["path"])
            let trigger = string(o["triggeredBy"]).map(FWDevText.shortPath)
            let detail = trigger ?? (path == "*" ? nil : path)
            return FWDevWireEvent(kind: .reload, title: "Full reload", detail: detail,
                                  buildState: .ok, issueUpdate: .replaceAll([]), isUpdate: true)
        case "prune":
            let count = (o["paths"] as? [Any])?.count ?? 0
            return FWDevWireEvent(kind: .info, title: "Pruned " + plural(count, "module"))
        case "error":
            guard let err = o["err"] as? [String: Any] else { return nil }
            let plugin = string(err["plugin"])
            var built = issue(from: string(err["message"]) ?? "Build error", severity: .error, origin: .build,
                              source: plugin.map { "Vite \($0)" } ?? "Vite")
            let loc = err["loc"] as? [String: Any]
            if let file = string(loc?["file"]) ?? string(err["id"]) {
                var path = file
                if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
                built.file = path
                built.line = loc.flatMap { OrbitInspectDecode.integer($0["line"]) } ?? built.line
                built.column = loc.flatMap { OrbitInspectDecode.integer($0["column"]) } ?? built.column
            }
            built.frame = string(err["frame"]).map(FWDevText.stripANSI)
            return FWDevWireEvent(kind: .error, title: "Build error", detail: FWDevText.firstLine(built.message),
                                  buildState: .failed, issueUpdate: .replaceAll([built]))
        case "custom":
            guard let name = string(o["event"]) else { return nil }
            if let known = viteCustomEvents[name] {
                if name == "nuxt:dev:error:clear" { return FWDevWireEvent(kind: known.kind, title: known.title, clearsRuntimeIssues: true) }
                return FWDevWireEvent(kind: known.kind, title: known.title)
            }
            if name == "nuxt:dev:error", let data = o["data"] as? [String: Any] {
                let built = issue(from: string(data["message"]) ?? "Nuxt dev error", severity: .error, origin: .runtime, source: "Nuxt")
                return FWDevWireEvent(kind: .error, title: "Nuxt dev error", detail: FWDevText.firstLine(built.message), issueUpdate: .append([built]))
            }
            // Vite's own housekeeping events (vite:forward-console and the like) are not worth a timeline row.
            if name.hasPrefix("vite:") { return FWDevWireEvent(kind: .info, title: name, inTimeline: false) }
            return FWDevWireEvent(kind: .info, title: "Custom event", detail: name)
        case "ping":
            return FWDevWireEvent(kind: .info, title: "Ping", inTimeline: false)
        default:
            return nil
        }
    }

    // MARK: webpack-dev-server

    /// SockJS wraps each message as `a["{...}"]`; `o` opens, `h` is a heartbeat and `c[...]` closes.
    private static func decodeWebpackDevServer(_ text: String) -> [FWDevWireEvent] {
        if text.hasPrefix("a["), let data = String(text.dropFirst()).data(using: .utf8),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            return list.compactMap { ($0 as? String).flatMap(object).flatMap(decodeWebpackDevServerMessage) }
        }
        return one(object(text).flatMap(decodeWebpackDevServerMessage))
    }

    private static func decodeWebpackDevServerMessage(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]) else { return nil }
        switch type {
        case "invalid":
            return FWDevWireEvent(kind: .building, title: "Rebuilding", buildState: .building, issueUpdate: .replaceAll([]))
        case "ok":
            return FWDevWireEvent(kind: .built, title: "Compiled", buildState: .ok, isUpdate: true, snapshotIfFirst: true)
        case "still-ok":
            return FWDevWireEvent(kind: .info, title: "Still ok", inTimeline: false)
        case "warnings", "errors":
            let severity: FWDevIssue.Severity = type == "errors" ? .error : .warning
            let issues = ((o["data"] as? [Any]) ?? []).compactMap { statsIssue($0, severity: severity) }
            let title = type == "errors" ? "Compiled with " + plural(issues.count, "error") : "Compiled with " + plural(issues.count, "warning")
            var event = FWDevWireEvent(kind: type == "errors" ? .error : .warning, title: title,
                                       detail: issues.first.map { FWDevText.firstLine($0.message) },
                                       issueUpdate: .replace(severity, issues))
            if type == "errors" { event.buildState = .failed }
            return event
        case "error":
            let message = string(o["data"]) ?? "Dev server error"
            return FWDevWireEvent(kind: .error, title: "Dev server error", detail: message)
        case "static-changed":
            return FWDevWireEvent(kind: .reload, title: "Static file changed", detail: string(o["data"]).map(FWDevText.shortPath), isUpdate: true)
        case "hash", "hot", "liveReload", "progress", "reconnect", "overlay", "progress-update", "logging", "close":
            return FWDevWireEvent(kind: .info, title: type, inTimeline: false)
        default:
            return nil
        }
    }

    /// A webpack StatsError: { message, moduleName, moduleIdentifier, loc, moduleId, moduleTrace, stack }.
    private static func statsIssue(_ raw: Any, severity: FWDevIssue.Severity) -> FWDevIssue? {
        if let text = raw as? String { return issue(from: text, severity: severity, origin: .build, source: "webpack") }
        guard let o = raw as? [String: Any] else { return nil }
        var built = issue(from: string(o["message"]) ?? "Compilation problem", severity: severity, origin: .build, source: "webpack")
        if let identifier = string(o["moduleIdentifier"]) {
            built.file = FWDevText.moduleFile(identifier)
        } else if built.file == nil, let name = string(o["moduleName"]) {
            built.file = FWDevText.moduleFile(name)
        }
        if let loc = string(o["loc"]) {
            let parsed = FWDevText.webpackLoc(loc)
            built.line = parsed.line ?? built.line
            built.column = parsed.column ?? built.column
        }
        if let stack = o["stack"] as? [Any] {
            let joined = stack.compactMap { $0 as? String }.joined(separator: "\n")
            if !joined.isEmpty { built.frame = FWDevText.stripANSI(joined) }
        } else if let stack = string(o["stack"]), !stack.isEmpty {
            built.frame = FWDevText.stripANSI(stack)
        }
        return built
    }

    // MARK: webpack-hot-middleware (Gatsby, older Next)

    private static func decodeHotMiddleware(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let action = string(o["action"]) else { return nil }
        switch action {
        case "building":
            return FWDevWireEvent(kind: .building, title: "Rebuilding", buildState: .building, issueUpdate: .replaceAll([]))
        case "built", "sync":
            let errors = ((o["errors"] as? [Any]) ?? []).compactMap { statsIssue($0, severity: .error) }
            let warnings = ((o["warnings"] as? [Any]) ?? []).compactMap { statsIssue($0, severity: .warning) }
            var title = action == "sync" ? "Synced with server" : "Built"
            if let time = OrbitInspectDecode.integer(o["time"]), time > 0, action == "built" { title += " in \(time) ms" }
            if !errors.isEmpty { title = "Built with " + plural(errors.count, "error") }
            var event = FWDevWireEvent(kind: errors.isEmpty ? .built : .error, title: title,
                                       buildState: errors.isEmpty ? .ok : .failed,
                                       issueUpdate: .replaceAll(errors + warnings))
            event.isUpdate = action == "built" && errors.isEmpty
            if let hash = string(o["hash"]), !hash.isEmpty { event.detail = "hash \(hash.prefix(10))" }
            return event
        default:
            return nil
        }
    }

    // MARK: Parcel

    private static func decodeParcel(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]) else { return nil }
        switch type {
        case "update":
            let assets = (o["assets"] as? [Any])?.count ?? 0
            return FWDevWireEvent(kind: .update, title: "Updated " + plural(assets, "asset"),
                                  buildState: .ok, issueUpdate: .replaceAll([]), isUpdate: true)
        case "reload":
            return FWDevWireEvent(kind: .reload, title: "Full reload", isUpdate: true)
        case "error":
            let diagnostics = o["diagnostics"] as? [String: Any]
            var issues: [FWDevIssue] = []
            for item in (diagnostics?["html"] as? [[String: Any]]) ?? [] {
                var built = issue(from: string(item["message"]) ?? "Build error", severity: .error, origin: .build, source: "Parcel")
                if let frame = (item["frames"] as? [[String: Any]])?.first, let location = string(frame["location"]),
                   let parsed = FWDevText.location(in: location) {
                    built.file = parsed.file; built.line = parsed.line; built.column = parsed.column
                    built.frame = string(frame["code"]).map(FWDevText.stripANSI)
                }
                if built.frame == nil { built.frame = string(item["stack"]).map(FWDevText.stripANSI) }
                issues.append(built)
            }
            if issues.isEmpty {
                issues = ((diagnostics?["ansi"] as? [[String: Any]]) ?? []).map {
                    issue(from: string($0["message"]) ?? "Build error", severity: .error, origin: .build, source: "Parcel")
                }
            }
            return FWDevWireEvent(kind: .error, title: "Build error", detail: issues.first.map { FWDevText.firstLine($0.message) },
                                  buildState: .failed, issueUpdate: .replaceAll(issues))
        default:
            return nil
        }
    }

    // MARK: Rsbuild

    private static func decodeRsbuild(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]) else { return nil }
        switch type {
        case "ok":
            return FWDevWireEvent(kind: .built, title: "Compiled", buildState: .ok, isUpdate: true, snapshotIfFirst: true)
        case "warnings", "errors":
            let severity: FWDevIssue.Severity = type == "errors" ? .error : .warning
            let data = o["data"] as? [String: Any]
            let issues = ((data?["text"] as? [Any]) ?? []).compactMap { ($0 as? String).map { issue(from: $0, severity: severity, origin: .build, source: "Rsbuild") } }
            var event = FWDevWireEvent(kind: severity == .error ? .error : .warning,
                                       title: "Compiled with " + plural(issues.count, severity == .error ? "error" : "warning"),
                                       detail: issues.first.map { FWDevText.firstLine($0.message) },
                                       issueUpdate: .replace(severity, issues))
            if severity == .error { event.buildState = .failed }
            return event
        case "static-changed", "content-changed":
            return FWDevWireEvent(kind: .reload, title: "Static file changed", isUpdate: true)
        case "full-reload":
            let path = (o["data"] as? [String: Any]).flatMap { string($0["path"]) }
            return FWDevWireEvent(kind: .reload, title: "Full reload", detail: path, isUpdate: true)
        case "custom":
            let name = (o["data"] as? [String: Any]).flatMap { string($0["event"]) }
            return FWDevWireEvent(kind: .info, title: "Custom event", detail: name)
        case "resolved-client-error":
            return FWDevWireEvent(kind: .info, title: "Client error resolved", inTimeline: false, clearsRuntimeIssues: true)
        case "hash", "early-update":
            return FWDevWireEvent(kind: .info, title: type, inTimeline: false)
        default:
            return nil
        }
    }

    // MARK: Remix classic live reload

    private static func decodeRemix(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]) else { return nil }
        switch type {
        case "RELOAD":
            return FWDevWireEvent(kind: .reload, title: "Full reload", isUpdate: true)
        case "HMR":
            let updates = (o["updates"] as? [Any])?.count ?? 0
            return FWDevWireEvent(kind: .update, title: "Hot update", detail: updates > 0 ? plural(updates, "route") : nil, isUpdate: true)
        case "LOG":
            return FWDevWireEvent(kind: .info, title: "Dev server log", detail: string(o["message"]))
        case "PING":
            return FWDevWireEvent(kind: .info, title: "Ping", inTimeline: false)
        default:
            return nil
        }
    }

    // MARK: LiveReload protocol (Hugo, Ember, livereload.js)

    private static func decodeLiveReload(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let command = string(o["command"]) else { return nil }
        switch command {
        case "reload", "refresh":
            let path = string(o["path"])
            let isCSS = (path?.hasSuffix(".css") ?? false) && ((o["liveCSS"] as? Bool) ?? false)
            return FWDevWireEvent(kind: isCSS ? .update : .reload, title: isCSS ? "Stylesheet reloaded" : "Page reload requested",
                                  detail: path.flatMap { $0 == "/x.js" ? nil : $0 }, isUpdate: true)
        case "hello":
            return FWDevWireEvent(kind: .info, title: "Handshake", inTimeline: false)
        case "alert":
            return FWDevWireEvent(kind: .info, title: "Server message", detail: string(o["message"]))
        default:
            return nil
        }
    }

    // MARK: Storybook channel

    static let storybookEvents: [String: (kind: FWDevEventKind, title: String)] = [
        "storyRendered": (.built, "Story rendered"),
        "storyErrored": (.error, "Story errored"),
        "storyThrewException": (.error, "Story threw"),
        "storyUnchanged": (.info, "Story unchanged"),
        "storyHotUpdated": (.update, "Story updated"),
        "storyIndexInvalidated": (.update, "Story index changed"),
        "forceReRender": (.info, "Re-render requested"),
        "forceRemount": (.info, "Remount requested"),
        "setCurrentStory": (.navigation, "Story selected"),
    ]

    private static func decodeStorybook(_ o: [String: Any]) -> FWDevWireEvent? {
        guard let type = string(o["type"]), let known = storybookEvents[type] else { return nil }
        let args = o["args"] as? [Any]
        var detail: String?
        var update: FWDevIssueUpdate = .none
        if let first = args?.first as? String { detail = first }
        if let first = args?.first as? [String: Any] {
            detail = string(first["storyId"]) ?? string(first["title"]) ?? string(first["name"])
            if known.kind == .error {
                let message = [string(first["title"]), string(first["description"]), string(first["message"])].compactMap { $0 }.joined(separator: ": ")
                var built = issue(from: message.isEmpty ? known.title : message, severity: .error, origin: .runtime, source: "Storybook")
                built.frame = string(first["stack"])
                update = .append([built])
                detail = FWDevText.firstLine(built.message)
            }
        }
        return FWDevWireEvent(kind: known.kind, title: known.title, detail: detail, issueUpdate: update,
                              isUpdate: type == "storyHotUpdated")
    }

    // MARK: Page events

    /// Observations the page script makes itself: runtime errors, router events and framework hooks.
    static let pageEvents: [String: (kind: FWDevEventKind, title: String)] = [
        "navigate": (.navigation, "Navigated"),
        "next.routeChangeStart": (.navigation, "Route change started"),
        "next.routeChangeComplete": (.navigation, "Route change complete"),
        "next.routeChangeError": (.error, "Route change failed"),
        "rr.loading": (.navigation, "Loading route data"),
        "rr.submitting": (.navigation, "Submitting"),
        "rr.idle": (.navigation, "Route idle"),
        "rr.revalidating": (.navigation, "Revalidating route data"),
        "nuxt.page:start": (.navigation, "Page transition started"),
        "nuxt.page:finish": (.navigation, "Page transition finished"),
        "nuxt.app:data:refresh": (.update, "Data refreshed"),
        "nuxt.app:error": (.error, "Nuxt app error"),
        "nuxt.vue:error": (.error, "Vue error"),
        "astro.before-preparation": (.navigation, "Navigation started"),
        "astro.after-swap": (.navigation, "Page swapped"),
        "astro.page-load": (.navigation, "Page loaded"),
        "gatsby.pageQueryResult": (.update, "Page data updated"),
        "gatsby.staticQueryResult": (.update, "Static query data updated"),
        "gatsby.overlayError": (.error, "Gatsby overlay error"),
        "gatsby.onRouteUpdate": (.navigation, "Route updated"),
        "storybook.storyRendered": (.built, "Story rendered"),
        "storybook.storyErrored": (.error, "Story errored"),
        "storybook.storyThrewException": (.error, "Story threw"),
        "storybook.storyHotUpdated": (.update, "Story updated"),
    ]

    static func decodePageEvent(name: String, detail: String?, message: String?, file: String?, line: Int?, column: Int?, stack: String?) -> FWDevWireEvent? {
        if name == "runtimeError" || name == "unhandledRejection" {
            var built = issue(from: message ?? "Script error", severity: .error, origin: .runtime, source: "Page")
            if let file, !file.isEmpty { built.file = file; built.line = line; built.column = column }
            built.frame = stack.flatMap { $0.isEmpty ? nil : FWDevText.stripANSI($0) }
            let title = name == "unhandledRejection" ? "Unhandled promise rejection" : "Uncaught error"
            return FWDevWireEvent(kind: .error, title: title, detail: FWDevText.firstLine(built.message), issueUpdate: .append([built]))
        }
        guard let known = pageEvents[name] else { return nil }
        var update: FWDevIssueUpdate = .none
        var shown = detail
        if known.kind == .error {
            let text = message ?? detail ?? known.title
            let built = issue(from: text, severity: .error, origin: .runtime, source: "Page")
            update = .append([built])
            shown = FWDevText.firstLine(built.message)
        }
        return FWDevWireEvent(kind: known.kind, title: known.title, detail: shown, issueUpdate: update,
                              isUpdate: name == "nuxt.app:data:refresh" || name == "storybook.storyHotUpdated",
                              clearsRuntimeIssues: name == "nuxt.app:error:cleared")
    }
}

// MARK: - Observations, state and resolution

struct FWDevEnvEntry: Identifiable, Equatable, Sendable {
    var key: String
    var value: String
    var source: String
    var id: String { source + "|" + key }
}

/// What the page script saw about the page and its framework on one pass.
struct FWDevProbe: Equatable, Sendable {
    var signals: Set<String> = []
    var facts: [String: String] = [:]
    /// Selectors of framework overlays currently in the DOM.
    var overlayHosts: [String] = []
    var overlayHidden = false
    var env: [FWDevEnvEntry] = []
    var serviceWorkers = 0
    var cacheEntries = 0
    var pathname = ""

    func has(_ signal: FWSignal) -> Bool { signals.contains(signal.rawValue) }
}

struct FWDevSocketInfo: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case connecting, open, closed, failed }

    var id: Int
    var url: String
    var transport: String
    var protocolID: FWWireProtocol?
    /// True when the URL alone settles the protocol; a weak match (a bare /ws path) needs a decodable message first.
    var strong: Bool
    var state: State = .connecting
    var closeCode: Int?
    var openedAt: Double?
    var lastFrameAt: Double?
    var frames = 0
    var recognisedFrames = 0
    var buildEvents = 0

    var isConfirmed: Bool { protocolID != nil && (strong || recognisedFrames > 0) }

    var path: String { URLComponents(string: url)?.path ?? url }
}

enum FWDevConnection: Equatable, Sendable {
    case noSocket, connecting, connected
    case disconnected(code: Int?)
}

struct FWDevState: Equatable, Sendable {
    static let maxEvents = 120
    static let maxIssues = 50

    var sockets: [FWDevSocketInfo] = []
    var events: [FWDevEvent] = []
    var buildState: FWBuildState = .unknown
    var buildIssues: [FWDevIssue] = []
    var runtimeIssues: [FWDevIssue] = []
    var lastUpdateAt: Double?
    var updateCount = 0
    var bundlerHint: FWBundler?
    var frameworkVersion: String?
    var staleness: String?
    var staticRoutes: [String: Bool] = [:]
    var serverSession: String?
    private var nextEventID = 1

    var confirmedSockets: [FWDevSocketInfo] { sockets.filter(\.isConfirmed) }

    /// The socket the header speaks for: an open one first, then the most recent.
    var primarySocket: FWDevSocketInfo? {
        let confirmed = confirmedSockets
        return confirmed.last(where: { $0.state == .open }) ?? confirmed.last(where: { $0.state == .connecting }) ?? confirmed.last
    }

    var connection: FWDevConnection {
        let confirmed = confirmedSockets
        if confirmed.isEmpty { return .noSocket }
        if confirmed.contains(where: { $0.state == .open }) { return .connected }
        if confirmed.contains(where: { $0.state == .connecting }) { return .connecting }
        return .disconnected(code: confirmed.last?.closeCode)
    }

    var allIssues: [FWDevIssue] { buildIssues + runtimeIssues }
    var errorCount: Int { allIssues.filter { $0.severity == .error }.count }

    /// A new document: sockets and issues belong to the old one. The timeline is kept when the origin did not change,
    /// so a full reload shows up as a row instead of erasing the history.
    mutating func resetForNewDocument(keepHistory: Bool) {
        let kept = keepHistory ? self : FWDevState()
        self = FWDevState()
        if keepHistory {
            events = kept.events
            lastUpdateAt = kept.lastUpdateAt
            updateCount = kept.updateCount
            nextEventID = kept.nextEventID
        }
    }

    mutating func addEvent(kind: FWDevEventKind, title: String, detail: String? = nil, at: Double) {
        events.append(FWDevEvent(id: nextEventID, at: at, kind: kind, title: title, detail: detail))
        nextEventID += 1
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    mutating func clearTimeline() { events.removeAll() }
    mutating func clearRuntimeIssues() { runtimeIssues.removeAll() }

    // MARK: Sockets

    mutating func socketOpened(id: Int, url: String, subprotocols: [String], transport: String, pageHost: String,
                               hints: Set<FWWireProtocol>, at: Double) {
        guard !sockets.contains(where: { $0.id == id }) else { return }
        let identified = FWDevWire.identify(url: url, subprotocols: subprotocols, pageHost: pageHost, hints: hints)
        sockets.append(FWDevSocketInfo(id: id, url: url, transport: transport,
                                       protocolID: identified?.protocolID, strong: identified?.strong ?? false))
        if sockets.count > 24 { sockets.removeFirst(sockets.count - 24) }
    }

    mutating func socketState(id: Int, state: FWDevSocketInfo.State, code: Int?, at: Double) {
        guard let index = sockets.firstIndex(where: { $0.id == id }) else { return }
        sockets[index].state = state
        if let code { sockets[index].closeCode = code }
        if state == .open { sockets[index].openedAt = at }
        guard let protocolID = sockets[index].protocolID, sockets[index].isConfirmed else { return }
        switch state {
        case .open:
            addEvent(kind: .connection, title: "Connected", detail: protocolID.title, at: at)
        case .closed:
            addEvent(kind: .warning, title: "Disconnected", detail: code.map { "code \($0)" } ?? protocolID.title, at: at)
        case .failed:
            addEvent(kind: .error, title: "Socket error", detail: protocolID.title, at: at)
        case .connecting:
            break
        }
    }

    mutating func receiveFrame(socketID: Int, text: String, binaryLength: Int?, at: Double) {
        guard let index = sockets.firstIndex(where: { $0.id == socketID }) else { return }
        sockets[index].frames += 1
        sockets[index].lastFrameAt = at
        guard let protocolID = sockets[index].protocolID, let text = binaryLength == nil ? text : nil else { return }
        let wasConfirmed = sockets[index].isConfirmed
        let decoded = FWDevWire.decode(protocolID: protocolID, text: text)
        guard !decoded.isEmpty else { return }
        sockets[index].recognisedFrames += 1
        if !wasConfirmed, sockets[index].isConfirmed, sockets[index].state == .open {
            addEvent(kind: .connection, title: "Connected", detail: protocolID.title, at: sockets[index].openedAt ?? at)
        }
        for var event in decoded {
            let isBuildEvent = event.kind == .built || event.kind == .building || event.kind == .error && event.buildState != nil
            if event.snapshotIfFirst, sockets[index].buildEvents == 0 {
                event.isUpdate = false
                event.title += " (initial)"
            }
            if isBuildEvent { sockets[index].buildEvents += 1 }
            apply(event, at: at)
        }
    }

    // MARK: Events

    mutating func apply(_ event: FWDevWireEvent, at: Double) {
        if let bundler = event.bundler { bundlerHint = bundler }
        if let version = event.frameworkVersion, !version.isEmpty { frameworkVersion = version }
        if let staleness = event.staleness { self.staleness = staleness }
        if let map = event.staticRoutes { staticRoutes = map }
        if let session = event.session {
            if let old = serverSession, old != session {
                addEvent(kind: .warning, title: "Dev server restarted", at: at)
            }
            serverSession = session
        }
        if let state = event.buildState { buildState = state }
        applyIssues(event.issueUpdate)
        if event.clearsRuntimeIssues { runtimeIssues.removeAll() }
        if event.isUpdate {
            lastUpdateAt = at
            updateCount += 1
        }
        if event.inTimeline { addEvent(kind: event.kind, title: event.title, detail: event.detail, at: at) }
    }

    private mutating func applyIssues(_ update: FWDevIssueUpdate) {
        switch update {
        case .none:
            break
        case .replaceAll(let issues):
            buildIssues = Array(issues.filter { $0.origin == .build }.prefix(Self.maxIssues))
            appendRuntime(issues.filter { $0.origin == .runtime })
        case .replace(let severity, let issues):
            buildIssues.removeAll { $0.severity == severity }
            buildIssues.append(contentsOf: issues.filter { $0.origin == .build })
            if buildIssues.count > Self.maxIssues { buildIssues.removeFirst(buildIssues.count - Self.maxIssues) }
        case .append(let issues):
            for issue in issues where issue.origin == .build && !buildIssues.contains(where: { $0.id == issue.id }) {
                buildIssues.append(issue)
            }
            if buildIssues.count > Self.maxIssues { buildIssues.removeFirst(buildIssues.count - Self.maxIssues) }
            appendRuntime(issues.filter { $0.origin == .runtime })
        }
    }

    private mutating func appendRuntime(_ issues: [FWDevIssue]) {
        for issue in issues where !runtimeIssues.contains(where: { $0.id == issue.id }) { runtimeIssues.append(issue) }
        if runtimeIssues.count > Self.maxIssues { runtimeIssues.removeFirst(runtimeIssues.count - Self.maxIssues) }
    }
}

// MARK: Resolution

enum FWDevMode: Equatable, Sendable { case development, production, notDetected }

struct FWDevResolution: Equatable, Sendable {
    var adapter: FWDevAdapter?
    var bundler: FWBundler?
    var protocolID: FWWireProtocol?
    var mode: FWDevMode
    var version: String?
    /// Evidence for the conclusion, for the "why" disclosure.
    var reasons: [String]
    /// Places where signals disagree; shown rather than hidden.
    var conflicts: [String]

    var frameworkName: String { adapter?.name ?? "No framework" }
}

enum FWDevLogic {

    static func resolve(detections: [FWDetected], probe: FWDevProbe, state: FWDevState) -> FWDevResolution {
        let strong = detections.filter { $0.confidence >= .likely }
        func detected(_ adapter: FWDevAdapter) -> FWDetected? {
            strong.filter { adapter.detectionNames.contains($0.name) }.max { $0.confidence < $1.confidence }
        }
        let matches: [(adapter: FWDevAdapter, detection: FWDetected)] = FWDevAdapters.all.compactMap { adapter -> (adapter: FWDevAdapter, detection: FWDetected)? in
            guard let found = detected(adapter) else { return nil }
            return (adapter, found)
        }.sorted { a, b in
            if a.adapter.specificity != b.adapter.specificity { return a.adapter.specificity > b.adapter.specificity }
            return a.detection.confidence > b.detection.confidence
        }

        var reasons: [String] = []
        var conflicts: [String] = []
        let primarySocket = state.primarySocket
        let protocolID = primarySocket?.protocolID

        var adapter = matches.first?.adapter
        var version = matches.first?.detection.version
        if let top = matches.first {
            reasons.append("\(top.adapter.name) detected from: " + top.detection.evidence.joined(separator: ", "))
            let others = matches.dropFirst().filter { $0.adapter.specificity >= 30 }
            if !others.isEmpty {
                conflicts.append("Also detected: " + others.map { $0.adapter.name }.joined(separator: ", ")
                                 + ". \(top.adapter.name) is the more specific match.")
            }
        } else if let protocolID, let fallback = FWDevAdapters.adapter(id: FWDevAdapters.adapterID(for: protocolID)) {
            adapter = fallback
            reasons.append("No framework detected; taking \(fallback.name) from the \(protocolID.title) socket")
        }

        if adapter?.id == "next", let installed = state.frameworkVersion { version = installed }

        if let socket = primarySocket, let protocolID {
            reasons.append("\(protocolID.title) socket \(socket.path.isEmpty ? socket.url : socket.path)")
            if let adapter, !protocolID.compatibleBundlers.isEmpty, !adapter.bundlers.isEmpty,
               !adapter.bundlers.contains(where: { protocolID.compatibleBundlers.contains($0) }) {
                conflicts.append("The HMR socket speaks \(protocolID.title), which \(adapter.name) does not normally use.")
            }
        }
        if probe.has(.viteClient), let adapter, !adapter.bundlers.isEmpty, !adapter.bundlers.contains(.vite) {
            conflicts.append("The page loads /@vite/client, which \(adapter.name) does not normally use.")
        }

        var bundler = state.bundlerHint
        if bundler == nil, probe.has(.nextTurbopack) { bundler = .turbopack }
        if bundler == nil, let protocolID, protocolID != .next { bundler = protocolID.impliedBundler }
        if bundler == .unknown { bundler = nil }
        if bundler == nil, let adapter, adapter.bundlers.count == 1 { bundler = adapter.bundlers[0] }
        if bundler == nil {
            if strong.contains(where: { $0.name == "Turbopack" }) { bundler = .turbopack }
            else if strong.contains(where: { $0.name == "Vite" }) { bundler = .vite }
            else if strong.contains(where: { $0.name == "webpack" }) { bundler = .webpack }
        }

        let devSignals = adapter?.devSignals.filter { probe.has($0) } ?? []
        let mode: FWDevMode
        if !state.confirmedSockets.isEmpty || !devSignals.isEmpty {
            mode = .development
            if !devSignals.isEmpty { reasons.append("Development-only signals: " + devSignals.map(\.rawValue).joined(separator: ", ")) }
        } else if adapter != nil {
            mode = .production
            reasons.append("No HMR socket and none of \(adapter?.name ?? "the framework")'s development signals")
        } else {
            mode = .notDetected
        }

        return FWDevResolution(adapter: adapter, bundler: bundler, protocolID: protocolID, mode: mode,
                               version: version, reasons: reasons, conflicts: conflicts)
    }

    // MARK: Header

    struct Header: Equatable, Sendable {
        var title: String
        var subtitle: String?
        var modeLabel: String
        var bundlerLabel: String?
        var connectionLabel: String
        /// 0 neutral, 1 good, 2 warning, 3 bad.
        var connectionTone: Int
        var buildLabel: String
        var buildTone: Int
    }

    static func header(resolution r: FWDevResolution, state: FWDevState, probe: FWDevProbe) -> Header {
        let title = r.adapter?.name ?? "No dev server detected"
        var subtitleParts: [String] = []
        if let version = r.version { subtitleParts.append("v\(version)") }
        if r.adapter?.id == "next" {
            if probe.has(.nextApp) { subtitleParts.append("App Router") } else if probe.has(.nextPages) { subtitleParts.append("Pages Router") }
        }
        var bundlerLabel = r.bundler?.title
        if r.adapter?.id == "angular", r.bundler == .vite { bundlerLabel = "Vite (esbuild)" }

        let modeLabel: String
        switch r.mode {
        case .development: modeLabel = "Development"
        case .production: modeLabel = "Production build"
        case .notDetected: modeLabel = "Not detected"
        }

        var connectionLabel = "No HMR socket"
        var connectionTone = 0
        switch state.connection {
        case .noSocket:
            connectionLabel = r.mode == .production ? "None (production)" : "No HMR socket"
        case .connecting:
            connectionLabel = "Connecting"; connectionTone = 2
        case .connected:
            connectionLabel = "Connected"; connectionTone = 1
        case .disconnected(let code):
            connectionLabel = code.map { "Disconnected (\($0))" } ?? "Disconnected"; connectionTone = 3
        }

        let buildLabel: String
        let buildTone: Int
        switch state.buildState {
        case .unknown: buildLabel = "Idle"; buildTone = 0
        case .building: buildLabel = "Building"; buildTone = 2
        case .ok: buildLabel = state.allIssues.contains { $0.severity == .warning } ? "OK with warnings" : "OK"; buildTone = 1
        case .failed:
            let n = state.buildIssues.filter { $0.severity == .error }.count
            buildLabel = n > 0 ? "Failed, \(FWDevText.plural(n, "error"))" : "Failed"; buildTone = 3
        }
        return Header(title: title, subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
                      modeLabel: modeLabel, bundlerLabel: bundlerLabel, connectionLabel: connectionLabel,
                      connectionTone: connectionTone, buildLabel: buildLabel, buildTone: buildTone)
    }

    /// The text under the header when the page is not a dev server, so the empty state says why instead of showing nothing.
    static func modeExplanation(_ r: FWDevResolution) -> String? {
        switch r.mode {
        case .development:
            return nil
        case .production:
            return "This looks like a production build of \(r.frameworkName). It has no HMR socket and none of the development-only globals, so build state, errors and server controls are unavailable."
        case .notDetected:
            return "No dev server detected. Orbit looks for HMR sockets (Vite, Next.js, webpack-dev-server, Parcel, Rsbuild, LiveReload) and for each framework's development-only globals. Open a page served by a dev server, or press Refresh."
        }
    }

    // MARK: Relative time

    static func relativeAge(from then: Double, to now: Double) -> String {
        let seconds = max(0, Int(clamping: (now - then) / 1000))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }

    // MARK: Versions

    /// Compares dotted numeric versions ("15.4.0-canary.3" counts as 15.4.0). Nil when either side has no number.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool? {
        func parts(_ text: String) -> [Int]? {
            let core = text.drop(while: { $0 == "v" }).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
            let numbers = core.split(separator: ".").compactMap { Int($0) }
            return numbers.isEmpty ? nil : numbers
        }
        guard let a = parts(version), let b = parts(minimum) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return true
    }

    // MARK: Strategies

    static func refreshStrategy(adapterID: String?, probe: FWDevProbe) -> FWRefreshStrategy? {
        switch adapterID {
        case "next":
            if probe.has(.nextRouterRefresh) { return .nextAppRefresh }
            if probe.has(.nextRouterReplace), probe.has(.nextPages) { return .nextPagesReplace }
            return nil
        case "reactRouter", "remix":
            return probe.has(.routerDataRouter) ? .routerRevalidate : nil
        case "nuxt":
            return probe.has(.nuxtApp) ? .nuxtRefreshData : nil
        case "storybook":
            return probe.has(.storybookPreview) ? .storybookReRender : nil
        default:
            return nil
        }
    }

    static func navigationStrategy(adapterID: String?, probe: FWDevProbe) -> FWNavStrategy {
        switch adapterID {
        case "next" where probe.has(.nextRouterPush): return .nextRouter
        case "reactRouter" where probe.has(.routerDataRouter), "remix" where probe.has(.routerDataRouter): return .routerNavigate
        case "nuxt" where probe.has(.nuxtApp): return .nuxtRouter
        case "gatsby" where probe.has(.gatsbyNavigate): return .gatsbyNavigate
        case "angular" where probe.has(.angularRouter): return .angularRouter
        default: return .linkClick
        }
    }

    // MARK: Editor and server endpoints

    /// Percent-encodes a query value the way encodeURIComponent does.
    static func encodeComponent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Candidate "open this file" requests in the order to try them, relative to the page origin.
    static func editorRequests(adapter: FWDevAdapter?, file: String, line: Int?, column: Int?) -> [String] {
        let l = line ?? 1
        let c = column ?? 1
        let styles = adapter?.editor ?? []
        return styles.map { style in
            switch style {
            case .nextLaunchEditor:
                // 15.5 and later read line1/column1; 14 to 15.4 read lineNumber/column. Both are sent so either server version answers.
                return "/__nextjs_launch-editor?file=\(encodeComponent(file))&line1=\(l)&column1=\(c)&lineNumber=\(l)&column=\(c)"
            case .openInEditor(let prefix):
                return "\(prefix)/__open-in-editor?file=\(encodeComponent("\(file):\(l):\(c)"))"
            case .webpackOpenEditor:
                return "/webpack-dev-server/open-editor?fileName=\(encodeComponent(file))"
            case .stackFrame:
                return "/__open-stack-frame-in-editor?fileName=\(encodeComponent(file))&lineNumber=\(l)&colNumber=\(c)"
            case .parcelLaunch:
                return "/__parcel_launch_editor?file=\(encodeComponent(file))"
            }
        }
    }

    static func restartRequest(_ endpoint: FWRestartEndpoint, clearCache: Bool) -> String {
        clearCache ? "\(endpoint.path)?\(endpoint.clearCacheQuery)" : endpoint.path
    }

    static let webpackInvalidatePath = "/webpack-dev-server/invalidate"
    static let gatsbyRefreshPath = "/__refresh"
    static let draftModeCookieNames = ["__prerender_bypass", "__next_preview_data"]

    // MARK: Controls

    struct ControlState: Identifiable, Equatable, Sendable {
        var control: FWDevControl
        var enabled: Bool
        /// Why it is unavailable, or what it does when it is available.
        var note: String
        var id: String { control.rawValue }
    }

    static func controls(resolution r: FWDevResolution, probe: FWDevProbe) -> [ControlState] {
        let adapter = r.adapter
        var list: [FWDevControl] = [.reload, .hardReload, .clearCaches]
        for control in adapter?.controls ?? [] where !list.contains(control) { list.append(control) }
        if r.protocolID == .webpackDevServer, !list.contains(.rebuild) { list.append(.rebuild) }
        // The restart row is always listed, so a framework with no restart route says so instead of staying silent.
        if !list.contains(.restartServer) { list.append(.restartServer) }
        list.append(.toggleOverlay)
        let isDev = r.mode == .development
        return list.map { control in
            let (enabled, note) = availability(control, resolution: r, probe: probe, isDev: isDev)
            return ControlState(control: control, enabled: enabled, note: note)
        }
    }

    private static func availability(_ control: FWDevControl, resolution r: FWDevResolution, probe: FWDevProbe, isDev: Bool) -> (Bool, String) {
        let adapter = r.adapter
        switch control {
        case .reload:
            return (true, "Reload the page.")
        case .hardReload:
            return (true, "Unregister service workers, clear Cache Storage, then reload.")
        case .clearCaches:
            if probe.serviceWorkers + probe.cacheEntries == 0 { return (false, "No service workers or Cache Storage entries on this origin.") }
            var parts: [String] = []
            if probe.serviceWorkers > 0 { parts.append(FWDevText.plural(probe.serviceWorkers, "service worker")) }
            if probe.cacheEntries > 0 { parts.append(FWDevText.plural(probe.cacheEntries, "cache")) }
            return (true, "Remove " + parts.joined(separator: " and ") + ".")
        case .softRefresh:
            guard let adapter else { return (false, "No framework detected.") }
            guard let strategy = refreshStrategy(adapterID: adapter.id, probe: probe) else { return (false, adapter.softRefreshUnavailable) }
            switch strategy {
            case .nextAppRefresh: return (true, "router.refresh(): refetch server components without a page load.")
            case .nextPagesReplace: return (true, "router.replace(asPath): refetch page data without a page load.")
            case .routerRevalidate: return (true, "router.revalidate(): rerun every active loader.")
            case .nuxtRefreshData: return (true, "Run the app:data:refresh hook, like refreshNuxtData().")
            case .storybookReRender: return (true, "Emit forceReRender on the story channel.")
            }
        case .hmrRefresh:
            if !probe.has(.nextRouterHmrRefresh) { return (false, "Needs the App Router in development.") }
            return (true, "router.hmrRefresh(): refetch server components as an HMR update does.")
        case .toggleOverlay:
            if probe.overlayHosts.isEmpty { return (false, "No framework error overlay is mounted on this page.") }
            return (true, probe.overlayHidden ? "Show the hidden overlay again." : "Hide the overlay without dismissing its state.")
        case .restartServer, .restartClearCache:
            guard let adapter else { return (false, "No framework detected.") }
            switch adapter.restart {
            case .unavailable(let reason):
                return (false, reason)
            case .endpoint(let endpoint):
                if !isDev { return (false, "Only a development server can be restarted.") }
                if let installed = r.version, isVersion(installed, atLeast: endpoint.minVersion) == false {
                    return (false, "Needs \(adapter.name) \(endpoint.minVersion) or later (this is \(installed)).")
                }
                let tail = control == .restartClearCache ? " and invalidate the bundler's filesystem cache." : "."
                return (true, "POST \(endpoint.path), then wait for the server to come back" + tail + " Works when started with next dev.")
            }
        case .rebuild:
            if r.protocolID != .webpackDevServer { return (false, "Needs a webpack-dev-server connection, which is not present.") }
            if !isDev { return (false, "Only a development server can rebuild.") }
            return (true, "GET \(webpackInvalidatePath): invalidate the compiler and rebuild.")
        case .refreshSourceData:
            if !isDev { return (false, "Only gatsby develop serves this route.") }
            return (true, "POST /__refresh. Gatsby answers 404 unless started with ENABLE_GATSBY_REFRESH_ENDPOINT=true.")
        case .exitDraftMode:
            if !probe.has(.draftModeCookie) { return (false, "Draft mode is off (no __prerender_bypass cookie for this site).") }
            return (true, "Delete the __prerender_bypass and __next_preview_data cookies. Entering draft mode needs an app route handler that calls draftMode().enable().")
        }
    }

    // MARK: Render and route information

    struct InfoRow: Identifiable, Equatable, Sendable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// Cache-Control as Next sets it for static and revalidated pages: `s-maxage=60, stale-while-revalidate=...`.
    static func cacheHints(headers: [String: String]) -> [InfoRow] {
        var rows: [InfoRow] = []
        let control = (headers["cache-control"] ?? "").lowercased()
        if let status = headers["x-nextjs-cache"] { rows.append(InfoRow(label: "Cache", value: status)) }
        if headers["x-nextjs-prerender"] == "1" { rows.append(InfoRow(label: "Prerendered", value: "yes")) }
        if let age = directive("s-maxage", in: control) {
            rows.append(InfoRow(label: "Revalidate", value: age == 0 ? "on every request" : "every \(age) s"))
        } else if control.contains("no-store") || control.contains("no-cache") {
            rows.append(InfoRow(label: "Revalidate", value: "not cached"))
        }
        if let stale = headers["x-nextjs-stale-time"] { rows.append(InfoRow(label: "Client stale time", value: "\(stale) s")) }
        return rows
    }

    private static func directive(_ name: String, in control: String) -> Int? {
        for part in control.split(separator: ",") {
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pieces.count == 2, pieces[0] == name { return Int(pieces[1]) }
        }
        return nil
    }

    /// What `__NEXT_DATA__` says about how a Pages Router page was rendered.
    static func nextPagesRenderMode(facts: [String: String]) -> String? {
        func on(_ key: String) -> Bool { facts[key] == "true" }
        if on("next.isFallback") { return "Fallback shell (getStaticPaths fallback)" }
        if on("next.gssp") { return "Server-side rendered (getServerSideProps)" }
        if on("next.gsp") { return "Statically generated (getStaticProps)" }
        if on("next.appGip") { return "Server rendered (getInitialProps in _app)" }
        if on("next.gip") { return "Server rendered (getInitialProps)" }
        if on("next.autoExport") { return "Automatic static optimization" }
        if on("next.nextExport") { return "Statically exported" }
        return nil
    }

    static func renderInfo(resolution r: FWDevResolution, probe: FWDevProbe, state: FWDevState, headers: [String: String]) -> [InfoRow] {
        var rows: [InfoRow] = []
        let facts = probe.facts
        func add(_ label: String, _ key: String) { if let value = facts[key], !value.isEmpty { rows.append(InfoRow(label: label, value: value)) } }
        switch r.adapter?.id {
        case "next":
            let appRouter = probe.has(.nextApp) && facts["next.router"] != "pages"
            rows.append(InfoRow(label: "Router", value: appRouter ? "App Router" : "Pages Router"))
            if appRouter {
                if let isStatic = state.staticRoutes[probe.pathname] {
                    rows.append(InfoRow(label: "Route", value: isStatic ? "Static (prerendered)" : "Dynamic (rendered per request)"))
                }
            } else if let mode = nextPagesRenderMode(facts: facts) {
                rows.append(InfoRow(label: "Rendering", value: mode))
            }
            add("Page", "next.page")
            if facts["next.isPreview"] == "true" { rows.append(InfoRow(label: "Preview mode", value: "on")) }
            rows.append(contentsOf: cacheHints(headers: headers))
            if state.staleness == "stale-patch" || state.staleness == "stale-minor" || state.staleness == "stale-major" {
                rows.append(InfoRow(label: "Version", value: "outdated (\(state.staleness ?? ""))"))
            }
        case "nuxt":
            if let rendered = facts["nuxt.serverRendered"] { rows.append(InfoRow(label: "Rendering", value: rendered == "true" ? "Server rendered" : "Client rendered (SPA)")) }
            add("Vue", "vue.version")
            add("Base URL", "nuxt.baseURL")
            add("Build id", "nuxt.buildId")
        case "reactRouter", "remix":
            if let ssr = facts["rr.ssr"] { rows.append(InfoRow(label: "Rendering", value: ssr == "true" ? "Server rendered" : "SPA mode")) }
            add("Base path", "rr.basename")
        case "astro":
            add("Islands", "astro.islands")
            add("Project root", "astro.root")
            if probe.facts["astro.sourceAttrs"] == "true" { rows.append(InfoRow(label: "Source locations", value: "data-astro-source-file present")) }
        case "sveltekit":
            add("Svelte", "svelte.major")
        case "angular":
            add("Hydration", "angular.hydration")
        case "qwik":
            add("Render", "qwik.render")
            add("Qwik", "qwik.version")
        case "storybook":
            add("Story", "storybook.story")
        default:
            break
        }
        return rows
    }
}
