import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import WebKit

/// chrome.idle, chrome.power, chrome.offscreen and chrome.system.*, which main's Orbit got from
/// //extensions and WebKit does not implement. Every answer comes from the system itself.
@MainActor
final class WebKitExtensionSystemAPIs {
    private unowned let services: WebKitExtensionServices

    init(services: WebKitExtensionServices) {
        self.services = services
    }

    func perform(namespace: String, method: String, args: [Any], extensionID: String) async throws -> Any {
        switch namespace {
        case "idle": return try idle(method, args, extensionID: extensionID)
        case "power": return try power(method, args, extensionID: extensionID)
        case "offscreen": return try await offscreen(method, args, extensionID: extensionID)
        case "system.cpu": return try cpu(method)
        case "system.memory": return try memory(method)
        case "system.display": return try display(method)
        case "system.storage": return try await storage(method, args)
        default: throw ChromeExtensionAPIError("Orbit has no \(namespace).\(method) wrapper.")
        }
    }

    func extensionLoaded(_ entry: WebKitExtensionEntry) {
        updateIdlePolling()
    }

    func permissionsChanged(_ entry: WebKitExtensionEntry) {
        updateIdlePolling()
    }

    func extensionUnloaded(_ extensionID: String) {
        releaseKeepAwake(extensionID)
        closeOffscreenDocument(extensionID)
        idleIntervals[extensionID] = nil
        idleStates[extensionID] = nil
        updateIdlePolling()
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = true
                self?.pollIdleState()
            }
        }))
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.pollIdleState()
            }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.services.broadcast(namespace: "system.display", event: "onDisplayChanged", args: [], permission: "system.display")
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                      let info = Self.storageUnit(for: volume)
                else { return }
                self?.services.broadcast(namespace: "system.storage", event: "onAttached", args: [info], permission: "system.storage")
            }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.services.broadcast(namespace: "system.storage", event: "onDetached", args: [Self.storageID(for: volume)], permission: "system.storage")
            }
        }))
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    // MARK: - idle

    private static let defaultIdleInterval = 60
    private static let minimumIdleInterval = 15
    private var idleIntervals: [String: Int] = [:]
    private var idleStates: [String: String] = [:]
    private var screenLocked = false
    private var idleTimer: Timer?

    private func idle(_ method: String, _ args: [Any], extensionID: String) throws -> Any {
        switch method {
        case "queryState":
            guard let interval = Self.integer(args.first) else {
                throw ChromeExtensionAPIError("Error at parameter 'detectionIntervalInSeconds': Invalid type: expected integer.")
            }
            return idleState(threshold: max(interval, Self.minimumIdleInterval))
        case "setDetectionInterval":
            guard let interval = Self.integer(args.first) else {
                throw ChromeExtensionAPIError("Error at parameter 'intervalInSeconds': Invalid type: expected integer.")
            }
            idleIntervals[extensionID] = max(interval, Self.minimumIdleInterval)
            return NSNull()
        default:
            throw ChromeExtensionAPIError("Unknown idle.\(method)")
        }
    }

    private func idleState(threshold: Int) -> String {
        if screenLocked { return "locked" }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds >= Double(threshold) ? "idle" : "active"
    }

    /// Chrome's IdleManager samples the system idle time once a second; so does this, and only
    /// while some loaded extension holds the idle permission.
    private func updateIdlePolling() {
        let watching = services.entries.keys.contains { services.hasPermission("idle", extensionID: $0) }
        if watching, idleTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollIdleState() }
            }
            RunLoop.main.add(timer, forMode: .common)
            idleTimer = timer
        } else if !watching {
            idleTimer?.invalidate()
            idleTimer = nil
            idleStates.removeAll()
        }
    }

    private func pollIdleState() {
        for id in services.entries.keys where services.hasPermission("idle", extensionID: id) {
            let state = idleState(threshold: idleIntervals[id] ?? Self.defaultIdleInterval)
            let previous = idleStates[id]
            idleStates[id] = state
            guard let previous, previous != state else { continue }
            services.deliver(namespace: "idle", event: "onStateChanged", args: [state], to: id)
        }
    }

    // MARK: - power

    private var keepAwake: [String: IOPMAssertionID] = [:]

    private func power(_ method: String, _ args: [Any], extensionID: String) throws -> Any {
        switch method {
        case "requestKeepAwake":
            let level = args.first as? String ?? ""
            let type: String
            switch level {
            case "system": type = kIOPMAssertionTypePreventUserIdleSystemSleep
            case "display": type = kIOPMAssertionTypePreventUserIdleDisplaySleep
            default: throw ChromeExtensionAPIError("Value must be one of display, system.")
            }
            releaseKeepAwake(extensionID)
            let name = services.entry(extensionID)?.manifest.name ?? extensionID
            var assertion: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "\(name) (chrome.power)" as CFString, &assertion
            )
            guard result == kIOReturnSuccess else {
                throw ChromeExtensionAPIError("The system refused the keep-awake request.")
            }
            keepAwake[extensionID] = assertion
            return NSNull()
        case "releaseKeepAwake":
            releaseKeepAwake(extensionID)
            return NSNull()
        default:
            throw ChromeExtensionAPIError("Unknown power.\(method)")
        }
    }

    private func releaseKeepAwake(_ extensionID: String) {
        guard let assertion = keepAwake.removeValue(forKey: extensionID) else { return }
        IOPMAssertionRelease(assertion)
    }

    // MARK: - offscreen

    static let offscreenReasons: Set<String> = [
        "TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA",
        "DISPLAY_MEDIA", "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION",
    ]

    private var offscreenDocuments: [String: OffscreenDocument] = [:]

    func offscreenWebView(for extensionID: String) -> WKWebView? {
        offscreenDocuments[extensionID]?.pageWebView
    }

    private func offscreen(_ method: String, _ args: [Any], extensionID: String) async throws -> Any {
        switch method {
        case "createDocument":
            return try await createOffscreenDocument(args.first as? [String: Any] ?? [:], extensionID: extensionID)
        case "closeDocument":
            guard offscreenDocuments[extensionID] != nil else {
                throw ChromeExtensionAPIError("No current offscreen document.")
            }
            closeOffscreenDocument(extensionID)
            return NSNull()
        case "hasDocument":
            return offscreenDocuments[extensionID] != nil
        default:
            throw ChromeExtensionAPIError("Unknown offscreen.\(method)")
        }
    }

    private func createOffscreenDocument(_ parameters: [String: Any], extensionID: String) async throws -> Any {
        guard let entry = services.entry(extensionID) else { throw ChromeExtensionAPIError("Extension is not loaded.") }
        guard offscreenDocuments[extensionID] == nil else {
            throw ChromeExtensionAPIError("Only a single offscreen document may be created.")
        }
        guard let reasons = parameters["reasons"] as? [String], !reasons.isEmpty else {
            throw ChromeExtensionAPIError("A `reason` must be provided.")
        }
        for reason in reasons where !Self.offscreenReasons.contains(reason) {
            throw ChromeExtensionAPIError("Error at parameter 'parameters': Error at property 'reasons': Value must be one of \(Self.offscreenReasons.sorted().joined(separator: ", ")).")
        }
        guard let justification = parameters["justification"] as? String, !justification.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ChromeExtensionAPIError("A `justification` must be provided.")
        }
        guard let path = parameters["url"] as? String,
              let url = Self.extensionURL(path, base: entry.context.baseURL)
        else { throw ChromeExtensionAPIError("Invalid URL.") }
        guard let configuration = entry.context.webViewConfiguration else {
            throw ChromeExtensionAPIError("The extension has no page configuration.")
        }
        let document = OffscreenDocument(configuration: configuration)
        offscreenDocuments[extensionID] = document
        do {
            try await document.load(url)
        } catch {
            if offscreenDocuments[extensionID] === document { closeOffscreenDocument(extensionID) }
            throw ChromeExtensionAPIError("Page failed to load.")
        }
        return NSNull()
    }

    /// Chrome only accepts the extension's own pages, given relative or as a full URL on its origin.
    private static func extensionURL(_ value: String, base: URL) -> URL? {
        guard !value.isEmpty else { return nil }
        if let absolute = URL(string: value), let scheme = absolute.scheme {
            let ownScheme = base.scheme?.lowercased() ?? ""
            let host = absolute.host?.lowercased() ?? ""
            guard scheme.lowercased() == ownScheme, host == base.host?.lowercased() else { return nil }
            return absolute
        }
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    private func closeOffscreenDocument(_ extensionID: String) {
        offscreenDocuments.removeValue(forKey: extensionID)?.close()
    }

    // MARK: - system.cpu

    private func cpu(_ method: String) throws -> Any {
        guard method == "getInfo" else { throw ChromeExtensionAPIError("Unknown system.cpu.\(method)") }
        var info: [String: Any] = [
            "numOfProcessors": ProcessInfo.processInfo.activeProcessorCount,
            "archName": Self.architectureName,
            "modelName": Self.cpuModelName,
            "features": Self.cpuFeatureList,
            "temperatures": [Double](),
        ]
        info["processors"] = Self.processorUsage()
        return info
    }

    private static let cpuModelName = sysctlString("machdep.cpu.brand_string") ?? ""
    private static let cpuFeatureList = cpuFeatures()

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func cpuFeatures() -> [String] {
        #if arch(x86_64)
        let flags: [(String, String)] = [
            ("hw.optional.mmx", "mmx"), ("hw.optional.sse", "sse"), ("hw.optional.sse2", "sse2"),
            ("hw.optional.sse3", "sse3"), ("hw.optional.supplementalsse3", "ssse3"),
            ("hw.optional.sse4_1", "sse4_1"), ("hw.optional.sse4_2", "sse4_2"), ("hw.optional.avx1_0", "avx"),
        ]
        return flags.compactMap { sysctlInteger($0.0) == 1 ? $0.1 : nil }
        #else
        return []
        #endif
    }

    /// Cumulative ticks per core, which is what Chrome reports.
    private static func processorUsage() -> [[String: Any]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var processors: [[String: Any]] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)]) + Double(info[base + Int(CPU_STATE_NICE)])
            let kernel = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            processors.append(["usage": ["user": user, "kernel": kernel, "idle": idle, "total": user + kernel + idle]])
        }
        return processors
    }

    // MARK: - system.memory

    private func memory(_ method: String) throws -> Any {
        guard method == "getInfo" else { throw ChromeExtensionAPIError("Unknown system.memory.\(method)") }
        return [
            "capacity": Double(ProcessInfo.processInfo.physicalMemory),
            "availableCapacity": Double(Self.availableMemory()),
        ]
    }

    private static func availableMemory() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count)
        return pages * pageSize
    }

    // MARK: - system.display

    private func display(_ method: String) throws -> Any {
        switch method {
        case "getInfo": return Self.displayUnits()
        // Chrome answers the layout only on ChromeOS; on macOS the list is empty.
        case "getDisplayLayout": return [Any]()
        default: throw ChromeExtensionAPIError("Unknown system.display.\(method)")
        }
    }

    private static func displayUnits() -> [[String: Any]] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let top = primary.frame.maxY
        func rect(_ frame: NSRect) -> [String: Any] {
            ["left": Int(frame.minX), "top": Int(top - frame.maxY), "width": Int(frame.width), "height": Int(frame.height)]
        }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let millimetres = CGDisplayScreenSize(displayID)
            let pixelsWide = Double(CGDisplayPixelsWide(displayID))
            let pixelsHigh = Double(CGDisplayPixelsHigh(displayID))
            let dpiX = millimetres.width > 0 ? pixelsWide / (millimetres.width / 25.4) : 0
            let dpiY = millimetres.height > 0 ? pixelsHigh / (millimetres.height / 25.4) : 0
            let mirror = CGDisplayMirrorsDisplay(displayID)
            return [
                "id": String(displayID),
                "name": screen.localizedName,
                "mirroringSourceId": mirror == kCGNullDirectDisplay ? "" : String(mirror),
                "mirroringDestinationIds": [String](),
                "isPrimary": screen == primary,
                "isInternal": CGDisplayIsBuiltin(displayID) != 0,
                "isEnabled": CGDisplayIsActive(displayID) != 0,
                "isUnified": false,
                "dpiX": dpiX,
                "dpiY": dpiY,
                "rotation": Int(CGDisplayRotation(displayID)),
                "bounds": rect(screen.frame),
                "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
                "workArea": rect(screen.visibleFrame),
                "modes": [Any](),
                "hasTouchSupport": false,
                "hasAccelerometerSupport": false,
                "availableDisplayZoomFactors": [Double](),
                "displayZoomFactor": 1.0,
                "activeState": "active",
            ]
        }
    }

    // MARK: - system.storage

    private func storage(_ method: String, _ args: [Any]) async throws -> Any {
        switch method {
        case "getInfo":
            return Self.mountedVolumes().compactMap(Self.storageUnit(for:))
        case "getAvailableCapacity":
            let id = args.first as? String ?? ""
            guard let volume = Self.mountedVolumes().first(where: { Self.storageID(for: $0) == id }),
                  let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            else { throw ChromeExtensionAPIError("No such device.") }
            let available = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
                ?? values.volumeAvailableCapacity.map(Double.init) ?? 0
            return ["id": id, "availableCapacity": available]
        case "ejectDevice":
            let id = args.first as? String ?? ""
            guard let volume = Self.mountedVolumes().first(where: { Self.storageID(for: $0) == id }) else {
                return "no_such_device"
            }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                return "success"
            } catch {
                let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                let busy = [(error as NSError).code, underlying?.code].contains(Int(EBUSY))
                return busy ? "in_use" : "failure"
            }
        default:
            throw ChromeExtensionAPIError("Unknown system.storage.\(method)")
        }
    }

    private static let mountedVolumeFilterKeys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsBrowsableKey]
    /// Prefetched so getInfo and getAvailableCapacity do not stat each volume again per key.
    private static let mountedVolumePrefetchKeys: [URLResourceKey] = [
        .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeUUIDStringKey,
        .volumeNameKey, .volumeTotalCapacityKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ]

    private static func mountedVolumes() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: mountedVolumePrefetchKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter { volume in
            let values = try? volume.resourceValues(forKeys: mountedVolumeFilterKeys)
            return values?.volumeIsLocal == true && values?.volumeIsBrowsable != false
        }
    }

    static func storageID(for volume: URL) -> String {
        let values = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString ?? volume.standardizedFileURL.path
    }

    private static let storageUnitKeys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeUUIDStringKey,
    ]

    static func storageUnit(for volume: URL) -> [String: Any]? {
        guard let values = try? volume.resourceValues(forKeys: storageUnitKeys) else { return nil }
        let type: String
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true {
            type = "removable"
        } else if values.volumeIsInternal == true {
            type = "fixed"
        } else {
            type = "unknown"
        }
        return [
            "id": values.volumeUUIDString ?? volume.standardizedFileURL.path,
            "name": values.volumeName ?? volume.lastPathComponent,
            "type": type,
            "capacity": Double(values.volumeTotalCapacity ?? 0),
        ]
    }

    // MARK: - Helpers

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// A hidden extension page with no tab, built on the extension's own web view configuration.
@MainActor
private final class OffscreenDocument: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    var pageWebView: WKWebView { webView }

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        finish(.failure(ChromeExtensionAPIError("The offscreen document was closed.")))
        webView.loadHTMLString("", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }
}
