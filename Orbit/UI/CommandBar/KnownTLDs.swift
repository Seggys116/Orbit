//  Chromium's omnibox only treats a bare "word.word" input as a confident
//  navigation when the host's final label is a real, registered TLD
//  (net::registry_controlled_domains::GetCanonicalHostRegistryLength in
//  components/omnibox/browser/autocomplete_input.cc). Orbit can't link
//  Chromium's public-suffix data into pure-Swift code, so this is a curated
//  stand-in: every ISO 3166-1 ccTLD plus the IANA-original and the common
//  modern gTLDs. Anything not in here (like the "c" in "google.c") is
//  treated as an unfinished domain, not a destination.
enum KnownTLDs {

    private static let countryCodes: Set<String> = [
        "ac", "ad", "ae", "af", "ag", "ai", "al", "am", "ao", "aq", "ar", "as", "at", "au", "aw", "ax", "az",
        "ba", "bb", "bd", "be", "bf", "bg", "bh", "bi", "bj", "bl", "bm", "bn", "bo", "bq", "br", "bs", "bt",
        "bv", "bw", "by", "bz",
        "ca", "cc", "cd", "cf", "cg", "ch", "ci", "ck", "cl", "cm", "cn", "co", "cr", "cu", "cv", "cw", "cx",
        "cy", "cz",
        "de", "dj", "dk", "dm", "do", "dz",
        "ec", "ee", "eg", "eh", "er", "es", "et", "eu",
        "fi", "fj", "fk", "fm", "fo", "fr",
        "ga", "gb", "gd", "ge", "gf", "gg", "gh", "gi", "gl", "gm", "gn", "gp", "gq", "gr", "gs", "gt", "gu",
        "gw", "gy",
        "hk", "hm", "hn", "hr", "ht", "hu",
        "id", "ie", "il", "im", "in", "io", "iq", "ir", "is", "it",
        "je", "jm", "jo", "jp",
        "ke", "kg", "kh", "ki", "km", "kn", "kp", "kr", "kw", "ky", "kz",
        "la", "lb", "lc", "li", "lk", "lr", "ls", "lt", "lu", "lv", "ly",
        "ma", "mc", "md", "me", "mf", "mg", "mh", "mk", "ml", "mm", "mn", "mo", "mp", "mq", "mr", "ms", "mt",
        "mu", "mv", "mw", "mx", "my", "mz",
        "na", "nc", "ne", "nf", "ng", "ni", "nl", "no", "np", "nr", "nu", "nz",
        "om",
        "pa", "pe", "pf", "pg", "ph", "pk", "pl", "pm", "pn", "pr", "ps", "pt", "pw", "py",
        "qa",
        "re", "ro", "rs", "ru", "rw",
        "sa", "sb", "sc", "sd", "se", "sg", "sh", "si", "sj", "sk", "sl", "sm", "sn", "so", "sr", "ss", "st",
        "su", "sv", "sx", "sy", "sz",
        "tc", "td", "tf", "tg", "th", "tj", "tk", "tl", "tm", "tn", "to", "tr", "tt", "tv", "tw", "tz",
        "ua", "ug", "uk", "us", "uy", "uz",
        "va", "vc", "ve", "vg", "vi", "vn", "vu",
        "wf", "ws",
        "ye", "yt",
        "za", "zm", "zw",
    ]

    private static let ianaOriginal: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "biz", "info", "name", "pro",
        "aero", "asia", "cat", "coop", "jobs", "mobi", "museum", "post", "tel", "travel", "xxx", "arpa",
    ]

    // RFC 6761 reserved domains: only reachable through detectTypedURL when
    // the caller already required a subdomain (a bare "example" has no dot).
    private static let reserved: Set<String> = ["example", "test", "local", "internal"]

    private static let modernGTLDs: Set<String> = [
        "zip", "mov", "foo", "dad", "phd", "prof", "esq", "new", "day", "rsvp", "blog", "art", "design",
        "digital", "click", "chat", "book", "fun", "ing", "meme", "boo", "channel", "nexus", "here",
        "how", "soy", "eat", "gle", "search", "map", "mba", "phd", "sport", "wine", "gold", "green",
        "app", "dev", "page", "xyz", "club", "online", "site", "tech", "store", "shop", "cloud", "live",
        "world", "life", "run", "work", "team", "news", "media", "agency", "company", "email", "expert",
        "finance", "fund", "games", "guru", "help", "host", "insurance", "insure", "kitchen", "land", "law",
        "lawyer", "legal", "link", "loan", "lol", "love", "ltd", "market", "marketing", "men", "menu",
        "money", "mortgage", "movie", "music", "network", "ninja", "one", "ooo", "partners", "party", "pet",
        "photo", "photography", "photos", "pics", "pictures", "pink", "pizza", "plumbing", "plus", "poker",
        "porn", "press", "productions", "promo", "properties", "protection", "pub", "quest", "racing",
        "radio", "realestate", "realty", "recipes", "red", "rehab", "rent", "rentals", "repair", "report",
        "rest", "restaurant", "review", "reviews", "rich", "rip", "rocks", "rodeo", "rugby", "sale", "salon",
        "save", "school", "science", "security", "services", "sex", "sexy", "shoes", "shopping", "show",
        "singles", "ski", "sky", "social", "software", "solar", "solutions", "song", "space", "sport",
        "spot", "storage", "stream", "studio", "study", "style", "sucks", "supplies", "supply", "support",
        "surf", "surgery", "systems", "tattoo", "tax", "taxi", "technology", "tennis", "theater", "theatre",
        "tickets", "tips", "tires", "today", "tools", "top", "tours", "town", "toys", "trade", "trading",
        "training", "tube", "university", "uno", "vacations", "vegas", "ventures", "vet", "video", "villas",
        "vin", "vip", "vision", "vodka", "vote", "voting", "voyage", "watch", "watches", "weather", "webcam",
        "website", "wedding", "wiki", "win", "wine", "works", "wtf", "yoga", "zone",
    ]

    private static let all: Set<String> = countryCodes
        .union(ianaOriginal)
        .union(reserved)
        .union(modernGTLDs)

    static func isKnown(tld: String) -> Bool {
        all.contains(tld.lowercased())
    }

    static var count: Int { all.count }

    // Chrome treats a fully-dotted IPv4 quad as navigable regardless of the
    // last "label" (autocomplete_input.cc's separate IPV4 branch), so it's
    // checked ahead of, not through, the TLD table.
    static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return String(value) == part
        }
    }

    static func isNavigableHost(_ host: String) -> Bool {
        if isIPv4Literal(host) { return true }
        guard let lastLabel = host.split(separator: ".").last else { return false }
        return isKnown(tld: String(lastLabel))
    }
}
