import AppKit
import Foundation
import Observation

nonisolated public struct DownloadsFile: Codable, Sendable {

    public var nextAPIID: Int
    public var items: [DownloadItem]
    /// Not encoded: true only for a file written before the counter existed.
    public var isLegacyShape: Bool

    private enum CodingKeys: String, CodingKey {
        case nextAPIID
        case items
    }

    public init(nextAPIID: Int = 1, items: [DownloadItem] = [], isLegacyShape: Bool = false) {
        self.nextAPIID = nextAPIID
        self.items = items
        self.isLegacyShape = isLegacyShape
    }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([DownloadItem].self) {
            self.init(nextAPIID: 1, items: legacy, isLegacyShape: true)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            nextAPIID: try container.decodeIfPresent(Int.self, forKey: .nextAPIID) ?? 1,
            items: try container.decodeIfPresent([DownloadItem].self, forKey: .items) ?? []
        )
    }
}

@MainActor
@Observable
public final class DownloadStore {

    public private(set) var downloads: [DownloadItem] = []

    private let writer: AtomicJSONFileWriter<DownloadsFile>

    private var nextAPIID: Int = 1

    public init(fileURL: URL = DownloadStore.defaultFileURL) {
        self.writer = AtomicJSONFileWriter(fileURL: fileURL)
        let file = writer.loadNow(default: DownloadsFile())
        self.downloads = file.items
        // max, not the stored counter alone: a hand-edited or restored-from-backup file must skip ids, never reuse one.
        self.nextAPIID = max(file.nextAPIID, (file.items.compactMap(\.apiID).max() ?? 0) + 1)
        if !backfillAPIIDsOnLoad(), file.isLegacyShape {
            saveNowIgnoringFailure()
        }
        verifyFilesExistOnLoad()
    }

    public nonisolated static var defaultFileURL: URL { OrbitDataRoot.processDefault.downloadsFile }

    // MARK: - Lifecycle

    @discardableResult
    public func beginDownload(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL,
        suggestedFileName: String,
        mimeType: String = "",
        totalBytes: Int64 = 0
    ) -> DownloadItem {
        let item = DownloadItem(
            id: id,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            suggestedFileName: suggestedFileName,
            mimeType: mimeType,
            totalBytes: totalBytes,
            receivedBytes: 0,
            state: .inProgress,
            apiID: allocateAPIID()
        )
        downloads.insert(item, at: 0)
        persist()
        return item
    }

    private func allocateAPIID() -> Int {
        let id = nextAPIID
        nextAPIID += 1
        return id
    }

    private func backfillAPIIDsOnLoad() -> Bool {
        let unassigned = downloads.indices
            .filter { downloads[$0].apiID == nil }
            .sorted {
                let left = downloads[$0], right = downloads[$1]
                if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
                return left.id.uuidString < right.id.uuidString
            }
        guard !unassigned.isEmpty else { return false }
        for index in unassigned {
            downloads[index].apiID = allocateAPIID()
        }
        saveNowIgnoringFailure()
        return true
    }

    public func updateProgress(id: UUID, progress: DownloadProgress) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].receivedBytes = progress.receivedBytes
        if progress.totalBytes > 0 { downloads[index].totalBytes = progress.totalBytes }
        downloads[index].state = progress.state
        switch progress.state {
        case .completed, .cancelled, .interrupted:
            downloads[index].finishedAt = Date()
        case .pending, .inProgress, .paused:
            break
        }
        persist()
    }

    public func cancel(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = .cancelled
        downloads[index].finishedAt = Date()
        persist()
    }

    public func remove(_ id: UUID) {
        downloads.removeAll { $0.id == id }
        persist()
    }

    public func clearList() {
        downloads.removeAll { item in
            switch item.state {
            case .completed, .cancelled, .interrupted: return true
            case .pending, .inProgress, .paused: return false
            }
        }
        persist()
    }

    // Drops every record, including in-progress ones. The files on disk are left alone.
    public func removeAllRecords() {
        guard !downloads.isEmpty else { return }
        downloads.removeAll()
        persist()
    }

    // MARK: - Renaming (Assist, Tidy Downloads)

    @discardableResult
    public func renameFile(id: UUID, to newFileName: String) -> URL? {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return nil }
        guard downloads[index].state == .completed else { return nil }

        let current = downloads[index].destinationURL
        let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }

        let directory = current.deletingLastPathComponent()
        let proposed = directory.appendingPathComponent(trimmed)
        guard proposed != current else { return nil }
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }

        let target = DownloadStore.uniqueDestination(in: directory, suggestedName: trimmed)
        do {
            try FileManager.default.moveItem(at: current, to: target)
        } catch {
            return nil
        }
        downloads[index].destinationURL = target
        persist()
        return target
    }

    // MARK: - Deleting the file on disk

    /// Deletes the file only: a completed download whose file is gone stays completed, exactly as it does after a Finder delete.
    @discardableResult
    public func removeFile(_ id: UUID) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return false }
        guard downloads[index].state == .completed else { return false }
        do {
            try FileManager.default.removeItem(at: downloads[index].destinationURL)
        } catch {
            return false
        }
        return true
    }

    // suggestedName is untrusted (page-controlled); must be sanitized before appendingPathComponent to prevent path traversal outside directory.
    static func uniqueDestination(in directory: URL, suggestedName: String) -> URL {
        var candidate = directory.appendingPathComponent(sanitizedFileName(suggestedName))
        if !isContained(candidate.standardizedFileURL, in: directory.standardizedFileURL) {
            candidate = directory.appendingPathComponent("download")
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var counter = 1
        repeat {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func sanitizedFileName(_ suggestedName: String) -> String {
        let leaf = (suggestedName as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return "download" }
        return leaf
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let candidate = url.pathComponents
        let root = directory.pathComponents
        guard candidate.count > root.count else { return false }
        return Array(candidate.prefix(root.count)) == root
    }

    // MARK: - Finder integration

    public func revealInFinder(_ id: UUID) {
        guard let item = downloads.first(where: { $0.id == id }) else { return }
        if FileManager.default.fileExists(atPath: item.destinationURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL.deletingLastPathComponent()])
        }
    }

    public func fileStillExists(_ id: UUID) -> Bool {
        guard let item = downloads.first(where: { $0.id == id }) else { return false }
        return FileManager.default.fileExists(atPath: item.destinationURL.path)
    }

    private func verifyFilesExistOnLoad() {
        var changed = false
        for index in downloads.indices where downloads[index].state == .completed {
            if !FileManager.default.fileExists(atPath: downloads[index].destinationURL.path) {
                downloads[index].state = .interrupted
                changed = true
            }
        }
        if changed { persist() }
    }

    public func saveNow() throws {
        try writer.saveNow(currentFile)
    }

    private var currentFile: DownloadsFile {
        DownloadsFile(nextAPIID: nextAPIID, items: downloads)
    }

    private func saveNowIgnoringFailure() {
        try? writer.saveNow(currentFile)
    }

    private func persist() {
        writer.scheduleSave(currentFile)
    }
}
