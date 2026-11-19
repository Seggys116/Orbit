import Foundation

/// Finds Apple's PasswordManagerBrowserExtensionHelper through the native messaging manifest macOS installs for Chrome.
/// Only an executable inside /System is accepted: the manifest under /Library can be rewritten by an administrator, and a
/// session key must never be handed to anything but Apple's own helper.
nonisolated enum SystemPasswordsHelperLocator {

    static let manifestPaths = [
        "/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json",
        "/System/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json",
    ]

    static let knownExecutablePath =
        "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"

    static func executablePath(fromManifest data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = object["path"] as? String,
              isTrustedPath(path)
        else { return nil }
        return path
    }

    static func isTrustedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/System/") else { return false }
        let standardized = (path as NSString).standardizingPath
        return standardized == path && !path.contains("/../") && !path.hasSuffix("/..")
    }

    static func locate(fileManager: FileManager = .default) -> URL? {
        var candidates: [String] = []
        for manifest in manifestPaths {
            if let data = fileManager.contents(atPath: manifest), let path = executablePath(fromManifest: data) {
                candidates.append(path)
            }
        }
        candidates.append(knownExecutablePath)
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard isTrustedPath(resolved) else { continue }
            return URL(fileURLWithPath: resolved)
        }
        return nil
    }
}
