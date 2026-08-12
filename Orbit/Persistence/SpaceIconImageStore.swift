import AppKit
import Foundation
import UniformTypeIdentifiers
#if DEBUG
import OSLog
#endif

@MainActor
public final class SpaceIconImageStore {

    private let memoryCache = NSCache<NSString, NSImage>()
    let diskDirectory: URL
    private let diskCapBytes: Int64

    public init(
        diskDirectory: URL = SpaceIconImageStore.defaultDiskDirectory,
        memoryCountLimit: Int = 60,
        diskCapBytes: Int64 = 200 * 1024 * 1024
    ) {
        self.diskDirectory = diskDirectory
        self.diskCapBytes = diskCapBytes
        memoryCache.countLimit = memoryCountLimit
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public nonisolated static var defaultDiskDirectory: URL { OrbitDataRoot.processDefault.spaceIcons }

    // MARK: - Bounds

    public static let maxSourceFileBytes = 10 * 1024 * 1024

    // Checked against decoded NSImage.size before any drawing: guards against a "pixel bomb" (e.g. an SVG viewBox claiming an enormous canvas).
    public static let maxSourceDimension = 8000

    public static let storedDimension = 256

    static let acceptedExtensions: Set<String> = ["png", "svg", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]

    public static let acceptedContentTypes: [UTType] = [.png, .svg, .jpeg, .gif, .tiff, .bmp, .webP, .heic]

    // MARK: - Errors

    public enum ImportError: Swift.Error, LocalizedError, Sendable, Equatable {
        case sourceUnreadable
        case unsupportedFileType(extension: String)
        case notAnImage
        case fileTooLarge(actualBytes: Int, maxBytes: Int)
        case dimensionsTooLarge(actualPoints: CGFloat, maxPoints: CGFloat)
        case emptyImage
        case rasterizationFailed
        case writeFailed(underlying: String)

        public var errorDescription: String? {
            switch self {
            case .sourceUnreadable:
                return "Orbit couldn't read that file."
            case .unsupportedFileType(let ext):
                return "\".\(ext)\" isn't a supported image type. Choose a PNG, SVG, JPEG, GIF, TIFF, BMP, HEIC or WebP file."
            case .notAnImage:
                return "That file isn't a valid image Orbit can read."
            case .fileTooLarge(let actual, let max):
                let actualMB = Double(actual) / 1024 / 1024
                let maxMB = Double(max) / 1024 / 1024
                return String(format: "That image is %.1f MB, which is larger than the %.0f MB limit for a Space icon.", actualMB, maxMB)
            case .dimensionsTooLarge(let actual, let max):
                return "That image is \(Int(actual))×\(Int(actual)) points, which is larger than the \(Int(max))×\(Int(max)) limit for a Space icon."
            case .emptyImage:
                return "That image has no visible size."
            case .rasterizationFailed:
                return "Orbit couldn't process that image."
            case .writeFailed(let underlying):
                return "Orbit couldn't save that image (\(underlying))."
            }
        }
    }

    // MARK: - Import

    @discardableResult
    public func importImage(fromFileAt sourceURL: URL) throws -> SpaceIconImageID {
        let ext = sourceURL.pathExtension.lowercased()
        guard SpaceIconImageStore.acceptedExtensions.contains(ext) else {
            throw ImportError.unsupportedFileType(extension: ext.isEmpty ? sourceURL.lastPathComponent : ext)
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let fileSize = attributes[.size] as? Int
        else {
            throw ImportError.sourceUnreadable
        }
        guard fileSize <= SpaceIconImageStore.maxSourceFileBytes else {
            throw ImportError.fileTooLarge(actualBytes: fileSize, maxBytes: SpaceIconImageStore.maxSourceFileBytes)
        }
        guard fileSize > 0, let data = try? Data(contentsOf: sourceURL) else {
            throw ImportError.sourceUnreadable
        }

        return try importImage(data: data, sourceExtension: ext)
    }

    @discardableResult
    func importImage(data: Data, sourceExtension: String) throws -> SpaceIconImageID {
        guard data.count <= SpaceIconImageStore.maxSourceFileBytes else {
            throw ImportError.fileTooLarge(actualBytes: data.count, maxBytes: SpaceIconImageStore.maxSourceFileBytes)
        }

        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-space-icon-import-\(UUID().uuidString).\(sourceExtension.isEmpty ? "img" : sourceExtension)")
        defer { try? FileManager.default.removeItem(at: scratchURL) }
        do {
            try data.write(to: scratchURL, options: .atomic)
        } catch {
            throw ImportError.sourceUnreadable
        }

        guard let image = NSImage(contentsOf: scratchURL), !image.representations.isEmpty else {
            throw ImportError.notAnImage
        }

        guard image.size.width > 0, image.size.height > 0 else {
            throw ImportError.emptyImage
        }
        let maxDimension = CGFloat(SpaceIconImageStore.maxSourceDimension)
        guard image.size.width <= maxDimension, image.size.height <= maxDimension else {
            throw ImportError.dimensionsTooLarge(actualPoints: max(image.size.width, image.size.height), maxPoints: maxDimension)
        }

        guard let png = SpaceIconImageStore.rasterize(image, to: SpaceIconImageStore.storedDimension) else {
            throw ImportError.rasterizationFailed
        }

        let id = SpaceIconImageID()
        do {
            try png.write(to: diskURL(for: id), options: .atomic)
        } catch {
            throw ImportError.writeFailed(underlying: error.localizedDescription)
        }

        if let normalized = NSImage(data: png) {
            memoryCache.setObject(normalized, forKey: id.uuidString as NSString)
        }
        evictDiskCacheIfNeeded()
        return id
    }

    // MARK: - Lookup

    public func cachedImage(for id: SpaceIconImageID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let url = diskURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
            return nil
        }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Single-id deletion

    public func deleteImage(for id: SpaceIconImageID) {
        try? FileManager.default.removeItem(at: diskURL(for: id))
        memoryCache.removeObject(forKey: id.uuidString as NSString)
    }

    // MARK: - Garbage collection

    public func pruneOrphaned(keeping liveImageIDs: Set<SpaceIconImageID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) else { return }
        let liveNames = Set(liveImageIDs.map { "\($0.uuidString).png" })
        for url in urls where !liveNames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            if let id = SpaceIconImageStore.imageID(fromDiskFilename: url.lastPathComponent) {
                memoryCache.removeObject(forKey: id.uuidString as NSString)
            }
        }
    }

