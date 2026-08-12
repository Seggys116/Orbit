import XCTest

@MainActor
final class ExtensionsSettingsPaneInstallTests: XCTestCase {

    // MARK: - Input classification

    func test_classifyInput_empty() {
        XCTAssertEqual(ExtensionInstallLogic.classifyInput(""), .empty)
        XCTAssertEqual(ExtensionInstallLogic.classifyInput("   \n  "), .empty)
    }

    func test_classifyInput_webStoreLink_bySlash() {
        XCTAssertEqual(
            ExtensionInstallLogic.classifyInput("https://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop"),
            .webStoreLink
        )
    }

    func test_classifyInput_webStoreLink_byColon_withNoSlash() {
        XCTAssertEqual(ExtensionInstallLogic.classifyInput("not-a-url:something"), .webStoreLink)
    }

    func test_classifyInput_extensionID_validShape() {
        let validID = String(repeating: "a", count: 32)
        XCTAssertEqual(ExtensionInstallLogic.classifyInput(validID), .extensionID)
    }

    func test_classifyInput_unrecognized_wrongLengthNoSlashOrColon() {
        XCTAssertEqual(ExtensionInstallLogic.classifyInput("tooshort"), .unrecognized)
    }

    func test_classifyInput_unrecognized_rightLengthWrongAlphabet() {
        let invalidID = String(repeating: "a", count: 31) + "1"
        XCTAssertEqual(ExtensionInstallLogic.classifyInput(invalidID), .unrecognized)
    }

    // MARK: - Error-to-message mapping

