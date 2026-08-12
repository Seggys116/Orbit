import Foundation

public struct ChromeExtensionManifest: Equatable, Sendable {

    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var hasToolbarAction: Bool
    public var iconRelativePath: String?
    public var key: String?
    public var description: String?
    public var permissions: [String]

    // MV2 has no host_permissions key; mixes host patterns into permissions.
    public var hostPermissions: [String]

    public var optionalPermissions: [String]
    public var optionalHostPermissions: [String]
    public var contentScriptMatches: [String]
    public var actionPopupPath: String?
    public var actionTitle: String?
    public var actionIconRelativePath: String?
    public var optionsPagePath: String?
    public var optionsOpenInTab: Bool
    public var backgroundServiceWorkerPath: String?

    public var minimumChromeVersion: String?

    public init(
        name: String,
        version: String,
        manifestVersion: Int,
        hasToolbarAction: Bool,
        iconRelativePath: String?,
        key: String?,
        description: String? = nil,
        permissions: [String] = [],
        hostPermissions: [String] = [],
        optionalPermissions: [String] = [],
        optionalHostPermissions: [String] = [],
        contentScriptMatches: [String] = [],
        actionPopupPath: String? = nil,
        actionTitle: String? = nil,
        actionIconRelativePath: String? = nil,
        optionsPagePath: String? = nil,
        optionsOpenInTab: Bool = false,
        backgroundServiceWorkerPath: String? = nil,
        minimumChromeVersion: String? = nil
    ) {
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.hasToolbarAction = hasToolbarAction
        self.iconRelativePath = iconRelativePath
        self.key = key
        self.description = description
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.optionalPermissions = optionalPermissions
        self.optionalHostPermissions = optionalHostPermissions
        self.contentScriptMatches = contentScriptMatches
        self.actionPopupPath = actionPopupPath
        self.actionTitle = actionTitle
        self.actionIconRelativePath = actionIconRelativePath
        self.optionsPagePath = optionsPagePath
        self.optionsOpenInTab = optionsOpenInTab
        self.backgroundServiceWorkerPath = backgroundServiceWorkerPath
        self.minimumChromeVersion = minimumChromeVersion
    }

