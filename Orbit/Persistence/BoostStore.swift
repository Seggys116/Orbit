import CryptoKit
import Foundation

@MainActor
@Observable
public final class BoostStore {

    public private(set) var boosts: [Boost] = []

    private let writer: AtomicJSONFileWriter<[Boost]>

    public init(fileURL: URL = BoostStore.defaultFileURL) {
        self.writer = AtomicJSONFileWriter(fileURL: fileURL)
        self.boosts = writer.loadNow(default: [])
    }

    public nonisolated static var defaultFileURL: URL { OrbitDataRoot.processDefault.boostsFile }

    // MARK: - CRUD

    @discardableResult
    public func createBoost(name: String, host: String) -> Boost {
        let boost = Boost(name: name, host: BoostStore.normalizeHost(host))
        boosts.append(boost)
        persist()
        return boost
    }

    public func updateBoost(_ id: UUID, _ transform: (inout Boost) -> Void) {
        guard let index = boosts.firstIndex(where: { $0.id == id }) else { return }
        transform(&boosts[index])
        boosts[index].updatedAt = Date()
        persist()
    }

    public func deleteBoost(_ id: UUID) {
        boosts.removeAll { $0.id == id }
        persist()
    }

    public func deleteAllBoosts() {
        guard !boosts.isEmpty else { return }
        for id in boosts.map(\.id) { deleteBoost(id) }
    }

    public func setEnabled(_ enabled: Bool, forBoost id: UUID) {
        updateBoost(id) { $0.isEnabled = enabled }
    }

    public func boost(_ id: UUID) -> Boost? {
        boosts.first { $0.id == id }
    }

    public func boosts(forHost host: String) -> [Boost] {
        let lowered = host.lowercased()
        return boosts.filter { boost in
            let boostHost = boost.host.lowercased()
            guard !boostHost.isEmpty else { return false }
            return lowered == boostHost || lowered.hasSuffix(".\(boostHost)")
        }
    }

    public func compiledScripts(forHost host: String) -> [UserScript] {
        guard BoostsGlobalSettings.isEnabled else { return [] }
        return boosts(forHost: host).filter(\.isEnabled).flatMap(BoostCompiler.compile)
    }

    public func allCompiledScripts() -> [UserScript] {
        guard BoostsGlobalSettings.isEnabled else { return [] }
        return boosts.filter(\.isEnabled).flatMap(BoostCompiler.compile)
    }

    // MARK: - Persistence

    public func saveNow() throws {
        try writer.saveNow(boosts)
    }

    private func persist() {
        writer.scheduleSave(boosts)
    }

    private nonisolated static func normalizeHost(_ host: String) -> String {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
        }
        if let slashIndex = trimmed.firstIndex(of: "/") {
            trimmed = String(trimmed[trimmed.startIndex..<slashIndex])
        }
        if trimmed.hasPrefix("www.") {
            trimmed.removeFirst("www.".count)
        }
        return trimmed
    }
}

// MARK: - Compilation into engine UserScripts

public enum BoostCompiler {

    public static func compile(_ boost: Boost) -> [UserScript] {
        guard boost.isEnabled else { return [] }
        let patterns = matchPatterns(forHost: boost.host)
        guard !patterns.isEmpty else { return [] }

        var scripts: [UserScript] = []

        let css = compiledCSS(for: boost)
        if !css.isEmpty {
            scripts.append(UserScript(
                id: scriptID(for: boost, kind: .stylesheet),
                kind: .stylesheet,
                source: css,
                injectionTime: .documentStart,
                matchPatterns: patterns,
                allFrames: true
            ))
        }

        let js = boost.customJavaScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !js.isEmpty {
            scripts.append(UserScript(
                id: scriptID(for: boost, kind: .javaScript),
                kind: .javaScript,
                source: boost.customJavaScript,
                injectionTime: .documentEnd,
                matchPatterns: patterns,
                allFrames: false
            ))
        }

        return scripts
    }

