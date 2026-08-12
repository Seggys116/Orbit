import CryptoKit
import Foundation

// MARK: - Metadata

nonisolated public struct FilterListCacheEntry: Codable, Sendable, Hashable {
    public var listID: String
    public var sourceURLs: [URL]
    public var declaredVersion: String?
    public var declaredTitle: String?
    public var expiresAfter: TimeInterval?
    public var fetchedAt: Date
    public var lastCheckedAt: Date
    public var etag: String?
    public var lastModified: String?
    public var byteCount: Int
    public var contentHash: String

    // Defaults to EasyList's own declared period when the list declares nothing.
    public var staleAfter: Date {
        fetchedAt.addingTimeInterval(expiresAfter ?? (4 * 24 * 60 * 60))
    }

    public func isStale(now: Date = Date()) -> Bool { now >= staleAfter }
}

nonisolated public enum FilterListState: Equatable, Sendable {
    case neverFetched
    case cached(FilterListCacheEntry)
    case stale(FilterListCacheEntry)
    case failed(message: String, previous: FilterListCacheEntry?)
}

// MARK: - Store

public actor FilterListStore {

    public enum StoreError: Error, LocalizedError {
        case httpStatus(Int, URL)
        case notText(URL)

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code, let url):
                return "HTTP \(code) fetching \(url.host ?? url.absoluteString)"
            case .notText(let url):
                return "Response from \(url.host ?? url.absoluteString) was not a filter list"
            }
        }
    }

    private let directory: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var index: [String: FilterListCacheEntry] = [:]
    private var didLoadIndex = false
    private var bundledLists: [String: (entry: FilterListCacheEntry, text: String)] = [:]

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(
        directory: URL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.session = session
        self.now = now
    }

    public static func defaultDirectory() -> URL { OrbitDataRoot.processDefault.contentBlocking }

    // MARK: Index

    private func loadIndexIfNeeded() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.orbitContentBlocking.decode([String: FilterListCacheEntry].self, from: data)
        else { return }
        index = decoded
    }

    private func persistIndex() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.orbitContentBlocking.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func fileURL(for listID: String) -> URL {
        let safe = listID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return directory.appendingPathComponent(String(safe) + ".txt")
    }

    private func compiledCacheURL(for listID: String) -> URL {
        let safe = listID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return directory.appendingPathComponent(String(safe) + ".compiled")
    }

    // MARK: Bundled lists

    // A bundled list is read straight out of the app bundle: it is never
    // fetched, never written to the cache directory, and never stale.
    private func bundledList(_ listID: String) -> (entry: FilterListCacheEntry, text: String)? {
        if let loaded = bundledLists[listID] { return loaded }
        guard let descriptor = FilterListCatalog.descriptor(id: listID), descriptor.isBundled,
              let text = FilterListCatalog.bundledText(for: descriptor),
              let data = text.data(using: .utf8)
        else { return nil }

        let header = Self.parseHeader(text)
        let timestamp = now()
        let entry = FilterListCacheEntry(
            listID: listID,
            sourceURLs: [],
            declaredVersion: header.version,
            declaredTitle: header.title,
            expiresAfter: nil,
            fetchedAt: timestamp,
            lastCheckedAt: timestamp,
            etag: nil,
            lastModified: nil,
            byteCount: data.count,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        let loaded = (entry, text)
        bundledLists[listID] = loaded
        return loaded
    }

    private func bundledState(_ listID: String) -> FilterListState {
        guard let loaded = bundledList(listID) else {
            return .failed(message: "Bundled filter list \(listID) is missing from the app bundle", previous: nil)
        }
        return .cached(loaded.entry)
    }

    private func isBundled(_ listID: String) -> Bool {
        FilterListCatalog.descriptor(id: listID)?.isBundled == true
    }

    // MARK: Reading

    public func states() -> [String: FilterListState] {
        loadIndexIfNeeded()
        var result: [String: FilterListState] = [:]
        for descriptor in FilterListCatalog.all {
            result[descriptor.id] = state(of: descriptor.id)
        }
        return result
    }

    public func state(of listID: String) -> FilterListState {
        if isBundled(listID) { return bundledState(listID) }
        loadIndexIfNeeded()
        guard let entry = index[listID],
              FileManager.default.fileExists(atPath: fileURL(for: listID).path)
        else { return .neverFetched }
        return entry.isStale(now: now()) ? .stale(entry) : .cached(entry)
    }

    public func cachedText(for listID: String) -> String? {
        if isBundled(listID) { return bundledList(listID)?.text }
        loadIndexIfNeeded()
        guard index[listID] != nil else { return nil }
        return try? String(contentsOf: fileURL(for: listID), encoding: .utf8)
    }

    public func cacheEntry(for listID: String) -> FilterListCacheEntry? {
        if isBundled(listID) { return bundledList(listID)?.entry }
        loadIndexIfNeeded()
        return index[listID]
    }

    // Callers must still validate against the list's current contentHash via
    // CompiledFilterListCache.decode; existing here says nothing about validity.
    public func compiledCacheData(for listID: String) -> Data? {
        try? Data(contentsOf: compiledCacheURL(for: listID))
    }

    public func storeCompiledCache(_ data: Data, for listID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: compiledCacheURL(for: listID), options: .atomic)
    }

    // MARK: Fetching

    @discardableResult
    public func update(_ descriptor: FilterListDescriptor, force: Bool = false) async -> FilterListState {
        if descriptor.isBundled { return bundledState(descriptor.id) }
        loadIndexIfNeeded()
        let existing = index[descriptor.id]
        let haveFile = FileManager.default.fileExists(atPath: fileURL(for: descriptor.id).path)

        if !force, let existing, haveFile, !existing.isStale(now: now()) {
            return .cached(existing)
        }

        var combined = ""
        var etag: String?
        var lastModified: String?
        var anyChanged = false

        do {
            for (offset, url) in descriptor.urls.enumerated() {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 30
                if descriptor.urls.count == 1, haveFile, let existing {
                    if let tag = existing.etag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
                    if let modified = existing.lastModified {
                        request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
                    }
                }

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw StoreError.notText(url)
                }

                if http.statusCode == 304, let existing, haveFile {
                    var refreshed = existing
                    refreshed.lastCheckedAt = now()
                    index[descriptor.id] = refreshed
                    persistIndex()
                    return refreshed.isStale(now: now()) ? .stale(refreshed) : .cached(refreshed)
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw StoreError.httpStatus(http.statusCode, url)
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw StoreError.notText(url)
                }
                let head = text.prefix(200)
                guard head.hasPrefix("[Adblock") || head.hasPrefix("!") else {
                    throw StoreError.notText(url)
                }

                anyChanged = true
                if offset == 0 {
                    etag = http.value(forHTTPHeaderField: "ETag")
                    lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                }
                combined += text
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        } catch {
            return .failed(message: error.localizedDescription, previous: existing)
        }

        guard anyChanged, let data = combined.data(using: .utf8) else {
            return .failed(message: "Empty response", previous: existing)
        }

        let header = Self.parseHeader(combined)
        let timestamp = now()
        let entry = FilterListCacheEntry(
            listID: descriptor.id,
            sourceURLs: descriptor.urls,
            declaredVersion: header.version,
            declaredTitle: header.title,
            expiresAfter: header.expires,
            fetchedAt: timestamp,
            lastCheckedAt: timestamp,
            etag: etag,
            lastModified: lastModified,
            byteCount: data.count,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: descriptor.id), options: .atomic)
        } catch {
            return .failed(message: error.localizedDescription, previous: existing)
        }

        index[descriptor.id] = entry
        persistIndex()
        return .cached(entry)
    }

    public func updateAll(ids: Set<String>, force: Bool = false) async -> [String: FilterListState] {
        let descriptors = FilterListCatalog.all.filter { ids.contains($0.id) }
        var results: [String: FilterListState] = [:]
        await withTaskGroup(of: (String, FilterListState).self) { group in
            for descriptor in descriptors {
                group.addTask { [self] in
                    (descriptor.id, await update(descriptor, force: force))
                }
            }
            for await (id, state) in group {
                results[id] = state
            }
        }
        return results
    }

    public func discard(_ listID: String) {
        bundledLists[listID] = nil
        loadIndexIfNeeded()
        index[listID] = nil
        try? FileManager.default.removeItem(at: fileURL(for: listID))
        try? FileManager.default.removeItem(at: compiledCacheURL(for: listID))
        persistIndex()
    }

    // MARK: Header parsing

    struct Header {
        var version: String?
        var title: String?
        var expires: TimeInterval?
    }

    static func parseHeader(_ text: String) -> Header {
        var header = Header()
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += 1
            if lines > 60 { break }
            guard line.hasPrefix("!") else {
                if line.hasPrefix("[Adblock") { continue }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                break
            }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[body.startIndex..<colon].lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "version": header.version = value
            case "title": header.title = value
            case "expires": header.expires = parseExpires(value)
            default: break
            }
        }
        return header
    }

    static func parseExpires(_ value: String) -> TimeInterval? {
        let scanner = Scanner(string: value)
        guard let amount = scanner.scanDouble() else { return nil }
        let rest = value.lowercased()
        if rest.contains("hour") { return amount * 3600 }
        if rest.contains("day") { return amount * 86_400 }
        return nil
    }
}

// MARK: - Coding

extension JSONEncoder {
    nonisolated static var orbitContentBlocking: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var orbitContentBlocking: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
