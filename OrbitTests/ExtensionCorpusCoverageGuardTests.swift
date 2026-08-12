// Asserts every available pin in Chromium/extension-corpus.json has a live suite
// driving it, and that no corpus test reaches OrbitDataRoot.production. Host-less.

import XCTest

final class ExtensionCorpusCoverageGuardTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    private struct CorpusEntry {
        var id: String
        var name: String
        var version: String?
        var sha256: String?
        var unavailable: String?
        var exercises: String
        var expectation: String
        var unreachedExpectation: String?
        var blockedBy: String?
    }

    private static let liveTestsDirectory = Schema.repositoryFile("OrbitAppTests")

    private func corpus() throws -> [CorpusEntry] {
        let url = Schema.repositoryFile("Chromium/extension-corpus.json")
        let object = try Schema.readObject(url)
        guard let raw = object["extensions"] as? [[String: Any]] else {
            throw Schema.SchemaError.malformed(url, "missing the \"extensions\" list")
        }
        return raw.map {
            CorpusEntry(
                id: $0["id"] as? String ?? "",
                name: $0["name"] as? String ?? "",
                version: $0["version"] as? String,
                sha256: $0["sha256"] as? String,
                unavailable: $0["unavailable"] as? String,
                exercises: $0["exercises"] as? String ?? "",
                expectation: $0["expectation"] as? String ?? "",
                unreachedExpectation: $0["unreached_expectation"] as? String,
                blockedBy: $0["blocked_by"] as? String
            )
        }
    }

    /// extension id -> the live suites naming it. A suite driving a corpus extension
    /// must assert the id against the pin, so containing the literal marks it.
    private func suitesNamingEachExtension() throws -> [String: [String]] {
        let identifiers = try corpus().map(\.id).filter { !$0.isEmpty }
        var claims: [String: [String]] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.liveTestsDirectory.path).sorted()
        where name.hasSuffix("LiveTests.swift") {
            let url = Self.liveTestsDirectory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for identifier in identifiers where text.contains(identifier) {
                claims[identifier, default: []].append(name)
            }
        }
        return claims
    }

    // MARK: - The manifest itself

    func test_theCorpusManifestIsPopulatedAndEveryEntryIsPinnedByHash() throws {
        let entries = try corpus()
        XCTAssertGreaterThan(entries.count, 4, "the corpus has only \(entries.count) entries; a corpus that small cannot represent 'any extension works'")
        for entry in entries {
            XCTAssertFalse(entry.id.isEmpty, "a corpus entry has no id")
            XCTAssertFalse(
                entry.exercises.isEmpty,
                "\(entry.name) is pinned with no note on what it exercises, so nobody can tell what its absence would cost"
            )
            XCTAssertFalse(
                entry.expectation.isEmpty,
                "\(entry.name) is pinned with no definition of what \"working\" means for it. An entry without one is a download, not a test."
            )
            if entry.unavailable == nil {
                XCTAssertNotNil(entry.version, "\(entry.name) is pinned to no version")
                let hash = entry.sha256 ?? ""
                XCTAssertEqual(
                    hash.count, 64,
                    "\(entry.name) has no SHA-256. An extension that silently updates turns the suite into a flake generator, so every pin is by hash and `Scripts/extension-corpus fetch` fails closed on a mismatch."
                )
            } else {
                XCTAssertNotNil(
                    entry.unavailable,
                    "\(entry.name) has no version and no explanation of why it could not be pinned"
                )
            }
        }
    }

    // MARK: - Coverage

    func test_everyAvailableCorpusExtensionIsDrivenByALiveSuite() throws {
        let claims = try suitesNamingEachExtension()
        let undriven = try corpus()
            .filter { $0.unavailable == nil && $0.version != nil }
            .filter { claims[$0.id] == nil }
            .map { "\($0.name) (\($0.id)) — expectation: \($0.expectation)" }
            .sorted()
        XCTAssertEqual(
            undriven, [],
            "these extensions are pinned in Chromium/extension-corpus.json and no live suite drives them. Add one in OrbitAppTests, named *LiveTests.swift, that resolves it through ExtensionCorpus and performs the pinned expectation. A pinned-but-undriven corpus is the same failure as a fixture: it looks like coverage and tests nothing."
        )
    }

    func test_anUnavailableCorpusEntryRecordsWhyRatherThanBeingQuietlyDropped() throws {
        for entry in try corpus() where entry.unavailable != nil {
            XCTAssertGreaterThan(
                (entry.unavailable ?? "").count, 5,
                "\(entry.name) is recorded unavailable with no reason. Deleting the entry instead would hide a real coverage hole: whatever it was pinned to exercise — \(entry.exercises) — is now exercised by nothing."
            )
        }
    }

    /// Suites that drive a pinned extension without resolving it through
    /// ExtensionCorpus. Each one is loading bytes nobody hashed, from a path
    /// that exists on one machine, so its pin proves nothing.
    private static let unpinnedDriverExceptions: [String: String] = [:]

    func test_everyCorpusSuiteResolvesItsSubjectThroughTheVendoredCorpus() throws {
        let claims = try suitesNamingEachExtension()
        var unpinned: [String] = []
        for name in Set(claims.values.flatMap { $0 }).sorted() {
            guard Self.unpinnedDriverExceptions[name] == nil else { continue }
            let text = (try? String(contentsOf: Self.liveTestsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            if !text.contains("ExtensionCorpus") { unpinned.append(name) }
        }
        XCTAssertEqual(
            unpinned, [],
            "these suites drive a pinned corpus extension without resolving it through ExtensionCorpus, so they load bytes nobody verified against the manifest's SHA-256. Pinning exists because an extension that silently updates turns the suite into a flake generator; a driver that ignores the pin gets the flakiness back and the reassurance of a hash."
        )
        let repaired = Self.unpinnedDriverExceptions.keys.filter { name in
            let text = (try? String(contentsOf: Self.liveTestsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.contains("ExtensionCorpus")
        }.sorted()
        XCTAssertEqual(
            repaired, [],
            "these suites now resolve through ExtensionCorpus and are still listed as exceptions. Delete their entries from unpinnedDriverExceptions — an exception list that outlives its reason stops being read."
        )
    }

    func test_everyExpectationTheSuiteCannotYetReachNamesWhatBlocksIt() throws {
        for entry in try corpus() where entry.unreachedExpectation != nil {
            XCTAssertGreaterThan(
                (entry.blockedBy ?? "").count, 20,
                "\(entry.name) records an expectation its suite does not reach and does not say what blocks it. An unreached expectation with no blocker is indistinguishable from one nobody got round to, and this file is where the difference has to be written down."
            )
        }
    }

    // MARK: - Shared engine state

    private func corpusSuiteFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.liveTestsDirectory.path)
            .filter { $0.hasPrefix("Corpus") && $0.hasSuffix("LiveTests.swift") }
            .sorted()
    }

    /// Every live suite shares one engine, so a suite leaving an extension loaded or
    /// the content blocker armed fails a later suite by name. Enforces CorpusLiveTestCase.
    func test_everyCorpusSuiteRestoresTheSharedEngineStateItBorrows() throws {
        let files = try corpusSuiteFiles()
        XCTAssertGreaterThan(files.count, 4, "found only \(files.count) corpus suites, so this guard would barely test anything")

        var wrongBase: [String] = []
        for name in files {
            let text = (try? String(contentsOf: Self.liveTestsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            if !text.contains(": CorpusLiveTestCase {") { wrongBase.append(name) }
        }
        XCTAssertEqual(
            wrongBase, [],
            "these corpus suites do not subclass CorpusLiveTestCase, so nothing puts back the shared engine state they borrow: an extension left loaded filters the next suite's pages, and Orbit's own content blocker — which arms itself from EasyList the first time any suite opens a tab — answers the next suite's negative control. Both have already happened."
        )
    }

    func test_everyCorpusSuiteUnloadsEveryExtensionItLoads() throws {
        var unbalanced: [String] = []
        for name in try corpusSuiteFiles() {
            let text = (try? String(contentsOf: Self.liveTestsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            let loads = text.components(separatedBy: ".loadExtension(at:").count - 1
            let unloads = text.components(separatedBy: ".unloadExtension(id:").count - 1
            if loads != unloads { unbalanced.append("\(name): \(loads) load(s), \(unloads) unload(s)") }
        }
        XCTAssertEqual(
            unbalanced, [],
            "these corpus suites load an extension into the shared engine more often than they unload one. Pair every load with `defer { engine.unloadExtension(id:session:) }` on the next line; CorpusLiveTestCase fails the suite at teardown if anything is still loaded, but only after it has already run under an extension it did not ask for."
        )
    }

    // MARK: - Profile safety

    func test_noCorpusSuiteReachesForTheUsersRealProfile() throws {
        let claims = try suitesNamingEachExtension()
        let corpusFiles = Set(claims.values.flatMap { $0 })
        XCTAssertFalse(corpusFiles.isEmpty, "found no corpus suites at all, so this guard would pass vacuously")

        var offenders: [String] = []
        for name in corpusFiles.sorted() {
            let url = Self.liveTestsDirectory.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("OrbitDataRoot.production") || text.contains("EngineStorageDirectory.productionProfile") {
                offenders.append(name)
            }
        }
        XCTAssertEqual(
            offenders, [],
            "a corpus suite reaches for the production data root. Under XCTest every store already resolves to a per-process scratch directory and the live host builds its engine with storage: .isolated; naming the production root defeats both and points a test that installs and uninstalls real extensions at the user's own profile."
        )
    }
}
