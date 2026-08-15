import Foundation

nonisolated public enum DownloadItemProjection {

    public static func itemsJSON(for downloads: [DownloadItem], fileManager: FileManager = .default) -> String {
        let objects = itemsObject(for: downloads, fileManager: fileManager)
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    public static func itemsObject(for downloads: [DownloadItem], fileManager: FileManager = .default) -> [[String: Any]] {
        downloads.compactMap { download in
            download.apiID == nil ? nil : item(for: download, fileManager: fileManager)
        }
    }

    public static func item(for download: DownloadItem, fileManager: FileManager = .default) -> [String: Any] {
        let source = download.sourceURL.absoluteString
        var item: [String: Any] = [
            "id": download.apiID ?? 0,
            "guid": download.id.uuidString.lowercased(),
            "url": source,
            "finalUrl": source,
            "filename": download.destinationURL.path,
            "mime": download.mimeType,
            "startTime": download.startedAt.timeIntervalSince1970,
            "endTime": download.finishedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "state": state(for: download.state),
            "paused": download.state == .paused,
            "bytesReceived": Double(download.receivedBytes),
            "totalBytes": Double(download.totalBytes),
            "exists": fileManager.fileExists(atPath: download.destinationURL.path),
        ]
        if download.state == .cancelled {
            item["error"] = "USER_CANCELED"
        }
        return item
    }

    private static func state(for state: DownloadState) -> String {
        switch state {
        case .pending, .inProgress, .paused: return "in_progress"
        case .completed: return "complete"
        case .cancelled, .interrupted: return "interrupted"
        }
    }
}
