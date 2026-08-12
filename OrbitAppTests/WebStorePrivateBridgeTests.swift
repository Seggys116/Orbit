import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebStorePrivateBridgeTests: XCTestCase {

    private var createdPaths: [URL] = []

    override func tearDown() {
        for path in createdPaths {
            try? FileManager.default.removeItem(at: path)
        }
        createdPaths.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WSPBStore-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(root)
        return ExtensionStore(root: root)
    }

    @discardableResult
    private func makeInstalledExtension(
        in store: ExtensionStore,
        name: String = "Fixture Extension",
        version: String = "1.0"
    ) throws -> LoadedExtension {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WSPBSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        createdPaths.append(source)
        let manifest: [String: Any] = ["name": name, "version": version, "manifest_version": 3]
        try JSONSerialization.data(withJSONObject: manifest, options: [])
            .write(to: source.appendingPathComponent("manifest.json"))
        return try store.install(unpackedAt: source, publicKey: nil)
    }

    private func makeContents(url: URL?) -> MockWebContents {
        let contents = MockWebContents()
        contents.navigationState.url = url
        return contents
    }

    private static let webStoreURL = URL(string: "https://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop")!

    // MARK: - Payload / response plumbing

    private func payload(requestID: String = "r1", api: String, method: String, args: [Any] = []) -> String {
        let dict: [String: Any] = ["requestId": requestID, "api": api, "method": method, "args": args]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private struct Decoded {
        let requestID: String
        let ok: Bool
        let result: Any?
        let errorMessage: String?
    }

    private func decode(_ response: (requestID: String, resultJSON: String)?) throws -> Decoded {
        let unwrapped = try XCTUnwrap(response, "handle(payload:contents:) returned nil for a well-formed payload.")
        let data = Data(unwrapped.resultJSON.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ok = try XCTUnwrap(object["ok"] as? Bool)
        if ok {
            return Decoded(requestID: unwrapped.requestID, ok: true, result: object["result"], errorMessage: nil)
        }
        let error = object["error"] as? [String: Any]
        return Decoded(requestID: unwrapped.requestID, ok: false, result: nil, errorMessage: error?["message"] as? String)
    }

    // MARK: - Delegate stub

    private final class ScriptedDelegate: NSObject, WebContentsDelegate {
        private(set) var installConsentCalls: [ExtensionInstaller.PendingInstall] = []
        var installConsentAnswer = false

        private(set) var uninstallConfirmCalls: [String] = []
        var uninstallConfirmAnswer = false

        func webContents(_ contents: WebContents, requestsExtensionInstallConsent pending: ExtensionInstaller.PendingInstall) async -> Bool {
            installConsentCalls.append(pending)
            return installConsentAnswer
        }

        func webContents(_ contents: WebContents, confirmUninstallExtensionNamed name: String) async -> Bool {
            uninstallConfirmCalls.append(name)
            return uninstallConfirmAnswer
        }
    }

    // MARK: - Origin enforcement

    func test_nonWebStoreOrigin_isRefused_forBothAPIs() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: URL(string: "https://evil.example.com/looks-like-a-store-page"))

        let webstorePrivateResponse = try await decode(
            bridge.handle(payload: payload(api: "webstorePrivate", method: "getBrowserLogin"), contents: contents)
        )
        XCTAssertFalse(webstorePrivateResponse.ok)
        XCTAssertEqual(webstorePrivateResponse.errorMessage, "This page is not allowed to use the Chrome Web Store install bridge.")

        let managementResponse = try await decode(
            bridge.handle(payload: payload(api: "management", method: "getAll"), contents: contents)
        )
        XCTAssertFalse(managementResponse.ok, "management.* must be refused from a non-Web-Store origin exactly like webstorePrivate.*, not just the install half of the API.")
        XCTAssertEqual(managementResponse.errorMessage, "This page is not allowed to use the Chrome Web Store install bridge.")
    }

    func test_noCommittedNavigation_isRefused() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: nil)

        let response = try await decode(bridge.handle(payload: payload(api: "webstorePrivate", method: "getBrowserLogin"), contents: contents))
        XCTAssertFalse(response.ok, "A tab with no committed navigation at all must not be trusted as the Web Store.")
    }

    func test_plainHTTPOnTheRealHost_isRefused() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: URL(string: "http://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop"))

        let response = try await decode(bridge.handle(payload: payload(api: "webstorePrivate", method: "getBrowserLogin"), contents: contents))
        XCTAssertFalse(response.ok, "The real host over plain HTTP is not the real Chrome Web Store; only https is.")
    }

    func test_lookalikeSubdomain_isRefused() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: URL(string: "https://chromewebstore.google.com.evil.example.com/detail/x"))

        let response = try await decode(bridge.handle(payload: payload(api: "webstorePrivate", method: "getBrowserLogin"), contents: contents))
        XCTAssertFalse(response.ok, "A host that merely CONTAINS the real store's hostname as a prefix is not the real store; the origin check must compare the whole host, not do a substring match.")
    }

    func test_realWebStoreOrigins_areAccepted() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)

        for url in [
            URL(string: "https://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop")!,
            URL(string: "https://chrome.google.com/webstore/detail/abcdefghijklmnopabcdefghijklmnop")!,
        ] {
            let contents = makeContents(url: url)
            let response = try await decode(bridge.handle(payload: payload(api: "webstorePrivate", method: "getBrowserLogin"), contents: contents))
            XCTAssertTrue(response.ok, "\(url.absoluteString) is one of the two real Web Store origins and must be accepted.")
        }
    }

    // MARK: - getReferrerChain

    func test_getReferrerChain_returnsTheNeverDecafConstant() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: Self.webStoreURL)

        let response = try await decode(bridge.handle(payload: payload(api: "webstorePrivate", method: "getReferrerChain"), contents: contents))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result as? String, "EgIIAA==")
    }

    // MARK: - management.setEnabled + hasPendingChanges honesty

    func test_managementSetEnabled_roundTripsAndHasPendingChangesReflectsItHonestly() async throws {
        let store = makeStore()
        let installed = try makeInstalledExtension(in: store)
        // Models what ChromiumEngine.start() does at boot: freeze the set of ids
        // that were actually handed to --load-extension.
        store.markActivated(ids: store.installed().map(\.id))
        XCTAssertFalse(store.hasPendingChanges, "test precondition: freshly activated, nothing pending")

        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: Self.webStoreURL)

        let disable = try await decode(
            bridge.handle(payload: payload(api: "management", method: "setEnabled", args: [installed.id, false]), contents: contents)
        )
        XCTAssertTrue(disable.ok, "setEnabled(false) failed: \(disable.errorMessage ?? "nil")")
        XCTAssertEqual(store.installed().first?.isEnabled, false)
        XCTAssertFalse(
            store.enabledDirectories().contains(installed.directory),
            "a disabled extension's directory must not be among the directories the NEXT engine start would enable."
        )
        XCTAssertTrue(
            store.hasPendingChanges,
            "the running Chromium was started with this extension enabled; disabling it now must be reported as a pending change, not silently taken as already in effect."
        )

        let reenable = try await decode(
            bridge.handle(payload: payload(api: "management", method: "setEnabled", args: [installed.id, true]), contents: contents)
        )
        XCTAssertTrue(reenable.ok)
        XCTAssertEqual(store.installed().first?.isEnabled, true)
        XCTAssertFalse(
            store.hasPendingChanges,
            "re-enabling it brings the enabled set back to exactly what --load-extension was given at boot, so there is nothing pending again."
        )
    }

    func test_managementSetEnabled_missingArguments_fails() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: Self.webStoreURL)

        let missingBool = try await decode(
            bridge.handle(payload: payload(api: "management", method: "setEnabled", args: ["some-id"]), contents: contents)
        )
        XCTAssertFalse(missingBool.ok)

        let unknownID = try await decode(
            bridge.handle(payload: payload(api: "management", method: "setEnabled", args: ["not-installed-id", true]), contents: contents)
        )
        XCTAssertFalse(unknownID.ok, "setEnabled for an id that is not installed must fail, not silently succeed.")
    }

    // MARK: - management.uninstall

    func test_managementUninstall_removesTheRecordAndTheDirectoryOnDisk() async throws {
        let store = makeStore()
        let installed = try makeInstalledExtension(in: store)
        let directory = installed.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "test precondition: the directory exists after install")

        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: Self.webStoreURL)

        let response = try await decode(
            bridge.handle(payload: payload(api: "management", method: "uninstall", args: [installed.id, NSNull()]), contents: contents)
        )
        XCTAssertTrue(response.ok, "uninstall failed: \(response.errorMessage ?? "nil")")
        XCTAssertTrue(store.installed().isEmpty, "the record must be gone from ExtensionStore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the extension's directory on disk must actually be removed, not just the bookkeeping record")
    }

    func test_managementUninstall_confirmDialogDeclined_leavesTheExtensionInstalled() async throws {
        let store = makeStore()
        let installed = try makeInstalledExtension(in: store)

        let bridge = WebStorePrivateBridge(store: store)
        let delegate = ScriptedDelegate()
        delegate.uninstallConfirmAnswer = false
        let contents = makeContents(url: Self.webStoreURL)
        contents.delegate = delegate

        let response = try await decode(
            bridge.handle(
                payload: payload(api: "management", method: "uninstall", args: [installed.id, ["showConfirmDialog": true]]),
                contents: contents
            )
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorMessage, "user_cancelled")
        XCTAssertEqual(delegate.uninstallConfirmCalls, [installed.name])
        XCTAssertEqual(store.installed().count, 1, "declining the confirm dialog must leave the extension installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.directory.path))
    }

    func test_managementUninstall_confirmDialogAccepted_removesIt() async throws {
        let store = makeStore()
        let installed = try makeInstalledExtension(in: store)

        let bridge = WebStorePrivateBridge(store: store)
        let delegate = ScriptedDelegate()
        delegate.uninstallConfirmAnswer = true
        let contents = makeContents(url: Self.webStoreURL)
        contents.delegate = delegate

        let response = try await decode(
            bridge.handle(
                payload: payload(api: "management", method: "uninstall", args: [installed.id, ["showConfirmDialog": true]]),
                contents: contents
            )
        )
        XCTAssertTrue(response.ok, "uninstall failed: \(response.errorMessage ?? "nil")")
        XCTAssertEqual(delegate.uninstallConfirmCalls, [installed.name])
        XCTAssertTrue(store.installed().isEmpty)
    }

    func test_managementUninstall_noConfirmDialogRequested_neverAsksTheDelegate() async throws {
        let store = makeStore()
        let installed = try makeInstalledExtension(in: store)

        let bridge = WebStorePrivateBridge(store: store)
        let delegate = ScriptedDelegate()
        // Leftover default answer would decline if asked — proving the assertion below is real, not a coincidence of a permissive default.
        delegate.uninstallConfirmAnswer = false
        let contents = makeContents(url: Self.webStoreURL)
        contents.delegate = delegate

        let response = try await decode(
            bridge.handle(payload: payload(api: "management", method: "uninstall", args: [installed.id]), contents: contents)
        )
        XCTAssertTrue(response.ok)
        XCTAssertTrue(delegate.uninstallConfirmCalls.isEmpty, "showConfirmDialog was not requested; the delegate must not be asked at all.")
        XCTAssertTrue(store.installed().isEmpty)
    }

    func test_managementUninstall_unknownID_fails() async throws {
        let store = makeStore()
        let bridge = WebStorePrivateBridge(store: store)
        let contents = makeContents(url: Self.webStoreURL)

        let response = try await decode(
            bridge.handle(payload: payload(api: "management", method: "uninstall", args: ["not-installed-id"]), contents: contents)
        )
        XCTAssertFalse(response.ok)
    }

    // MARK: - Relaunch constraint

    /// An `ExtensionStore.install` staged on disk does not start running until the next browser start-up re-reads `enabledDirectories()` into `--load-extension`; this models that boot -> install -> (not yet running) sequence and asserts `ExtensionStore` reports it honestly rather than optimistically.
    func test_freshlyInstalledExtension_isNotClaimedToBeRunningUntilTheNextEngineStart() async throws {
        let store = makeStore()
        // Boot with nothing enabled — the state ChromiumEngine.start() left the running process in.
        store.markActivated(ids: [])
        XCTAssertFalse(store.hasPendingChanges, "test precondition")

        let installed = try makeInstalledExtension(in: store, name: "Freshly Installed")

        XCTAssertTrue(
            store.installed().contains { $0.id == installed.id && $0.isEnabled },
            "the record must exist and be enabled — installation itself succeeded"
        )
        XCTAssertTrue(
            store.enabledDirectories().contains(installed.directory),
            "the newly installed extension's directory must be staged for the NEXT --load-extension, or a relaunch would not pick it up either"
        )
        XCTAssertTrue(
            store.hasPendingChanges,
            """
            The currently RUNNING Chromium process was started before this extension existed, so it \
            cannot possibly be executing right now — there is no way to add an extension to a running browser process. \
            ExtensionStore must say hasPendingChanges == true here; claiming false would be Orbit lying \
            to itself (and, downstream, to the user) about an extension that is installed but not running.
            """
        )
    }
}
