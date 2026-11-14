import CryptoKit
import XCTest

final class GlyphPlanetShaderStampTests: XCTestCase {

    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    func testMetallibStampMatchesShaderSource() throws {
        let source = try Data(contentsOf: repoURL("Shaders/GlyphPlanet.metal"))
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let stampText = try String(contentsOf: repoURL("Orbit/Resources/GlyphPlanet.metallib.sha256"), encoding: .utf8)
        let stamp = stampText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            stamp,
            digest,
            "Shaders/GlyphPlanet.metal changed since Orbit/Resources/GlyphPlanet.metallib was built; run Scripts/build-shaders and commit the result."
        )
    }

    func testMetallibIsCheckedIn() throws {
        let library = try Data(contentsOf: repoURL("Orbit/Resources/GlyphPlanet.metallib"))
        XCTAssertFalse(library.isEmpty, "Orbit/Resources/GlyphPlanet.metallib is empty; run Scripts/build-shaders.")
    }
}
