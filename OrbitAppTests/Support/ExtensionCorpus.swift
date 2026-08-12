//  Reads Chromium/extension-corpus.json and resolves pinned real extensions
//  under ThirdParty/extension-corpus, vendored by `Scripts/extension-corpus fetch`.

import Foundation
import XCTest

enum ExtensionCorpus {

    struct Entry: Decodable, Sendable {
        let id: String
        let name: String
        let version: String?
        let sha256: String?
        let crxBytes: Int?
        let unavailable: String?
        let exercises: String
        let expectation: String
    }

    private struct Manifest: Decodable {
        let unpackRoot: String
        let extensions: [Entry]
    }

    private struct Marker: Decodable {
        let id: String
        let version: String
        let sha256: String
    }

    private struct UnpackedManifest: Decodable {
        let version: String
        let manifestVersion: Int

        private enum CodingKeys: String, CodingKey {
            case version
            case manifestVersion = "manifest_version"
        }
    }

    enum CorpusError: LocalizedError {
        case manifestUnreadable(URL, String)
        case unknownEntry(String, [String])
        case stale(Entry, URL, String)

        var errorDescription: String? {
            switch self {
            case .manifestUnreadable(let url, let reason):
                return "Could not read the extension corpus manifest at \(url.path): \(reason)"
            case .unknownEntry(let name, let known):
                return "\"\(name)\" is not in Chromium/extension-corpus.json. Pinned entries: \(known.joined(separator: ", "))"
            case .stale(let entry, let directory, let reason):
                return """
                \(entry.name) at \(directory.path) does not match the pin in Chromium/extension-corpus.json: \(reason).
                This directory is a leftover from a different build, so the test would be measuring the wrong extension.
                Re-vendor it: Scripts/extension-corpus fetch \(entry.id) --force
                """
            }
        }
    }

    private static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let manifestURL: URL = repositoryRoot.appendingPathComponent("Chromium/extension-corpus.json")

    private static func loadManifest() throws -> Manifest {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw CorpusError.manifestUnreadable(manifestURL, error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Manifest.self, from: data)
        } catch {
            throw CorpusError.manifestUnreadable(manifestURL, String(describing: error))
        }
    }

    static func all() throws -> [Entry] {
        try loadManifest().extensions
    }

    /// The pinned `id`, `version`, `expectation` and notes for one entry,
    /// matched on the manifest's `name` (case- and punctuation-insensitive) or
    /// its exact extension id.
    static func entry(for name: String) throws -> Entry {
        let entries = try all()
        let wanted = slug(name)
        guard let match = entries.first(where: { $0.id == name || slug($0.name) == wanted }) else {
            throw CorpusError.unknownEntry(name, entries.map(\.name))
        }
        return match
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The unpacked `ThirdParty/extension-corpus/<id>-<version>/` directory.
    /// Throws `XCTSkip` when not vendored, a hard `CorpusError` when present
    /// but unpacked from a different build than pinned. Never downloads.
    static func directory(for name: String) throws -> URL {
        let entry = try self.entry(for: name)

        if let unavailable = entry.unavailable, entry.version == nil {
            throw XCTSkip(
                """
                \(entry.name) (\(entry.id)) is recorded unavailable in Chromium/extension-corpus.json: \(unavailable).
                The Chrome Web Store will not serve it, so there is nothing to vendor.
                """
            )
        }

        guard let version = entry.version, let sha256 = entry.sha256 else {
            throw XCTSkip(
                """
                \(entry.name) (\(entry.id)) has no pinned version in Chromium/extension-corpus.json.
                Pin it deliberately, then vendor it:
                  Scripts/extension-corpus pin \(entry.id)
                  Scripts/extension-corpus fetch \(entry.id)
                """
            )
        }

        let root = try loadManifest().unpackRoot
        let directory = repositoryRoot
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent("\(entry.id)-\(version)", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip(
                """
                \(entry.name) \(version) is not vendored on this machine. Nothing downloads at test time, on purpose.
                Run: Scripts/extension-corpus fetch \(entry.id)
                Expected at: \(directory.path)
                """
            )
        }

        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            throw CorpusError.stale(entry, directory, "it contains no manifest.json")
        }

        let markerURL = directory.appendingPathComponent(".orbit-corpus.json")
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Marker.self, from: markerData)
        else {
            throw CorpusError.stale(entry, directory, "it carries no .orbit-corpus.json provenance marker")
        }
        guard marker.sha256 == sha256, marker.version == version, marker.id == entry.id else {
            throw CorpusError.stale(
                entry,
                directory,
                "it was unpacked from \(marker.id) \(marker.version) (sha256 \(marker.sha256)), not the pinned \(entry.id) \(version) (sha256 \(sha256))"
            )
        }

        return directory
    }

    /// Asserts the unpacked `manifest.json` declares the pinned version, so
    /// a leftover directory fails by name. Returns `manifest_version` (2 or 3).
    @discardableResult
    static func verifyManifestVersionMatchesPin(
        for name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let entry = try self.entry(for: name)
        let directory = try self.directory(for: name)
        let unpackedManifestURL = directory.appendingPathComponent("manifest.json")

        let data = try Data(contentsOf: unpackedManifestURL)
        let unpacked = try JSONDecoder().decode(UnpackedManifest.self, from: data)

        XCTAssertEqual(
            unpacked.version,
            entry.version,
            """
            \(entry.name)'s unpacked manifest.json at \(manifestURL.path) declares version \(unpacked.version), \
            but Chromium/extension-corpus.json pins \(entry.version ?? "nothing"). This directory is a different \
            build than the one the expectation was written against - "\(entry.expectation)" - so any result here \
            is meaningless. Re-vendor it: Scripts/extension-corpus fetch \(entry.id) --force
            """,
            file: file,
            line: line
        )

        return unpacked.manifestVersion
    }
}
