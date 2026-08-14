import AppKit
import Foundation

// MARK: - Engine identity

nonisolated public enum EngineKind: String, Codable, Sendable, CaseIterable {
    case chromium

    public var displayName: String {
        switch self {
        case .chromium: return "Chromium"
        }
    }
}

nonisolated public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let extensions = EngineCapabilities(rawValue: 1 << 0)
    public static let developerTools = EngineCapabilities(rawValue: 1 << 1)
    public static let audioMuting = EngineCapabilities(rawValue: 1 << 2)
    public static let pictureInPicture = EngineCapabilities(rawValue: 1 << 3)
    public static let backgroundSnapshots = EngineCapabilities(rawValue: 1 << 4)
    public static let printing = EngineCapabilities(rawValue: 1 << 5)
    public static let downloadManager = EngineCapabilities(rawValue: 1 << 6)
    public static let multipleProfiles = EngineCapabilities(rawValue: 1 << 7)
    public static let userScripts = EngineCapabilities(rawValue: 1 << 8)
    public static let contentBlocking = EngineCapabilities(rawValue: 1 << 9)
    /// Separate from `contentBlocking` — check this before showing a count.
    public static let blockedRequestCounts = EngineCapabilities(rawValue: 1 << 10)
}

/// One wording for every surface that has to explain a missing capability, so
/// two of them cannot drift apart.
nonisolated public enum EngineCapabilityCopy {
    public static let developerToolsUnavailable =
        "The browser engine isn't running yet, so there is no developer tools inspector to open."
}

// MARK: - Extensions

nonisolated public enum ExtensionActivation: String, Sendable, CaseIterable {
    /// `loadExtension` throws.
    case unsupported
    /// Loaded into the running engine only at its next `start()`.
    case nextLaunch
    /// Loaded into the running engine as soon as `loadExtension` returns --
    /// content scripts included, so a navigation started straight after it
    /// runs them.
    case immediate
}

/// Why an extension is being loaded, which is what decides whether the
/// extension sees `chrome.runtime.onInstalled` or `chrome.runtime.onStartup`
/// and whether its persisted service-worker event registrations survive.
nonisolated public enum ExtensionLoadReason: String, Sendable, CaseIterable {
    /// A user or an update asked for it now: a fresh install, an update, a
    /// re-enable, a developer "Load Unpacked".
    case userAction
    /// The bootstrap pass putting back what was already installed when the
    /// browser last shut down. Fires `onStartup`; fires `onInstalled` only if
    /// the version on disk genuinely changed while the browser was closed.
    case browserStartup
}

// MARK: - Navigation

nonisolated public struct NavigationState: Equatable, Sendable {
    public var url: URL?
    public var title: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    /// 0.0 ... 1.0
    public var progress: Double
    public var security: SecurityLevel

    public init(
        url: URL? = nil,
        title: String = "",
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        progress: Double = 0,
        security: SecurityLevel = .unknown
    ) {
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.progress = progress
        self.security = security
    }

    public static let empty = NavigationState()
}

nonisolated public enum SecurityLevel: String, Codable, Sendable {
    case unknown
    case secure
    case mixedContent
    case insecure
    case certificateError
    /// `file:`, `orbit:`, `about:`.
    case local
}

nonisolated public enum NavigationKind: String, Codable, Sendable {
    case typed
    case linkActivated
    case formSubmitted
    case backForward
    case reload
    case redirect
    case restored
    case other
}

nonisolated public enum NewContentDisposition: String, Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    case newWindow
    case popup
    case download
}

public extension NewContentDisposition {
    /// Numbering comes from `WindowOpenDisposition`'s own declaration order -- see
    /// `OrbitSetNewContentRequestCallback` in orbit_bridge_api.h. Anything Orbit has
    /// no distinct surface for opens as an ordinary foreground tab rather than being dropped.
    init(chromiumWindowOpenDisposition raw: Int32) {
        switch raw {
        case 1: self = .currentTab
        case 4: self = .newBackgroundTab
        case 5: self = .popup
        case 6: self = .newWindow
        case 7: self = .download
        default: self = .newForegroundTab
        }
    }
}

