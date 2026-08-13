import XCTest

@MainActor
final class ExtensionInstallerTests: XCTestCase {

    private var createdPaths: [URL] = []

    override func tearDown() {
        for path in createdPaths {
            try? FileManager.default.removeItem(at: path)
        }
        createdPaths.removeAll()
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Store / client fixtures

    private func makeStore() -> ExtensionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionInstallerStore-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(root)
        return ExtensionStore(root: root)
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient() -> ChromeWebStoreClient {
        ChromeWebStoreClient(session: makeStubbedSession(), prodVersion: "151")
    }

    private static let downloadBlobURL = URL(string: "https://clients2.googleusercontent.com/crx/blobs/fixture.crx")!

    // Unclassifiable requests answer 404, a loud failure rather than a hang.
    private func makeHandler(crxBytes: Data?, updateCheckXML: String? = nil) -> (URLRequest) -> StubURLProtocol.Script {
        { request in
            guard let url = request.url else {
                return .respond(status: 400, headers: [:], body: Data())
            }
            if url.host == Self.downloadBlobURL.host {
                return .respond(
                    status: 200,
                    headers: ["Content-Type": "application/x-chrome-extension"],
                    body: crxBytes ?? Data()
                )
            }
            if url.query?.contains("response=redirect") == true {
                return .redirect(to: Self.downloadBlobURL)
            }
            if let updateCheckXML {
                return .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(updateCheckXML.utf8))
            }
            return .respond(status: 404, headers: [:], body: Data())
        }
    }

