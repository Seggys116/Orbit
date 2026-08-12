import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum DownloadFileIcon {
    @MainActor
    static func icon(for item: DownloadItem, fileExists: Bool) -> NSImage {
        if fileExists {
            return NSWorkspace.shared.icon(forFile: item.destinationURL.path)
        }
        let ext = item.destinationURL.pathExtension.isEmpty
            ? (item.suggestedFileName as NSString).pathExtension
            : item.destinationURL.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

@MainActor
final class DownloadThumbnailStore {
    static let shared = DownloadThumbnailStore()

    struct Key: Hashable {
        var path: String
        var side: CGFloat
        var scale: CGFloat
        var modified: Date?
    }

    private static let capacity = 64

    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []
    private var refused: Set<Key> = []

    private init() {}

    func cached(for url: URL, side: CGFloat, scale: CGFloat) -> NSImage? {
        cache[key(for: url, side: side, scale: scale)]
    }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        // QuickLook returns a blank document for a path that doesn't exist yet.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let key = key(for: url, side: side, scale: scale)
        if let hit = cache[key] { return hit }
        guard !refused.contains(key) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .all
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            store(representation.nsImage, for: key)
            return representation.nsImage
        } catch {
            refused.insert(key)
            return nil
        }
    }

    private func key(for url: URL, side: CGFloat, scale: CGFloat) -> Key {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Key(path: url.path, side: side, scale: scale, modified: modified)
    }

    private func store(_ image: NSImage, for key: Key) {
        if cache[key] == nil {
            order.append(key)
            while order.count > Self.capacity {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        cache[key] = image
    }
}