    public static func read(fromDirectory directory: URL) throws -> ChromeExtensionManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionStoreError.manifestMissing(manifestURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExtensionStoreError.manifestUnreadable(manifestURL, error.localizedDescription)
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExtensionStoreError.manifestInvalid(
                    manifestURL,
                    "The top-level JSON value is not an object."
                )
            }
            json = parsed
        } catch let error as ExtensionStoreError {
            throw error
        } catch {
            throw ExtensionStoreError.manifestInvalid(manifestURL, error.localizedDescription)
        }

        guard let name = json["name"] as? String, !name.isEmpty else {
            throw ExtensionStoreError.manifestInvalid(manifestURL, "Missing or empty \"name\".")
        }
        guard let version = json["version"] as? String, !version.isEmpty else {
            throw ExtensionStoreError.manifestInvalid(manifestURL, "Missing or empty \"version\".")
        }

        let manifestVersion = (json["manifest_version"] as? Int) ?? 3
        let resolvedName = resolveMessage(name, directory: directory, manifestJSON: json)
        let hasToolbarAction = (json["action"] != nil) || (json["browser_action"] != nil)
        let iconRelativePath = largestIconPath(from: json["icons"])
        let key = json["key"] as? String

        let resolvedDescription: String?
        if let rawDescription = json["description"] as? String, !rawDescription.isEmpty {
            resolvedDescription = resolveMessage(rawDescription, directory: directory, manifestJSON: json)
        } else {
            resolvedDescription = nil
        }

        let (permissions, hostPermissions) = splitPermissions(
            json["permissions"] as? [String] ?? [],
            manifestVersion: manifestVersion,
            hostPermissionsKey: json["host_permissions"] as? [String]
        )
        let (optionalPermissions, optionalHostPermissions) = splitPermissions(
            json["optional_permissions"] as? [String] ?? [],
            manifestVersion: manifestVersion,
            hostPermissionsKey: json["optional_host_permissions"] as? [String]
        )

        let contentScriptMatches = contentScriptMatchUnion(from: json["content_scripts"])

        let actionDict = (json["action"] as? [String: Any]) ?? (json["browser_action"] as? [String: Any])
        let actionPopupPath = nonEmptyString(actionDict?["default_popup"])
        let actionTitle: String?
        if let rawActionTitle = actionDict?["default_title"] as? String, !rawActionTitle.isEmpty {
            actionTitle = resolveMessage(rawActionTitle, directory: directory, manifestJSON: json)
        } else {
            actionTitle = nil
        }
        let actionIconRelativePath = actionIconPath(from: actionDict?["default_icon"])

        let optionsUI = json["options_ui"] as? [String: Any]
        let optionsPagePath = nonEmptyString(optionsUI?["page"]) ?? nonEmptyString(json["options_page"])
        let optionsOpenInTab = (optionsUI?["open_in_tab"] as? Bool) ?? false

        let backgroundServiceWorkerPath = backgroundContextPath(from: json["background"] as? [String: Any])
        let minimumChromeVersion = nonEmptyString(json["minimum_chrome_version"])

        return ChromeExtensionManifest(
            name: resolvedName,
            version: version,
            manifestVersion: manifestVersion,
            hasToolbarAction: hasToolbarAction,
            iconRelativePath: iconRelativePath,
            key: key,
            description: resolvedDescription,
            permissions: permissions,
            hostPermissions: hostPermissions,
            optionalPermissions: optionalPermissions,
            optionalHostPermissions: optionalHostPermissions,
            contentScriptMatches: contentScriptMatches,
            actionPopupPath: actionPopupPath,
            actionTitle: actionTitle,
            actionIconRelativePath: actionIconRelativePath,
            optionsPagePath: optionsPagePath,
            optionsOpenInTab: optionsOpenInTab,
            backgroundServiceWorkerPath: backgroundServiceWorkerPath,
            minimumChromeVersion: minimumChromeVersion
        )
    }

    // MARK: - `__MSG_x__` resolution

    private static func resolveMessage(_ raw: String, directory: URL, manifestJSON: [String: Any]) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else {
            return raw
        }
        let messageKey = String(raw.dropFirst(6).dropLast(2))
        guard !messageKey.isEmpty else { return raw }

        guard let defaultLocale = manifestJSON["default_locale"] as? String, !defaultLocale.isEmpty else {
            return raw
        }

        let messagesURL = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(defaultLocale, isDirectory: true)
            .appendingPathComponent("messages.json")

        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return raw
        }

        // Chrome matches message keys case-insensitively; exact match tried first to avoid an O(n) scan.
        if let message = messageText(messages[messageKey]) {
            return message
        }
        let lowered = messageKey.lowercased()
        for (candidateKey, value) in messages where candidateKey.lowercased() == lowered {
            if let message = messageText(value) {
                return message
            }
        }
        return raw
    }

    private static func messageText(_ value: Any?) -> String? {
        (value as? [String: Any])?["message"] as? String
    }

    // MARK: - Icons

    private static func largestIconPath(from iconsValue: Any?) -> String? {
        guard let icons = iconsValue as? [String: Any] else { return nil }
        var best: (size: Int, path: String)?
        for (sizeKey, value) in icons {
            guard let size = Int(sizeKey), let path = value as? String, !path.isEmpty else { continue }
            if best == nil || size > best!.size {
                best = (size, path)
            }
        }
        return best?.path
    }

    // default_icon may be a bare string path or a size-keyed object like icons.
    private static func actionIconPath(from defaultIconValue: Any?) -> String? {
        if let path = defaultIconValue as? String, !path.isEmpty {
            return path
        }
        return largestIconPath(from: defaultIconValue)
    }

    // MARK: - Permissions

    private static func splitPermissions(
        _ mixedArray: [String],
        manifestVersion: Int,
        hostPermissionsKey: [String]?
    ) -> (permissions: [String], hostPermissions: [String]) {
        guard manifestVersion < 3 else {
            return (mixedArray, hostPermissionsKey ?? [])
        }
        var apiPermissions: [String] = []
        var hostPatterns: [String] = []
        for entry in mixedArray {
            if looksLikeHostMatchPattern(entry) {
                hostPatterns.append(entry)
            } else {
                apiPermissions.append(entry)
            }
        }
        return (apiPermissions, hostPatterns)
    }

    private static func looksLikeHostMatchPattern(_ value: String) -> Bool {
        value == "<all_urls>" || value.contains("://")
    }

    // MARK: - Content scripts

    private static func contentScriptMatchUnion(from contentScriptsValue: Any?) -> [String] {
        guard let entries = contentScriptsValue as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var union: [String] = []
        for entry in entries {
            guard let matches = entry["matches"] as? [String] else { continue }
            for pattern in matches where seen.insert(pattern).inserted {
                union.append(pattern)
            }
        }
        return union
    }

    // MARK: - Background context

    private static func backgroundContextPath(from backgroundDict: [String: Any]?) -> String? {
        guard let backgroundDict else { return nil }
        if let serviceWorker = nonEmptyString(backgroundDict["service_worker"]) {
            return serviceWorker
        }
        if let page = nonEmptyString(backgroundDict["page"]) {
            return page
        }
        if let scripts = backgroundDict["scripts"] as? [String] {
            return scripts.first { !$0.isEmpty }
        }
        return nil
    }

    // MARK: - Small shared helpers

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
