//  Extensions/<id>/<version>/manifest.json; version directories must sort numerically (1.10.0 > 1.9.0), not lexicographically.
//  MV3 keeps host_permissions separate from permissions, MV2 mixes them; Secure Preferences' enabled key is absent for most disabled extensions, so absence must read as unknown, never as enabled.
//  Secure Preferences' cached manifest.name is deliberately not used: it can describe a different version than the one on disk.
//  Secure Preferences state: 1=enabled, 0=disabled.

import Foundation

// MARK: - Values

/// One extension found in Arc's profile. This is an INVENTORY entry, not an
/// installation — reading it never loads anything into Orbit's engine.
public struct ArcExtension: Sendable, Hashable {
    public var identifier: String
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var directory: URL
    public var permissions: [String]
    public var hostPermissions: [String]
    public var isEnabled: Bool?
    public var webStoreURL: URL

    public init(
        identifier: String,
        name: String,
        version: String,
        manifestVersion: Int,
        directory: URL,
        permissions: [String] = [],
        hostPermissions: [String] = [],
        isEnabled: Bool? = nil,
        webStoreURL: URL
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.directory = directory
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.isEnabled = isEnabled
        self.webStoreURL = webStoreURL
    }
}

// MARK: - Reader

public enum ArcExtensionInventory {

    static let webStoreDetailPrefix = "https://chromewebstore.google.com/detail/"
    static let extensionIDLength = 32
    static let extensionIDAlphabet = Set("abcdefghijklmnop")
    static let fallbackLocales = ["en", "en_US", "en_GB"]
    static let defaultManifestVersion = 2

    public static func read(profileDirectory: URL, browser: ImportableBrowser) throws -> [ArcExtension] {
        let fileManager = FileManager.default
        let root = profileDirectory.appendingPathComponent("Extensions", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let identifierDirectories: [URL]
        do {
            identifierDirectories = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            if BrowserImportError.isPermissionDenied(error) {
                throw BrowserImportError.permissionDenied(browser, path: root.path)
            }
            throw BrowserImportError.unreadable(browser, reason: "Couldn't list the Extensions directory: \(error.localizedDescription)")
        }

        let states = enabledStates(profileDirectory: profileDirectory)

        var found: [ArcExtension] = []
        for directory in identifierDirectories {
            let identifier = directory.lastPathComponent
            guard isExtensionIdentifier(identifier) else { continue }
            guard let versionDirectory = highestVersionDirectory(in: directory) else { continue }
            guard let entry = self.extension(
                identifier: identifier,
                versionDirectory: versionDirectory,
                isEnabled: states[identifier]
            ) else { continue }
            found.append(entry)
        }

        return found.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.identifier < $1.identifier : comparison == .orderedAscending
        }
    }

    // MARK: One extension

    /// `nil` (not thrown) for a half-unpacked or corrupt directory, so it doesn't take the rest of the import down with it.
    static func `extension`(identifier: String, versionDirectory: URL, isEnabled: Bool?) -> ArcExtension? {
        let manifestURL = versionDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let manifest = json as? [String: Any]
        else { return nil }

        let manifestVersion = (ArcSidebarDocument.double(manifest["manifest_version"])).map { Int($0) }
            ?? defaultManifestVersion

        let rawName = (manifest["name"] as? String) ?? ""
        let name = resolvedName(
            rawName,
            versionDirectory: versionDirectory,
            defaultLocale: manifest["default_locale"] as? String
        )

        let directoryVersion = versionDirectory.lastPathComponent.components(separatedBy: "_").first ?? ""
        let version = (manifest["version"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directoryVersion

        let declaredPermissions = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let declaredHosts = (manifest["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String }

        let permissions = declaredPermissions.filter { !isHostPattern($0) }
        let hostPermissions = declaredHosts + declaredPermissions.filter { isHostPattern($0) }

        guard let webStoreURL = URL(string: webStoreDetailPrefix + identifier) else { return nil }

        return ArcExtension(
            identifier: identifier,
            name: name.isEmpty ? identifier : name,
            version: version,
            manifestVersion: manifestVersion,
            directory: versionDirectory,
            permissions: permissions,
            hostPermissions: hostPermissions,
            isEnabled: isEnabled,
            webStoreURL: webStoreURL
        )
    }

    static func isHostPattern(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }

    // MARK: Identifiers and versions

    static func isExtensionIdentifier(_ name: String) -> Bool {
        name.count == extensionIDLength && name.allSatisfy { extensionIDAlphabet.contains($0) }
    }

    static func highestVersionDirectory(in identifierDirectory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: identifierDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .max { versionOrdering($0.lastPathComponent, $1.lastPathComponent) }
    }

    static func versionOrdering(_ left: String, _ right: String) -> Bool {
        guard let leftParts = numericComponents(left), let rightParts = numericComponents(right) else {
            return left < right
        }
        for index in 0..<max(leftParts.count, rightParts.count) {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0
            if leftValue != rightValue { return leftValue < rightValue }
        }
        return false
    }

    static func numericComponents(_ name: String) -> [Int]? {
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "._"))
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }

    // MARK: i18n

    static func resolvedName(_ raw: String, versionDirectory: URL, defaultLocale: String?) -> String {
        guard let key = messageKey(raw) else { return raw }

        let localesDirectory = versionDirectory.appendingPathComponent("_locales", isDirectory: true)
        let available = ((try? FileManager.default.contentsOfDirectory(
            at: localesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).map(\.lastPathComponent).sorted()

        var ordered: [String] = []
        for candidate in [defaultLocale].compactMap({ $0 }) + fallbackLocales + available {
            // BCP-47 form (en-GB) is normalised to Chrome's directory form (en_GB).
            let normalised = candidate.replacingOccurrences(of: "-", with: "_")
            for form in [candidate, normalised] where !ordered.contains(form) {
                ordered.append(form)
            }
        }

        for locale in ordered {
            let messagesURL = localesDirectory
                .appendingPathComponent(locale, isDirectory: true)
                .appendingPathComponent("messages.json", isDirectory: false)
            guard let data = try? Data(contentsOf: messagesURL),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let messages = json as? [String: Any]
            else { continue }

            guard let matched = messages.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                  let entry = messages[matched] as? [String: Any],
                  let message = entry["message"] as? String,
                  !message.isEmpty
            else { continue }
            return message
        }

        return raw
    }

    static func messageKey(_ raw: String) -> String? {
        let prefix = "__MSG_"
        let suffix = "__"
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count else { return nil }
        return String(raw.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // MARK: Enabled state

    static func enabledStates(profileDirectory: URL) -> [String: Bool] {
        let url = profileDirectory.appendingPathComponent("Secure Preferences", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let extensions = root["extensions"] as? [String: Any],
              let settings = extensions["settings"] as? [String: Any]
        else { return [:] }

        var states: [String: Bool] = [:]
        for (identifier, value) in settings {
            guard let entry = value as? [String: Any],
                  let state = ArcSidebarDocument.double(entry["state"]).map({ Int($0) })
            else { continue }
            switch state {
            case 1: states[identifier] = true
            case 0: states[identifier] = false
            default: continue
            }
        }
        return states
    }
}