nonisolated public struct NewContentRequest: Sendable {
    public var url: URL
    public var disposition: NewContentDisposition
    public var isUserGesture: Bool
    public var preferredSize: CGSize?

    public init(
        url: URL,
        disposition: NewContentDisposition,
        isUserGesture: Bool,
        preferredSize: CGSize? = nil
    ) {
        self.url = url
        self.disposition = disposition
        self.isUserGesture = isUserGesture
        self.preferredSize = preferredSize
    }
}

/// One new-window request the engine has already built the content for.
/// `adopt()` transfers ownership; call exactly once, only once committed to hosting it.
@MainActor
public final class PendingWebContents {
    public let request: NewContentRequest

    private var make: (() -> (any WebContents)?)?

    public init(request: NewContentRequest, make: @escaping () -> (any WebContents)?) {
        self.request = request
        self.make = make
    }

    /// nil if the engine could not wrap it, or if this was already called.
    public func adopt() -> (any WebContents)? {
        guard let make else { return nil }
        self.make = nil
        return make()
    }

    public var isAdopted: Bool { make == nil }
}

// MARK: - Errors

nonisolated public struct EngineError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case cancelled
        case networkUnreachable
        case hostNotFound
        case connectionRefused
        case connectionTimedOut
        case tooManyRedirects
        case certificateInvalid
        case fileNotFound
        case blockedByPolicy
        case unsupportedScheme
        case renderProcessCrashed
        case engineUnavailable
        /// A real, honest "not built yet" — distinct from `engineUnavailable`,
        /// which means "retry"; this means "this feature has no implementation
        /// in the running engine at all".
        case notImplemented
        case unknown
    }

    public var code: Code
    public var url: URL?
    public var underlyingDescription: String

    public init(code: Code, url: URL? = nil, underlyingDescription: String = "") {
        self.code = code
        self.url = url
        self.underlyingDescription = underlyingDescription
    }

    public var headline: String {
        switch code {
        case .cancelled: return "Load cancelled"
        case .networkUnreachable: return "You're offline"
        case .hostNotFound: return "Can't find that site"
        case .connectionRefused: return "This site refused to connect"
        case .connectionTimedOut: return "This site took too long"
        case .tooManyRedirects: return "This page redirected too many times"
        case .certificateInvalid: return "This connection isn't private"
        case .fileNotFound: return "That file isn't there"
        case .blockedByPolicy: return "Blocked"
        case .unsupportedScheme: return "Orbit can't open that kind of link"
        case .renderProcessCrashed: return "This tab crashed"
        case .engineUnavailable: return "The browser engine isn't available"
        case .notImplemented: return "Orbit doesn't support this yet"
        case .unknown: return "Something went wrong"
        }
    }
}

// MARK: - Find in page

nonisolated public struct FindResult: Equatable, Sendable {
    public var activeMatchOrdinal: Int
    public var matchCount: Int
    public var isFinalUpdate: Bool

    public init(activeMatchOrdinal: Int, matchCount: Int, isFinalUpdate: Bool) {
        self.activeMatchOrdinal = activeMatchOrdinal
        self.matchCount = matchCount
        self.isFinalUpdate = isFinalUpdate
    }

    public static let none = FindResult(activeMatchOrdinal: 0, matchCount: 0, isFinalUpdate: true)
}

nonisolated public struct FindOptions: Equatable, Sendable {
    public var forward: Bool
    public var matchCase: Bool
    public var findNext: Bool

    public init(forward: Bool = true, matchCase: Bool = false, findNext: Bool = false) {
        self.forward = forward
        self.matchCase = matchCase
        self.findNext = findNext
    }
}

// MARK: - Permissions

