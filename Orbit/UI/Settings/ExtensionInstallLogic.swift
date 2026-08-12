import Foundation

// MARK: - Input classification

public enum ExtensionInstallInputKind: Equatable, Sendable {
    case empty
    case webStoreLink
    case extensionID
    case unrecognized
}

public enum ExtensionInstallLogic {

    public static func classifyInput(_ raw: String) -> ExtensionInstallInputKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") {
            return .webStoreLink
        }
        if ChromeExtensionID.isValid(trimmed) {
            return .extensionID
        }
        return .unrecognized
    }

    // MARK: - Error surfacing

    public static func installFailureMessage(for error: Error) -> String {
        if error is CancellationError { return "Installation cancelled." }
        if let described = (error as? LocalizedError)?.errorDescription {
            return described
        }
        return error.localizedDescription
    }

    // MARK: - Path-derived-ID gating

    public static func isPathDerivedID(manifestKey: String?) -> Bool {
        guard let manifestKey, ChromeExtensionID.id(fromPublicKeyBase64: manifestKey) != nil else {
            return true
        }
        return false
    }

    // MARK: - Consent-sheet warning grouping

    public static func groupedWarnings(
        _ warnings: [ExtensionPermissionWarning]
    ) -> (granted: [ExtensionPermissionWarning], optional: [ExtensionPermissionWarning]) {
        (warnings.filter(\.isGrantedAtInstall), warnings.filter { !$0.isGrantedAtInstall })
    }

    // MARK: - `chrome.tabs` disclosure

    public static func requestsTabsPermission(_ manifest: ChromeExtensionManifest) -> Bool {
        manifest.permissions.contains("tabs")
    }

    // MARK: - Update-result mapping

    public static func updateOutcome(for result: ExtensionInstaller.InstallResult) -> ExtensionUpdateOutcome {
        switch result {
        case .installed(let extensionRecord, _, let previousVersion):
            return .updated(name: extensionRecord.name, newVersion: extensionRecord.version, previousVersion: previousVersion)
        case .declined:
            return .declined
        case .noUpdateAvailable(_, let currentVersion):
            return .alreadyCurrent(version: currentVersion)
        }
    }

}

public enum ExtensionUpdateOutcome: Equatable, Sendable {
    case updated(name: String, newVersion: String, previousVersion: String?)
    case alreadyCurrent(version: String)
    case declined
}

// MARK: - Stage presentation

// Single source of truth for install-flow copy: the tab-overlay banner and Settings pane's inline installer both call this, so the two can never drift.

public struct ExtensionInstallStagePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let fraction: Double?
}

public enum ExtensionInstallStagePresenter {
    public static func present(_ stage: ExtensionInstallStage) -> ExtensionInstallStagePresentation {
        switch stage {
        case .downloading(let received, let total):
            return ExtensionInstallStagePresentation(
                title: "Downloading extension…",
                detail: total > 0 ? "\(LibraryByteFormat.string(received)) of \(LibraryByteFormat.string(total))" : nil,
                fraction: total > 0 ? Double(received) / Double(total) : nil
            )
        case .verifying:
            return ExtensionInstallStagePresentation(title: "Verifying…", detail: nil, fraction: nil)
        case .extracting(let completed, let total):
            return ExtensionInstallStagePresentation(
                title: "Unpacking…",
                detail: total > 0 ? "\(completed) of \(total) files" : nil,
                fraction: total > 0 ? Double(completed) / Double(total) : nil
            )
        case .awaitingConsent:
            return ExtensionInstallStagePresentation(title: "Waiting for your decision…", detail: nil, fraction: nil)
        case .installing:
            return ExtensionInstallStagePresentation(title: "Installing…", detail: nil, fraction: nil)
        }
    }
}

// MARK: - Failure presentation

// Categorises a failure into a fixed headline plus detailed message, so it never renders as a raw error string dumped into a label.

public enum ExtensionInstallFailureCategory: Equatable, Sendable {
    case cancelled
    case network
    case verification
    case alreadyInstalled
    case unsupportedManifest
    case other

    public var title: String {
        switch self {
        case .cancelled: return "Installation Cancelled"
        case .network: return "Couldn't Reach the Chrome Web Store"
        case .verification: return "Couldn't Verify This Extension"
        case .alreadyInstalled: return "Already Installed"
        case .unsupportedManifest: return "Unsupported Extension"
        case .other: return "Installation Failed"
        }
    }

