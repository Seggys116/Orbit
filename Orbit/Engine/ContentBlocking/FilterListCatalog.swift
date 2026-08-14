import Foundation

nonisolated public enum FilterListCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case generic
    case privacy
    case cookies
    case regional
    case compatibility

    public var displayName: String {
        switch self {
        case .generic: return "Ad Blockers"
        case .privacy: return "Trackers"
        case .cookies: return "Cookie Banners"
        case .regional: return "Regional Ad Blockers"
        case .compatibility: return "Site Fixes"
        }
    }

    public var settingsRowTitle: String? {
        switch self {
        case .generic: return "Block Ads"
        case .privacy: return "Block Trackers"
        case .cookies: return "Block Cookie Banners"
        case .regional: return nil
        case .compatibility: return "Fix Sites Broken by Blocking"
        }
    }

    public var settingsRowFootnote: String? {
        switch self {
        case .cookies: return "Blocking cookie banners may cause pages to load incorrectly."
        case .compatibility:
            return "Un-blocks the handful of requests that a filter list gets wrong and a site cannot load without."
        default: return nil
        }
    }
}

nonisolated public struct FilterListDescriptor: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var category: FilterListCategory
    public var urls: [URL]
    public var infoURL: URL?
    public var licence: String
    public var licenceURL: URL?
    public var isDefaultEnabled: Bool
}