nonisolated public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case geolocation
    case notifications
    case clipboardRead
    case midi
    case screenCapture
    case protectedMediaIdentifier
    case sensors
    case fileSystemWrite

    public var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .geolocation: return "Location"
        case .notifications: return "Notifications"
        case .clipboardRead: return "Clipboard"
        case .midi: return "MIDI Devices"
        case .screenCapture: return "Screen Sharing"
        case .protectedMediaIdentifier: return "Protected Content"
        case .sensors: return "Motion Sensors"
        case .fileSystemWrite: return "File Editing"
        }
    }

    public var promptDescription: String {
        switch self {
        case .camera: return "use your camera"
        case .microphone: return "use your microphone"
        case .geolocation: return "know your location"
        case .notifications: return "send you notifications"
        case .clipboardRead: return "read your clipboard"
        case .midi: return "use your MIDI devices"
        case .screenCapture: return "share your screen"
        case .protectedMediaIdentifier: return "play protected content"
        case .sensors: return "use your device sensors"
        case .fileSystemWrite: return "edit files on your Mac"
        }
    }
}

nonisolated public enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
    case allowAlways
    case denyAlways
}

nonisolated public struct PermissionRequest: Sendable {
    public var kinds: Set<PermissionKind>
    public var origin: URL

    public init(kinds: Set<PermissionKind>, origin: URL) {
        self.kinds = kinds
        self.origin = origin
    }
}

// MARK: - Content settings

nonisolated public enum ContentSetting: String, Codable, Sendable, CaseIterable {
    case ask
    case allow
    case block
    /// Cannot read or write a stored decision for this kind; UI must not
    /// offer a control here.
    case unsupported
}

