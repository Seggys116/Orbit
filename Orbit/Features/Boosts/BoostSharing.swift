import AppKit
import Foundation

nonisolated struct SharedBoostPayload: Codable, Sendable {
    var formatVersion: Int = 1
    var name: String
    var host: String
    var zappedSelectors: [String]
    var customCSS: String
    var backgroundColor: ThemeColor?
    var textColor: ThemeColor?
    var accentColor: ThemeColor?
    var fontFamily: String?
    var invertLightness: Bool = false
    var contrast: Double = 1.0
    var brightness: Double = 1.0
    var saturation: Double = 1.0
    var pageSizeScale: Double = 1.0
    var textCase: BoostTextCase = .original

    init(
        formatVersion: Int = 1,
        name: String,
        host: String,
        zappedSelectors: [String],
        customCSS: String,
        backgroundColor: ThemeColor? = nil,
        textColor: ThemeColor? = nil,
        accentColor: ThemeColor? = nil,
        fontFamily: String? = nil,
        invertLightness: Bool = false,
        contrast: Double = 1.0,
        brightness: Double = 1.0,
        saturation: Double = 1.0,
        pageSizeScale: Double = 1.0,
        textCase: BoostTextCase = .original
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.host = host
        self.zappedSelectors = zappedSelectors
        self.customCSS = customCSS
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.accentColor = accentColor
        self.fontFamily = fontFamily
        self.invertLightness = invertLightness
        self.contrast = contrast
        self.brightness = brightness
        self.saturation = saturation
        self.pageSizeScale = pageSizeScale
        self.textCase = textCase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        zappedSelectors = try container.decodeIfPresent([String].self, forKey: .zappedSelectors) ?? []
        customCSS = try container.decodeIfPresent(String.self, forKey: .customCSS) ?? ""
        backgroundColor = try container.decodeIfPresent(ThemeColor.self, forKey: .backgroundColor)
        textColor = try container.decodeIfPresent(ThemeColor.self, forKey: .textColor)
        accentColor = try container.decodeIfPresent(ThemeColor.self, forKey: .accentColor)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        invertLightness = try container.decodeIfPresent(Bool.self, forKey: .invertLightness) ?? false
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        pageSizeScale = try container.decodeIfPresent(Double.self, forKey: .pageSizeScale) ?? 1.0
        textCase = try container.decodeIfPresent(BoostTextCase.self, forKey: .textCase) ?? .original
    }
}

enum BoostSharingError: LocalizedError {
    case containsJavaScript

    var errorDescription: String? {
        switch self {
        case .containsJavaScript:
            return "This Boost can't be shared because it includes custom JavaScript. " +
                "Running someone else's arbitrary JavaScript on their machine is a real " +
                "security risk, so Orbit will only package the CSS-only kind. " +
                "Remove the JavaScript (or share just the CSS/Zap portion as a new " +
                "Boost) to enable sharing."
        }
    }
}

enum BoostSharing {

    static func makePayload(for boost: Boost) -> Result<SharedBoostPayload, BoostSharingError> {
        let js = boost.customJavaScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard js.isEmpty else { return .failure(.containsJavaScript) }
        return .success(SharedBoostPayload(
            name: boost.name,
            host: boost.host,
            zappedSelectors: boost.zappedSelectors,
            customCSS: boost.customCSS,
            backgroundColor: boost.backgroundColor,
            textColor: boost.textColor,
            accentColor: boost.accentColor,
            fontFamily: boost.fontFamily,
            invertLightness: boost.invertLightness,
            contrast: boost.contrast,
            brightness: boost.brightness,
            saturation: boost.saturation,
            pageSizeScale: boost.pageSizeScale,
            textCase: boost.textCase
        ))
    }

    static func encode(_ payload: SharedBoostPayload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data) -> SharedBoostPayload? {
        try? JSONDecoder().decode(SharedBoostPayload.self, from: data)
    }

    @MainActor
    static func presentShareSheet(for boost: Boost, from view: NSView) -> BoostSharingError? {
        switch makePayload(for: boost) {
        case .failure(let error):
            return error
        case .success(let payload):
            guard let data = encode(payload) else { return nil }
            let fileName = "\(sanitizedFileComponent(boost.name)).orbitboost.json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? data.write(to: tempURL, options: .atomic)
            let picker = NSSharingServicePicker(items: [tempURL])
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            return nil
        }
    }

    @MainActor
    @discardableResult
    static func importPayload(from url: URL, into store: BoostStore, overrideHost: String? = nil) -> Boost? {
        guard let data = try? Data(contentsOf: url), let payload = decode(data) else { return nil }
        let host = overrideHost ?? payload.host
        let boost = store.createBoost(name: payload.name, host: host)
        store.updateBoost(boost.id) { b in
            b.zappedSelectors = payload.zappedSelectors
            b.customCSS = payload.customCSS
            b.backgroundColor = payload.backgroundColor
            b.textColor = payload.textColor
            b.accentColor = payload.accentColor
            b.fontFamily = payload.fontFamily
            b.invertLightness = payload.invertLightness
            b.contrast = payload.contrast
            b.brightness = payload.brightness
            b.saturation = payload.saturation
            b.pageSizeScale = payload.pageSizeScale
            b.textCase = payload.textCase
        }
        return store.boost(boost.id)
    }

    private static func sanitizedFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }
        let joined = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "Boost" : joined
    }
}
