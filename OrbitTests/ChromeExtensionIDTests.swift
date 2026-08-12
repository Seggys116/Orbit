import XCTest

final class ChromeExtensionIDTests: XCTestCase {

    // MARK: - A vector that runs everywhere, unconditionally

    func test_derivesTheCorrectIDForAFixedHardcodedKey_noArcInstallRequired() throws {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        let id = try XCTUnwrap(
            ChromeExtensionID.id(fromPublicKeyBase64: key),
            "A well-formed base64 key must always decode."
        )
        XCTAssertEqual(id, "gdanmncjggmeddggjbbcfeeilllcflep")
        XCTAssertTrue(ChromeExtensionID.isValid(id), "A derived id must always satisfy the algorithm's own validity check.")
    }

    func test_idFromPublicKeyBase64_returnsNilForMalformedBase64() {
        XCTAssertNil(ChromeExtensionID.id(fromPublicKeyBase64: "not valid base64!!"))
        XCTAssertNil(ChromeExtensionID.id(fromPublicKeyBase64: ""))
        XCTAssertNil(ChromeExtensionID.id(fromPublicKeyBase64: "   "))
    }

    // MARK: - Verified against a real Arc profile, 2026-08-05

    /// Skips (does not fail) when Arc is not installed.
    func test_derivesTheExactIDArcAssignedForEveryRealSignedExtension() throws {
        let securePreferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data/Default/Secure Preferences")

        guard let data = try? Data(contentsOf: securePreferencesURL) else {
            throw XCTSkip("Arc is not installed on this machine (\(securePreferencesURL.path) not found).")
        }
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let extensionsDict = root["extensions"] as? [String: Any],
            let settings = extensionsDict["settings"] as? [String: Any]
        else {
            throw XCTSkip("Arc's Secure Preferences did not have the expected extensions.settings shape.")
        }

        var checkedCount = 0
        for (extensionID, rawEntry) in settings {
            guard
                let entry = rawEntry as? [String: Any],
                let manifest = entry["manifest"] as? [String: Any],
                let key = manifest["key"] as? String
            else {
                continue
            }

            let derivedID = ChromeExtensionID.id(fromPublicKeyBase64: key)
            let name = manifest["name"] as? String ?? "?"
            XCTAssertEqual(
                derivedID, extensionID,
                """
                ChromeExtensionID.id(fromPublicKeyBase64:) derived \(derivedID ?? "nil") for \
                "\(name)", but Arc itself stores this entry under id \(extensionID). Chromium \
                would load a copy of this extension into a directory keyed by \(extensionID); \
                Orbit's importer would compute a different one and never find it again.
                """
            )
            checkedCount += 1
        }

        XCTAssertGreaterThan(
            checkedCount, 0,
            "Found zero extensions.settings entries with a manifest.key in this machine's real Arc profile — this test proves nothing without at least one, and refs/ARC_PROFILES.md §0.1 recorded eight on this exact machine."
        )
    }

    // MARK: - isValid boundaries

    func test_isValid_acceptsExactlyThirtyTwoLowercaseAThroughPCharacters() {
        XCTAssertTrue(ChromeExtensionID.isValid(String(repeating: "a", count: 32)))
        XCTAssertTrue(ChromeExtensionID.isValid(String(repeating: "p", count: 32)))
        XCTAssertTrue(ChromeExtensionID.isValid("abcdefghijklmnopabcdefghijklmnop"))
    }

    func test_isValid_rejectsTheWrongLength() {
        XCTAssertFalse(ChromeExtensionID.isValid(String(repeating: "a", count: 31)), "31 characters is one short.")
        XCTAssertFalse(ChromeExtensionID.isValid(String(repeating: "a", count: 33)), "33 characters is one long.")
        XCTAssertFalse(ChromeExtensionID.isValid(""))
    }

    func test_isValid_rejectsAnyCharacterOutsideAThroughP() {
        XCTAssertFalse(ChromeExtensionID.isValid(String(repeating: "a", count: 31) + "q"))
        XCTAssertFalse(ChromeExtensionID.isValid(String(repeating: "a", count: 31) + "0"))
        XCTAssertFalse(ChromeExtensionID.isValid(String(repeating: "a", count: 31) + "A"))
        XCTAssertFalse(ChromeExtensionID.isValid(UUID().uuidString), "A real UUID must not be mistaken for a Chromium extension id.")
    }

    // MARK: - id(forUnpackedPath:)

    func test_idForUnpackedPath_isStableForTheSamePath() {
        let path = URL(fileURLWithPath: "/tmp/orbit-fixture/unpacked-extension-a")
        XCTAssertEqual(
            ChromeExtensionID.id(forUnpackedPath: path),
            ChromeExtensionID.id(forUnpackedPath: path),
            "The same path must derive the same id every time — ExtensionStore relies on this to recognise an extension it already installed at that path."
        )
    }

    func test_idForUnpackedPath_differsForADifferentPath() {
        let pathA = URL(fileURLWithPath: "/tmp/orbit-fixture/unpacked-extension-a")
        let pathB = URL(fileURLWithPath: "/tmp/orbit-fixture/unpacked-extension-b")
        XCTAssertNotEqual(
            ChromeExtensionID.id(forUnpackedPath: pathA),
            ChromeExtensionID.id(forUnpackedPath: pathB),
            "Two different unpacked extensions at two different paths must not collide on the same install-directory id."
        )
    }

    // Vectors are SHA-256 over the realpath-resolved path, matching UnpackedInstaller.
    // /tmp is a symlink to /private/tmp on macOS; hashing the unresolved spelling
    // produces an id the engine never runs anything under -- the next test pins this.
    func test_idForUnpackedPath_matchesIndependentlyComputedVectors() {
        XCTAssertEqual(
            ChromeExtensionID.id(forUnpackedPath: URL(fileURLWithPath: "/private/tmp/orbit-fixture/unpacked-extension-a")),
            "fhcfgdpfpdcnjfgdagnhoecdoljfichn"
        )
        XCTAssertEqual(
            ChromeExtensionID.id(forUnpackedPath: URL(fileURLWithPath: "/private/tmp/orbit-fixture/unpacked-extension-b")),
            "nnnhllejjohejmbdoojbookbckhkpnkj"
        )
    }

    func test_idForUnpackedPath_resolvesSymlinkedAncestorsTheWayChromiumDoes() {
        XCTAssertEqual(
            ChromeExtensionID.id(forUnpackedPath: URL(fileURLWithPath: "/tmp/orbit-fixture/unpacked-extension-a")),
            ChromeExtensionID.id(forUnpackedPath: URL(fileURLWithPath: "/private/tmp/orbit-fixture/unpacked-extension-a")),
            "/tmp is a symlink to /private/tmp; Chromium realpaths the directory before hashing it, so both spellings must derive the one id its chrome-extension:// origin answers to."
        )
    }
}
