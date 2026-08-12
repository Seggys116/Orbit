//  dlopen/dlsym FFI boundary to Orbit Framework; one image per process, so this is a singleton.
//  OrbitMain nests Chromium's own run loop and must only be scheduled via
//  CFRunLoopPerformBlock, never called synchronously or via DispatchQueue.main.async.

import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import OSLog

/// What the engine should do with one intercepted network request. Top level,
/// not nested in `OrbitChromiumBridge`, since it is built on a background sequence.
nonisolated enum ContentBlockingOutcome: Sendable, Equatable {
    case allow
    case block
    case substitute(mimeType: String, body: [UInt8])
}

@MainActor
final class OrbitChromiumBridge {

    static let shared = OrbitChromiumBridge()

    enum BridgeError: Error, CustomStringConvertible {
        case frameworkNotFound(String)
        case dlopenFailed(String)
        case symbolMissing(String)
        case protocolConformanceFailed(String)

        var description: String {
            switch self {
            case .frameworkNotFound(let path): return "Orbit Framework not found at \(path)"
            case .dlopenFailed(let reason): return "dlopen of Orbit Framework failed: \(reason)"
            case .symbolMissing(let name): return "Orbit Framework is missing expected symbol \(name)"
            case .protocolConformanceFailed(let name):
                return "NSApp does not conform to the Orbit Framework's @\(name); content::responsiveness::Watcher::SetUp() would abort the browser process"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "OrbitChromiumBridge")

    private(set) var isReady = false
    private var didStart = false
    // Set only by a load() that ran to completion. A partial load leaves
    // plenty of function pointers behind, so no individual one can stand in
    // for "the framework is loaded" -- see load().
    private var didLoad = false

    // MARK: - dlsym'd C ABI, mirroring Chromium/Embedder/bridge/orbit_bridge_api.h

    private typealias OrbitMainFn = @convention(c) (Int32, UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias ReadyCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetReadyCallbackFn = @convention(c) (ReadyCallback, UnsafeMutableRawPointer?) -> Void
    private typealias SetUserDataDirectoryFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias RequestQuitFn = @convention(c) () -> Int32
    private typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias PathFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    // UnsafeRawPointer, not a typed pointer to OrbitWebContentsCallbacksLayout:
    // a Swift-native struct type is not representable in a @convention(c)
    // function type, even by pointer. setCallbacks(_:_:) rebinds it.
    private typealias SetCallbacksFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    private typealias GetNativeViewFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetVisibleFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias LoadURLFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias ReloadFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GoBackFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GoForwardFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GoToOffsetFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias CanGoFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias FocusFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    // Mirrors orbit_bridge_api.h's OrbitWebContentsCut/Copy/Paste/SelectAll.
    private typealias EditingCommandFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias NotifyNativeEventFn = @convention(c) (UnsafeMutableRawPointer?, UInt) -> Void

    // Mirrors orbit_bridge_api.h's OrbitJavaScriptResultCallback.
    fileprivate typealias JavaScriptResultCallback = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void
    private typealias EvaluateJavaScriptFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, JavaScriptResultCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias InjectUserScriptFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias SetUserScriptsFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias SetColorSchemeFn = @convention(c) (Int32) -> Void

    // Mirrors orbit_bridge_api.h's OrbitContentBlockingDecisionCallback:
    // 0 = allow, 1 = block, 2 = serve the substitution written to the three
    // out-parameters (char**, uint8_t**, int32_t*).
    fileprivate typealias ContentBlockingDecisionCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int32>?
    ) -> Int32
    private typealias SetContentBlockingDecisionCallbackFn = @convention(c) (
        ContentBlockingDecisionCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias SetContentBlockingActiveFn = @convention(c) (Int32) -> Void

    private typealias SessionHistoryFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias LoadHTMLFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void
    private typealias SavePageFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    // Mirrors orbit_bridge_api.h's OrbitPrintToPdfCallback.
    fileprivate typealias PrintToPdfCallback = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias PrintToPdfFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, PrintToPdfCallback, UnsafeMutableRawPointer?
    ) -> Void

    private typealias FindFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32, Int32
    ) -> Void
    private typealias StopFindingFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias SetZoomFactorFn = @convention(c) (UnsafeMutableRawPointer?, Double) -> Void
    private typealias EnableAutoResizeFn = @convention(c) (
        UnsafeMutableRawPointer?, Double, Double, Double, Double
    ) -> Void

