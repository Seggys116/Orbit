import AppKit
import Foundation
#if DEBUG
import OSLog
#endif

@MainActor
public final class FaviconCache {

    private let memoryCache = NSCache<NSString, NSImage>()
    let diskDirectory: URL
    private var inFlightTasks: [String: Task<NSImage, Never>] = [:]

    // pendingDiskWork chains each mutation after the last, so a discarded
    // import's removes finish before a fresh import's writes.
    private let diskStore: FaviconDiskStore
    private var pendingDiskWork: Task<Void, Never>?

    public init(
        diskDirectory: URL = FaviconCache.defaultDiskDirectory,
        memoryCountLimit: Int = 300,
        diskCapBytes: Int64 = 25 * 1024 * 1024
    ) {
        self.diskDirectory = diskDirectory
        self.diskStore = FaviconDiskStore(diskDirectory: diskDirectory, diskCapBytes: diskCapBytes)
        memoryCache.countLimit = memoryCountLimit
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public nonisolated static var defaultDiskDirectory: URL { OrbitDataRoot.processDefault.favicons }

    // The cache a FaviconView falls back to when no owning AppEnvironment has
    // injected its own. Rooted at the process default, so in the Orbit Demo
    // app or an XCTest host it is a scratch directory, never the real profile.
    static let processDefault = FaviconCache()

    // MARK: - Synchronous lookup

    public func cachedImage(forHost host: String) -> NSImage? {
        let key = host.lowercased() as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let url = diskURL(forHost: host)
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
            return nil
        }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Direct caching (engine-provided images)

    // Persists to the real, shared on-disk cache. Test fixtures must use cacheInMemoryOnly instead, or they permanently overwrite real sites' icons.
    public func cache(_ image: NSImage, forHost host: String) {
        store(image, forHost: host)
    }

    public func cacheInMemoryOnly(_ image: NSImage, forHost host: String) {
        memoryCache.setObject(image, forKey: host.lowercased() as NSString)
    }

    // MARK: - Imported icons (encoded bytes)

    /// Accepts whatever another browser stored — PNG or ICO — and reports false when the bytes aren't a usable image.
    @discardableResult
    public func cache(imageData: Data, forHost host: String) -> Bool {
        guard let image = FaviconCache.decodedImage(imageData) else { return false }
        store(image, forHost: host)
        return true
    }

    /// One eviction pass for the whole batch; evicting per icon rescans the directory once per file.
    @discardableResult
    public func cache(imageDataByHost icons: [String: Data]) -> Int {
        var toWrite: [(host: String, image: NSImage)] = []
        for (host, data) in icons {
            guard let image = FaviconCache.decodedImage(data) else { continue }
            let key = host.lowercased()
            memoryCache.setObject(image, forKey: key as NSString)
            toWrite.append((key, image))
        }
        if !toWrite.isEmpty {
            enqueueWriteBatchThenEvict(toWrite)
        }
        return toWrite.count
    }

    // MARK: - Browser import

    private var importManifestURL: URL {
        diskDirectory.appendingPathComponent("imported-hosts.json", isDirectory: false)
    }

    /// Discards what the last import wrote before writing this one — a wrong icon already on disk outlives any fix to the reader that produced it.
    @discardableResult
    public func cacheImported(imageDataByHost icons: [String: Data]) -> Int {
        discardPreviousImport()

        var toWrite: [(host: String, image: NSImage)] = []
        for (host, data) in icons {
            guard let image = FaviconCache.decodedImage(data) else { continue }
            let key = host.lowercased()
            memoryCache.setObject(image, forKey: key as NSString)
            toWrite.append((key, image))
        }

        if let manifest = try? JSONEncoder().encode(toWrite.map(\.host).sorted()) {
            try? manifest.write(to: importManifestURL, options: .atomic)
        }
        if !toWrite.isEmpty {
            enqueueWriteBatchThenEvict(toWrite)
        }
        return toWrite.count
    }

    public func removeCachedImage(forHost host: String) {
        let key = host.lowercased()
        memoryCache.removeObject(forKey: key as NSString)
        let store = diskStore
        enqueueDiskWork { await store.remove(host: key) }
    }

    private func discardPreviousImport() {
        guard let manifest = try? Data(contentsOf: importManifestURL),
              let hosts = try? JSONDecoder().decode([String].self, from: manifest)
        else {
            // No manifest means the cache predates import tracking, so any file in it may be an icon an earlier import filed under the wrong host.
            removeAllIcons()
            return
        }
        for host in hosts { removeCachedImage(forHost: host) }
    }

    private nonisolated static func decodedImage(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    // MARK: - Async fetch

    public func image(for faviconURL: URL?, host: String) async -> NSImage {
        if let cached = cachedImage(forHost: host) {
            return cached
        }

        let key = host.lowercased()
        if let existing = inFlightTasks[key] {
            return await existing.value
        }
        guard !isInFailureCooldown(host: key) else {
            return FaviconCache.fallbackIcon(forHost: host)
        }

        let task = Task<NSImage, Never> { [weak self] in
            guard let self else { return FaviconCache.fallbackIcon(forHost: host) }
            if let resolved = await self.resolve(faviconURL: faviconURL, host: host) {
                self.store(resolved, forHost: host)
                return resolved
            }
            self.beginFailureCooldown(host: key)
            return FaviconCache.fallbackIcon(forHost: host)
        }
        inFlightTasks[key] = task
        let result = await task.value
        inFlightTasks[key] = nil
        return result
    }

    // Must stay true under XCTest: FaviconView renders in many pixel-diff tests, and unguarded resolution would fire real network requests on every one.
    private nonisolated static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func resolve(faviconURL: URL?, host: String) async -> NSImage? {
        guard !FaviconCache.isHostingTests else { return nil }
        for candidate in FaviconCache.wellKnownIconURLs(faviconURL: faviconURL, host: host) {
            if let image = await download(candidate) { return image }
        }
        for candidate in await declaredIconURLs(forHost: host) {
            if let image = await download(candidate) { return image }
        }
        return nil
    }

    nonisolated static func wellKnownIconURLs(faviconURL: URL?, host: String) -> [URL] {
        var candidates: [URL] = []
        if let faviconURL { candidates.append(faviconURL) }

        if let wellKnown = URL(string: "https://\(host)/favicon.ico"),
           wellKnown.host() != nil,
           host.contains("."),
           !host.contains("/"),
           !host.contains(" ") {
            candidates.append(wellKnown)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private nonisolated func declaredIconURLs(forHost host: String) async -> [URL] {
        guard let home = URL(string: "https://\(host)/"), home.host() != nil else { return [] }
        guard let html = await FaviconCache.fetchDocumentHead(home) else { return [] }
        return FaviconCache.iconURLs(inHTML: html, relativeTo: home)
    }

    nonisolated static let downloadTimeout: TimeInterval = 6

    private func download(_ url: URL) async -> NSImage? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = FaviconCache.downloadTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Reading the site's own markup

    private nonisolated static let maximumDocumentHeadBytes = 512 * 1024

    private nonisolated static func fetchDocumentHead(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = downloadTimeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count >= maximumDocumentHeadBytes { break }
                if buffer.count % 1024 == 0, FaviconCache.containsHeadTerminator(buffer) { break }
            }
            return String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private nonisolated static func containsHeadTerminator(_ data: Data) -> Bool {
        guard let text = String(data: data.suffix(2048), encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        return lowered.contains("</head") || lowered.contains("<body")
    }

    nonisolated static func iconURLs(inHTML html: String, relativeTo base: URL) -> [URL] {
        var candidates: [(url: URL, weight: Int, order: Int)] = []
        var seen = Set<String>()

        for (order, tag) in linkTags(in: html).enumerated() {
            let attributes = attributes(inTag: tag)
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon") else { continue }
            guard !rel.contains("mask-icon") else { continue }
            guard let href = attributes["href"], !href.isEmpty else { continue }
            guard let resolved = URL(string: decodingHTMLEntities(href), relativeTo: base)?.absoluteURL else { continue }
            guard resolved.scheme == "https" || resolved.scheme == "http" else { continue }
            guard seen.insert(resolved.absoluteString).inserted else { continue }

            let declared = largestDeclaredSize(attributes["sizes"])
            let weight = declared ?? (rel.contains("apple-touch-icon") ? 180 : 0)
            candidates.append((resolved, weight, order))
        }

        return candidates
            .sorted { $0.weight == $1.weight ? $0.order < $1.order : $0.weight > $1.weight }
            .map(\.url)
    }

    private nonisolated static func linkTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
    }

    private nonisolated static func attributes(inTag tag: String) -> [String: String] {
        let pattern = "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\">]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [:] }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var attributes: [String: String] = [:]
        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            for group in 2...4 {
                if let valueRange = Range(match.range(at: group), in: tag) {
                    attributes[name] = String(tag[valueRange])
                    break
                }
            }
        }
        return attributes
    }

    private nonisolated static func largestDeclaredSize(_ sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let edges = sizes.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { token -> Int? in
                guard let edge = token.split(separator: "x").first else { return nil }
                return Int(edge)
            }
        return edges.max()
    }

    private nonisolated static func decodingHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Failure cooldown

    static let failureCooldown: TimeInterval = 60

    private var failedHosts: [String: Date] = [:]

    private func isInFailureCooldown(host key: String) -> Bool {
        guard let failedAt = failedHosts[key] else { return false }
        guard Date().timeIntervalSince(failedAt) < FaviconCache.failureCooldown else {
            failedHosts[key] = nil
            return false
        }
        return true
    }

    private func beginFailureCooldown(host key: String) {
        failedHosts[key] = Date()
    }

    // MARK: - Storage / eviction

    // The memory cache is updated inline, so a synchronous cachedImage(forHost:)
    // call right after this returns still finds the image; only the PNG encode,
    // the atomic disk write and the eviction scan move to the background actor.
    private func store(_ image: NSImage, forHost host: String) {
        let key = host.lowercased()
        memoryCache.setObject(image, forKey: key as NSString)
        let store = diskStore
        enqueueDiskWork {
            await store.write(image, forHost: key)
            await store.evictIfNeeded()
        }
    }

    private func diskURL(forHost host: String) -> URL {
        FaviconDiskStore.diskURL(forHost: host, in: diskDirectory)
    }

    /// Runs a batch of writes on the background actor followed by a single eviction pass, chained after whatever disk work is already queued.
    private func enqueueWriteBatchThenEvict(_ items: [(host: String, image: NSImage)]) {
        let store = diskStore
        enqueueDiskWork {
            for item in items {
                await store.write(item.image, forHost: item.host)
            }
            await store.evictIfNeeded()
        }
    }

    /// Chains `work` after whatever disk work is already queued, so removes, writes and eviction scans on the same cache never race each other even though none of them run on the main actor.
    private func enqueueDiskWork(_ work: @escaping @Sendable () async -> Void) {
        let previous = pendingDiskWork
        pendingDiskWork = Task.detached {
            _ = await previous?.value
            await work()
        }
    }

    // MARK: - Test seam

    /// Awaits every disk write, remove and eviction scan queued so far. Production code never needs this — the memory cache is always current — but a test that reopens the same directory in a fresh FaviconCache has no memory cache to fall back on and needs the background write to have actually landed.
    func _test_awaitPendingWrites() async {
        await pendingDiskWork?.value
    }

    // MARK: - Bulk clear

    public func removeAll() {
        inFlightTasks.removeAll()
        removeAllIcons()
        let manifestURL = importManifestURL
        enqueueDiskWork { try? FileManager.default.removeItem(at: manifestURL) }
    }

    private func removeAllIcons() {
        memoryCache.removeAllObjects()
        let store = diskStore
        enqueueDiskWork { await store.removeAllPNGs() }
    }

    // MARK: - Generated fallback icon

    public nonisolated static func fallbackIcon(forHost host: String, size: CGFloat = 32) -> NSImage {
        let displayHost = host.isEmpty ? "?" : host
        let letter = String(displayHost.first ?? "?").uppercased()
        let color = deterministicColor(for: displayHost)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22)
        color.setFill()
        path.fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.52, weight: .semibold),
            .foregroundColor: color.contrastingForegroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        let textSize = letter.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size - textSize.width) / 2,
            y: (size - textSize.height) / 2 - size * 0.02,
            width: textSize.width,
            height: textSize.height
        )
        letter.draw(in: textRect, withAttributes: attributes)