nonisolated public enum ContentSettingOrigin {

    /// `nil` for anything not `http`/`https`.
    public static func normalize(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              webSchemes.contains(scheme),
              let host = url.host()?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port, port != defaultPort(for: scheme) {
            components.port = port
        }
        return components.url
    }

    private static let webSchemes: Set<String> = ["http", "https"]

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

// MARK: - JavaScript dialogs

nonisolated public enum JavaScriptDialogKind: String, Sendable {
    case alert
    case confirm
    case prompt
    /// `onbeforeunload`.
    case beforeUnload
}

nonisolated public struct JavaScriptDialogRequest: Sendable {
    public var kind: JavaScriptDialogKind
    public var message: String
    public var defaultPromptText: String
    public var origin: URL?

    public init(
        kind: JavaScriptDialogKind,
        message: String,
        defaultPromptText: String = "",
        origin: URL? = nil
    ) {
        self.kind = kind
        self.message = message
        self.defaultPromptText = defaultPromptText
        self.origin = origin
    }
}

nonisolated public struct JavaScriptDialogResponse: Sendable {
    public var accepted: Bool
    public var promptText: String?

    public init(accepted: Bool, promptText: String? = nil) {
        self.accepted = accepted
        self.promptText = promptText
    }
}

// MARK: - Context menu

nonisolated public struct ContextMenuContext: Sendable {
    public enum MediaKind: String, Sendable {
        case none, image, video, audio, canvas, file, plugin
    }

    public var pageURL: URL?
    public var frameURL: URL?
    public var linkURL: URL?
    public var unfilteredLinkURL: URL?
    public var sourceURL: URL?
    public var titleText: String?
    public var selectionText: String?
    public var mediaKind: MediaKind
    public var isEditable: Bool
    public var misspelledWord: String?
    public var dictionarySuggestions: [String]
    public var location: CGPoint

    public init(
        pageURL: URL? = nil,
        frameURL: URL? = nil,
        linkURL: URL? = nil,
        unfilteredLinkURL: URL? = nil,
        sourceURL: URL? = nil,
        titleText: String? = nil,
        selectionText: String? = nil,
        mediaKind: MediaKind = .none,
        isEditable: Bool = false,
        misspelledWord: String? = nil,
        dictionarySuggestions: [String] = [],
        location: CGPoint = .zero
    ) {
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.linkURL = linkURL
        self.unfilteredLinkURL = unfilteredLinkURL
        self.sourceURL = sourceURL
        self.titleText = titleText
        self.selectionText = selectionText
        self.mediaKind = mediaKind
        self.isEditable = isEditable
        self.misspelledWord = misspelledWord
        self.dictionarySuggestions = dictionarySuggestions
        self.location = location
    }
}

// MARK: - Media

nonisolated public struct MediaState: Equatable, Sendable {
    public var isAudible: Bool
    public var isMuted: Bool
    public var hasVideo: Bool
    /// Distinct from merely containing a media element (`hasVideo`).
    public var hasActiveMediaSession: Bool
    public var isPictureInPictureActive: Bool
    /// The engine's own answer to "would toggling PiP right now find something to float" --
    /// content::WebContentsObserver's MediaPlayerInfo, per frame, main or sub-. This is what
    /// gates the mini-player's PiP button; `hasVideo` is a page-side, main-frame-only scan
    /// and must not be used for that (it misses iframe-hosted players).
    public var isPictureInPictureAvailable: Bool
    public var isFullscreen: Bool
    public var nowPlayingTitle: String?
    public var nowPlayingArtist: String?
    public var nowPlayingArtworkURL: URL?
    public var isPlaying: Bool

    /// Read this rather than composing `isPlaying || isAudible`.
    public var isMediaActive: Bool {
        hasActiveMediaSession || isPlaying || isAudible
    }

    public init(
        isAudible: Bool = false,
        isMuted: Bool = false,
        hasVideo: Bool = false,
        hasActiveMediaSession: Bool = false,
        isPictureInPictureActive: Bool = false,
        isPictureInPictureAvailable: Bool = false,
        isFullscreen: Bool = false,
        nowPlayingTitle: String? = nil,
        nowPlayingArtist: String? = nil,
        nowPlayingArtworkURL: URL? = nil,
        isPlaying: Bool = false
    ) {
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.hasVideo = hasVideo
        self.hasActiveMediaSession = hasActiveMediaSession
        self.isPictureInPictureActive = isPictureInPictureActive
        self.isPictureInPictureAvailable = isPictureInPictureAvailable
        self.isFullscreen = isFullscreen
        self.nowPlayingTitle = nowPlayingTitle
        self.nowPlayingArtist = nowPlayingArtist
        self.nowPlayingArtworkURL = nowPlayingArtworkURL
        self.isPlaying = isPlaying
    }

    public static let idle = MediaState()
}

// MARK: - Colour scheme

/// Distinct from `PageColorSchemeScript.Scheme`, which only sets the
/// document's own `color-scheme`.
nonisolated public enum ContentColorScheme: String, CaseIterable, Sendable {
    case light
    case dark
}

// MARK: - Zoom

nonisolated public enum ZoomStep: Double, CaseIterable, Sendable {
    case p25 = 0.25
    case p33 = 0.33
    case p50 = 0.50
    case p67 = 0.67
    case p75 = 0.75
    case p80 = 0.80
    case p90 = 0.90
    case p100 = 1.00
    case p110 = 1.10
    case p125 = 1.25
    case p150 = 1.50
    case p175 = 1.75
    case p200 = 2.00
    case p250 = 2.50
    case p300 = 3.00
    case p400 = 4.00
    case p500 = 5.00

    public var percentLabel: String { "\(Int((rawValue * 100).rounded()))%" }

    public static func stepUp(from factor: Double) -> ZoomStep {
        allCases.first { $0.rawValue > factor + 0.001 } ?? .p500
    }

    public static func stepDown(from factor: Double) -> ZoomStep {
        allCases.last { $0.rawValue < factor - 0.001 } ?? .p25
    }
}

// MARK: - User scripts

nonisolated public struct UserScript: Identifiable, Codable, Sendable, Hashable {
    public enum InjectionTime: String, Codable, Sendable {
        case documentStart
        case documentEnd
    }

    public enum Kind: String, Codable, Sendable {
        case javaScript
        case stylesheet
    }

    public var id: UUID
    public var kind: Kind
    public var source: String
    public var injectionTime: InjectionTime
    public var matchPatterns: [String]
    public var allFrames: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        source: String,
        injectionTime: InjectionTime = .documentEnd,
        matchPatterns: [String] = ["<all_urls>"],
        allFrames: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.injectionTime = injectionTime
        self.matchPatterns = matchPatterns
        self.allFrames = allFrames
    }
}

// MARK: - Downloads

nonisolated public enum DownloadState: String, Codable, Sendable {
    case pending
    case inProgress
    case paused
    case completed
    case cancelled
    case interrupted
}