    public var systemImage: String {
        switch self {
        case .cancelled: return "xmark.circle"
        case .network: return "wifi.exclamationmark"
        case .verification: return "exclamationmark.shield.fill"
        case .alreadyInstalled: return "checkmark.circle.fill"
        case .unsupportedManifest: return "puzzlepiece.extension"
        case .other: return "exclamationmark.triangle.fill"
        }
    }
}

public struct ExtensionInstallFailurePresentation: Equatable, Sendable {
    public let category: ExtensionInstallFailureCategory
    public let title: String
    public let message: String
    public let systemImage: String

    public init(category: ExtensionInstallFailureCategory, message: String) {
        self.category = category
        self.title = category.title
        self.message = message
        self.systemImage = category.systemImage
    }

    public static func present(_ error: Error) -> ExtensionInstallFailurePresentation {
        ExtensionInstallFailurePresentation(category: category(for: error), message: ExtensionInstallLogic.installFailureMessage(for: error))
    }

    private static func category(for error: Error) -> ExtensionInstallFailureCategory {
        if error is CancellationError { return .cancelled }
        guard let installError = error as? ExtensionInstallError else { return .other }
        switch installError {
        case .alreadyInstalled:
            return .alreadyInstalled
        case .verificationFailed:
            return .verification
        case .manifestInvalid:
            return .unsupportedManifest
        case .webStoreFailure(let webError):
            switch webError {
            case .network, .httpStatus, .responseTooLarge:
                return .network
            case .unrecognizedInput, .invalidExtensionID, .extensionNotFound, .unexpectedContentType, .malformedUpdateResponse:
                return .other
            }
        case .notInstalled, .identityMismatch, .stagingFailed, .installFailed:
            return .other
        }
    }
}

// MARK: - Who the install is for

// Name/version/icon are known only once the CRX is verified; `.installing` must still show them though its staging directory has since moved into the store.

public struct ExtensionInstallSubject: Equatable, Sendable {
    public let name: String
    public let version: String
    public let iconPNGData: Data?

    public init(name: String, version: String, iconPNGData: Data?) {
        self.name = name
        self.version = version
        self.iconPNGData = iconPNGData
    }

    public init(pending: ExtensionInstaller.PendingInstall) {
        self.name = pending.name
        self.version = pending.version
        self.iconPNGData = pending.iconURL.flatMap { try? Data(contentsOf: $0) }
    }
}

// MARK: - Terminal outcome

public enum ExtensionInstallOutcome: Equatable, Sendable {
    case installed(name: String, version: String)
    case failed(ExtensionInstallFailurePresentation)
}

// MARK: - The one modal's phases

// Consent, progress and outcome are three states of the same sheet, in the same frame.

public enum ExtensionInstallModalPhase: Equatable {
    case progress(ExtensionInstallStage)
    case consent(ExtensionInstaller.PendingInstall)
    case outcome(ExtensionInstallOutcome)
}

// MARK: - Progress phase

public enum ExtensionInstallPhase: Equatable, Sendable {
    case idle
    case resolving
    case downloadingAndVerifying
    case awaitingConsent
    case finishingInstall
    case checkingForUpdate
}

// MARK: - Consent bridge

/// Resumes `ExtensionInstaller`'s consent closure exactly once, on every sheet-dismissal path, defaulting to `false` if none ever fires.
@MainActor
public final class ExtensionConsentBridge {

    public struct PendingConsentRequest: Identifiable {
        public let id = UUID()
        public let pending: ExtensionInstaller.PendingInstall
        fileprivate let box: ExtensionConsentResumeBox
    }

    public private(set) var activeRequest: PendingConsentRequest?

    public init() {}

    public func requestConsent(for pending: ExtensionInstaller.PendingInstall) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ExtensionConsentResumeBox(continuation)
            activeRequest = PendingConsentRequest(pending: pending, box: box)
        }
    }

    public func answer(_ granted: Bool) {
        activeRequest?.box.resume(granted)
        activeRequest = nil
    }

    public func sheetDismissedWithoutAnswer() {
        guard let activeRequest else { return }
        activeRequest.box.resume(false)
        self.activeRequest = nil
    }
}

private final class ExtensionConsentResumeBox {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ granted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: granted)
    }

    deinit {
        continuation?.resume(returning: false)
    }
}