    private typealias TogglePictureInPictureFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias HasPictureInPictureVideoFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    // Mirrors orbit_bridge_api.h's OrbitCapturePreviewCallback.
    fileprivate typealias CapturePreviewCallback = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32
    ) -> Void
    private typealias CapturePreviewFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Double, Double, Double, Double, Double, Double,
        CapturePreviewCallback, UnsafeMutableRawPointer?
    ) -> Void

    private typealias SetUserAgentFn = @convention(c) (UnsafePointer<CChar>?) -> Void

    // Mirrors orbit_bridge_api.h's OrbitCookiesCallback.
    fileprivate typealias CookiesCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias GetCookiesFn = @convention(c) (
        UnsafePointer<CChar>?, CookiesCallback, UnsafeMutableRawPointer?
    ) -> Void

    // Mirrors orbit_bridge_api.h's OrbitCompletionCallback.
    fileprivate typealias CompletionCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias DeleteCookiesFn = @convention(c) (
        UnsafePointer<CChar>?, CompletionCallback, UnsafeMutableRawPointer?
    ) -> Void

    // Mirrors orbit_bridge_api.h's OrbitSetCookiesCallback.
    fileprivate typealias SetCookiesResultCallback = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias SetCookiesFn = @convention(c) (
        UnsafePointer<CChar>?, SetCookiesResultCallback, UnsafeMutableRawPointer?
    ) -> Void

    // Mirrors orbit_bridge_api.h's OrbitLoadExtensionCallback -- same shape as
    // JavaScriptResultCallback.
    fileprivate typealias LoadExtensionCallback = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void
    private typealias LoadExtensionFn = @convention(c) (
        UnsafePointer<CChar>?, LoadExtensionCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias UnloadExtensionFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias GetLoadedExtensionsJSONFn = @convention(c) () -> UnsafePointer<CChar>?

    fileprivate typealias ExtensionActionCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void
    private typealias SetExtensionActionCallbackFn = @convention(c) (
        ExtensionActionCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias GetExtensionActionsJSONFn = @convention(c) () -> UnsafePointer<CChar>?

    // chrome.privacy.services.searchSuggestEnabled. `enabled` is the EFFECTIVE
    // value, i.e. after any extension override -- see orbit_bridge_api.h.
    private typealias SearchSuggestEnabledCallback = @convention(c) (
        UnsafeMutableRawPointer?, Int32
    ) -> Void
    private typealias SetSearchSuggestEnabledCallbackFn = @convention(c) (
        SearchSuggestEnabledCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias GetSearchSuggestEnabledFn = @convention(c) () -> Int32
    private typealias SetSearchSuggestEnabledFn = @convention(c) (Int32) -> Void

    private typealias CancelDownloadFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias PauseDownloadFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias ResumeDownloadFn = @convention(c) (UnsafePointer<CChar>?) -> Void

    private typealias GetContentSettingFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?
    private typealias SetContentSettingFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void

    // Mirrors orbit_bridge_api.h's chrome.tabs/chrome.windows bridge --
    // see OrbitChromiumTabsBridge.swift, the one caller of all of these.
    private typealias TabsCreatedFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32
    ) -> Void
    private typealias TabsRemovedFn = @convention(c) (Int32, Int32) -> Void
    private typealias TabsActivatedFn = @convention(c) (Int32, Int32, Int32) -> Void
    private typealias TabsMovedFn = @convention(c) (Int32, Int32, Int32, Int32) -> Void
    private typealias TabsSetPinnedFn = @convention(c) (Int32, Int32) -> Void
    private typealias TabsIndexChangedFn = @convention(c) (Int32, Int32) -> Void
    private typealias WindowsCreatedFn = @convention(c) (Int32, Int32) -> Void
    private typealias WindowsRemovedFn = @convention(c) (Int32) -> Void
    private typealias WindowsFocusChangedFn = @convention(c) (Int32) -> Void
    private typealias WindowsStateChangedFn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

    // UnsafeRawPointer for the same reason SetCallbacksFn uses one.
    private typealias SetTabsDelegateFn = @convention(c) (UnsafeRawPointer?) -> Void
    private typealias SetManagementDelegateFn = @convention(c) (UnsafeRawPointer?) -> Void
    private typealias ManagementUninstallConsentFn = @convention(c) (UInt64, Int32) -> Void
    private typealias SetPermissionsConsentDelegateFn = @convention(c) (UnsafeRawPointer?) -> Void
    private typealias PermissionsConsentResponseFn = @convention(c) (UInt64, Int32) -> Void

    // Mirrors orbit_bridge_api.h's OrbitExtensionTabRequestCallback. Not
    // fileprivate, unlike this file's other callback typealiases: its one
    // trampoline lives in OrbitChromiumTabsBridge.swift, not here.
    typealias ExtensionTabRequestCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32
    ) -> Int32
    private typealias SetExtensionTabRequestCallbackFn = @convention(c) (
        ExtensionTabRequestCallback, UnsafeMutableRawPointer?
    ) -> Void

    // Process-wide, not an OrbitWebContentsCallbacks field, so `source` names the
    // asking tab and the adopted handle can be handed over before Swift wraps it.
    // Params: opaque, source, handle, url, disposition, user_gesture.
    typealias NewContentRequestCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?, Int32, Int32
    ) -> Int32
    private typealias SetNewContentRequestCallbackFn = @convention(c) (
        NewContentRequestCallback, UnsafeMutableRawPointer?
    ) -> Void

    private typealias RespondToExtensionRequestFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void

    // Process-wide, not an OrbitWebContentsCallbacks field, so the owning tab
    // arrives as `handle` instead of the struct's own opaque.
    // Params: opaque, handle, request_id, request_url, host, cert_error, error_name,
    // issuer, subject, valid_from, valid_until, overridable.
    typealias CertificateErrorCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt64,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Double, Double, Int32
    ) -> Void
    private typealias SetCertificateErrorCallbackFn = @convention(c) (
        CertificateErrorCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias RespondToCertificateErrorFn = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, Int32
    ) -> Void

    // Mirrors orbit_bridge_api.h's OrbitWebContentsOpenDevTools/OrbitWebContentsInspectElementAt.
    private typealias OpenDevToolsFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32
    ) -> UnsafeMutableRawPointer?
    private typealias InspectElementAtFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void
    private typealias DevToolsStateJSONFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

    private var orbitMain: OrbitMainFn?
    private var setReadyCallback: SetReadyCallbackFn?
    private var setUserDataDirectoryFn: SetUserDataDirectoryFn?
    private var requestQuit: RequestQuitFn?
    private var versionNumber: VersionFn?
    private var browserContextPath: PathFn?
    private var webContentsCreate: CreateFn?
    private var webContentsDestroy: DestroyFn?
    private var webContentsSetCallbacks: SetCallbacksFn?
    private var webContentsGetNativeView: GetNativeViewFn?
    private var webContentsSetVisible: SetVisibleFn?
    private var webContentsLoadURL: LoadURLFn?
    private var webContentsReload: ReloadFn?
    private var webContentsStop: StopFn?
    private var webContentsGoBack: GoBackFn?
    private var webContentsGoForward: GoForwardFn?
    private var webContentsGoToOffset: GoToOffsetFn?
    private var webContentsCanGoBack: CanGoFn?
    private var webContentsCanGoForward: CanGoFn?
    private var webContentsFocus: FocusFn?
    private var webContentsCut: EditingCommandFn?
    private var webContentsCopy: EditingCommandFn?
    private var webContentsPaste: EditingCommandFn?
    private var webContentsSelectAll: EditingCommandFn?
    private var notifyWillRunEvent: NotifyNativeEventFn?
    private var notifyDidRunEvent: NotifyNativeEventFn?
    private var webContentsEvaluateJavaScript: EvaluateJavaScriptFn?
    private var webContentsEvaluateJavaScriptWithUserGesture: EvaluateJavaScriptFn?
    private var webContentsInjectUserScript: InjectUserScriptFn?
    private var setUserScripts: SetUserScriptsFn?
    private var setColorSchemeIsDark: SetColorSchemeFn?
    private var setContentBlockingDecisionCallback: SetContentBlockingDecisionCallbackFn?
    private var setContentBlockingActiveFn: SetContentBlockingActiveFn?
    private var webContentsSessionHistory: SessionHistoryFn?
    private var webContentsLoadHTML: LoadHTMLFn?
    private var webContentsSavePage: SavePageFn?
    private var webContentsPrintToPdf: PrintToPdfFn?
    private var webContentsFind: FindFn?
    private var webContentsStopFinding: StopFindingFn?
    private var webContentsSetZoomFactor: SetZoomFactorFn?
    private var webContentsEnableAutoResize: EnableAutoResizeFn?
    private var webContentsTogglePictureInPicture: TogglePictureInPictureFn?
    private var webContentsHasPictureInPictureVideo: HasPictureInPictureVideoFn?
    private var webContentsCapturePreview: CapturePreviewFn?
    private var setUserAgent: SetUserAgentFn?
    private var getCookies: GetCookiesFn?
    private var deleteCookies: DeleteCookiesFn?
    private var setCookies: SetCookiesFn?
    private var loadExtensionFn: LoadExtensionFn?
    private var loadExtensionForStartupFn: LoadExtensionFn?
    private var unloadExtensionFn: UnloadExtensionFn?
    private var uninstallExtensionFn: UnloadExtensionFn?
    private var getLoadedExtensionsJSON: GetLoadedExtensionsJSONFn?
    private var setExtensionActionCallbackFn: SetExtensionActionCallbackFn?
    private var getExtensionActionsJSONFn: GetExtensionActionsJSONFn?
    private var setSearchSuggestEnabledCallbackFn: SetSearchSuggestEnabledCallbackFn?
    private var getSearchSuggestEnabledFn: GetSearchSuggestEnabledFn?
    private var setSearchSuggestEnabledFn: SetSearchSuggestEnabledFn?

    /// Fires whenever the effective value changes, from either side: an
    /// extension's types.ChromeSetting.set, or setSearchSuggestEnabled below.
    var searchSuggestEnabledHandler: ((Bool) -> Void)?

    /// Runs once the browser process exists, i.e. once there is a PrefService
    /// to push into. Read at call time, so installing it after loadAndStart()
    /// but before the browser is up still works.
    var browserReadyHandler: (() -> Void)?
    private var cancelDownloadFn: CancelDownloadFn?
    private var pauseDownloadFn: PauseDownloadFn?
    private var resumeDownloadFn: ResumeDownloadFn?
    private var getContentSettingFn: GetContentSettingFn?
    private var setContentSettingFn: SetContentSettingFn?
    private var tabsCreatedFn: TabsCreatedFn?
    private var tabsRemovedFn: TabsRemovedFn?
    private var tabsActivatedFn: TabsActivatedFn?
    private var tabsMovedFn: TabsMovedFn?
    private var tabsSetPinnedFn: TabsSetPinnedFn?
    private var tabsIndexChangedFn: TabsIndexChangedFn?
    private var windowsCreatedFn: WindowsCreatedFn?
    private var windowsRemovedFn: WindowsRemovedFn?
    private var windowsFocusChangedFn: WindowsFocusChangedFn?
    private var windowsStateChangedFn: WindowsStateChangedFn?
    private var setTabsDelegateFn: SetTabsDelegateFn?
    private var setManagementDelegateFn: SetManagementDelegateFn?
    private var managementUninstallConsentFn: ManagementUninstallConsentFn?
    private var setPermissionsConsentDelegateFn: SetPermissionsConsentDelegateFn?
    private var permissionsConsentResponseFn: PermissionsConsentResponseFn?
    private var setExtensionTabRequestCallbackFn: SetExtensionTabRequestCallbackFn?
    private var setNewContentRequestCallbackFn: SetNewContentRequestCallbackFn?
    private var respondToExtensionRequestFn: RespondToExtensionRequestFn?
    private var setCertificateErrorCallbackFn: SetCertificateErrorCallbackFn?
    private var respondToCertificateErrorFn: RespondToCertificateErrorFn?
    private var webContentsOpenDevTools: OpenDevToolsFn?
    private var webContentsInspectElementAt: InspectElementAtFn?
    private var webContentsDevToolsStateJSON: DevToolsStateJSONFn?

    typealias ContentBlockingHandler = (
        _ requestURL: String, _ documentURL: String, _ resourceType: Int32
    ) -> ContentBlockingOutcome

    /// Asked synchronously on a background sequence, never the main actor; `nil`
    /// means allow. `nonisolated` and lock-backed to read off the main actor safely.
    nonisolated var contentBlockingDecisionHandler: ContentBlockingHandler? {
        get { contentBlockingHandlerBox.value }
        set { contentBlockingHandlerBox.value = newValue }
    }
    private let contentBlockingHandlerBox = ContentBlockingHandlerBox()

    /// Gates whether the interceptor is installed at all; the decision handler
    /// above only ever changes what a decision returns, not whether it runs.
    func setContentBlockingActive(_ active: Bool) {
        setContentBlockingActiveFn?(active ? 1 : 0)
    }

    // MARK: - Load + start

    /// Whatever was handed to `setUserDataDirectory`, or `nil` while the
    /// engine is still on its own production default.
    private(set) var appliedUserDataDirectory: String?

    /// Must run before `loadAndStart()` schedules OrbitMain, the last moment the
    /// engine reads it. Traps rather than degrading into the real user's profile.
    func setUserDataDirectory(_ path: String) throws {
        if !didLoad {
            try load()
        }
        guard let setUserDataDirectoryFn else {
            fatalError(
                "Orbit Framework does not export OrbitSetUserDataDirectory, so the engine cannot be pointed at \(path) — it would run on the real user's profile instead. Rebuild the Chromium embedder."
            )
        }
        if let appliedUserDataDirectory {
            guard appliedUserDataDirectory == path else {
                fatalError(
                    "OrbitChromiumBridge: this process's engine already resolved its profile to \(appliedUserDataDirectory); it cannot also run on \(path)"
                )
            }
            return
        }
        guard !didStart else {
            fatalError(
                "OrbitChromiumBridge: setUserDataDirectory(\(path)) came after OrbitMain was scheduled — the engine would have used the production profile instead"
            )
        }
        path.withCString { setUserDataDirectoryFn($0) }
        appliedUserDataDirectory = path
    }

    /// Idempotent. Throws only for a genuinely unusable framework (missing
    /// binary, missing symbol) -- never for "not ready yet", which is not an
    /// error, see `isReady`.
    func loadAndStart() throws {
        if !didLoad {
            try load()
        }
        guard !didStart else { return }
        didStart = true

        setReadyCallback?(OrbitChromiumBridge.readyTrampoline, Unmanaged.passUnretained(self).toOpaque())
        // Safe to register before any handler is installed: the trampolines
        // read their handler at call time, not at registration time.
        setContentBlockingDecisionCallback?(
            OrbitChromiumBridge.contentBlockingDecisionTrampoline, Unmanaged.passUnretained(self).toOpaque()
        )
        setExtensionActionCallbackFn?(
            OrbitChromiumBridge.extensionActionTrampoline, Unmanaged.passUnretained(self).toOpaque()
        )
        setSearchSuggestEnabledCallbackFn?(
            OrbitChromiumBridge.searchSuggestEnabledTrampoline, Unmanaged.passUnretained(self).toOpaque()
        )

        // Never call orbitMain synchronously; DispatchQueue.main.async would starve
        // once its nested pump takes over GCD's non-reentrant queue drain.
        let argv = ProcessInfo.processInfo.arguments
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [orbitMain] in
            guard let orbitMain else { return }
            let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            defer {
                // OrbitMain does not return until process shutdown (see the
                // file comment), so this only runs on the way out.
                for pointer in cArgv { free(pointer) }
            }
            cArgv.withUnsafeBufferPointer { buffer in
                _ = orbitMain(Int32(argv.count), buffer.baseAddress)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func load() throws {
        guard let frameworkURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Orbit Framework.framework/Orbit Framework")
        else {
            throw BridgeError.frameworkNotFound("<no Frameworks directory in this bundle>")
        }
        guard FileManager.default.fileExists(atPath: frameworkURL.path) else {
            throw BridgeError.frameworkNotFound(frameworkURL.path)
        }
        guard let handle = dlopen(frameworkURL.path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) else {
            throw BridgeError.dlopenFailed(String(cString: dlerror()))
        }

        // Before any dlsym: content::responsiveness::Watcher::SetUp() DCHECKs
        // this conformance the moment OrbitMain runs.
        try OrbitChromiumBridge.registerRealNativeEventProtocols()
        OrbitChromiumBridge.installSendEventSwizzleOnce

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw BridgeError.symbolMissing(name)
            }
            return unsafeBitCast(raw, to: T.self)
        }

        // A framework built before this symbol existed still starts the browser.
        func optionalSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else {
                OrbitChromiumBridge.logger.notice(
                    "Orbit Framework does not export \(name, privacy: .public); the feature it backs is unavailable"
                )
                return nil
            }
            return unsafeBitCast(raw, to: T.self)
        }

        orbitMain = try symbol("OrbitMain", as: OrbitMainFn.self)
        setReadyCallback = try symbol("OrbitSetBrowserReadyCallback", as: SetReadyCallbackFn.self)
        // Optional: `.persistent` needs no override; setUserDataDirectory traps
        // for the modes that do rather than write into the real profile.
        setUserDataDirectoryFn = optionalSymbol("OrbitSetUserDataDirectory", as: SetUserDataDirectoryFn.self)
        requestQuit = try symbol("OrbitRequestBrowserQuit", as: RequestQuitFn.self)
        versionNumber = try symbol("OrbitChromiumVersionNumber", as: VersionFn.self)
        browserContextPath = try symbol("OrbitBrowserContextPath", as: PathFn.self)
        webContentsCreate = try symbol("OrbitWebContentsCreate", as: CreateFn.self)
        webContentsDestroy = try symbol("OrbitWebContentsDestroy", as: DestroyFn.self)
        webContentsSetCallbacks = try symbol("OrbitWebContentsSetCallbacks", as: SetCallbacksFn.self)
        webContentsGetNativeView = try symbol("OrbitWebContentsGetNativeView", as: GetNativeViewFn.self)
        webContentsSetVisible = optionalSymbol("OrbitWebContentsSetVisible", as: SetVisibleFn.self)
        webContentsLoadURL = try symbol("OrbitWebContentsLoadURL", as: LoadURLFn.self)
        webContentsReload = try symbol("OrbitWebContentsReload", as: ReloadFn.self)
        webContentsStop = try symbol("OrbitWebContentsStop", as: StopFn.self)
        webContentsGoBack = try symbol("OrbitWebContentsGoBack", as: GoBackFn.self)
        webContentsGoForward = try symbol("OrbitWebContentsGoForward", as: GoForwardFn.self)
        webContentsGoToOffset = try symbol("OrbitWebContentsGoToOffset", as: GoToOffsetFn.self)
        webContentsCanGoBack = try symbol("OrbitWebContentsCanGoBack", as: CanGoFn.self)
        webContentsCanGoForward = try symbol("OrbitWebContentsCanGoForward", as: CanGoFn.self)
        webContentsFocus = try symbol("OrbitWebContentsFocus", as: FocusFn.self)
        webContentsCut = try symbol("OrbitWebContentsCut", as: EditingCommandFn.self)
        webContentsCopy = try symbol("OrbitWebContentsCopy", as: EditingCommandFn.self)
        webContentsPaste = try symbol("OrbitWebContentsPaste", as: EditingCommandFn.self)
        webContentsSelectAll = try symbol("OrbitWebContentsSelectAll", as: EditingCommandFn.self)
        notifyWillRunEvent = try symbol("OrbitNotifyWillRunNativeEvent", as: NotifyNativeEventFn.self)
        notifyDidRunEvent = try symbol("OrbitNotifyDidRunNativeEvent", as: NotifyNativeEventFn.self)
        webContentsEvaluateJavaScript = try symbol("OrbitWebContentsEvaluateJavaScript", as: EvaluateJavaScriptFn.self)
        webContentsInjectUserScript = try symbol("OrbitWebContentsInjectUserScript", as: InjectUserScriptFn.self)
        setUserScripts = try symbol("OrbitSetUserScripts", as: SetUserScriptsFn.self)
        setColorSchemeIsDark = optionalSymbol(
            "OrbitSetColorSchemeIsDark", as: SetColorSchemeFn.self
        )
        setContentBlockingDecisionCallback = try symbol(
            "OrbitSetContentBlockingDecisionCallback", as: SetContentBlockingDecisionCallbackFn.self
        )
        setContentBlockingActiveFn = try symbol("OrbitSetContentBlockingActive", as: SetContentBlockingActiveFn.self)
        webContentsSessionHistory = try symbol("OrbitWebContentsSessionHistory", as: SessionHistoryFn.self)
        webContentsLoadHTML = try symbol("OrbitWebContentsLoadHTML", as: LoadHTMLFn.self)
        webContentsSavePage = try symbol("OrbitWebContentsSavePage", as: SavePageFn.self)
        webContentsPrintToPdf = try symbol("OrbitWebContentsPrintToPdf", as: PrintToPdfFn.self)
        webContentsFind = try symbol("OrbitWebContentsFind", as: FindFn.self)
        webContentsStopFinding = try symbol("OrbitWebContentsStopFinding", as: StopFindingFn.self)
        webContentsSetZoomFactor = try symbol("OrbitWebContentsSetZoomFactor", as: SetZoomFactorFn.self)
        webContentsEnableAutoResize = try symbol("OrbitWebContentsEnableAutoResize", as: EnableAutoResizeFn.self)
        webContentsTogglePictureInPicture = optionalSymbol(
            "OrbitWebContentsTogglePictureInPicture", as: TogglePictureInPictureFn.self
        )
        webContentsHasPictureInPictureVideo = optionalSymbol(
            "OrbitWebContentsHasPictureInPictureVideo", as: HasPictureInPictureVideoFn.self
        )
        webContentsCapturePreview = try symbol("OrbitWebContentsCapturePreview", as: CapturePreviewFn.self)
        setUserAgent = try symbol("OrbitSetUserAgent", as: SetUserAgentFn.self)
        getCookies = try symbol("OrbitGetCookies", as: GetCookiesFn.self)
        deleteCookies = try symbol("OrbitDeleteCookies", as: DeleteCookiesFn.self)
        setCookies = try symbol("OrbitSetCookies", as: SetCookiesFn.self)
        loadExtensionFn = try symbol("OrbitLoadExtension", as: LoadExtensionFn.self)
        loadExtensionForStartupFn = optionalSymbol("OrbitLoadExtensionForStartup", as: LoadExtensionFn.self)
        unloadExtensionFn = try symbol("OrbitUnloadExtension", as: UnloadExtensionFn.self)
        uninstallExtensionFn = optionalSymbol("OrbitUninstallExtension", as: UnloadExtensionFn.self)
        getLoadedExtensionsJSON = try symbol("OrbitGetLoadedExtensionsJSON", as: GetLoadedExtensionsJSONFn.self)
        setExtensionActionCallbackFn = try symbol(
            "OrbitSetExtensionActionCallback", as: SetExtensionActionCallbackFn.self
        )
        getExtensionActionsJSONFn = try symbol(
            "OrbitGetExtensionActionsJSON", as: GetExtensionActionsJSONFn.self
        )
        setSearchSuggestEnabledCallbackFn = optionalSymbol(
            "OrbitSetSearchSuggestEnabledCallback", as: SetSearchSuggestEnabledCallbackFn.self
        )
        getSearchSuggestEnabledFn = optionalSymbol(
            "OrbitGetSearchSuggestEnabled", as: GetSearchSuggestEnabledFn.self
        )
        setSearchSuggestEnabledFn = optionalSymbol(
            "OrbitSetSearchSuggestEnabled", as: SetSearchSuggestEnabledFn.self
        )
        cancelDownloadFn = try symbol("OrbitCancelDownload", as: CancelDownloadFn.self)
        pauseDownloadFn = try symbol("OrbitPauseDownload", as: PauseDownloadFn.self)
        resumeDownloadFn = try symbol("OrbitResumeDownload", as: ResumeDownloadFn.self)
        getContentSettingFn = try symbol("OrbitGetContentSetting", as: GetContentSettingFn.self)
        setContentSettingFn = try symbol("OrbitSetContentSetting", as: SetContentSettingFn.self)
        tabsCreatedFn = try symbol("OrbitTabsCreated", as: TabsCreatedFn.self)
        tabsRemovedFn = try symbol("OrbitTabsRemoved", as: TabsRemovedFn.self)
        tabsActivatedFn = try symbol("OrbitTabsActivated", as: TabsActivatedFn.self)
        tabsMovedFn = try symbol("OrbitTabsMoved", as: TabsMovedFn.self)
        tabsSetPinnedFn = try symbol("OrbitTabsSetPinned", as: TabsSetPinnedFn.self)
        tabsIndexChangedFn = optionalSymbol("OrbitTabsIndexChanged", as: TabsIndexChangedFn.self)
        windowsCreatedFn = try symbol("OrbitWindowsCreated", as: WindowsCreatedFn.self)
        windowsRemovedFn = try symbol("OrbitWindowsRemoved", as: WindowsRemovedFn.self)
        windowsFocusChangedFn = try symbol("OrbitWindowsFocusChanged", as: WindowsFocusChangedFn.self)
        windowsStateChangedFn = optionalSymbol("OrbitWindowsStateChanged", as: WindowsStateChangedFn.self)
        setTabsDelegateFn = try symbol("OrbitSetTabsDelegate", as: SetTabsDelegateFn.self)
        setManagementDelegateFn = try symbol("OrbitSetManagementDelegate", as: SetManagementDelegateFn.self)
        managementUninstallConsentFn = try symbol("OrbitManagementUninstallConsent", as: ManagementUninstallConsentFn.self)
        setPermissionsConsentDelegateFn = optionalSymbol(
            "OrbitSetPermissionsConsentDelegate", as: SetPermissionsConsentDelegateFn.self
        )
        webContentsEvaluateJavaScriptWithUserGesture = optionalSymbol(
            "OrbitWebContentsEvaluateJavaScriptWithUserGesture", as: EvaluateJavaScriptFn.self
        )
        permissionsConsentResponseFn = optionalSymbol(
            "OrbitPermissionsConsentResponse", as: PermissionsConsentResponseFn.self
        )
        setExtensionTabRequestCallbackFn = try symbol(
            "OrbitSetExtensionTabRequestCallback", as: SetExtensionTabRequestCallbackFn.self
        )
        setNewContentRequestCallbackFn = try symbol(
            "OrbitSetNewContentRequestCallback", as: SetNewContentRequestCallbackFn.self
        )
        respondToExtensionRequestFn = try symbol(
            "OrbitWebContentsRespondToExtensionRequest", as: RespondToExtensionRequestFn.self
        )
        setCertificateErrorCallbackFn = try symbol(
            "OrbitSetCertificateErrorCallback", as: SetCertificateErrorCallbackFn.self
        )
        respondToCertificateErrorFn = try symbol(
            "OrbitWebContentsRespondToCertificateError", as: RespondToCertificateErrorFn.self
        )
        webContentsOpenDevTools = try symbol("OrbitWebContentsOpenDevTools", as: OpenDevToolsFn.self)
        webContentsInspectElementAt = try symbol("OrbitWebContentsInspectElementAt", as: InspectElementAtFn.self)
        webContentsDevToolsStateJSON = try symbol("OrbitWebContentsDevToolsStateJSON", as: DevToolsStateJSONFn.self)

        didLoad = true
    }

    // Registers on NSApplication itself, not NSApp's private runtime subclass,
    // since class-hierarchy lookup walks up to it. Throws rather than logs: a
    // missed conformance DCHECK-aborts the process with no clue why.
    private static func registerRealNativeEventProtocols() throws {
        for name in ["NativeEventProcessor", "CrAppProtocol", "CrAppControlProtocol"] {
            guard let real = objc_getProtocol(name) else {
                throw BridgeError.protocolConformanceFailed(name)
            }
            class_addProtocol(NSApplication.self, real)
            guard class_conformsToProtocol(NSApplication.self, real) else {
                throw BridgeError.protocolConformanceFailed(name)
            }
        }
    }

    // Runs exactly once per process (static let, not a function): swapping
    // twice would exchange the IMPs back, undoing the swizzle entirely.
    private static let installSendEventSwizzleOnce: Void = {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.orbitSendEvent(_:)))
        else {
            logger.error("could not resolve NSApplication.sendEvent(_:) / orbitSendEvent(_:) for the swizzle")
            return
        }
        method_exchangeImplementations(original, replacement)
    }()

    // MARK: - Ready callback trampoline

    // No captures, so this compiles to a plain C function pointer; state
    // lives on the instance recovered via the opaque context pointer.
    private static let readyTrampoline: ReadyCallback = { opaque in
        guard let opaque else { return }
        // Always fires from PreMainMessageLoopRun on content::BrowserThread::UI,
        // which on mac is this process's main thread -- see the file comment.
        MainActor.assumeIsolated {
            let bridge = Unmanaged<OrbitChromiumBridge>.fromOpaque(opaque).takeUnretainedValue()
            bridge.isReady = true
            OrbitChromiumBridge.logger.info("browser process ready")
            bridge.browserReadyHandler?()
        }
    }

    // Deliberately not MainActor.assumeIsolated: fires on a background
    // ThreadPool sequence, and asserting main-actor isolation here would
    // crash the browser process on the first real page load.
    nonisolated private static let contentBlockingDecisionTrampoline: ContentBlockingDecisionCallback = {
        opaque, requestURLPtr, documentURLPtr, resourceType, outMimeType, outBody, outBodyLength in
        guard let opaque, let requestURLPtr, let documentURLPtr else { return 0 }
        let bridge = Unmanaged<OrbitChromiumBridge>.fromOpaque(opaque).takeUnretainedValue()
        guard let handler = bridge.contentBlockingDecisionHandler else { return 0 }
        switch handler(String(cString: requestURLPtr), String(cString: documentURLPtr), resourceType) {
        case .allow:
            return 0
        case .block:
            return 1
        case .substitute(let mimeType, let body):
            // Blocks rather than allows if the stub can't be handed over. On success both
            // outMimeType/outBody buffers become the C++ side's to free(); freed here only
            // on the failure paths below.
            guard let outMimeType, let outBody, let outBodyLength,
                  body.count <= OrbitChromiumBridge.maximumSubstitutionBodyBytes,
                  let mimePointer = strdup(mimeType)
            else { return 1 }
            var bodyPointer: UnsafeMutablePointer<UInt8>?
            if !body.isEmpty {
                guard let raw = malloc(body.count) else {
                    free(mimePointer)
                    return 1
                }
                let buffer = raw.bindMemory(to: UInt8.self, capacity: body.count)
                body.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: body.count) }
                bodyPointer = buffer
            }
            outMimeType.pointee = mimePointer
            outBody.pointee = bodyPointer
            outBodyLength.pointee = Int32(body.count)
            return 2
        }
    }

    // Mirrors kMaxSubstitutionBodyBytes in
    // orbit_content_blocking_url_loader_factory.cc, which refuses anything
    // larger anyway.
    nonisolated static let maximumSubstitutionBodyBytes = 1024 * 1024

    // MARK: - Process-level calls

    var versionDescription: String {
        guard let versionNumber, let cString = versionNumber() else { return "Chromium" }
        return "Chromium \(String(cString: cString))"
    }

    var browserContextPathValue: String? {
        guard let browserContextPath, let cString = browserContextPath() else { return nil }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    /// `false` if the browser has not reached the point a quit closure
    /// exists yet -- the caller must treat that as "not shut down", not as
    /// success.
    @discardableResult
    func requestQuitBrowser() -> Bool {
        (requestQuit?() ?? 0) != 0
    }

    // MARK: - WebContents

    func makeWebContentsHandle() throws -> UnsafeMutableRawPointer {
        guard isReady, let webContentsCreate else {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "browser process has not reached PreMainMessageLoopRun yet")
        }
        guard let handle = webContentsCreate() else {
            throw EngineError(code: .engineUnavailable, underlyingDescription: "OrbitWebContentsCreate returned NULL")
        }
        return handle
    }

    func destroyWebContents(_ handle: UnsafeMutableRawPointer) {
        webContentsDestroy?(handle)
    }

    func setCallbacks(_ handle: UnsafeMutableRawPointer, _ callbacks: OrbitWebContentsCallbacksLayout) {
        var mutableCallbacks = callbacks
        withUnsafePointer(to: &mutableCallbacks) { pointer in
            webContentsSetCallbacks?(handle, UnsafeRawPointer(pointer))
        }
    }

    func nativeView(_ handle: UnsafeMutableRawPointer) -> NSView? {
        guard let raw = webContentsGetNativeView?(handle) else { return nil }
        return Unmanaged<NSView>.fromOpaque(raw).takeUnretainedValue()
    }

    var canSetVisible: Bool { webContentsSetVisible != nil }

    func setVisible(_ handle: UnsafeMutableRawPointer, _ visible: Bool) {
        webContentsSetVisible?(handle, visible ? 1 : 0)
    }

    func loadURL(_ handle: UnsafeMutableRawPointer, _ url: String) {
        url.withCString { webContentsLoadURL?(handle, $0) }
    }

    func reload(_ handle: UnsafeMutableRawPointer, bypassCache: Bool) {
        webContentsReload?(handle, bypassCache ? 1 : 0)
    }

    func stop(_ handle: UnsafeMutableRawPointer) {
        webContentsStop?(handle)
    }

    func goBack(_ handle: UnsafeMutableRawPointer) {
        webContentsGoBack?(handle)
    }

    func goForward(_ handle: UnsafeMutableRawPointer) {
        webContentsGoForward?(handle)
    }

    func goToOffset(_ handle: UnsafeMutableRawPointer, _ offset: Int) {
        webContentsGoToOffset?(handle, Int32(offset))
    }

    func canGoBack(_ handle: UnsafeMutableRawPointer) -> Bool {
        (webContentsCanGoBack?(handle) ?? 0) != 0
    }

    func canGoForward(_ handle: UnsafeMutableRawPointer) -> Bool {
        (webContentsCanGoForward?(handle) ?? 0) != 0
    }

    func focus(_ handle: UnsafeMutableRawPointer) {
        webContentsFocus?(handle)
    }

    func cut(_ handle: UnsafeMutableRawPointer) {
        webContentsCut?(handle)
    }

    func copy(_ handle: UnsafeMutableRawPointer) {
        webContentsCopy?(handle)
    }

    func paste(_ handle: UnsafeMutableRawPointer) {
        webContentsPaste?(handle)
    }

    func selectAll(_ handle: UnsafeMutableRawPointer) {
        webContentsSelectAll?(handle)
    }

    // MARK: - Developer tools

    /// nil if the framework is missing the symbol, the browser is not ready,
    /// or `handle` already has an open inspector -- see
    /// OrbitWebContentsOpenDevTools's own comment.
    func openDevTools(_ handle: UnsafeMutableRawPointer, hasInspectPoint: Bool, x: Int32, y: Int32) -> UnsafeMutableRawPointer? {
        webContentsOpenDevTools?(handle, hasInspectPoint ? 1 : 0, x, y)
    }

    func inspectElementAt(_ handle: UnsafeMutableRawPointer, x: Int32, y: Int32) {
        webContentsInspectElementAt?(handle, x, y)
    }

    /// Mirrors orbit_bridge_api.h's OrbitWebContentsDevToolsStateJSON: "{}" if
    /// the framework is missing the symbol (older build), else the real
    /// {"open":bool,...} JSON for `handle`'s inspector, open or not.
    func devToolsStateJSON(_ handle: UnsafeMutableRawPointer) -> String {
        guard let webContentsDevToolsStateJSON, let cString = webContentsDevToolsStateJSON(handle) else { return "{}" }
        return String(cString: cString)
    }

    // MARK: - JavaScript / user scripts

    /// world 0 = main world; anything else = Orbit's isolated world. Result is
    /// (success, resultJSON, errorMessage) -- ChromiumWebContents turns that
    /// into `Any?` / a thrown EngineError.
    func evaluateJavaScript(
        _ handle: UnsafeMutableRawPointer,
        script: String,
        world: Int32,
        userGesture: Bool = false
    ) async -> (success: Bool, resultJSON: String?, errorMessage: String) {
        let symbolName = userGesture
            ? "OrbitWebContentsEvaluateJavaScriptWithUserGesture"
            : "OrbitWebContentsEvaluateJavaScript"
        guard let evaluate = userGesture
            ? webContentsEvaluateJavaScriptWithUserGesture
            : webContentsEvaluateJavaScript
        else {
            return (false, nil, "Orbit Framework is missing \(symbolName)")
        }
        return await withCheckedContinuation { continuation in
            let box = JavaScriptEvaluationBox(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            script.withCString { cScript in
                evaluate(handle, cScript, world, OrbitChromiumBridge.javaScriptResultTrampoline, opaque)
            }
        }
    }

    func injectUserScript(_ handle: UnsafeMutableRawPointer, json: String) {
        json.withCString { webContentsInjectUserScript?(handle, $0) }
    }

    func setUserScripts(json: String) {
        json.withCString { setUserScripts?($0) }
    }

    /// Mirrors OrbitSetColorSchemeIsDark: the appearance every document --
    /// web page and inspector alike -- resolves `prefers-color-scheme`
    /// against. Process-global and applies to documents already loaded.
    var supportsColorScheme: Bool { setColorSchemeIsDark != nil }

    func setColorScheme(isDark: Bool) {
        setColorSchemeIsDark?(isDark ? 1 : 0)
    }

    private static let javaScriptResultTrampoline: JavaScriptResultCallback = { opaque, success, resultJSONPtr, errorPtr in
        guard let opaque else { return }
        let box = Unmanaged<JavaScriptEvaluationBox>.fromOpaque(opaque).takeRetainedValue()
        let resultJSON = resultJSONPtr.map { String(cString: $0) }
        let errorMessage = errorPtr.map { String(cString: $0) } ?? ""
        box.continuation.resume(returning: (success != 0, resultJSON, errorMessage))
    }

    // MARK: - Session history / HTML / save

    func sessionHistoryJSON(_ handle: UnsafeMutableRawPointer) -> String {
        guard let webContentsSessionHistory, let cString = webContentsSessionHistory(handle) else { return "[]" }
        return String(cString: cString)
    }

    func loadHTML(_ handle: UnsafeMutableRawPointer, html: String, baseURL: String) {
        html.withCString { cHTML in
            baseURL.withCString { cBaseURL in
                webContentsLoadHTML?(handle, cHTML, cBaseURL)
            }
        }
    }

    func savePage(_ handle: UnsafeMutableRawPointer, targetPath: String) {
        targetPath.withCString { webContentsSavePage?(handle, $0) }
    }

    /// `true` once the whole current document has actually been written to
    /// `targetPath` as a PDF; `false` if the symbol is missing, there is no
    /// live main frame, or the write failed.
    func printToPdf(_ handle: UnsafeMutableRawPointer, targetPath: String) async -> Bool {
        guard let webContentsPrintToPdf else { return false }
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox<Bool>(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            targetPath.withCString { webContentsPrintToPdf(handle, $0, OrbitChromiumBridge.printToPdfTrampoline, opaque) }
        }
    }

    private static let printToPdfTrampoline: PrintToPdfCallback = { opaque, success in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<Bool>>.fromOpaque(opaque).takeRetainedValue()
        box.continuation.resume(returning: success != 0)
    }

    // MARK: - Find in page

    func find(_ handle: UnsafeMutableRawPointer, text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        text.withCString {
            webContentsFind?(handle, $0, forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0)
        }
    }

    /// action: 0 clears the selection, 1 keeps it, 2 activates it.
    func stopFinding(_ handle: UnsafeMutableRawPointer, action: Int32) {
        webContentsStopFinding?(handle, action)
    }

    // MARK: - Zoom

    func setZoomFactor(_ handle: UnsafeMutableRawPointer, _ factor: Double) {
        webContentsSetZoomFactor?(handle, factor)
    }

    // MARK: - Picture-in-picture

    /// `false` if this framework predates the symbol -- see
    /// `togglePictureInPicture(_:)`, whose own `false` is ambiguous without it.
    var supportsPictureInPicture: Bool { webContentsTogglePictureInPicture != nil }

    /// `true` only if a transition started; the entered/left edge itself
    /// arrives through OrbitWebContentsCallbacksLayout.pictureInPictureChanged.
    func togglePictureInPicture(_ handle: UnsafeMutableRawPointer) -> Bool {
        (webContentsTogglePictureInPicture?(handle) ?? 0) != 0
    }

    func hasPictureInPictureVideo(_ handle: UnsafeMutableRawPointer) -> Bool {
        (webContentsHasPictureInPictureVideo?(handle) ?? 0) != 0
    }

    // MARK: - Content sizing

    func enableAutoResize(_ handle: UnsafeMutableRawPointer, minimum: CGSize, maximum: CGSize) {
        webContentsEnableAutoResize?(
            handle, Double(minimum.width), Double(minimum.height),
            Double(maximum.width), Double(maximum.height)
        )
    }

    // MARK: - Preview capture

    /// `rect` nil captures the whole surface; `size` .zero requests native
    /// resolution (no scaling).
    func capturePreview(_ handle: UnsafeMutableRawPointer, rect: CGRect?, size: CGSize) async -> NSImage? {
        guard let webContentsCapturePreview else { return nil }
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox<NSImage?>(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            webContentsCapturePreview(
                handle, rect != nil ? 1 : 0,
                Double(rect?.origin.x ?? 0), Double(rect?.origin.y ?? 0),
                Double(rect?.size.width ?? 0), Double(rect?.size.height ?? 0),
                Double(size.width), Double(size.height),
                OrbitChromiumBridge.capturePreviewTrampoline, opaque
            )
        }
    }

    private static let capturePreviewTrampoline: CapturePreviewCallback = {
        opaque, success, rgbaData, width, height, stride in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<NSImage?>>.fromOpaque(opaque).takeRetainedValue()
        guard success != 0, let rgbaData, width > 0, height > 0, stride > 0 else {
            box.continuation.resume(returning: nil)
            return
        }
        box.continuation.resume(
            returning: OrbitChromiumBridge.makeImage(
                rgbaData: rgbaData, width: Int(width), height: Int(height), stride: Int(stride)
            )
        )
    }

    // Copies the pixels into a CFData up front (CFDataCreate), so the result
    // is safe to use after this call returns even though `rgbaData` itself
    // is only valid for the duration of the C callback.
    static func makeImage(rgbaData: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> NSImage? {
        guard let data = CFDataCreate(nil, rgbaData, stride * height),
              let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: stride,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(width), height: CGFloat(height)))
    }

    // MARK: - User agent

    func setUserAgent(_ userAgent: String) {
        userAgent.withCString { setUserAgent?($0) }
    }

    // MARK: - Cookies

    func getCookiesJSON(url: String) async -> String {
        guard let getCookies else { return "[]" }
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox<String>(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            url.withCString { getCookies($0, OrbitChromiumBridge.cookiesResultTrampoline, opaque) }
        }
    }

    func deleteCookies(url: String) async {
        guard let deleteCookies else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ContinuationBox<Void>(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            url.withCString { deleteCookies($0, OrbitChromiumBridge.deleteCookiesTrampoline, opaque) }
        }
    }

    func setCookiesJSON(_ json: String) async -> Int {
        guard let setCookies else { return 0 }
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox<Int>(continuation: continuation)
            let opaque = Unmanaged.passRetained(box).toOpaque()
            json.withCString { setCookies($0, OrbitChromiumBridge.setCookiesResultTrampoline, opaque) }
        }
    }

    private static let cookiesResultTrampoline: CookiesCallback = { opaque, jsonPtr in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<String>>.fromOpaque(opaque).takeRetainedValue()
        box.continuation.resume(returning: jsonPtr.map { String(cString: $0) } ?? "[]")
    }

    private static let deleteCookiesTrampoline: CompletionCallback = { opaque in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<Void>>.fromOpaque(opaque).takeRetainedValue()
        box.continuation.resume()
    }

    private static let setCookiesResultTrampoline: SetCookiesResultCallback = { opaque, acceptedCount in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<Int>>.fromOpaque(opaque).takeRetainedValue()
        box.continuation.resume(returning: Int(acceptedCount))
    }

    // MARK: - Extensions

    /// `forStartup` fires `chrome.runtime.onStartup` and re-registers rather than
    /// re-installs an unchanged version, so onInstalled stays quiet and persisted
    /// service-worker registrations survive.
    func loadExtension(
        directoryPath: String, forStartup: Bool = false
    ) async -> (success: Bool, extensionJSON: String?, errorMessage: String) {
        let loadExtensionFn = forStartup ? (loadExtensionForStartupFn ?? self.loadExtensionFn) : self.loadExtensionFn
        guard let loadExtensionFn else {
            return (false, nil, "Orbit Framework is missing OrbitLoadExtension")
        }
        if forStartup, loadExtensionForStartupFn == nil {
            Self.logger.error("Orbit Framework predates OrbitLoadExtensionForStartup: this launch will re-install every extension and never fire runtime.onStartup")
        }
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox<(success: Bool, extensionJSON: String?, errorMessage: String)>(
                continuation: continuation
            )
            let opaque = Unmanaged.passRetained(box).toOpaque()
            directoryPath.withCString { cPath in
                loadExtensionFn(cPath, OrbitChromiumBridge.loadExtensionTrampoline, opaque)
            }
        }
    }

    private static let loadExtensionTrampoline: LoadExtensionCallback = { opaque, success, jsonPtr, errorPtr in
        guard let opaque else { return }
        let box = Unmanaged<ContinuationBox<(success: Bool, extensionJSON: String?, errorMessage: String)>>
            .fromOpaque(opaque).takeRetainedValue()
        let json = jsonPtr.map { String(cString: $0) }
        let errorMessage = errorPtr.map { String(cString: $0) } ?? ""
        box.continuation.resume(returning: (success != 0, json, errorMessage))
    }

    func unloadExtension(id: String) {
        id.withCString { unloadExtensionFn?($0) }
    }

    /// Falls back to `unloadExtension` on a framework predating the symbol,
    /// where the one unload call deleted the prefs anyway.
    func uninstallExtension(id: String) {
        guard let uninstallExtensionFn else {
            unloadExtension(id: id)
            return
        }
        id.withCString { uninstallExtensionFn($0) }
    }

    /// A JSON array, one object per currently loaded extension. `"[]"` if the
    /// browser is not ready yet or the symbol is missing.
    func loadedExtensionsJSON() -> String {
        guard let getLoadedExtensionsJSON, let cString = getLoadedExtensionsJSON() else { return "[]" }
        return String(cString: cString)
    }

    // MARK: - chrome.action state

    /// Fired on the main thread, once per chrome.action mutation and once
    /// per extension load/unload.
    var extensionActionHandler: ((String) -> Void)?

    /// A JSON array of one payload per loaded extension declaring an action.
    func extensionActionsJSON() -> String {
        guard let getExtensionActionsJSONFn, let cString = getExtensionActionsJSONFn() else { return "[]" }
        return String(cString: cString)
    }

    /// nil when the running Orbit Framework predates the symbol, in which case
    /// callers keep their own stored answer rather than inventing one.
    func searchSuggestEnabled() -> Bool? {
        guard let getSearchSuggestEnabledFn else { return nil }
        return getSearchSuggestEnabledFn() != 0
    }

    /// Writes the user value. An extension override still wins over it, so the
    /// effective answer comes back through searchSuggestEnabledHandler.
    func setSearchSuggestEnabled(_ enabled: Bool) {
        setSearchSuggestEnabledFn?(enabled ? 1 : 0)
    }

    private static let searchSuggestEnabledTrampoline: SearchSuggestEnabledCallback = { opaque, enabled in
        guard let opaque else { return }
        MainActor.assumeIsolated {
            let bridge = Unmanaged<OrbitChromiumBridge>.fromOpaque(opaque).takeUnretainedValue()
            bridge.searchSuggestEnabledHandler?(enabled != 0)
        }
    }

    private static let extensionActionTrampoline: ExtensionActionCallback = { opaque, jsonPtr in
        guard let opaque, let jsonPtr else { return }
        let json = String(cString: jsonPtr)
        // Always dispatched from the UI thread, which on mac is this process's
        // main thread -- same contract as readyTrampoline.
        MainActor.assumeIsolated {
            let bridge = Unmanaged<OrbitChromiumBridge>.fromOpaque(opaque).takeUnretainedValue()
            bridge.extensionActionHandler?(json)
        }
    }

    // MARK: - Downloads

    /// `downloadID` is a download's own GUID -- see
    /// OrbitWebContentsCallbacksLayout.WillBeginDownload's own comment.
    func cancelDownload(id downloadID: String) {
        downloadID.withCString { cancelDownloadFn?($0) }
    }

    func pauseDownload(id downloadID: String) {
        downloadID.withCString { pauseDownloadFn?($0) }
    }

    func resumeDownload(id downloadID: String) {
        downloadID.withCString { resumeDownloadFn?($0) }
    }

    // MARK: - Content settings

    /// Returns one of "ask"/"allow"/"block"/"unsupported" -- mirrors
    /// Orbit/Engine/EngineTypes.swift's ContentSetting.rawValue. `"unsupported"`
    /// if the symbol is missing.
    func contentSetting(kind: String, url: String) -> String {
        guard let getContentSettingFn else { return "unsupported" }
        return kind.withCString { cKind in
            url.withCString { cURL in
                guard let cString = getContentSettingFn(cKind, cURL) else { return "unsupported" }
                return String(cString: cString)
            }
        }
    }

    /// `setting` is one of "ask"/"allow"/"block" -- mirrors
    /// Orbit/Engine/EngineTypes.swift's ContentSetting.rawValue.
    func setContentSetting(_ setting: String, kind: String, url: String) {
        setting.withCString { cSetting in
            kind.withCString { cKind in
                url.withCString { cURL in
                    setContentSettingFn?(cSetting, cKind, cURL)
                }
            }
        }
    }

    // MARK: - Tabs / windows (chrome.tabs / chrome.windows)
    // Pure dlsym plumbing; see OrbitChromiumTabsBridge.swift for the callers.

    func tabsCreated(handle: UnsafeMutableRawPointer, tabID: Int32, windowID: Int32, index: Int32, active: Bool, pinned: Bool) {
        tabsCreatedFn?(handle, tabID, windowID, index, active ? 1 : 0, pinned ? 1 : 0)
    }

    func tabsRemoved(tabID: Int32, windowClosing: Bool) {
        tabsRemovedFn?(tabID, windowClosing ? 1 : 0)
    }

    func tabsActivated(tabID: Int32, windowID: Int32, previousTabID: Int32) {
        tabsActivatedFn?(tabID, windowID, previousTabID)
    }

    func tabsMoved(tabID: Int32, windowID: Int32, fromIndex: Int32, toIndex: Int32) {
        tabsMovedFn?(tabID, windowID, fromIndex, toIndex)
    }

    func tabsSetPinned(tabID: Int32, pinned: Bool) {
        tabsSetPinnedFn?(tabID, pinned ? 1 : 0)
    }

    func tabsIndexChanged(tabID: Int32, index: Int32) {
        tabsIndexChangedFn?(tabID, index)
    }

    func windowsCreated(windowID: Int32, focused: Bool) {
        windowsCreatedFn?(windowID, focused ? 1 : 0)
    }

    func windowsRemoved(windowID: Int32) {
        windowsRemovedFn?(windowID)
    }

    func windowsFocusChanged(windowID: Int32) {
        windowsFocusChangedFn?(windowID)
    }

    /// `state` is one of "normal"/"minimized"/"maximized"/"fullscreen" --
    /// mirrors windows.json's WindowState enum.
    func windowsStateChanged(windowID: Int32, state: String) {
        guard let windowsStateChangedFn else { return }
        state.withCString { windowsStateChangedFn(windowID, $0) }
    }

    /// `nil` clears any previously-installed delegate (matches OrbitSetTabsDelegate(NULL)).
    func setTabsDelegate(_ layout: TabsDelegateLayout?) {
        guard let setTabsDelegateFn else { return }
        if var layout {
            withUnsafePointer(to: &layout) { setTabsDelegateFn(UnsafeRawPointer($0)) }
        } else {
            setTabsDelegateFn(UnsafeRawPointer?.none)
        }
    }

    func setManagementDelegate(_ layout: OrbitManagementDelegateLayout) {
        guard let setManagementDelegateFn else { return }
        var layout = layout
        withUnsafePointer(to: &layout) { setManagementDelegateFn(UnsafeRawPointer($0)) }
    }

    nonisolated func managementUninstallConsent(requestID: UInt64, approved: Bool) {
        MainActor.assumeIsolated {
            managementUninstallConsentFn?(requestID, approved ? 1 : 0)
        }
    }

    /// `false` when the loaded framework predates the two chrome.permissions
    /// consent symbols, in which case nothing is installed and the engine
    /// refuses every request that would have needed a prompt.
    @discardableResult
    func setPermissionsConsentDelegate(_ layout: OrbitPermissionsConsentDelegateLayout) -> Bool {
        guard let setPermissionsConsentDelegateFn, permissionsConsentResponseFn != nil else { return false }
        var layout = layout
        withUnsafePointer(to: &layout) { setPermissionsConsentDelegateFn(UnsafeRawPointer($0)) }
        return true
    }

    func permissionsConsentResponse(requestID: UInt64, approved: Bool) {
        permissionsConsentResponseFn?(requestID, approved ? 1 : 0)
    }

    /// Installs the one callback OrbitExtensionHostDelegate::CreateTab (an
    /// extension page's window.open()) answers through -- see
    /// OrbitChromiumTabsBridge's ExtensionTabRequestTrampoline, the one caller.
    func setExtensionTabRequestCallback(_ callback: ExtensionTabRequestCallback, opaque: UnsafeMutableRawPointer) {
        setExtensionTabRequestCallbackFn?(callback, opaque)
    }

    /// Until installed, the browser cannot follow any link wanting a second tab.
    func setNewContentRequestCallback(_ callback: NewContentRequestCallback, opaque: UnsafeMutableRawPointer? = nil) {
        setNewContentRequestCallbackFn?(callback, opaque)
    }

    /// False when the loaded framework predates OrbitSetNewContentRequestCallback.
    var hasNewContentRequestCallback: Bool { setNewContentRequestCallbackFn != nil }

    /// Until installed, every certificate error is denied without being shown.
    func setCertificateErrorCallback(_ callback: CertificateErrorCallback, opaque: UnsafeMutableRawPointer? = nil) {
        setCertificateErrorCallbackFn?(callback, opaque)
    }

    /// Answers one certificate error. `allow` must be backed by an explicit
    /// user action; the browser refuses it for a non-overridable request
    /// regardless.
    func respondToCertificateError(_ handle: UnsafeMutableRawPointer, requestID: UInt64, allow: Bool) {
        respondToCertificateErrorFn?(handle, requestID, allow ? 1 : 0)
    }

    /// Answers one OrbitWebContentsCallbacksLayout.nativeExtensionRequest call
    /// -- see that field's own comment. `resultJSON` is the {"ok":...}
    /// envelope WebStorePrivateBridge.encode(_:) produces.
    func respondToExtensionRequest(_ handle: UnsafeMutableRawPointer, requestID: String, resultJSON: String) {
        requestID.withCString { requestIDPtr in
            resultJSON.withCString { resultJSONPtr in
                respondToExtensionRequestFn?(handle, requestIDPtr, resultJSONPtr)
            }
        }
    }

    // MARK: - Native event processor
    // Called from OrbitApplication.sendEvent(_:); a no-op until loaded and observed.

    func notifyWillRunNativeEvent(_ observer: UnsafeMutableRawPointer, _ identifier: UInt) {
        notifyWillRunEvent?(observer, identifier)
    }

    func notifyDidRunNativeEvent(_ observer: UnsafeMutableRawPointer, _ identifier: UInt) {
        notifyDidRunEvent?(observer, identifier)
    }
}