nonisolated public struct DownloadProgress: Equatable, Sendable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Int64
    public var state: DownloadState

    public init(
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Int64 = 0,
        state: DownloadState = .pending
    ) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.state = state
    }

    /// 0.0 ... 1.0, or `nil` when the total size is unknown.
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, Double(receivedBytes) / Double(totalBytes))
    }
}

// MARK: - Browsing data

nonisolated public struct BrowsingDataScope: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let cookies = BrowsingDataScope(rawValue: 1 << 0)
    public static let cache = BrowsingDataScope(rawValue: 1 << 1)

    // Site storage, passwords and autofill have no removal API on today's
    // engine; they are cleared from the profile files by ChromiumProfileData instead.
    public static let all: BrowsingDataScope = [.cookies, .cache]
}

// MARK: - Cookies

nonisolated public struct EngineCookie: Sendable, Hashable {

    public enum SameSite: Sendable, Hashable {
        /// Not `.lax` — Chromium's unspecified-default has moved between releases.
        case unspecified
        case none
        case lax
        case strict
    }

    public var name: String
    public var value: String
    /// Leading dot (`.example.com`) covers subdomains; without it, host-only.
    public var domain: String
    public var path: String
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: SameSite
    /// `nil` for a session cookie — distinct from an expiry already in the past.
    public var expiresAt: Date?
    public var createdAt: Date
    public var lastAccessedAt: Date

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        sameSite: SameSite = .unspecified,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

// MARK: - Certificates

nonisolated public struct CertificateProblem: Sendable {
    public var host: String
    public var issuer: String
    public var subject: String
    public var validFrom: Date?
    public var validUntil: Date?
    public var reason: String
    /// The engine's own error code, e.g. `net::ERR_CERT_DATE_INVALID` is -201.
    public var errorCode: Int
    /// False when the engine reported the error as strictly enforced — an HSTS
    /// host, a pinned key. No proceed affordance may be offered; the engine
    /// refuses one anyway.
    public var isOverridable: Bool

    public init(
        host: String,
        issuer: String = "",
        subject: String = "",
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        reason: String = "",
        errorCode: Int = 0,
        isOverridable: Bool = true
    ) {
        self.host = host
        self.issuer = issuer
        self.subject = subject
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.reason = reason
        self.errorCode = errorCode
        self.isOverridable = isOverridable
    }
}

/// Human wording for the net:: certificate errors Orbit's interstitial can be
/// shown for. Anything unmapped falls back to the engine's own short name so
/// the reason line is never blank.
nonisolated public enum CertificateProblemReason {
    public static func describe(errorCode: Int, engineName: String) -> String {
        switch errorCode {
        case -200: return "The certificate does not match the site's name."
        case -201: return "The certificate has expired or is not valid yet."
        case -202: return "The certificate was not issued by a trusted authority."
        case -203: return "The certificate contains errors."
        case -204: return "The certificate offers no way to check whether it was revoked."
        case -205: return "The certificate's revocation status could not be checked."
        case -206: return "The certificate has been revoked."
        case -207: return "The certificate is not valid for this connection."
        case -208: return "The certificate uses a weak signature algorithm."
        case -210: return "The certificate names a non-unique host."
        case -211: return "The certificate uses a weak key."
        case -212: return "The certificate violates its issuer's name constraints."
        case -213: return "The certificate's validity period is too long to be trusted."
        case -217: return "The connection is being intercepted by known software."
        case -219: return "The certificate is self-signed by a local network device."
        default: return engineName.isEmpty ? "The certificate could not be verified." : engineName
        }
    }
}

/// `nil` means nothing to show — never a stand-in for a real certificate.
nonisolated public struct SiteCertificate: Sendable {
    public var subject: String
    public var issuer: String
    public var validFrom: Date?
    public var validUntil: Date?
    /// Hex-encoded DER serial number, e.g. `"04A1B2C3"`.
    public var serialNumber: String?

    public init(
        subject: String,
        issuer: String,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        serialNumber: String? = nil
    ) {
        self.subject = subject
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.serialNumber = serialNumber
    }
}
