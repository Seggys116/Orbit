import CryptoKit
import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated private final class DirectoryWatcher: @unchecked Sendable {

    private let source: DispatchSourceFileSystemObject

    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { onChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

@MainActor
@Observable
public final class DownloadsFolderIndex {

    public let directory: URL

    public private(set) var items: [DownloadItem] = []

    @ObservationIgnored
    private var itemsByID: [UUID: DownloadItem] = [:]

    @ObservationIgnored
    private var watcher: DirectoryWatcher?

    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    @ObservationIgnored
    private var scanGeneration = 0

    nonisolated static let debounceInterval: Duration = .milliseconds(300)

    nonisolated static let partialSuffixes: Set<String> = ["download", "crdownload", "part", "opdownload", "tmp"]

    public init(directory: URL) {
        self.directory = directory
    }

    public var isWatching: Bool { watcher != nil }

    public func item(id: UUID) -> DownloadItem? {
        itemsByID[id]
    }

    // Scanning starts here, not at init: the first read of ~/Downloads can raise a macOS privacy prompt.
    public func startWatching() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(directory: directory) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        requestRescan()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    public func requestRescan() {
        Task { await rescanNow() }
    }

    public func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            await self.rescanNow()
        }
    }

    /// A scan that finishes after a newer one has started is discarded, so the newest listing always wins.
    public func rescanNow() async {
        scanGeneration += 1
        let generation = scanGeneration
        let directory = directory
        let scanned = await Task.detached(priority: .utility) {
            Self.scan(directory: directory)
        }.value
        guard generation == scanGeneration else { return }
        apply(scanned)
    }

    func forget(_ id: UUID) {
        guard itemsByID[id] != nil else { return }
        apply(items.filter { $0.id != id })
    }

    private func apply(_ scanned: [DownloadItem]) {
        guard scanned != items else { return }
        items = scanned
        itemsByID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Scanning

    nonisolated static func scan(directory: URL) -> [DownloadItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isPackageKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [DownloadItem] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard !partialSuffixes.contains(entry.pathExtension.lowercased()),
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isPackage != true
            else { continue }
            let size = Int64(values.fileSize ?? 0)
            result.append(DownloadItem(
                id: stableID(for: entry),
                sourceURL: whereFromURL(of: entry) ?? entry,
                destinationURL: entry,
                suggestedFileName: entry.lastPathComponent,
                mimeType: UTType(filenameExtension: entry.pathExtension)?.preferredMIMEType ?? "",
                totalBytes: size,
                receivedBytes: size,
                state: .completed,
                startedAt: values.addedToDirectoryDate ?? values.creationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return result.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.destinationURL.lastPathComponent.localizedStandardCompare($1.destinationURL.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated static func stableID(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    nonisolated static func whereFromURL(of file: URL) -> URL? {
        let path = file.path
        let size = getxattr(path, whereFromsAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, whereFromsAttribute, &buffer, size, 0, 0)
        guard read > 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(buffer.prefix(read)), options: [], format: nil),
              let sources = plist as? [String],
              let first = sources.first,
              let url = URL(string: first),
              url.scheme != nil
        else { return nil }
        return url
    }
}
