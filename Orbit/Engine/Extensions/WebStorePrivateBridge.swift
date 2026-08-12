import Foundation
import OSLog

@MainActor
public final class WebStorePrivateBridge {

    // Gated by DiagnosticChannel.webStoreBridge; same subsystem as the C++
    // document-start logs, so one `log stream` predicate shows the whole timeline.
    private static let diagnosticsLogger = Logger(subsystem: "com.orbit.browser", category: "WebStorePrivateBridge")

    private let store: ExtensionStore

    public init(store: ExtensionStore? = nil) {
        self.store = store ?? AppEnvironment.processRoot.extensionStore
    }

    // MARK: - Entry point

    public func handle(payload: String, contents: WebContents) async -> (requestID: String, resultJSON: String)? {
        guard let data = payload.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = request["requestId"] as? String,
              let api = request["api"] as? String,
              let method = request["method"] as? String
        else {
            if DiagnosticChannel.webStoreBridge.isEnabled {
                Self.diagnosticsLogger.error("handle(payload:): payload did not parse as a webstorePrivate/management request — chrome.webstorePrivate called into native but the message was malformed. Raw payload: \(payload, privacy: .public)")
            }
            return nil
        }
        let args = (request["args"] as? [Any]) ?? []

        if DiagnosticChannel.webStoreBridge.isEnabled {
            Self.diagnosticsLogger.info("handle(payload:): \(api, privacy: .public).\(method, privacy: .public) requestId=\(requestID, privacy: .public) committedURL=\(contents.navigationState.url?.absoluteString ?? "nil", privacy: .public)")
        }

        // webstorePrivate/management are privileged: only the real Chrome Web
        // Store may drive installs or read/change what's installed. The page
        // cannot be trusted to self-report this, so check the committed URL.
        guard Self.isWebStoreOrigin(contents.navigationState.url) else {
            if DiagnosticChannel.webStoreBridge.isEnabled {
                Self.diagnosticsLogger.error("handle(payload:): REJECTED \(api, privacy: .public).\(method, privacy: .public) — isWebStoreOrigin(\(contents.navigationState.url?.absoluteString ?? "nil", privacy: .public)) returned false")
            }
            return (requestID, Self.encode(.failure("This page is not allowed to use the Chrome Web Store install bridge.")))
        }

        let response: Response
        switch (api, method) {
        case ("webstorePrivate", "beginInstallWithManifest3"):
            response = await beginInstallWithManifest3(args: args, contents: contents)
        case ("webstorePrivate", "completeInstall"):
            response = await completeInstall(args: args, contents: contents)
        case ("webstorePrivate", "getExtensionStatus"):
            response = getExtensionStatus(args: args)
        case ("webstorePrivate", "getBrowserLogin"):
            response = .success(["login": ""])
        case ("webstorePrivate", "getStoreLogin"):
            response = .success("")
        case ("webstorePrivate", "getWebGLStatus"):
            response = .success("webgl_allowed")
        case ("webstorePrivate", "getIsLauncherEnabled"):
            response = .success(false)
        case ("webstorePrivate", "isInIncognitoMode"):
            response = .success(!contents.session.isPersistent)
        case ("webstorePrivate", "isPendingCustodianApproval"):
            response = .success(false)
        case ("webstorePrivate", "getReferrerChain"):
            // Constant used by NeverDecaf/chromium-web-store, proven in production.
            response = .success("EgIIAA==")
        case ("webstorePrivate", "getFullChromeVersion"):
            response = .success(["version_number": ChromiumBuild.version])
        case ("webstorePrivate", "getMV2DeprecationStatus"):
            response = .success("inactive")
        case ("management", "getAll"):
            response = .success(store.installed().map(Self.extensionInfoJSON(for:)))
        case ("management", "get"):
            response = managementGet(args: args)
        case ("management", "setEnabled"):
            response = managementSetEnabled(args: args)
        case ("management", "uninstall"):
            response = await managementUninstall(args: args, contents: contents)
        default:
            response = .failure("Unknown method \(api).\(method).")
        }

        return (requestID, Self.encode(response))
    }

    // MARK: - webstorePrivate.beginInstallWithManifest3
    // The page's manifest here is unverified and must never be shown to the user;
    // the one real consent prompt is in completeInstall, from the verified manifest.