// MARK: - Content blocking handler box

/// Lock-backed, not `nonisolated(unsafe)`: written from the main actor and read
/// concurrently from arbitrary background sequences by the decision trampoline.
private final class ContentBlockingHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: OrbitChromiumBridge.ContentBlockingHandler?

    var value: OrbitChromiumBridge.ContentBlockingHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }
}

// MARK: - JavaScript evaluation continuation box

/// Retained for one in-flight call, released by the callback that resumes it.
/// content:: always invokes it exactly once, even on mid-call teardown.
private final class JavaScriptEvaluationBox {
    let continuation: CheckedContinuation<(success: Bool, resultJSON: String?, errorMessage: String), Never>

    init(continuation: CheckedContinuation<(success: Bool, resultJSON: String?, errorMessage: String), Never>) {
        self.continuation = continuation
    }
}

// MARK: - General-purpose continuation box
// Same retain/release-on-callback lifetime as JavaScriptEvaluationBox.

private final class ContinuationBox<T> {
    let continuation: CheckedContinuation<T, Never>

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }
}

// MARK: - Callback struct mirror

/// Field-for-field mirror of orbit_bridge_api.h's OrbitWebContentsCallbacks.
/// Crossed only by pointer, so layout must match C's sequential, unpadded layout.
struct OrbitWebContentsCallbacksLayout {
    typealias NavigationStateChanged = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, UnsafePointer<CChar>?) -> Void
    typealias LoadProgressChanged = @convention(c) (UnsafeMutableRawPointer?, Double) -> Void
    typealias TitleChanged = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias DidCommit = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Void
    typealias DidFinish = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Void
    typealias DidFail = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void
    typealias DidReceiveScriptMessage = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    typealias FindResultChanged = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void
    typealias ZoomFactorChanged = @convention(c) (UnsafeMutableRawPointer?, Double) -> Void
    typealias PreferredSizeChanged = @convention(c) (UnsafeMutableRawPointer?, Double, Double) -> Void

    /// Mirrors orbit_bridge_api.h's OrbitDownloadTargetCallback.
    typealias DownloadTargetCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias WillBeginDownload = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int64,
        UnsafePointer<CChar>?, DownloadTargetCallback, UnsafeMutableRawPointer?
    ) -> Void
    typealias DownloadProgressChanged = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int64, Int64, Int32
    ) -> Void

    /// Mirrors orbit_bridge_api.h's OrbitPermissionDecisionCallback.
    typealias PermissionDecisionCallback = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias RequestPermission = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, PermissionDecisionCallback,
        UnsafeMutableRawPointer?
    ) -> Void

    /// Mirrors orbit_bridge_api.h's native_extension_request field -- no
    /// completion callback of its own; the answer comes back later, out of
    /// band, through OrbitChromiumBridge.respondToExtensionRequest(_:requestID:resultJSON:).
    typealias NativeExtensionRequest = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void

    /// Mirrors orbit_bridge_api.h's devtools_closed field.
    typealias DevToolsClosed = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Mirrors orbit_bridge_api.h's devtools_docked_changed field.
    typealias DevToolsDockedChanged = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    /// Mirrors orbit_bridge_api.h's devtools_inspected_page_bounds field --
    /// x, y, width, height, hide_inspected_page, in that order.
    typealias DevToolsInspectedPageBounds = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32
    ) -> Void

    /// Mirrors orbit_bridge_api.h's devtools_close_requested field.
    typealias DevToolsCloseRequested = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Mirrors orbit_bridge_api.h's devtools_bring_to_front field.
    typealias DevToolsBringToFront = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Mirrors orbit_bridge_api.h's show_context_menu field; params in C struct order.
    typealias ShowContextMenu = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32
    ) -> Void

    /// Mirrors orbit_bridge_api.h's picture_in_picture_changed field -- the
    /// browser-side entered/left edge, `is_active` 0/1.
    typealias PictureInPictureChanged = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    /// Mirrors orbit_bridge_api.h's favicon_changed field -- icon_url, then
    /// premultiplied RGBA pixels + width, height, stride, all zero/null when
    /// nothing decoded. The pixels are only valid for the duration of the call.
    typealias FaviconChanged = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int32, Int32, Int32
    ) -> Void

    var opaque: UnsafeMutableRawPointer?
    var navigationStateChanged: NavigationStateChanged?
    var loadProgressChanged: LoadProgressChanged?
    var titleChanged: TitleChanged?
    var didCommit: DidCommit?
    var didFinish: DidFinish?
    var didFail: DidFail?
    var didReceiveScriptMessage: DidReceiveScriptMessage?
    var findResultChanged: FindResultChanged?
    var zoomFactorChanged: ZoomFactorChanged?
    var preferredSizeChanged: PreferredSizeChanged?
    var willBeginDownload: WillBeginDownload?
    var downloadProgressChanged: DownloadProgressChanged?
    var requestPermission: RequestPermission?
    var nativeExtensionRequest: NativeExtensionRequest?
    var devtoolsClosed: DevToolsClosed?
    var showContextMenu: ShowContextMenu?
    var pictureInPictureChanged: PictureInPictureChanged?
    var faviconChanged: FaviconChanged?
    var devtoolsDockedChanged: DevToolsDockedChanged?
    var devtoolsInspectedPageBounds: DevToolsInspectedPageBounds?
    var devtoolsCloseRequested: DevToolsCloseRequested?
    var devtoolsBringToFront: DevToolsBringToFront?
}

// MARK: - Tabs delegate struct mirror

/// Field-for-field mirror of orbit_bridge_api.h's OrbitTabsDelegate. File-scope,
/// not nested: a type nested in a class isn't representable in @convention(c).
struct TabsDelegateLayout {
    typealias CreateTab = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32, Int32,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<Int32>?
    ) -> Int32
    typealias UpdateTabURL = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?
    ) -> Int32
    typealias ActivateTab = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias RemoveTab = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias SetTabPinned = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32

    var opaque: UnsafeMutableRawPointer?
    var createTab: CreateTab?
    var updateTabURL: UpdateTabURL?
    var activateTab: ActivateTab?
    var removeTab: RemoveTab?
    var setTabPinned: SetTabPinned?
}
