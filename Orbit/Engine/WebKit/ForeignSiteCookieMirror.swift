import Foundation
import WebKit

/// A Site Profile store is only meant to hold its own site. When a page on it visits another site (a Google sign-in popup
/// or redirect), that site is shown with the Space's cookies, and whatever the visit changes there goes back to the Space.
@MainActor
final class ForeignSiteCookieMirror {

    struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            domain = cookie.domain.lowercased()
            path = cookie.path
        }
    }

    struct Plan {
        var set: [HTTPCookie] = []
        var delete: [HTTPCookie] = []
    }

    private let pageStore: WebKitSession
    private let spaceStore: WebKitSession
    private let ownSite: String
    private var visiting: String?
    private var snapshots: [String: [CookieKey: HTTPCookie]] = [:]

    init(pageStore: WebKitSession, spaceStore: WebKitSession, ownSite: String) {
        self.pageStore = pageStore
        self.spaceStore = spaceStore
        self.ownSite = ownSite
    }

    var visitingSite: String? { visiting }

    func willNavigate(to url: URL) async {
        let site = SiteProfile.siteKey(for: url)
        if let visiting, visiting != site {
            await returnChanges(for: visiting)
            self.visiting = nil
        }
        guard let site, site != ownSite, site != visiting else { return }
        await bringIn(site)
        visiting = site
    }

    func finish() async {
        guard let visiting else { return }
        await returnChanges(for: visiting)
        self.visiting = nil
    }

    private func bringIn(_ site: String) async {
        let source = await spaceStore.cookies(forSite: site)
        let existing = await pageStore.cookies(forSite: site)
        let plan = Self.mirrorPlan(source: source, existing: existing)
        for cookie in plan.delete { await pageStore.dataStore.httpCookieStore.deleteCookie(cookie) }
        for cookie in plan.set { await pageStore.dataStore.httpCookieStore.setCookie(cookie) }
        snapshots[site] = Self.keyed(source)
    }

    private func returnChanges(for site: String) async {
        guard let base = snapshots.removeValue(forKey: site) else { return }
        let visited = await pageStore.cookies(forSite: site)
        let current = await spaceStore.cookies(forSite: site)
        let plan = Self.returnPlan(base: base, visited: visited, current: current)
        for cookie in plan.delete { await spaceStore.dataStore.httpCookieStore.deleteCookie(cookie) }
        for cookie in plan.set { await spaceStore.dataStore.httpCookieStore.setCookie(cookie) }
    }

    /// Makes the page store's cookies for a site exactly the Space's.
    static func mirrorPlan(source: [HTTPCookie], existing: [HTTPCookie]) -> Plan {
        let sourceKeys = Set(source.map(CookieKey.init))
        return Plan(set: source, delete: existing.filter { !sourceKeys.contains(CookieKey($0)) })
    }

    /// Only what the visit itself changed goes back, and a cookie the Space has since changed on its own is left as the Space has it.
    static func returnPlan(base: [CookieKey: HTTPCookie], visited: [HTTPCookie], current: [HTTPCookie]) -> Plan {
        let visitedByKey = keyed(visited)
        let currentByKey = keyed(current)
        var plan = Plan()
        for (key, cookie) in visitedByKey {
            if let original = base[key], same(original, cookie) { continue }
            if let original = base[key], let now = currentByKey[key], !same(original, now) { continue }
            plan.set.append(cookie)
        }
        for (key, original) in base where visitedByKey[key] == nil {
            guard let now = currentByKey[key], same(now, original) else { continue }
            plan.delete.append(now)
        }
        return plan
    }

    static func keyed(_ cookies: [HTTPCookie]) -> [CookieKey: HTTPCookie] {
        Dictionary(cookies.map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
    }

    static func same(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.value == b.value && a.expiresDate == b.expiresDate && a.isSecure == b.isSecure && a.isHTTPOnly == b.isHTTPOnly
    }
}
