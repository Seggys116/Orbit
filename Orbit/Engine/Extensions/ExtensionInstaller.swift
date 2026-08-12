import Foundation

// MARK: - Install progress

// Coarse, honest phases — no fabricated byte/entry counts when the
// underlying step genuinely can't report them.
public enum ExtensionInstallStage: Sendable, Equatable {
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying
    case extracting(completedEntries: Int, totalEntries: Int)
    case awaitingConsent
    case installing
}

// MARK: - Installer

// nonisolated, not @MainActor: download/verify/extract are CPU/IO-heavy and must
// not run there; only `consent` and the final ExtensionStore mutation hop to it.
nonisolated public final class ExtensionInstaller {

    // MARK: - Consent surface

    public struct PendingInstall: Equatable {
        public let id: String
        public let name: String
        public let version: String
        public let description: String?
        public let iconURL: URL?
        public let warnings: [ExtensionPermissionWarning]
        public let isUpdate: Bool
        public let previousVersion: String?
        public let chromiumVersionWarning: String?

        public init(
            id: String,
            name: String,
            version: String,
            description: String?,
            iconURL: URL?,
            warnings: [ExtensionPermissionWarning],
            isUpdate: Bool,
            previousVersion: String?,
            chromiumVersionWarning: String?
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.description = description
            self.iconURL = iconURL
            self.warnings = warnings
            self.isUpdate = isUpdate
            self.previousVersion = previousVersion
            self.chromiumVersionWarning = chromiumVersionWarning
        }
    }

    // MARK: - Result

    public enum InstallResult: Equatable {
        case installed(LoadedExtension, isUpdate: Bool, previousVersion: String?)
        case declined(id: String)
        case noUpdateAvailable(id: String, currentVersion: String)
    }

    // MARK: - Dependencies

    private let store: ExtensionStore
    private let client: ChromeWebStoreClient
    private let zipLimits: ZipArchiveExtractor.Limits
    private let consent: @MainActor (PendingInstall) async -> Bool

    public init(
        store: ExtensionStore,
        client: ChromeWebStoreClient = ChromeWebStoreClient(),
        zipLimits: ZipArchiveExtractor.Limits = .default,
        consent: @escaping @MainActor (PendingInstall) async -> Bool
    ) {
        self.store = store
        self.client = client
        self.zipLimits = zipLimits
        self.consent = consent
    }

    // MARK: - Install

    public func install(
        _ input: String,
        reinstall: Bool = false,
        onStage: (@Sendable (ExtensionInstallStage) -> Void)? = nil
    ) async throws -> InstallResult {
        let id: String
        do {
            id = try ChromeWebStoreLocator.extensionID(from: input)
        } catch let error as ChromeWebStoreError {
            throw ExtensionInstallError.webStoreFailure(error)
        }
        return try await installVerified(id: id, allowReplacingExisting: reinstall, onStage: onStage)
    }

    public func checkForUpdatesAndInstall(
        id: String,
        onStage: (@Sendable (ExtensionInstallStage) -> Void)? = nil
    ) async throws -> InstallResult {
        let installedList = await store.installed()
        guard let existing = installedList.first(where: { $0.id == id }) else {
            throw ExtensionInstallError.notInstalled(id)
        }

        let updateResult: ChromeWebStoreUpdateCheckResult
        do {
            updateResult = try await client.checkForUpdate(id: id, installedVersion: existing.version)
        } catch let error as ChromeWebStoreError {
            throw ExtensionInstallError.webStoreFailure(error)
        }

        guard case .updateAvailable = updateResult else {
            return .noUpdateAvailable(id: id, currentVersion: existing.version)
        }

        return try await installVerified(id: id, allowReplacingExisting: true, onStage: onStage)
    }

    // MARK: - The one verified pipeline

    private func installVerified(
        id: String,
        allowReplacingExisting: Bool,
        onStage: (@Sendable (ExtensionInstallStage) -> Void)?
    ) async throws -> InstallResult {
        let installedList = await store.installed()
        let existing = installedList.first { $0.id == id }
        if let existing, !allowReplacingExisting {
            throw ExtensionInstallError.alreadyInstalled(id: id, installedVersion: existing.version)
        }

        try Task.checkCancellation()
        onStage?(.downloading(receivedBytes: 0, totalBytes: 0))
        let data: Data
        do {
            data = try await client.download(id: id) { received, total in
                onStage?(.downloading(receivedBytes: received, totalBytes: total))
            }
        } catch let error as ChromeWebStoreError {
            throw ExtensionInstallError.webStoreFailure(error)
        }

        try Task.checkCancellation()
        onStage?(.verifying)
        // Off the calling actor: RSA signature verification of a large payload is real CPU work.
        let verified = try await Task.detached(priority: .userInitiated) {
            try Self.verifyCRX(data, requestedID: id)
        }.value

        try Task.checkCancellation()
        let stagingRoot = Self.makeStagingDirectory()
        var stagingExists = false
        defer {
            if stagingExists {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }

        let extractLimits = zipLimits
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try ZipArchiveExtractor.extract(verified.zipPayload, to: stagingRoot, limits: extractLimits) { completed, total in
                    onStage?(.extracting(completedEntries: completed, totalEntries: total))
                }
            }.value
            stagingExists = true
        } catch let error as ZipArchiveError {
            throw ExtensionInstallError.stagingFailed(error)
        }

        let manifest: ChromeExtensionManifest
        do {
            manifest = try ChromeExtensionManifest.read(fromDirectory: stagingRoot)
        } catch let error as ExtensionStoreError {
            throw ExtensionInstallError.manifestInvalid(error)
        }

        let warnings = ExtensionPermissionWarnings.warnings(for: manifest)
        let iconURL = manifest.iconRelativePath.map { stagingRoot.appendingPathComponent($0) }
        let chromiumVersionWarning = Self.chromiumVersionWarning(for: manifest.minimumChromeVersion)

        let pending = PendingInstall(
            id: id,
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            iconURL: iconURL,
            warnings: warnings,
            isUpdate: existing != nil,
            previousVersion: existing?.version,
            chromiumVersionWarning: chromiumVersionWarning
        )

        try Task.checkCancellation()
        onStage?(.awaitingConsent)
        guard await consent(pending) else {
            return .declined(id: id)
        }

        onStage?(.installing)
        let root = store.root
        let publicKeyBase64 = verified.publicKeyBase64
        let loaded: LoadedExtension
        do {
            // A running id must be fully unloaded before stageInstall
            // deletes/overwrites its directory below.
            if existing != nil {
                await store.notifyWillReplace(id: id)
            }
            let staged = try await Task.detached(priority: .userInitiated) {
                try ExtensionStore.stageInstall(
                    unpackedAt: stagingRoot, root: root, publicKey: publicKeyBase64, consumingSource: true
                )
            }.value
            loaded = try await store.finalizeInstall(staged)
        } catch let error as ExtensionStoreError {
            throw ExtensionInstallError.installFailed(error)
        }

        return .installed(loaded, isUpdate: existing != nil, previousVersion: existing?.version)
    }

    // MARK: - Verification + identity cross-check

    // Security boundary: the derived id must be cross-checked against requestedID — do not skip this.
    private static func verifyCRX(_ data: Data, requestedID: String) throws -> CRX3Verifier.VerifiedExtension {
        let verified: CRX3Verifier.VerifiedExtension
        do {
            verified = try CRX3Verifier.verify(data)
        } catch let error as CRX3Error {
            throw ExtensionInstallError.verificationFailed(error)
        }

        guard let derivedID = ChromeExtensionID.id(fromPublicKeyBase64: verified.publicKeyBase64) else {
            throw ExtensionInstallError.identityMismatch(requested: requestedID, received: nil)
        }
        guard derivedID == requestedID else {
            throw ExtensionInstallError.identityMismatch(requested: requestedID, received: derivedID)
        }
        return verified
    }

    // MARK: - Staging directory

    private static func makeStagingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbit-ExtensionInstall-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Chromium version warning

    private static func chromiumVersionWarning(for minimumChromeVersion: String?) -> String? {
        guard let minimumChromeVersion, !minimumChromeVersion.isEmpty else { return nil }
        guard isVersion(minimumChromeVersion, newerThan: ChromiumBuild.version) else { return nil }
        return "This extension declares that it requires Chrome \(minimumChromeVersion) or later. "
            + "Orbit currently embeds Chromium \(ChromiumBuild.version), which is older, so some of its features may not work correctly."
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsComponents = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsComponents = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return false
    }
}

