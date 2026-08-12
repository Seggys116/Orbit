import Foundation

// MARK: - Which browsers Orbit can read

public enum ImportableBrowser: String, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case brave
    case edge
    case opera
    case firefox
    case arc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .opera: return "Opera"
        case .firefox: return "Firefox"
        case .arc: return "Arc"
        }
    }

    public var importsNativeStructure: Bool { self == .arc }

    /// Only Arc: Chromium browsers each encrypt cookies with an AES key under their own Keychain "Safe Storage" item; Safari and Firefox use different mechanisms `ArcCookieDecryptor` doesn't cover.
    public var importsLoginSessions: Bool { self == .arc }

    public var importedFolderName: String { "Imported From \(displayName)" }

    /// Firefox must stay excluded here explicitly — it is neither Chromium nor Safari and has no `Bookmarks` JSON file.
    var isChromium: Bool {
        switch self {
        case .chrome, .brave, .edge, .opera, .arc: return true
        case .safari, .firefox: return false
        }
    }

    // MARK: File layout

    /// TCC-protected — an app without Full Disk Access can `stat` it but not read the files inside.
    func safariDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Safari", isDirectory: true)
    }

    func userDataDirectory(homeDirectory: URL) -> URL? {
        let relative: String
        switch self {
        case .safari, .firefox: return nil
        // ChromiumProfileLocator requires a Bookmarks file to recognize a profile; Arc has none, so ArcImportReader names its Default directory directly instead of routing through here.
        case .arc: relative = "Library/Application Support/Arc/User Data"
        case .chrome: relative = "Library/Application Support/Google/Chrome"
        case .brave: relative = "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: relative = "Library/Application Support/Microsoft Edge"
        case .opera: relative = "Library/Application Support/com.operasoftware.Opera"
        }
        return homeDirectory.appendingPathComponent(relative, isDirectory: true)
    }

    // MARK: Presence

    /// TCC blocks reading, not `stat`ing, so Safari is still correctly offered without Full Disk Access; the read then reports `.permissionDenied`.
    public func isPresent(homeDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        switch self {
        case .safari:
            let directory = safariDirectory(homeDirectory: homeDirectory)
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Bookmarks.plist").path) { return true }
            if fileManager.fileExists(atPath: directory.appendingPathComponent("History.db").path) { return true }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        case .arc:
            return ArcImportReader.isPresent(homeDirectory: homeDirectory)
        case .firefox:
            // Not decided from profiles.ini alone: a removed profile is still listed there.
            return !FirefoxProfileLocator.profiles(
                in: FirefoxProfileLocator.rootDirectory(homeDirectory: homeDirectory)
            ).isEmpty
        case .chrome, .brave, .edge, .opera:
            guard let root = userDataDirectory(homeDirectory: homeDirectory) else { return false }
            return !ChromiumProfileLocator.profiles(in: root).isEmpty
        }
    }
}

// MARK: - What comes out

public struct ImportedBookmark: Sendable, Hashable {
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct ImportedBookmarkFolder: Sendable, Hashable {
    public var name: String
    public var bookmarks: [ImportedBookmark]
    public var subfolders: [ImportedBookmarkFolder]

    public init(
        name: String,
        bookmarks: [ImportedBookmark] = [],
        subfolders: [ImportedBookmarkFolder] = []
    ) {
        self.name = name
        self.bookmarks = bookmarks
        self.subfolders = subfolders
    }

    public var totalBookmarkCount: Int {
        bookmarks.count + subfolders.reduce(0) { $0 + $1.totalBookmarkCount }
    }

    public var totalSubfolderCount: Int {
        subfolders.count + subfolders.reduce(0) { $0 + $1.totalSubfolderCount }
    }

    public var isEmpty: Bool {
        bookmarks.isEmpty && subfolders.allSatisfy(\.isEmpty)
    }

    func prunedOfEmptySubfolders() -> ImportedBookmarkFolder {
        ImportedBookmarkFolder(
            name: name,
            bookmarks: bookmarks,
            subfolders: subfolders.filter { !$0.isEmpty }.map { $0.prunedOfEmptySubfolders() }
        )
    }
}

public struct ImportedVisit: Sendable, Hashable {
    public var url: URL
    public var title: String
    public var visitedAt: Date
    public var visitCount: Int
    public var wasTyped: Bool

    public init(url: URL, title: String, visitedAt: Date, visitCount: Int, wasTyped: Bool) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visitCount = visitCount
        self.wasTyped = wasTyped
    }
}

public struct BrowserImportPayload: Sendable {
    public var browser: ImportableBrowser
    public var bookmarkRoot: ImportedBookmarkFolder
    public var visits: [ImportedVisit]

    public init(browser: ImportableBrowser, bookmarkRoot: ImportedBookmarkFolder, visits: [ImportedVisit]) {
        self.browser = browser
        self.bookmarkRoot = bookmarkRoot
        self.visits = visits
    }
}

// MARK: - Errors

public enum BrowserImportError: Error, LocalizedError, Sendable {
    case notInstalled(ImportableBrowser)
    case permissionDenied(ImportableBrowser, path: String)
    case unreadable(ImportableBrowser, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let browser):
            return "\(browser.displayName) doesn't have any data on this Mac to import."
        case .permissionDenied(let browser, let path):
            return "macOS blocked Orbit from reading \(browser.displayName)'s data at \(path). "
                + "Grant Orbit Full Disk Access in System Settings > Privacy & Security, then try again."
        case .unreadable(let browser, let reason):
            return "Couldn't read \(browser.displayName)'s data: \(reason)"
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return true
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
