import Foundation
import WebKit

/// Whether an extension may see Incognito windows and tabs. Allowed unless the manifest says
/// `"incognito": "not_allowed"` or the user turned it off for that extension.
@MainActor
enum ExtensionIncognitoAccess {

    static let deniedKey = "OrbitExtensionsDeniedInIncognito.v1"

    static func isAllowed(extensionID: String, directory: URL) -> Bool {
        if manifestForbids(directory: directory) { return false }
        return !deniedIDs().contains(extensionID)
    }

    static func setAllowed(_ allowed: Bool, extensionID: String) {
        var denied = deniedIDs()
        if allowed { denied.remove(extensionID) } else { denied.insert(extensionID) }
        OrbitDefaults.standard.set(Array(denied).sorted(), forKey: deniedKey)
    }

    private static func deniedIDs() -> Set<String> {
        Set(OrbitDefaults.standard.stringArray(forKey: deniedKey) ?? [])
    }

    private static func manifestForbids(directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (manifest["incognito"] as? String) == "not_allowed"
    }
}

extension WebKitEngine {

    /// Applies the user's choice at once: WebKit stops showing the extension private windows and
    /// tabs, or starts to, without a reload.
    func setExtensionAllowedInIncognito(id: String, allowed: Bool) {
        ExtensionIncognitoAccess.setAllowed(allowed, extensionID: id)
        guard let record = loadedExtensionContext(id: id) else { return }
        let permitted = allowed && ExtensionIncognitoAccess.isAllowed(extensionID: id, directory: record.baseDirectory)
        record.context.hasAccessToPrivateData = permitted
    }
}