// MARK: - Errors

public enum ExtensionInstallError: LocalizedError, Equatable {
    case alreadyInstalled(id: String, installedVersion: String)
    case notInstalled(String)
    case identityMismatch(requested: String, received: String?)
    case webStoreFailure(ChromeWebStoreError)
    case verificationFailed(CRX3Error)
    case stagingFailed(ZipArchiveError)
    case manifestInvalid(ExtensionStoreError)
    case installFailed(ExtensionStoreError)

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let id, let installedVersion):
            return "\"\(id)\" is already installed (version \(installedVersion)). "
                + "Reinstall or check for an update instead of installing it again from scratch."
        case .notInstalled(let id):
            return "No extension with id \"\(id)\" is installed, so there is no version to check for an update against."
        case .identityMismatch(let requested, let received):
            if let received {
                return "The Chrome Web Store returned an extension signed as \"\(received)\", not the requested \"\(requested)\". The download was refused."
            }
            return "The downloaded extension's signing key did not produce a recognizable extension id. The download was refused."
        case .webStoreFailure(let error):
            return error.errorDescription
        case .verificationFailed(let error):
            return error.errorDescription
        case .stagingFailed(let error):
            return error.errorDescription
        case .manifestInvalid(let error):
            return error.errorDescription
        case .installFailed(let error):
            return error.errorDescription
        }
    }
}