    private static func imageID(fromDiskFilename filename: String) -> SpaceIconImageID? {
        UUID(uuidString: (filename as NSString).deletingPathExtension)
    }

    // MARK: - Rasterization

    private static func rasterize(_ image: NSImage, to dimension: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: dimension,
            pixelsHigh: dimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: dimension, height: dimension)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let sourceSize = image.size
        let scale = min(CGFloat(dimension) / sourceSize.width, CGFloat(dimension) / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = NSPoint(x: (CGFloat(dimension) - drawSize.width) / 2, y: (CGFloat(dimension) - drawSize.height) / 2)
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1.0
        )

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Disk

    private func diskURL(for id: SpaceIconImageID) -> URL {
        diskDirectory.appendingPathComponent("\(id.uuidString).png", isDirectory: false)
    }

    private func evictDiskCacheIfNeeded() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast
            entries.append((url, size, date))
            total += size
        }
        guard total > diskCapBytes else { return }

        var remaining = total
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard remaining > diskCapBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining -= entry.size
            if let id = SpaceIconImageStore.imageID(fromDiskFilename: entry.url.lastPathComponent) {
                memoryCache.removeObject(forKey: id.uuidString as NSString)
            }
        }
    }
}

#if DEBUG
private let spaceIconSelfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "SpaceIconSelfCheck")

extension SpaceIconImageStore {
    func runSelfCheck() {
        let probeImage = NSImage(size: NSSize(width: 4, height: 4))
        probeImage.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        probeImage.unlockFocus()
        guard let tiff = probeImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            spaceIconSelfCheckLogger.error("SpaceIconImageStore self-check: could not synthesize a probe PNG.")
            return
        }

        do {
            let id = try importImage(data: png, sourceExtension: "png")
            let expectedURL = diskURL(for: id)
            let exists = FileManager.default.fileExists(atPath: expectedURL.path)
            let readable = cachedImage(for: id) != nil
            spaceIconSelfCheckLogger.info("""
            diskDirectory=\(self.diskDirectory.path, privacy: .public) \
            directoryExists=\(FileManager.default.fileExists(atPath: self.diskDirectory.path)) \
            probeFile=\(expectedURL.path, privacy: .public) \
            probeFileExists=\(exists) probeFileReadable=\(readable)
            """)
            try? FileManager.default.removeItem(at: expectedURL)
            memoryCache.removeObject(forKey: id.uuidString as NSString)
        } catch {
            spaceIconSelfCheckLogger.error("SpaceIconImageStore self-check: probe import failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
