import Foundation

public enum ExtensionPermissionWarningSeverity: Int, Sendable, Comparable, CaseIterable {
    case critical
    case high
    case moderate
    case low

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ExtensionPermissionWarning: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let severity: ExtensionPermissionWarningSeverity
    public let isGrantedAtInstall: Bool

    public init(id: String, text: String, severity: ExtensionPermissionWarningSeverity, isGrantedAtInstall: Bool) {
        self.id = id
        self.text = text
        self.severity = severity
        self.isGrantedAtInstall = isGrantedAtInstall
    }
}

public enum ExtensionPermissionWarnings {

    public static func warnings(for manifest: ChromeExtensionManifest) -> [ExtensionPermissionWarning] {
        var ordered: [ExtensionPermissionWarning] = []
        var indexByText: [String: Int] = [:]

        // MARK: Host access — granted at install

        let grantedHostPatterns = Set(manifest.hostPermissions).union(manifest.contentScriptMatches)
        let grantedHostsCollapseToAll = grantedHostPatterns.contains(where: isAllHostsPattern)
        if let warning = hostWarning(from: grantedHostPatterns, collapsesToAll: grantedHostsCollapseToAll, isGrantedAtInstall: true) {
            addOrUpgrade(warning, into: &ordered, indexByText: &indexByText)
        }

        // MARK: Host access — optional (may be requested later)

        if !grantedHostsCollapseToAll {
            let optionalHostPatterns = Set(manifest.optionalHostPermissions).subtracting(grantedHostPatterns)
            let optionalHostsCollapseToAll = optionalHostPatterns.contains(where: isAllHostsPattern)
            if let warning = hostWarning(
                from: optionalHostPatterns,
                collapsesToAll: optionalHostsCollapseToAll,
                isGrantedAtInstall: false
            ) {
                addOrUpgrade(warning, into: &ordered, indexByText: &indexByText)
            }
        }

        // MARK: API permissions — granted at install

        for permission in manifest.permissions {
            let warning = apiPermissionWarning(for: permission, isGrantedAtInstall: true)
            addOrUpgrade(warning, into: &ordered, indexByText: &indexByText)
        }

        // MARK: API permissions — optional

        let grantedPermissionSet = Set(manifest.permissions)
        for permission in manifest.optionalPermissions where !grantedPermissionSet.contains(permission) {
            let warning = apiPermissionWarning(for: permission, isGrantedAtInstall: false)
            addOrUpgrade(warning, into: &ordered, indexByText: &indexByText)
        }

        return ordered.sorted { $0.severity < $1.severity }
    }

    // MARK: - De-duplication

    private static func addOrUpgrade(
        _ warning: ExtensionPermissionWarning,
        into ordered: inout [ExtensionPermissionWarning],
        indexByText: inout [String: Int]
    ) {
        if let existingIndex = indexByText[warning.text] {
            if !ordered[existingIndex].isGrantedAtInstall && warning.isGrantedAtInstall {
                let existing = ordered[existingIndex]
                ordered[existingIndex] = ExtensionPermissionWarning(
                    id: existing.id,
                    text: existing.text,
                    severity: existing.severity,
                    isGrantedAtInstall: true
                )
            }
            return
        }
        indexByText[warning.text] = ordered.count
        ordered.append(warning)
    }

    // MARK: - Host permission collapsing and grouping

    private static func isAllHostsPattern(_ pattern: String) -> Bool {
        pattern == "<all_urls>" || hostComponent(of: pattern) == "*"
    }

    private static func hostComponent(of pattern: String) -> String? {
        guard let schemeRange = pattern.range(of: "://") else { return nil }
        let afterScheme = pattern[schemeRange.upperBound...]
        guard let host = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
              !host.isEmpty
        else {
            return nil
        }
        return String(host)
    }

    private static func displayHost(_ host: String) -> String {
        host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
    }

    private static func hostWarning(
        from patterns: Set<String>,
        collapsesToAll: Bool,
        isGrantedAtInstall: Bool
    ) -> ExtensionPermissionWarning? {
        guard !patterns.isEmpty else { return nil }

        if collapsesToAll {
            return ExtensionPermissionWarning(
                id: isGrantedAtInstall ? "host.all" : "host.all.optional",
                text: "Read and change all your data on all websites",
                severity: .critical,
                isGrantedAtInstall: isGrantedAtInstall
            )
        }

        let hosts = Set(patterns.map { displayHost(hostComponent(of: $0) ?? $0) })

        let text: String
        if hosts.count == 1, let onlyHost = hosts.first {
            text = "Read and change your data on \(onlyHost)"
        } else {
            text = "Read and change your data on \(hosts.count) websites"
        }

        return ExtensionPermissionWarning(
            id: (isGrantedAtInstall ? "host:" : "host-optional:") + hosts.sorted().joined(separator: "|"),
            text: text,
            severity: .high,
            isGrantedAtInstall: isGrantedAtInstall
        )
    }