    private func omahaUpdateAvailableXML(appID: String, version: String, codebase: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
        <app appid="\(appID)">
        <updatecheck status="ok" codebase="\(codebase)" version="\(version)"/>
        </app>
        </gupdate>
        """
    }

    // MARK: - Unpacked source tree / real ZIP fixtures

    private func makeSourceTree(
        name: String = "Fixture Extension",
        version: String = "1.0",
        permissions: [String] = [],
        minimumChromeVersion: String? = nil,
        includeIcon: Bool = true
    ) throws -> (root: URL, topLevelEntries: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionInstallerSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdPaths.append(root)

        var manifest: [String: Any] = [
            "name": name,
            "version": version,
            "manifest_version": 3,
        ]
        if !permissions.isEmpty {
            manifest["permissions"] = permissions
        }
        if let minimumChromeVersion {
            manifest["minimum_chrome_version"] = minimumChromeVersion
        }
        var entries = ["manifest.json"]
        if includeIcon {
            manifest["icons"] = ["128": "icon128.png"]
        }

        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))

        if includeIcon {
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: root.appendingPathComponent("icon128.png"))
            entries.append("icon128.png")
        }

        return (root, entries)
    }

    private func zipDirectory(root: URL, entries: [String]) throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionInstallerZip-\(UUID().uuidString).zip")
        createdPaths.append(archiveURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", archiveURL.path] + entries
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to build the test fixture archive.")

        return try Data(contentsOf: archiveURL)
    }

    private func buildSignedCRX(zipPayload: Data) throws -> (bytes: Data, publicKeyBase64: String, id: String) {
        let built = try CRX3TestFixture.build(zipPayload: zipPayload)
        let id = try XCTUnwrap(
            ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64),
            "A freshly base64-encoded SPKI key must always decode back through ChromeExtensionID."
        )
        return (built.bytes, built.publicKeyBase64, id)
    }

    private func differentValidID(from id: String) -> String {
        var characters = Array(id)
        characters[0] = (characters[0] == "a") ? "b" : "a"
        return String(characters)
    }

    // Snapshotted before and after an install attempt so a test can assert
    // nothing was left behind, on every branch including the ones (signature
    // failure, identity mismatch) where staging is never even created.
    private func stagingDirectorySnapshot() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("Orbit-ExtensionInstall-") })
    }

    // MARK: - Happy path

    func test_happyPath_installsAndTheRecordLandsInStore() async throws {
        let (sourceRoot, entries) = try makeSourceTree(
            name: "Fixture Extension",
            version: "1.0",
            permissions: ["tabs"]
        )
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let (crxBytes, _, id) = try buildSignedCRX(zipPayload: zipData)

        StubURLProtocol.handler = makeHandler(crxBytes: crxBytes)

        let store = makeStore()
        var seenPending: ExtensionInstaller.PendingInstall?
        let installer = ExtensionInstaller(store: store, client: makeClient()) { pending in
            seenPending = pending
            return true
        }

        let before = stagingDirectorySnapshot()
        let result = try await installer.install(id)
        let after = stagingDirectorySnapshot()

        guard case .installed(let loaded, let isUpdate, let previousVersion) = result else {
            return XCTFail("Expected .installed, got \(result)")
        }
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.name, "Fixture Extension")
        XCTAssertEqual(loaded.version, "1.0")
        XCTAssertFalse(isUpdate)
        XCTAssertNil(previousVersion)

        XCTAssertEqual(store.installed().count, 1)
        XCTAssertEqual(store.installed().first?.id, id)
        XCTAssertEqual(store.installed().first?.version, "1.0")

        let pending = try XCTUnwrap(seenPending, "consent must be asked before a fresh install completes")
        XCTAssertEqual(pending.id, id)
        XCTAssertFalse(pending.isUpdate)
        XCTAssertNil(pending.previousVersion)
        XCTAssertNil(pending.chromiumVersionWarning, "no minimum_chrome_version was declared")
        XCTAssertTrue(
            pending.warnings.contains(where: { $0.text.localizedCaseInsensitiveContains("browsing history") }),
            "the \"tabs\" permission must produce a visible warning — got \(pending.warnings)"
        )
        XCTAssertNotNil(pending.iconURL, "the fixture manifest declares an icon")

        XCTAssertEqual(after, before, "the staging directory must be removed even after a successful install")
    }

    // MARK: - Main actor is not blocked during a real install

    private func makeManyFileSourceTree(fileCount: Int) throws -> (root: URL, entries: [String]) {
        let (root, baseEntries) = try makeSourceTree(name: "Bulk Fixture", version: "1.0")
        var entries = baseEntries
        let bulkDirectory = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: bulkDirectory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: 512)
        for index in 0..<fileCount {
            let relative = "files/file\(index).bin"
            try payload.write(to: root.appendingPathComponent(relative))
            entries.append(relative)
        }
        return (root, entries)
    }

    @MainActor
    private final class TickCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // Proves the fix, not just that install() returns: a MainActor ticker runs alongside a
    // stubbed 1,500-entry install. If verify/extract ran on the main actor, it would stall.
    func test_install_doesNotBlockTheMainActorDuringDownloadVerifyAndExtract() async throws {
        let (sourceRoot, entries) = try makeManyFileSourceTree(fileCount: 1500)
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let (crxBytes, _, id) = try buildSignedCRX(zipPayload: zipData)
        StubURLProtocol.handler = makeHandler(crxBytes: crxBytes)

        let store = makeStore()
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in true }

        let ticker = TickCounter()
        let tickerTask = Task { @MainActor in
            while !Task.isCancelled {
                ticker.increment()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { tickerTask.cancel() }

        let start = Date()
        let result = try await installer.install(id)
        let elapsed = Date().timeIntervalSince(start)
        tickerTask.cancel()

        guard case .installed = result else {
            return XCTFail("Expected .installed, got \(result)")
        }
        // Scaled to elapsed time, not a fixed count: a blocked actor ticks ~0 however long the
        // install takes, while a fast install legitimately affords few ticks.
        let requiredTicks = max(2, Int(elapsed / 0.05))
        XCTAssertGreaterThanOrEqual(
            ticker.count, requiredTicks,
            "the main actor ticked only \(ticker.count) time(s) in \(elapsed)s while a 1,500-entry install ran, "
                + "expected at least \(requiredTicks) — it was blocked instead of staying free for the UI"
        )
    }

    // MARK: - Chromium-version warning (non-blocking, per design)

    func test_newerMinimumChromeVersion_producesAWarningButStillInstalls() async throws {
        let (sourceRoot, entries) = try makeSourceTree(
            version: "1.0",
            minimumChromeVersion: "9999.0.0.0"
        )
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let (crxBytes, _, id) = try buildSignedCRX(zipPayload: zipData)

        StubURLProtocol.handler = makeHandler(crxBytes: crxBytes)

        let store = makeStore()
        var seenPending: ExtensionInstaller.PendingInstall?
        let installer = ExtensionInstaller(store: store, client: makeClient()) { pending in
            seenPending = pending
            return true
        }

        let result = try await installer.install(id)

        guard case .installed = result else {
            return XCTFail("Expected .installed even though a warning was raised, got \(result)")
        }
        let pending = try XCTUnwrap(seenPending)
        XCTAssertNotNil(pending.chromiumVersionWarning)
        XCTAssertTrue(pending.chromiumVersionWarning!.contains("9999.0.0.0"))
    }

    // MARK: - Signature failure aborts and installs nothing

    func test_signatureFailure_abortsAndInstallsNothing() async throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        var built = try CRX3TestFixture.build(zipPayload: zipData)
        built.bytes[built.signatureRange.lowerBound] ^= 0xFF
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64))

        StubURLProtocol.handler = makeHandler(crxBytes: built.bytes)

        let store = makeStore()
        var consentWasAsked = false
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in
            consentWasAsked = true
            return true
        }

        let before = stagingDirectorySnapshot()
        do {
            _ = try await installer.install(id)
            XCTFail("Expected ExtensionInstallError.verificationFailed")
        } catch ExtensionInstallError.verificationFailed {
            // expected
        } catch {
            XCTFail("Expected .verificationFailed, got \(error)")
        }
        let after = stagingDirectorySnapshot()

        XCTAssertFalse(consentWasAsked, "a container that fails verification must never reach the consent step")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual(after, before, "verification must fail before any staging directory is ever created")
    }

    // MARK: - Identity mismatch aborts

    func test_identityMismatch_abortsWhenTheDownloadedKeyNamesADifferentExtension() async throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let (crxBytes, _, realID) = try buildSignedCRX(zipPayload: zipData)
        let requestedID = differentValidID(from: realID)

        StubURLProtocol.handler = makeHandler(crxBytes: crxBytes)

        let store = makeStore()
        var consentWasAsked = false
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in
            consentWasAsked = true
            return true
        }

        let before = stagingDirectorySnapshot()
        do {
            _ = try await installer.install(requestedID)
            XCTFail("Expected ExtensionInstallError.identityMismatch")
        } catch ExtensionInstallError.identityMismatch(let requested, let received) {
            XCTAssertEqual(requested, requestedID)
            XCTAssertEqual(received, realID)
        } catch {
            XCTFail("Expected .identityMismatch, got \(error)")
        }
        let after = stagingDirectorySnapshot()

        XCTAssertFalse(consentWasAsked)
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual(after, before, "an identity mismatch must be caught before any staging directory is ever created")
    }

    // MARK: - Consent declined

    func test_consentDeclined_installsNothingAndLeavesNoStagingDirectory() async throws {
        let (sourceRoot, entries) = try makeSourceTree()
        let zipData = try zipDirectory(root: sourceRoot, entries: entries)
        let (crxBytes, _, id) = try buildSignedCRX(zipPayload: zipData)

        StubURLProtocol.handler = makeHandler(crxBytes: crxBytes)

        let store = makeStore()
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in false }

        let before = stagingDirectorySnapshot()
        let result = try await installer.install(id)
        let after = stagingDirectorySnapshot()

        guard case .declined(let declinedID) = result else {
            return XCTFail("Expected .declined, got \(result)")
        }
        XCTAssertEqual(declinedID, id)
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual(after, before, "a declined install must remove its staging directory")
    }

    // MARK: - Already installed

    func test_alreadyInstalled_refusesWithoutAttemptingADownload() async throws {
        let store = makeStore()
        let keyOnlyFixture = try CRX3TestFixture.build(zipPayload: Data())
        let publicKeyBase64 = keyOnlyFixture.publicKeyBase64
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: publicKeyBase64))

        let (existingSourceRoot, _) = try makeSourceTree(version: "1.0")
        _ = try store.install(unpackedAt: existingSourceRoot, publicKey: publicKeyBase64)
        XCTAssertEqual(store.installed().count, 1)

        var requestAttempted = false
        StubURLProtocol.handler = { request in
            requestAttempted = true
            return .respond(status: 500, headers: [:], body: Data())
        }

        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in true }

        do {
            _ = try await installer.install(id, reinstall: false)
            XCTFail("Expected ExtensionInstallError.alreadyInstalled")
        } catch ExtensionInstallError.alreadyInstalled(let erroredID, let installedVersion) {
            XCTAssertEqual(erroredID, id)
            XCTAssertEqual(installedVersion, "1.0")
        } catch {
            XCTFail("Expected .alreadyInstalled, got \(error)")
        }

        XCTAssertFalse(requestAttempted, "an already-installed id must be refused before any network request is made")
        XCTAssertEqual(store.installed().count, 1, "the existing record must be untouched")
    }

    // MARK: - Update path replaces and reports the previous version

    func test_updatePath_replacesAndReportsThePreviousVersion() async throws {
        let store = makeStore()

        let (newSourceRoot, newEntries) = try makeSourceTree(version: "2.0")
        let newZipData = try zipDirectory(root: newSourceRoot, entries: newEntries)
        let (newCRXBytes, newPublicKeyBase64, id) = try buildSignedCRX(zipPayload: newZipData)

        let (oldSourceRoot, _) = try makeSourceTree(version: "1.0")
        _ = try store.install(unpackedAt: oldSourceRoot, publicKey: newPublicKeyBase64)
        XCTAssertEqual(store.installed().first?.version, "1.0")

        let updateXML = omahaUpdateAvailableXML(
            appID: id,
            version: "2.0",
            codebase: "https://clients2.googleusercontent.com/crx/blobs/unused-codebase.crx"
        )
        StubURLProtocol.handler = makeHandler(crxBytes: newCRXBytes, updateCheckXML: updateXML)

        var seenPending: ExtensionInstaller.PendingInstall?
        let installer = ExtensionInstaller(store: store, client: makeClient()) { pending in
            seenPending = pending
            return true
        }

        let result = try await installer.checkForUpdatesAndInstall(id: id)

        guard case .installed(let loaded, let isUpdate, let previousVersion) = result else {
            return XCTFail("Expected .installed, got \(result)")
        }
        XCTAssertTrue(isUpdate)
        XCTAssertEqual(previousVersion, "1.0")
        XCTAssertEqual(loaded.version, "2.0")
        XCTAssertEqual(store.installed().count, 1, "the update must replace, not duplicate, the existing record")
        XCTAssertEqual(store.installed().first?.version, "2.0")

        let pending = try XCTUnwrap(seenPending)
        XCTAssertTrue(pending.isUpdate)
        XCTAssertEqual(pending.previousVersion, "1.0")
    }

    func test_checkForUpdatesAndInstall_reportsNoUpdateAvailableWithoutAnyConsentPrompt() async throws {
        let store = makeStore()
        let keyOnlyFixture = try CRX3TestFixture.build(zipPayload: Data())
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyOnlyFixture.publicKeyBase64))

        let (sourceRoot, _) = try makeSourceTree(version: "1.0")
        _ = try store.install(unpackedAt: sourceRoot, publicKey: keyOnlyFixture.publicKeyBase64)

        StubURLProtocol.handler = { request in
            .respond(
                status: 200,
                headers: ["Content-Type": "text/xml"],
                body: Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
                    <app appid="\(id)">
                    <updatecheck status="noupdate"/>
                    </app>
                    </gupdate>
                    """.utf8
                )
            )
        }

        var consentWasAsked = false
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in
            consentWasAsked = true
            return true
        }

        let result = try await installer.checkForUpdatesAndInstall(id: id)
        guard case .noUpdateAvailable(let reportedID, let currentVersion) = result else {
            return XCTFail("Expected .noUpdateAvailable, got \(result)")
        }
        XCTAssertEqual(reportedID, id)
        XCTAssertEqual(currentVersion, "1.0")
        XCTAssertFalse(consentWasAsked)
        XCTAssertEqual(store.installed().first?.version, "1.0")
    }

    func test_checkForUpdatesAndInstall_throwsNotInstalledForAnUnknownID() async throws {
        let store = makeStore()
        let keyOnlyFixture = try CRX3TestFixture.build(zipPayload: Data())
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: keyOnlyFixture.publicKeyBase64))

        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in true }

        do {
            _ = try await installer.checkForUpdatesAndInstall(id: id)
            XCTFail("Expected ExtensionInstallError.notInstalled")
        } catch ExtensionInstallError.notInstalled(let notInstalledID) {
            XCTAssertEqual(notInstalledID, id)
        } catch {
            XCTFail("Expected .notInstalled, got \(error)")
        }
    }

    // MARK: - Staging cleaned up on every remaining failure branch

    func test_corruptZipPayload_abortsStagingAndCleansUp() async throws {
        let notAZip = Data("this is not a zip archive".utf8)
        let built = try CRX3TestFixture.build(zipPayload: notAZip)
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64))

        StubURLProtocol.handler = makeHandler(crxBytes: built.bytes)

        let store = makeStore()
        var consentWasAsked = false
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in
            consentWasAsked = true
            return true
        }

        let before = stagingDirectorySnapshot()
        do {
            _ = try await installer.install(id)
            XCTFail("Expected ExtensionInstallError.stagingFailed")
        } catch ExtensionInstallError.stagingFailed {
            // expected
        } catch {
            XCTFail("Expected .stagingFailed, got \(error)")
        }
        let after = stagingDirectorySnapshot()

        XCTAssertFalse(consentWasAsked)
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual(after, before, "a ZIP extraction failure must leave no staging directory behind")
    }

    // The one branch that exercises cleanup of an already-populated staging directory: extraction succeeds but manifest.json is missing "version".
    func test_invalidManifest_abortsAfterStagingAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ExtensionInstallerBadManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdPaths.append(root)
        let manifestData = try JSONSerialization.data(withJSONObject: ["name": "Missing Version"], options: [])
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))
        let zipData = try zipDirectory(root: root, entries: ["manifest.json"])

        let built = try CRX3TestFixture.build(zipPayload: zipData)
        let id = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: built.publicKeyBase64))

        StubURLProtocol.handler = makeHandler(crxBytes: built.bytes)

        let store = makeStore()
        var consentWasAsked = false
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in
            consentWasAsked = true
            return true
        }

        let before = stagingDirectorySnapshot()
        do {
            _ = try await installer.install(id)
            XCTFail("Expected ExtensionInstallError.manifestInvalid")
        } catch ExtensionInstallError.manifestInvalid {
            // expected
        } catch {
            XCTFail("Expected .manifestInvalid, got \(error)")
        }
        let after = stagingDirectorySnapshot()

        XCTAssertFalse(consentWasAsked)
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertEqual(after, before, "a staged-but-invalid manifest must still leave no staging directory behind")
    }

    // MARK: - Locator failures surface through the same error type

    func test_unrecognizedInput_isWrappedAsWebStoreFailure() async {
        let store = makeStore()
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in true }

        do {
            _ = try await installer.install("https://example.com/definitely-not-a-web-store-link")
            XCTFail("Expected ExtensionInstallError.webStoreFailure")
        } catch ExtensionInstallError.webStoreFailure(let underlying) {
            guard case .unrecognizedInput = underlying else {
                return XCTFail("Expected .unrecognizedInput, got \(underlying)")
            }
        } catch {
            XCTFail("Expected .webStoreFailure, got \(error)")
        }
    }

    func test_invalidBareID_isWrappedAsWebStoreFailure() async {
        let store = makeStore()
        let installer = ExtensionInstaller(store: store, client: makeClient()) { _ in true }

        do {
            _ = try await installer.install("not a web store link or id")
            XCTFail("Expected ExtensionInstallError.webStoreFailure")
        } catch ExtensionInstallError.webStoreFailure(let underlying) {
            guard case .invalidExtensionID = underlying else {
                return XCTFail("Expected .invalidExtensionID, got \(underlying)")
            }
        } catch {
            XCTFail("Expected .webStoreFailure, got \(error)")
        }
    }
}

// MARK: - StubURLProtocol

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Script {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(to: URL)
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Script)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .redirect(let redirectURL):
            let redirectRequest = URLRequest(url: redirectURL)
            let redirectResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: redirectResponse)
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