    func test_installFailureMessage_alreadyInstalled() {
        let error = ExtensionInstallError.alreadyInstalled(id: "abcdefghijklmnopabcdefghijklmnop", installedVersion: "1.0.0")
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("already installed"), message)
    }

    func test_installFailureMessage_notInstalled() {
        let error = ExtensionInstallError.notInstalled("abcdefghijklmnopabcdefghijklmnop")
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("No extension"), message)
    }

    func test_installFailureMessage_identityMismatch_withReceivedID() {
        let error = ExtensionInstallError.identityMismatch(requested: "requestedidrequestedidrequestedi", received: "receivedidreceivedidreceivedidre")
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("signed as"), message)
        XCTAssertTrue(message.contains("refused"), message)
    }

    func test_installFailureMessage_identityMismatch_noReceivedID() {
        let error = ExtensionInstallError.identityMismatch(requested: "requestedidrequestedidrequestedi", received: nil)
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("did not produce a recognizable"), message)
    }

    func test_installFailureMessage_webStoreFailure() {
        let error = ExtensionInstallError.webStoreFailure(.unrecognizedInput("not a link"))
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("doesn't look like a Chrome Web Store link"), message)
    }

    func test_installFailureMessage_verificationFailed_readsAsSignatureFailure() {
        let error = ExtensionInstallError.verificationFailed(.invalidMagic)
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertFalse(message.lowercased().contains("install failed"))
    }

    func test_installFailureMessage_stagingFailed() {
        let error = ExtensionInstallError.stagingFailed(.notAZipArchive)
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertFalse(message.isEmpty)
    }

    func test_installFailureMessage_manifestInvalid() {
        let manifestURL = URL(fileURLWithPath: "/tmp/does-not-exist/manifest.json")
        let error = ExtensionInstallError.manifestInvalid(.manifestMissing(manifestURL))
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("manifest.json"), message)
    }

    func test_installFailureMessage_installFailed() {
        let path = URL(fileURLWithPath: "/tmp/a,b")
        let error = ExtensionInstallError.installFailed(.pathContainsComma(path))
        let message = ExtensionInstallLogic.installFailureMessage(for: error)
        XCTAssertEqual(message, error.errorDescription)
        XCTAssertTrue(message.contains("comma"), message)
    }

    func test_installFailureMessage_nonLocalizedError_fallsBackToLocalizedDescription() {
        struct PlainError: Error {}
        let message = ExtensionInstallLogic.installFailureMessage(for: PlainError())
        XCTAssertEqual(message, PlainError().localizedDescription)
    }

    // MARK: - Path-derived-id gating

    func test_isPathDerivedID_nilKey_isPathDerived() {
        XCTAssertTrue(ExtensionInstallLogic.isPathDerivedID(manifestKey: nil))
    }

    func test_isPathDerivedID_emptyKey_isPathDerived() {
        XCTAssertTrue(ExtensionInstallLogic.isPathDerivedID(manifestKey: ""))
    }

    func test_isPathDerivedID_malformedBase64Key_isPathDerived() {
        XCTAssertTrue(ExtensionInstallLogic.isPathDerivedID(manifestKey: "!!!not-valid-base64!!!"))
    }

    func test_isPathDerivedID_decodableKey_isNotPathDerived() {
        let key = Data("some RSA public key bytes".utf8).base64EncodedString()
        XCTAssertFalse(ExtensionInstallLogic.isPathDerivedID(manifestKey: key))
    }

    // MARK: - Warning grouping

    func test_groupedWarnings_splitsByIsGrantedAtInstall_preservingOrder() {
        let granted1 = ExtensionPermissionWarning(id: "1", text: "Granted 1", severity: .critical, isGrantedAtInstall: true)
        let optional1 = ExtensionPermissionWarning(id: "2", text: "Optional 1", severity: .high, isGrantedAtInstall: false)
        let granted2 = ExtensionPermissionWarning(id: "3", text: "Granted 2", severity: .low, isGrantedAtInstall: true)
        let optional2 = ExtensionPermissionWarning(id: "4", text: "Optional 2", severity: .moderate, isGrantedAtInstall: false)

        let grouped = ExtensionInstallLogic.groupedWarnings([granted1, optional1, granted2, optional2])

        XCTAssertEqual(grouped.granted.map(\.id), ["1", "3"])
        XCTAssertEqual(grouped.optional.map(\.id), ["2", "4"])
    }

    func test_groupedWarnings_empty() {
        let grouped = ExtensionInstallLogic.groupedWarnings([])
        XCTAssertTrue(grouped.granted.isEmpty)
        XCTAssertTrue(grouped.optional.isEmpty)
    }

    // MARK: - `"tabs"` permission disclosure gate

    func test_requestsTabsPermission_true() {
        let manifest = ChromeExtensionManifest(
            name: "Test",
            version: "1.0",
            manifestVersion: 3,
            hasToolbarAction: false,
            iconRelativePath: nil,
            key: nil,
            permissions: ["storage", "tabs"]
        )
        XCTAssertTrue(ExtensionInstallLogic.requestsTabsPermission(manifest))
    }

    func test_requestsTabsPermission_false_whenAbsent() {
        let manifest = ChromeExtensionManifest(
            name: "Test",
            version: "1.0",
            manifestVersion: 3,
            hasToolbarAction: false,
            iconRelativePath: nil,
            key: nil,
            permissions: ["storage"]
        )
        XCTAssertFalse(ExtensionInstallLogic.requestsTabsPermission(manifest))
    }

    func test_requestsTabsPermission_false_forActiveTabAlone() {
        let manifest = ChromeExtensionManifest(
            name: "Test",
            version: "1.0",
            manifestVersion: 3,
            hasToolbarAction: false,
            iconRelativePath: nil,
            key: nil,
            permissions: ["activeTab"]
        )
        XCTAssertFalse(ExtensionInstallLogic.requestsTabsPermission(manifest))
    }

    // MARK: - Update-result -> UI-state mapping

    private func makeLoadedExtension(name: String = "Test Extension", version: String = "2.0.0") -> LoadedExtension {
        LoadedExtension(
            id: "abcdefghijklmnopabcdefghijklmnop",
            name: name,
            version: version,
            directory: URL(fileURLWithPath: "/tmp/does-not-matter")
        )
    }

    func test_updateOutcome_installed_mapsToUpdated() {
        let ext = makeLoadedExtension()
        let result = ExtensionInstaller.InstallResult.installed(ext, isUpdate: true, previousVersion: "1.0.0")
        let outcome = ExtensionInstallLogic.updateOutcome(for: result)
        XCTAssertEqual(outcome, .updated(name: "Test Extension", newVersion: "2.0.0", previousVersion: "1.0.0"))
    }

    func test_updateOutcome_declined_mapsToDeclined() {
        let result = ExtensionInstaller.InstallResult.declined(id: "abcdefghijklmnopabcdefghijklmnop")
        XCTAssertEqual(ExtensionInstallLogic.updateOutcome(for: result), .declined)
    }

    func test_updateOutcome_noUpdateAvailable_mapsToAlreadyCurrent_notAnError() {
        let result = ExtensionInstaller.InstallResult.noUpdateAvailable(id: "abcdefghijklmnopabcdefghijklmnop", currentVersion: "3.1.4")
        XCTAssertEqual(ExtensionInstallLogic.updateOutcome(for: result), .alreadyCurrent(version: "3.1.4"))
    }

    // MARK: - Consent bridge: default-to-decline and single-resume

    private func makePendingInstall(isUpdate: Bool = false, previousVersion: String? = nil) -> ExtensionInstaller.PendingInstall {
        ExtensionInstaller.PendingInstall(
            id: "abcdefghijklmnopabcdefghijklmnop",
            name: "Test Extension",
            version: "1.0.0",
            description: "A test extension.",
            iconURL: nil,
            warnings: [],
            isUpdate: isUpdate,
            previousVersion: previousVersion,
            chromiumVersionWarning: nil
        )
    }

    /// `Task.yield()` is ordinary Swift Concurrency test sequencing, not a blocking wait on user input.
    private func waitForActiveRequest(_ bridge: ExtensionConsentBridge) async {
        for _ in 0..<200 where bridge.activeRequest == nil {
            await Task.yield()
        }
    }

    func test_consentBridge_dismissedWithoutAnswer_defaultsToDecline() async {
        let bridge = ExtensionConsentBridge()
        let task = Task { await bridge.requestConsent(for: makePendingInstall()) }

        await waitForActiveRequest(bridge)
        XCTAssertNotNil(bridge.activeRequest)

        bridge.sheetDismissedWithoutAnswer()

        let granted = await task.value
        XCTAssertFalse(granted)
        XCTAssertNil(bridge.activeRequest)
    }

    func test_consentBridge_explicitApprove_resolvesTrue() async {
        let bridge = ExtensionConsentBridge()
        let task = Task { await bridge.requestConsent(for: makePendingInstall()) }

        await waitForActiveRequest(bridge)
        bridge.answer(true)

        let granted = await task.value
        XCTAssertTrue(granted)
    }

    func test_consentBridge_explicitDecline_resolvesFalse() async {
        let bridge = ExtensionConsentBridge()
        let task = Task { await bridge.requestConsent(for: makePendingInstall()) }

        await waitForActiveRequest(bridge)
        bridge.answer(false)

        let granted = await task.value
        XCTAssertFalse(granted)
    }

    func test_consentBridge_answerThenDismiss_secondCallIsNoOp() async {
        let bridge = ExtensionConsentBridge()
        let task = Task { await bridge.requestConsent(for: makePendingInstall()) }

        await waitForActiveRequest(bridge)
        bridge.answer(true)
        bridge.sheetDismissedWithoutAnswer()

        let granted = await task.value
        XCTAssertTrue(granted)
    }

    func test_consentBridge_dismissTwice_doesNotCrash() async {
        let bridge = ExtensionConsentBridge()
        let task = Task { await bridge.requestConsent(for: makePendingInstall()) }

        await waitForActiveRequest(bridge)
        bridge.sheetDismissedWithoutAnswer()
        bridge.sheetDismissedWithoutAnswer()

        let granted = await task.value
        XCTAssertFalse(granted)
    }

    func test_consentBridge_overwrittenRequest_resolvesFirstOneToFalseViaDeinit() async {
        let bridge = ExtensionConsentBridge()
        let firstTask = Task { await bridge.requestConsent(for: makePendingInstall()) }
        await waitForActiveRequest(bridge)

        let secondTask = Task { await bridge.requestConsent(for: makePendingInstall(isUpdate: true, previousVersion: "0.9.0")) }
        for _ in 0..<200 where bridge.activeRequest?.pending.isUpdate != true {
            await Task.yield()
        }

        let firstGranted = await firstTask.value
        XCTAssertFalse(firstGranted)

        bridge.answer(true)
        let secondGranted = await secondTask.value
        XCTAssertTrue(secondGranted)
    }
}
