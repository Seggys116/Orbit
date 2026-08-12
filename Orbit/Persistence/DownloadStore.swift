import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class DownloadStore {

    public private(set) var downloads: [DownloadItem] = []

    private let writer: AtomicJSONFileWriter<[DownloadItem]>

    public init(fileURL: URL = DownloadStore.defaultFileURL) {
        self.writer = AtomicJSONFileWriter(fileURL: fileURL)
        self.downloads = writer.loadNow(default: [])
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
            state: .inProgress
        )
        downloads.insert(item, at: 0)
        persist()
        return item
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
        try writer.saveNow(downloads)
    }

    private func persist() {
        writer.scheduleSave(downloads)
    }
}