        return image
    }

    private nonisolated static func deterministicColor(for host: String) -> NSColor {
        let hash = fnv1aHash(host)
        let hue = Double(hash % 360) / 360.0
        return NSColor(calibratedHue: hue, saturation: 0.52, brightness: 0.62, alpha: 1.0)
    }

    private nonisolated static func fnv1aHash(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// The disk side of FaviconCache: PNG encoding, atomic writes, removes and the
/// eviction scan, all off the main actor. Every FaviconCache instance owns
/// exactly one of these, and FaviconCache serialises access to it through
/// `enqueueDiskWork` rather than through the actor's own scheduling.
private actor FaviconDiskStore {
    private let diskDirectory: URL
    private let diskCapBytes: Int64

    init(diskDirectory: URL, diskCapBytes: Int64) {
        self.diskDirectory = diskDirectory
        self.diskCapBytes = diskCapBytes
    }

    nonisolated static func diskURL(forHost host: String, in directory: URL) -> URL {
        let safeName = host.lowercased()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directory.appendingPathComponent("\(safeName).png", isDirectory: false)
    }

    func write(_ image: NSImage, forHost host: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: FaviconDiskStore.diskURL(forHost: host, in: diskDirectory), options: .atomic)
    }

    func remove(host: String) {
        try? FileManager.default.removeItem(at: FaviconDiskStore.diskURL(forHost: host, in: diskDirectory))
    }

    func removeAllPNGs() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "png" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func evictIfNeeded() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in urls where url.pathExtension == "png" {
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
        }
    }
}

