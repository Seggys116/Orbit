import Foundation

@MainActor
public final class ExtensionStore {

    public let root: URL

    private var records: [ExtensionRecord]

    private var activatedIDs: Set<String>?

    public enum ChangeEvent {
        case installed(LoadedExtension)
        case uninstalled(id: String)
        case enabled(LoadedExtension)
        case disabled(LoadedExtension)
        // Fired before install/update touches an id's files on disk; the caller
        // must await ExtensionRuntime's synchronous unload before staging files.
        case willReplace(id: String)
    }

    private var changeObservers: [UUID: (ChangeEvent) -> Void] = [:]

    @discardableResult
    public func addChangeObserver(_ handler: @escaping (ChangeEvent) -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = handler
        return token
    }

    public func removeChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    private func notify(_ event: ChangeEvent) {
        for handler in changeObservers.values { handler(event) }
    }

    // Must be awaited to completion before stageInstall's copy for a known-installed
    // id: synchronous end to end, so the id is fully unloaded by the time this returns.
    public func notifyWillReplace(id: String) {
        notify(.willReplace(id: id))
    }

    // MARK: - Init

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.records = Self.loadRecords(root: root)
        self.activatedIDs = nil
    }

    public static func defaultRoot() -> URL { OrbitDataRoot.processDefault.extensions }

    // MARK: - Reading

    public func installed() -> [LoadedExtension] {
        records.map(loadedExtension(from:))
    }

    // MARK: - Install / remove / enable

    // Chromium derives its runtime id from the copied manifest's own key, not from
    // this method's id computation. Resolves the id before staging so a live copy
    // under it can be unloaded before stageInstall deletes/overwrites its files.
    @discardableResult
    public func install(unpackedAt source: URL, publicKey: String?) throws -> LoadedExtension {
        let id = try Self.resolveInstallID(unpackedAt: source, root: root, publicKey: publicKey)
        if records.contains(where: { $0.id == id }) {
            notifyWillReplace(id: id)
        }
        let staged = try Self.stageInstall(unpackedAt: source, root: root, publicKey: publicKey)
        return try finalizeInstall(staged)
    }

    // MARK: - Off-main-actor staging (large Web Store installs)

    // Everything install(unpackedAt:publicKey:) needs except the in-memory record mutation below.
    public struct StagedInstall: Sendable {
        let id: String
        let directoryName: String
        let sourcePath: String
        let manifest: ChromeExtensionManifest
        let idIsPathDerived: Bool
    }

    // Cheap: reads only manifest.json, so callers can resolve the id before
    // the potentially slow stageInstall copy to decide if notifyWillReplace is needed.
    nonisolated public static func resolveInstallID(unpackedAt source: URL, root: URL, publicKey: String?) throws -> String {
        let manifest = try ChromeExtensionManifest.read(fromDirectory: source)
        return Self.resolveIdentity(manifest: manifest, source: source, root: root, publicKey: publicKey).id
    }

    // A keyless extension's id is Chromium's hash of the destination path, not the
    // source; the directory is named after the source and the id after the destination.
    nonisolated private static func resolveIdentity(
        manifest: ChromeExtensionManifest, source: URL, root: URL, publicKey: String?
    ) -> (id: String, directoryName: String, idIsPathDerived: Bool) {
        if let publicKey, let derivedID = ChromeExtensionID.id(fromPublicKeyBase64: publicKey) {
            return (derivedID, derivedID, false)
        }
        if let manifestKey = manifest.key, let derivedID = ChromeExtensionID.id(fromPublicKeyBase64: manifestKey) {
            return (derivedID, derivedID, false)
        }
        let directoryName = ChromeExtensionID.id(forUnpackedPath: source)
        let destination = root.appendingPathComponent(directoryName, isDirectory: true)
        return (ChromeExtensionID.id(forUnpackedPath: destination), directoryName, true)
    }

    // Off-main-actor: a large tree copy is real wall-clock time. Callers replacing
    // a possibly-loaded id must await notifyWillReplace(id:) first. `consumingSource`
    // renames rather than copies; never pass true for a source the user still owns.
    nonisolated public static func stageInstall(
        unpackedAt source: URL, root: URL, publicKey: String?, consumingSource: Bool = false
    ) throws -> StagedInstall {
        let manifest = try ChromeExtensionManifest.read(fromDirectory: source)
        let (id, directoryName, idIsPathDerived) = Self.resolveIdentity(
            manifest: manifest, source: source, root: root, publicKey: publicKey
        )

        let destination = root.appendingPathComponent(directoryName, isDirectory: true)
        // A comma here would corrupt --load-extension; must not be weakened.
        guard !destination.path.contains(",") else {
            throw ExtensionStoreError.pathContainsComma(destination)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        var moved = false
        if consumingSource {
            moved = (try? FileManager.default.moveItem(at: source, to: destination)) != nil
        }
        if !moved {
            try FileManager.default.copyItem(at: source, to: destination)
        }

        if let publicKey {
            try rewriteManifestKey(inDirectory: destination, key: publicKey)
        }

        return StagedInstall(
            id: id, directoryName: directoryName, sourcePath: source.path,
            manifest: manifest, idIsPathDerived: idIsPathDerived
        )
    }

    // Fast: an in-memory record append plus a small JSON persist — stays on the main actor.
    public func finalizeInstall(_ staged: StagedInstall) throws -> LoadedExtension {
        let record = ExtensionRecord(
            id: staged.id,
            directoryName: staged.directoryName,
            name: staged.manifest.name,
            version: staged.manifest.version,
            manifestVersion: staged.manifest.manifestVersion,
            hasToolbarAction: staged.manifest.hasToolbarAction,
            iconRelativePath: staged.manifest.iconRelativePath,
            isEnabled: true,
            installedAt: Date(),
            sourcePath: staged.sourcePath,
            idIsPathDerived: staged.idIsPathDerived
        )

        records.removeAll { $0.id == record.id }
        records.append(record)
        try persist()

        let loaded = loadedExtension(from: record)
        notify(.installed(loaded))
        return loaded
    }

    // notify(.uninstalled) must complete before the directory is deleted, or the
    // still-running extension is left pointing at unlinked files.
    public func remove(id: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw ExtensionStoreError.notInstalled(id)
        }
        let removed = records.remove(at: index)
        try persist()
        notify(.uninstalled(id: id))

        let directory = directory(of: removed)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func removeAllExtensions() throws {
        for id in records.map(\.id) { try remove(id: id) }
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw ExtensionStoreError.notInstalled(id)
        }
        let changed = records[index].isEnabled != enabled
        records[index].isEnabled = enabled
        try persist()
        guard changed else { return }
        let loaded = loadedExtension(from: records[index])
        notify(loaded.isEnabled ? .enabled(loaded) : .disabled(loaded))
    }

    // MARK: - Activation

    public func enabledDirectories() -> [URL] {
        enabledInstallations().map(\.directory)
    }

    // ExtensionRuntime needs the id alongside the directory: a keyless
    // install's directory is not named after its id.
    public func enabledInstallations() -> [(id: String, directory: URL)] {
        records
            .filter(\.isEnabled)
            .map { (id: $0.id, directory: directory(of: $0)) }
            .filter { !$0.directory.path.contains(",") }
    }

    public func markActivated(ids: [String]) {
        activatedIDs = Set(ids)
    }

    public var hasPendingChanges: Bool {
        guard let activatedIDs else { return false }
        let currentlyEnabled = Set(records.filter(\.isEnabled).map(\.id))
        return currentlyEnabled != activatedIDs
    }

    // MARK: - Persistence

    private struct ExtensionRecord: Codable {
        var id: String
        // Absent in records written before a keyless install's id stopped
        // being its directory name; for those the two were the same.
        var directoryName: String?
        var name: String
        var version: String
        var manifestVersion: Int
        var hasToolbarAction: Bool
        var iconRelativePath: String?
        var isEnabled: Bool
        var installedAt: Date
        var sourcePath: String
        var idIsPathDerived: Bool
    }

    private func installedJSONURL() -> URL {
        root.appendingPathComponent("installed.json")
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: installedJSONURL(), options: .atomic)
    }

    private static func loadRecords(root: URL) -> [ExtensionRecord] {
        let url = root.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ExtensionRecord].self, from: data) else { return [] }

        let pruned = decoded.filter { record in
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(record.directoryName ?? record.id, isDirectory: true).path
            )
        }

        if pruned.count != decoded.count {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(pruned) {
                try? data.write(to: url, options: .atomic)
            }
        }

        return pruned
    }

    // MARK: - Manifest rewriting

    nonisolated private static func rewriteManifestKey(inDirectory directory: URL, key: String) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionStoreError.manifestInvalid(
                manifestURL,
                "The top-level JSON value is not an object."
            )
        }
        json["key"] = key
        let rewritten = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try rewritten.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Mapping

    private func directory(of record: ExtensionRecord) -> URL {
        root.appendingPathComponent(record.directoryName ?? record.id, isDirectory: true)
    }

    private func loadedExtension(from record: ExtensionRecord) -> LoadedExtension {
        let directory = directory(of: record)
        let iconURL = record.iconRelativePath.map { directory.appendingPathComponent($0) }
        return LoadedExtension(
            id: record.id,
            name: record.name,
            version: record.version,
            directory: directory,
            iconURL: iconURL,
            hasToolbarAction: record.hasToolbarAction,
            manifestVersion: record.manifestVersion,
            isEnabled: record.isEnabled
        )
    }
}

public enum ExtensionStoreError: LocalizedError, Equatable {
    case manifestMissing(URL)
    case manifestUnreadable(URL, String)
    case manifestInvalid(URL, String)
    case notInstalled(String)
    case pathContainsComma(URL)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing(let url):
            return "No manifest.json was found at \(url.path)."
        case .manifestUnreadable(let url, let reason):
            return "manifest.json at \(url.path) could not be read: \(reason)"
        case .manifestInvalid(let url, let reason):
            return "manifest.json at \(url.path) is not a valid Chrome extension manifest: \(reason)"
        case .notInstalled(let id):
            return "No extension with id \"\(id)\" is installed."
        case .pathContainsComma(let url):
            return "\(url.path) contains a comma, which would corrupt Chromium's --load-extension switch."
        }
    }
}