    public static func scriptID(for boost: Boost, kind: UserScript.Kind) -> UUID {
        let digest = SHA256.hash(data: Data("orbit.boost.\(boost.id.uuidString).\(kind.rawValue)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func matchPatterns(forHost host: String) -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return [
            "https://\(trimmed)/*",
            "https://*.\(trimmed)/*",
            "http://\(trimmed)/*",
            "http://*.\(trimmed)/*",
        ]
    }

    public static func compiledCSS(for boost: Boost) -> String {
        var pieces: [String] = []

        let selectors = boost.zappedSelectors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !selectors.isEmpty {
            pieces.append("\(selectors.joined(separator: ",\n")) {\n  display: none !important;\n}")
        }

        pieces.append(contentsOf: visualControlRules(for: boost))

        var overrides: [String] = []
        if let backgroundColor = boost.backgroundColor {
            overrides.append("background-color: \(cssColor(backgroundColor)) !important;")
        }
        if let textColor = boost.textColor {
            overrides.append("color: \(cssColor(textColor)) !important;")
        }
        if let fontFamily = boost.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines), !fontFamily.isEmpty {
            overrides.append("font-family: \(fontFamily) !important;")
        }
        if !overrides.isEmpty {
            pieces.append("html, body {\n  \(overrides.joined(separator: "\n  "))\n}")
        }
        if let accentColor = boost.accentColor {
            pieces.append("html {\n  accent-color: \(cssColor(accentColor)) !important;\n}")
        }

        let customCSS = boost.customCSS.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customCSS.isEmpty {
            pieces.append(boost.customCSS)
        }

        return pieces.joined(separator: "\n\n")
    }

    // MARK: Visual controls, compiled

    private static let mediaSelectorsToReinvert = [
        "img", "picture", "video", "canvas", "svg", "iframe", "embed", "object",
    ]

    private static func visualControlRules(for boost: Boost) -> [String] {
        var pieces: [String] = []

        var filters: [String] = []
        if boost.invertLightness {
            filters.append("invert(1)")
            filters.append("hue-rotate(180deg)")
        }
        let contrast = clampAdjustment(boost.contrast)
        if contrast != 1.0 { filters.append("contrast(\(number(contrast)))") }
        let brightness = clampAdjustment(boost.brightness)
        if brightness != 1.0 { filters.append("brightness(\(number(brightness)))") }
        let saturation = clampAdjustment(boost.saturation)
        if saturation != 1.0 { filters.append("saturate(\(number(saturation)))") }

        if !filters.isEmpty {
            var rootDeclarations = ["filter: \(filters.joined(separator: " ")) !important;"]
            if boost.invertLightness {
                rootDeclarations.append("background-color: #ffffff;")
            }
            pieces.append("html {\n  \(rootDeclarations.joined(separator: "\n  "))\n}")

            if boost.invertLightness {
                pieces.append("""
                \(mediaSelectorsToReinvert.joined(separator: ",\n")) {
                  filter: invert(1) hue-rotate(180deg) !important;
                }
                """)
            }
        }

        let scale = clampPageSize(boost.pageSizeScale)
        if scale != 1.0 {
            pieces.append("html {\n  zoom: \(number(scale)) !important;\n}")
        }

        if let transform = cssTextTransform(boost.textCase) {
            pieces.append("body, body * {\n  text-transform: \(transform) !important;\n}")
        }

        return pieces
    }

    private static func cssTextTransform(_ textCase: BoostTextCase) -> String? {
        switch textCase {
        case .original: return nil
        case .uppercase: return "uppercase"
        case .lowercase: return "lowercase"
        case .capitalize: return "capitalize"
        }
    }

    private static func clampAdjustment(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, Boost.colorAdjustmentRange.lowerBound), Boost.colorAdjustmentRange.upperBound)
    }

    private static func clampPageSize(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, Boost.pageSizeScaleRange.lowerBound), Boost.pageSizeScaleRange.upperBound)
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() {
            return String(Int(rounded.rounded()))
        }
        return String(rounded)
    }

    private static func cssColor(_ color: ThemeColor) -> String {
        func channel(_ value: Double) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(max(0, min(1, color.alpha))))"
    }
}