    private func beginInstallWithManifest3(args: [Any], contents: WebContents) async -> Response {
        guard let details = args.first as? [String: Any] else { return .success("manifest_error") }
        guard let id = details["id"] as? String, ChromeExtensionID.isValid(id) else { return .success("invalid_id") }
        guard let manifestText = details["manifest"] as? String, !manifestText.isEmpty else { return .success("manifest_error") }
        guard contents.session.isPersistent else { return .success("feature_disabled") }
        guard !store.installed().contains(where: { $0.id == id }) else { return .success("already_installed") }
        guard (try? Self.parseManifest(jsonText: manifestText)) != nil else { return .success("manifest_error") }
        return .success("")
    }

    // MARK: - webstorePrivate.completeInstall
    // The only consent prompt: downloads and CRX3-verifies the real CRX first, so the
    // user always sees the truth, never what the page claimed.

    private func completeInstall(args: [Any], contents: WebContents) async -> Response {
        guard let id = args.first as? String else { return .failure("Missing extension id.") }
        guard contents.session.isPersistent else { return .failure("feature_disabled") }

        let realInstaller = ExtensionInstaller(store: store) { pending in
            guard let delegate = contents.delegate else { return false }
            return await delegate.webContents(contents, requestsExtensionInstallConsent: pending)
        }

        // contents isn't Sendable; boxed so onStage (called off-MainActor) can carry it
        // into a Task that's the only place it's actually touched.
        let progressBox = UncheckedSendableBox(contents)
        let onStage: @Sendable (ExtensionInstallStage) -> Void = { stage in
            Task { @MainActor in
                let contents = progressBox.value
                contents.delegate?.webContents(contents, didUpdateExtensionInstallProgress: stage)
            }
        }
        // The handle lets the install sheet's Cancel actually stop the pipeline;
        // ExtensionInstaller checks cancellation at every stage boundary.
        let installTask = Task { try await realInstaller.install(id, reinstall: false, onStage: onStage) }
        contents.delegate?.webContents(contents, canCancelExtensionInstallWith: { installTask.cancel() })
        defer {
            contents.delegate?.webContents(contents, didUpdateExtensionInstallProgress: nil)
            contents.delegate?.webContents(contents, canCancelExtensionInstallWith: nil)
        }

        do {
            let result = try await installTask.value
            switch result {
            case .installed(let installed, _, _):
                contents.delegate?.webContents(
                    contents,
                    didFinishExtensionInstallWith: .installed(name: installed.name, version: installed.version)
                )
                return .success(NSNull())
            case .declined:
                return .failure("user_cancelled")
            case .noUpdateAvailable:
                return .failure("unknown_error")
            }
        } catch {
            let presentation = ExtensionInstallFailurePresentation.present(error)
            // A cancellation is the user's own Cancel press: reporting it back
            // to them as a failure dialog they then have to dismiss is one
            // click of nothing.
            if presentation.category != .cancelled {
                contents.delegate?.webContents(contents, didFinishExtensionInstallWith: .failed(presentation))
            }
            return .failure(Self.resultToken(for: error))
        }
    }

    // MARK: - webstorePrivate.getExtensionStatus

    private func getExtensionStatus(args: [Any]) -> Response {
        guard let id = args.first as? String,
              let record = store.installed().first(where: { $0.id == id })
        else {
            return .success("installable")
        }
        return .success(record.isEnabled ? "enabled" : "disabled")
    }

    // MARK: - management.get / getAll

    private func managementGet(args: [Any]) -> Response {
        guard let id = args.first as? String, let ext = store.installed().first(where: { $0.id == id }) else {
            return .failure("No extension with id \"\(args.first as? String ?? "")\" is installed.")
        }
        return .success(Self.extensionInfoJSON(for: ext))
    }

    /// Also used by `AppEnvironment` to build `chrome.management` event
    /// payloads (`onInstalled`/`onEnabled`/`onDisabled` all deliver an
    /// `ExtensionInfo` of this exact shape as their listener argument).
    static func extensionInfoJSON(for ext: LoadedExtension) -> [String: Any] {
        let manifest = try? ChromeExtensionManifest.read(fromDirectory: ext.directory)
        let raw = Self.rawManifestJSON(directory: ext.directory)

        let icons: [[String: Any]] = ((raw?["icons"] as? [String: Any]) ?? [:]).compactMap { sizeKey, value in
            guard let size = Int(sizeKey), let path = value as? String, !path.isEmpty else { return nil }
            return ["size": size, "url": "chrome-extension://\(ext.id)/\(path)"]
        }
        let optionsUrl = manifest?.optionsPagePath.map { "chrome-extension://\(ext.id)/\($0)" } ?? ""

        return [
            "id": ext.id,
            "name": ext.name,
            "shortName": (raw?["short_name"] as? String) ?? ext.name,
            "description": manifest?.description ?? "",
            "version": ext.version,
            "mayDisable": true,
            "enabled": ext.isEnabled,
            "type": "extension",
            "offlineEnabled": (raw?["offline_enabled"] as? Bool) ?? false,
            "optionsUrl": optionsUrl,
            "icons": icons,
            "permissions": manifest?.permissions ?? [],
            "hostPermissions": manifest?.hostPermissions ?? [],
            "installType": "normal",
            "homepageUrl": (raw?["homepage_url"] as? String) ?? "",
            "updateUrl": (raw?["update_url"] as? String) ?? "",
        ]
    }