nonisolated public enum FilterListCatalog {

    // Every string below is a compile-time literal; a failure here is a typo, not a runtime condition.
    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Malformed catalogue URL literal: \(string)")
        }
        return url
    }

    private static let gplV3 = "GNU GPL v3"
    private static let gplV3URL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")
    private static let easyListLicence = "GNU GPL v3 / CC BY-SA 3.0"
    private static let easyListLicenceURL = URL(string: "https://easylist.to/pages/licence.html")

    public static let all: [FilterListDescriptor] = [
        // MARK: Generic — ads
        FilterListDescriptor(
            id: "EasyList",
            displayName: "EasyList",
            category: .generic,
            urls: [url("https://easylist.to/easylist/easylist.txt")],
            infoURL: url("https://easylist.to/"),
            licence: easyListLicence,
            licenceURL: easyListLicenceURL,
            isDefaultEnabled: true
        ),
        FilterListDescriptor(
            id: "AdGuardAds",
            displayName: "AdGuard - Ads",
            category: .generic,
            urls: [url("https://filters.adtidy.org/extension/ublock/filters/2_without_easylist.txt")],
            infoURL: url("https://github.com/AdguardTeam/AdguardFilters#adguard-filters"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: false
        ),
        FilterListDescriptor(
            id: "uBlock",
            displayName: "uBlock Origin filters",
            category: .generic,
            urls: [
                url("https://ublockorigin.github.io/uAssets/filters/filters.txt"),
                url("https://ublockorigin.github.io/uAssets/filters/filters-2026.txt"),
                url("https://ublockorigin.github.io/uAssets/filters/ubo-link-shorteners.txt"),
                url("https://ublockorigin.github.io/uAssets/filters/badware.txt"),
                url("https://ublockorigin.github.io/uAssets/filters/privacy.txt"),
            ],
            infoURL: url("https://github.com/uBlockOrigin/uAssets"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: true
        ),

        // MARK: Privacy & tracking
        FilterListDescriptor(
            id: "EasyPrivacy",
            displayName: "EasyPrivacy",
            category: .privacy,
            urls: [url("https://easylist.to/easylist/easyprivacy.txt")],
            infoURL: url("https://easylist.to/"),
            licence: easyListLicence,
            licenceURL: easyListLicenceURL,
            isDefaultEnabled: true
        ),
        FilterListDescriptor(
            id: "AdGuardSpyware",
            displayName: "AdGuard Tracking Protection",
            category: .privacy,
            urls: [url("https://filters.adtidy.org/extension/ublock/filters/3.txt")],
            infoURL: url("https://github.com/AdguardTeam/AdguardFilters#adguard-filters"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: false
        ),
        FilterListDescriptor(
            id: "EasyListSocial",
            displayName: "EasyList - Social Widgets",
            category: .privacy,
            urls: [url("https://easylist.to/easylist/fanboy-social.txt")],
            infoURL: url("https://easylist.to/"),
            licence: easyListLicence,
            licenceURL: easyListLicenceURL,
            isDefaultEnabled: false
        ),
        FilterListDescriptor(
            id: "AdGuardSocial",
            displayName: "AdGuard – Social Widgets",
            category: .privacy,
            urls: [url("https://filters.adtidy.org/extension/ublock/filters/4.txt")],
            infoURL: url("https://github.com/AdguardTeam/AdguardFilters#adguard-filters"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: false
        ),
        FilterListDescriptor(
            id: "FanBoyThirdParty",
            displayName: "Fanboy – Anti-Facebook",
            category: .privacy,
            urls: [url("https://secure.fanboy.co.nz/fanboy-antifacebook.txt")],
            infoURL: url("https://github.com/easylist/easylist#fanboy-lists"),
            licence: easyListLicence,
            licenceURL: easyListLicenceURL,
            isDefaultEnabled: false
        ),

        // MARK: Cookie notices
        FilterListDescriptor(
            id: "CookieMonster",
            displayName: "CookieMonster by Fanboy",
            category: .cookies,
            urls: [url("https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")],
            infoURL: url("https://github.com/easylist/easylist#fanboy-lists"),
            licence: easyListLicence,
            licenceURL: easyListLicenceURL,
            isDefaultEnabled: false
        ),
        FilterListDescriptor(
            id: "AdGuardCookies",
            displayName: "AdGuard – Cookie Notices",
            category: .cookies,
            urls: [url("https://filters.adtidy.org/extension/ublock/filters/18.txt")],
            infoURL: url("https://github.com/AdguardTeam/AdguardFilters#adguard-filters"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: false
        ),

        // MARK: Site compatibility
        FilterListDescriptor(
            id: "uBlockUnbreak",
            displayName: "uBlock Origin – Unbreak",
            category: .compatibility,
            urls: [
                url("https://ublockorigin.github.io/uAssets/filters/unbreak.txt"),
                url("https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt"),
            ],
            infoURL: url("https://github.com/uBlockOrigin/uAssets"),
            licence: gplV3,
            licenceURL: gplV3URL,
            isDefaultEnabled: true
        ),

        // MARK: Regional
        regional("de", "EasyList Germany", "https://easylist.to/easylistgermany/easylistgermany.txt", easyListLicence, easyListLicenceURL),
        regional("fr", "AdGuard Français", "https://filters.adtidy.org/extension/ublock/filters/16.txt", gplV3, gplV3URL),
        regional("es", "EasyList Spanish", "https://easylist.to/easylistspanish/easylistspanish.txt", easyListLicence, easyListLicenceURL),
        regional("it", "EasyList Italy", "https://easylist-downloads.adblockplus.org/easylistitaly.txt", easyListLicence, easyListLicenceURL),
        regional("pl", "EasyList - Polska lista", "https://easylist-downloads.adblockplus.org/easylistpolish.txt", easyListLicence, easyListLicenceURL),
        regional("nl", "EasyList Dutch", "https://easylist-downloads.adblockplus.org/easylistdutch.txt", easyListLicence, easyListLicenceURL),
        regional("cssk", "EasyList Czech and Slovak", "https://raw.githubusercontent.com/tomasko126/easylistczechandslovak/master/filters.txt", gplV3, gplV3URL),
        regional("lt", "EasyList Lithuania", "https://easylist-downloads.adblockplus.org/easylistlithuania.txt", easyListLicence, easyListLicenceURL),
        regional("il", "EasyList Hebrew", "https://raw.githubusercontent.com/easylist/EasyListHebrew/master/EasyListHebrew.txt", gplV3, gplV3URL),
        regional("zn", "AdGuard Chinese (中文)", "https://filters.adtidy.org/extension/ublock/filters/224.txt", gplV3, gplV3URL),
        regional("jp", "AdGuard Japanese", "https://filters.adtidy.org/extension/ublock/filters/7.txt", gplV3, gplV3URL),
        regional("tr", "AdGuard Turkish", "https://filters.adtidy.org/extension/ublock/filters/13.txt", gplV3, gplV3URL),
        regional("ru", "RU AdList", "https://easylist-downloads.adblockplus.org/advblock+cssfixes.txt", gplV3, gplV3URL),
    ]

    private static func regional(
        _ id: String,
        _ name: String,
        _ urlString: String,
        _ licence: String,
        _ licenceURL: URL?
    ) -> FilterListDescriptor {
        FilterListDescriptor(
            id: id,
            displayName: name,
            category: .regional,
            urls: [url(urlString)],
            infoURL: nil,
            licence: licence,
            licenceURL: licenceURL,
            isDefaultEnabled: false
        )
    }

    public static func descriptor(id: String) -> FilterListDescriptor? {
        all.first { $0.id == id }
    }

    public static func lists(in category: FilterListCategory) -> [FilterListDescriptor] {
        all.filter { $0.category == category }
    }

    public static var defaultEnabledIDs: Set<String> {
        Set(all.filter(\.isDefaultEnabled).map(\.id))
    }
}