private extension NSColor {
    var contrastingForegroundColor: NSColor {
        let rgb = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1.0) : NSColor.white
    }
}

#if DEBUG
private let faviconSelfCheckLogger = Logger(subsystem: "com.orbit.browser", category: "FaviconSelfCheck")

extension FaviconCache {
    func runSelfCheck() {
        let host = "orbit-self-check.invalid"
        let probe = FaviconCache.fallbackIcon(forHost: host, size: 32)
        store(probe, forHost: host)

        let expectedURL = diskURL(forHost: host)
        Task { [weak self] in
            guard let self else { return }
            // store() queued the probe's write on the background actor; wait
            // for it so this diagnostic reads the real outcome, not a race.
            await self._test_awaitPendingWrites()

            let exists = FileManager.default.fileExists(atPath: expectedURL.path)
            let readable = NSImage(contentsOf: expectedURL) != nil

            faviconSelfCheckLogger.info("""
            diskDirectory=\(self.diskDirectory.path, privacy: .public) \
            directoryExists=\(FileManager.default.fileExists(atPath: self.diskDirectory.path)) \
            probeFile=\(expectedURL.path, privacy: .public) \
            probeFileExists=\(exists) probeFileReadable=\(readable)
            """)

            try? FileManager.default.removeItem(at: expectedURL)
            self.memoryCache.removeObject(forKey: host as NSString)
        }
    }
}
#endif
