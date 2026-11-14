// Sizes are CSS pixels in the natural orientation; WKWebView cannot render at another density, so `dpr` and touch are emulated in JS.

import Foundation

enum OrbitDeviceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case phone
    case tablet
    case computer
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: "Phones"
        case .tablet: "Tablets"
        case .computer: "Laptops and displays"
        case .custom: "Custom devices"
        }
    }
}

enum OrbitDeviceUserAgents {
    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let windowsEdge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0"
    static let nestHub = "Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 CrKey/1.56.500000"

    static func android(_ model: String, version: Int = 15) -> String {
        "Mozilla/5.0 (Linux; Android \(version); \(model)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"
    }
}

struct OrbitDeviceProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: OrbitDeviceCategory
    var width: Int
    var height: Int
    var dpr: Double
    var mobile: Bool
    var touch: Bool
    var userAgent: String

    var isCustom: Bool { category == .custom }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (OrbitDeviceLimits.minimum...OrbitDeviceLimits.maximum).contains(width)
            && (OrbitDeviceLimits.minimum...OrbitDeviceLimits.maximum).contains(height)
            && dpr.isFinite && dpr > 0
            && !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns nil for an empty name or a non-positive pixel ratio; an empty user agent falls back to a generic one.
    static func makeCustom(
        id: String = "custom-" + UUID().uuidString,
        name: String,
        width: Int,
        height: Int,
        dpr: Double,
        userAgent: String,
        mobile: Bool,
        touch: Bool
    ) -> OrbitDeviceProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, dpr.isFinite, dpr > 0 else { return nil }
        let trimmedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAgent = mobile ? OrbitDeviceUserAgents.iPhone : OrbitDeviceUserAgents.macSafari
        return OrbitDeviceProfile(
            id: id,
            name: trimmedName,
            category: .custom,
            width: OrbitDeviceLimits.clamp(width),
            height: OrbitDeviceLimits.clamp(height),
            dpr: min(dpr, 8),
            mobile: mobile,
            touch: touch,
            userAgent: trimmedAgent.isEmpty ? fallbackAgent : trimmedAgent
        )
    }
}

enum OrbitDevicePresets {
    private static func phone(
        _ id: String, _ name: String, _ width: Int, _ height: Int, _ dpr: Double, _ userAgent: String
    ) -> OrbitDeviceProfile {
        OrbitDeviceProfile(
            id: id, name: name, category: .phone, width: width, height: height, dpr: dpr,
            mobile: true, touch: true, userAgent: userAgent
        )
    }

    private static func tablet(
        _ id: String, _ name: String, _ width: Int, _ height: Int, _ dpr: Double, _ userAgent: String = OrbitDeviceUserAgents.iPad
    ) -> OrbitDeviceProfile {
        OrbitDeviceProfile(
            id: id, name: name, category: .tablet, width: width, height: height, dpr: dpr,
            mobile: true, touch: true, userAgent: userAgent
        )
    }

    private static func computer(
        _ id: String, _ name: String, _ width: Int, _ height: Int, _ dpr: Double,
        touch: Bool = false, _ userAgent: String = OrbitDeviceUserAgents.macSafari
    ) -> OrbitDeviceProfile {
        OrbitDeviceProfile(
            id: id, name: name, category: .computer, width: width, height: height, dpr: dpr,
            mobile: false, touch: touch, userAgent: userAgent
        )
    }

    static let all: [OrbitDeviceProfile] = [
        phone("iphone-se", "iPhone SE", 375, 667, 2, OrbitDeviceUserAgents.iPhone),
        phone("iphone-15-pro", "iPhone 15 Pro", 393, 852, 3, OrbitDeviceUserAgents.iPhone),
        phone("iphone-15-pro-max", "iPhone 15 Pro Max", 430, 932, 3, OrbitDeviceUserAgents.iPhone),
        phone("iphone-16-pro", "iPhone 16 Pro", 402, 874, 3, OrbitDeviceUserAgents.iPhone),
        phone("iphone-16-pro-max", "iPhone 16 Pro Max", 440, 956, 3, OrbitDeviceUserAgents.iPhone),
        phone("pixel-8", "Pixel 8", 412, 915, 2.625, OrbitDeviceUserAgents.android("Pixel 8")),
        phone("pixel-9", "Pixel 9", 412, 923, 2.625, OrbitDeviceUserAgents.android("Pixel 9", version: 16)),
        phone("galaxy-s24", "Galaxy S24", 360, 780, 3, OrbitDeviceUserAgents.android("SM-S921B", version: 14)),
        tablet("ipad-mini", "iPad mini", 744, 1133, 2),
        tablet("ipad-air", "iPad Air", 820, 1180, 2),
        tablet("ipad-pro-11", "iPad Pro 11", 834, 1210, 2),
        tablet("ipad-pro-13", "iPad Pro 13", 1032, 1376, 2),
        computer("surface-pro", "Surface Pro", 912, 1368, 2, touch: true, OrbitDeviceUserAgents.windowsEdge),
        computer("nest-hub", "Nest Hub", 1024, 600, 2, touch: true, OrbitDeviceUserAgents.nestHub),
        computer("laptop-1280", "Laptop 1280", 1280, 720, 1),
        computer("laptop-1440", "Laptop 1440", 1440, 900, 2),
        computer("laptop-1920", "Laptop 1920", 1920, 1080, 1),
    ]
}

enum OrbitDeviceCatalog {
    struct Section: Equatable {
        var category: OrbitDeviceCategory
        var profiles: [OrbitDeviceProfile]
    }

    static func profiles(custom: [OrbitDeviceProfile]) -> [OrbitDeviceProfile] {
        OrbitDevicePresets.all + custom
    }

    static func profile(id: String, custom: [OrbitDeviceProfile]) -> OrbitDeviceProfile? {
        profiles(custom: custom).first { $0.id == id }
    }

    static func sections(custom: [OrbitDeviceProfile]) -> [Section] {
        let everything = profiles(custom: custom)
        return OrbitDeviceCategory.allCases.compactMap { category in
            let members = everything.filter { $0.category == category }
            return members.isEmpty ? nil : Section(category: category, profiles: members)
        }
    }

    static func upserting(_ profile: OrbitDeviceProfile, into custom: [OrbitDeviceProfile]) -> [OrbitDeviceProfile] {
        var result = custom
        if let index = result.firstIndex(where: { $0.id == profile.id }) {
            result[index] = profile
        } else {
            result.append(profile)
        }
        return result
    }

    static func removing(id: String, from custom: [OrbitDeviceProfile]) -> [OrbitDeviceProfile] {
        custom.filter { $0.id != id }
    }
}