    // MARK: - API permission warnings

    private static func apiPermissionWarning(for permission: String, isGrantedAtInstall: Bool) -> ExtensionPermissionWarning {
        if let known = apiPermissionCatalog[permission] {
            return ExtensionPermissionWarning(
                id: "perm:\(permission)",
                text: known.text,
                severity: known.severity,
                isGrantedAtInstall: isGrantedAtInstall
            )
        }
        return ExtensionPermissionWarning(
            id: "perm:\(permission)",
            text: permission,
            severity: .moderate,
            isGrantedAtInstall: isGrantedAtInstall
        )
    }

    private static let apiPermissionCatalog: [String: (text: String, severity: ExtensionPermissionWarningSeverity)] = [
        // MARK: critical — browser-wide or sandbox-escaping access
        "debugger": (
            "Access the Chrome DevTools debugger, which can read and change all your data on all websites",
            .critical
        ),
        "nativeMessaging": (
            "Communicate with cooperating native applications installed on your Mac",
            .critical
        ),

        // MARK: high — meaningful personal data or page-level code execution
        "history": ("Read and change your browsing history", .high),
        "tabs": ("Read your browsing history", .high),
        "bookmarks": ("Read and change your bookmarks", .high),
        "cookies": ("Read and change your cookies and other site data", .high),
        // Opening a downloaded file needs downloads.open on top of downloads.
        "downloads": ("Manage your downloads", .high),
        "downloads.open": ("Open downloaded files", .high),
        "clipboardRead": ("Read data you copy and paste", .high),
        "clipboardWrite": ("Modify data you copy and paste", .high),
        "geolocation": ("Detect your physical location", .high),
        "scripting": ("Read and change all your data on the websites this extension can access", .high),
        "userScripts": ("Run scripts you have given it on the websites this extension can access", .high),
        "declarativeNetRequest": ("Block or modify network requests on websites you visit", .high),
        "declarativeNetRequestWithHostAccess": ("Block or modify network requests on websites you visit", .high),
        "declarativeNetRequestFeedback": ("Read details about network requests this extension has blocked or modified", .high),
        "webRequest": ("Read and, in some cases, modify data you send and receive while browsing", .high),
        "webRequestBlocking": ("Read and change data you send and receive while browsing, before it loads", .high),
        "webRequestAuthProvider": ("Supply usernames and passwords to websites that ask you to sign in", .high),
        "proxy": ("Control your network traffic and proxy settings", .high),
        "browsingData": ("Clear your browsing history, cookies, and other stored site data", .high),
        "tabCapture": ("Capture the visible contents of tabs you are viewing", .high),
        "desktopCapture": ("Capture the contents of your screen, other windows, and other applications", .high),

        // MARK: moderate — real but narrower-blast-radius capabilities
        "activeTab": (
            "Access the page you're currently viewing, only when you click the extension's icon or use its menu",
            .moderate
        ),
        "management": ("Manage your other extensions, apps, and themes", .moderate),
        "privacy": ("Change your privacy-related browser settings", .moderate),
        "webNavigation": ("Know when you navigate to a new page and what that page's address is", .moderate),
        "contentSettings": ("Change settings that control which websites can use features like cookies, JavaScript, and plugins", .moderate),
        "topSites": ("Read the list of pages you visit most often", .moderate),
        "sessions": ("Read and reopen your recently closed tabs", .moderate),
        "fontSettings": ("Change the fonts your browser uses", .moderate),
        "printerProvider": ("Interact with attached printers", .moderate),

        // MARK: low — narrow, local, or already-sandboxed capabilities
        "storage": ("Store data on your Mac", .low),
        "unlimitedStorage": ("Store an unlimited amount of data on your Mac", .low),
        "notifications": ("Display notifications", .low),
        "contextMenus": ("Add items to the right-click menu", .low),
        "search": ("Run searches with your default search engine", .low),
        "alarms": ("Schedule code to run at a later time", .low),
        "idle": ("Detect when your Mac is idle", .low),
        "power": ("Keep your Mac from sleeping while the extension is active", .low),
        "identity": ("Know your basic profile information from your signed-in account", .low),
        "gcm": ("Receive push messages sent to this extension", .low),
        "system.display": ("Read details about your connected displays", .low),
        "system.cpu": ("Read details about your Mac's CPU", .low),
        "system.memory": ("Read details about your Mac's available memory", .low),
        "system.storage": ("Read details about your Mac's storage devices", .low),
        "background": ("Run in the background, even when no window is open", .low),
        "offscreen": ("Create hidden pages to perform work off screen", .low),
        "tts": ("Read text out loud using text-to-speech", .low),
        "fileSystemProvider": ("Provide access to files as if they were on a local disk", .low),
    ]
}