    private static func rawManifestJSON(directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - management.setEnabled

    private func managementSetEnabled(args: [Any]) -> Response {
        guard let id = args.first as? String, let enabled = args.dropFirst().first as? Bool else {
            return .failure("setEnabled requires an id and a boolean.")
        }
        do {
            try store.setEnabled(enabled, id: id)
            return .success(NSNull())
        } catch {
            return .failure(ExtensionInstallLogic.installFailureMessage(for: error))
        }
    }

    // MARK: - management.uninstall
    // ExtensionStore has no `uninstall` method; the real work is `remove(id:)`.

    private func managementUninstall(args: [Any], contents: WebContents) async -> Response {
        guard let id = args.first as? String else { return .failure("uninstall requires an id.") }
        guard let ext = store.installed().first(where: { $0.id == id }) else {
            return .failure("No extension with id \"\(id)\" is installed.")
        }

        let options = args.dropFirst().first as? [String: Any]
        let showConfirmDialog = (options?["showConfirmDialog"] as? Bool) ?? false
        if showConfirmDialog {
            let confirmed = await contents.delegate?.webContents(contents, confirmUninstallExtensionNamed: ext.name) ?? false
            guard confirmed else { return .failure("user_cancelled") }
        }

        do {
            try store.remove(id: id)
            return .success(NSNull())
        } catch {
            return .failure(ExtensionInstallLogic.installFailureMessage(for: error))
        }
    }

    // MARK: - Untrusted manifest parsing

    private static func parseManifest(jsonText: String) throws -> ChromeExtensionManifest {
        guard let data = jsonText.data(using: .utf8) else {
            throw BridgeError.manifestNotUTF8
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbit-WebStorePrivate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return try ChromeExtensionManifest.read(fromDirectory: directory)
    }

    private enum BridgeError: Error {
        case manifestNotUTF8
    }

    // MARK: - Origin check

    private static let webStoreHosts: Set<String> = ["chromewebstore.google.com", "chrome.google.com"]

    // The page's own claims are untrusted; only the real store's committed origin may drive this bridge.
    // Also used by AppEnvironment to scope pushed chrome.management events to Web Store tabs only.
    static func isWebStoreOrigin(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return webStoreHosts.contains(host)
    }

    // MARK: - Result-string mapping

    private static func resultToken(for error: Error) -> String {
        guard let installError = error as? ExtensionInstallError else { return "unknown_error" }
        switch installError {
        case .alreadyInstalled:
            return "already_installed"
        case .notInstalled, .identityMismatch, .verificationFailed, .stagingFailed, .installFailed:
            return "install_error"
        case .webStoreFailure(let webError):
            switch webError {
            case .invalidExtensionID, .extensionNotFound:
                return "invalid_id"
            default:
                return "install_error"
            }
        case .manifestInvalid:
            return "manifest_error"
        }
    }

    // MARK: - Response encoding

    private enum Response {
        case success(Any)
        case failure(String)
    }

    /// The `{"ok":true,"result":...}` envelope a `chrome.management` event
    /// listener expects, for `AppEnvironment`'s pushed events.
    static func encodeEventResult(_ value: Any) -> String {
        encode(.success(value))
    }

    private static func encode(_ response: Response) -> String {
        var dict: [String: Any] = [:]
        switch response {
        case .success(let value):
            dict["ok"] = true
            dict["result"] = value
        case .failure(let message):
            dict["ok"] = false
            dict["error"] = ["message": message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":{\"message\":\"Internal error encoding the response.\"}}"
        }
        return string
    }
}

// MARK: - Carrying a non-Sendable value across an isolation boundary, on trust

// Only safe because every caller here only ever reads `.value` back on MainActor.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
