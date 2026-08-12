import Foundation
import Observation

@MainActor
@Observable
public final class ExtensionInstallController {

    // MARK: - Observable state

    public private(set) var phase: ExtensionInstallPhase = .idle

    public private(set) var installStage: ExtensionInstallStage?

    public var consentRequest: ExtensionConsentBridge.PendingConsentRequest? {
        consentBridge.activeRequest
    }

    public var isBusy: Bool { phase != .idle }

    // MARK: - Dependencies

    private let consentBridge = ExtensionConsentBridge()

    private let store: ExtensionStore
    private let client: ChromeWebStoreClient

    @ObservationIgnored
    private lazy var installer: ExtensionInstaller = ExtensionInstaller(store: store, client: client) { [weak self] pending in
        guard let self else { return false }
        self.phase = .awaitingConsent
        let granted = await self.consentBridge.requestConsent(for: pending)
        self.phase = .finishingInstall
        return granted
    }

    public init(store: ExtensionStore? = nil, client: ChromeWebStoreClient = ChromeWebStoreClient()) {
        self.store = store ?? AppEnvironment.processRoot.extensionStore
        self.client = client
    }

    // MARK: - Consent

    public func answerConsent(_ granted: Bool) {
        consentBridge.answer(granted)
    }

    public func consentSheetDismissedWithoutAnswer() {
        consentBridge.sheetDismissedWithoutAnswer()
    }

    // MARK: - Install

    public func install(_ input: String, reinstall: Bool = false) async throws -> ExtensionInstaller.InstallResult {
        phase = .resolving
        do {
            _ = try ChromeWebStoreLocator.extensionID(from: input)
        } catch let error as ChromeWebStoreError {
            phase = .idle
            throw ExtensionInstallError.webStoreFailure(error)
        }

        phase = .downloadingAndVerifying
        defer {
            phase = .idle
            installStage = nil
        }
        return try await installer.install(input, reinstall: reinstall, onStage: makeStageReporter())
    }

    // MARK: - Update check

    public func checkForUpdate(id: String) async throws -> ExtensionInstaller.InstallResult {
        phase = .checkingForUpdate
        defer {
            phase = .idle
            installStage = nil
        }
        return try await installer.checkForUpdatesAndInstall(id: id, onStage: makeStageReporter())
    }

    // MARK: - Progress reporting

    // Not stored beyond the single install() / checkForUpdate() call below, so a strong
    // capture here creates no retain cycle (unlike the long-lived `consent` closure above).
    private func makeStageReporter() -> @Sendable (ExtensionInstallStage) -> Void {
        let box = UncheckedSendableBox(self)
        return { stage in
            Task { @MainActor in box.value.installStage = stage }
        }
    }
}
