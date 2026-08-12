//  Proves PNG/SVG import against real files on real disk, with SVG's rasterized
//  pixels actually inspected rather than merely checking import didn't throw.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class SpaceIconImageStoreTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: SpaceIconImageStore!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-SpaceIconImageStore-\(UUID().uuidString)", isDirectory: true)
        store = SpaceIconImageStore(diskDirectory: scratchDirectory)
    }

    override func tearDown() {
        store = nil
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeOrangePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor(calibratedRed: 1, green: 0.4, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("could not synthesize a PNG fixture on this machine")
        }
        return png
    }

    private static let sampleSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
      <circle cx="32" cy="32" r="28" fill="#FF6600"/>
      <rect x="2" y="2" width="10" height="10" fill="#0000FF"/>
    </svg>
    """

    private func write(_ string: String, extension ext: String) throws -> URL {
        let url = scratchDirectory.appendingPathComponent("fixture-\(UUID().uuidString).\(ext)")
        try string.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func write(_ data: Data, extension ext: String) throws -> URL {
        let url = scratchDirectory.appendingPathComponent("fixture-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: - 1. PNG import → retrieval round trip

    func test_importPNG_roundTripsAndIsRetrievable() throws {
        let png = try makeOrangePNGData()
        let fileURL = try write(png, extension: "png")

        let id = try store.importImage(fromFileAt: fileURL)

        let retrieved = try XCTUnwrap(store.cachedImage(for: id), "the just-imported image must be retrievable by the id importImage returned")
        XCTAssertGreaterThan(retrieved.size.width, 0)
        XCTAssertGreaterThan(retrieved.size.height, 0)

        let reopened = SpaceIconImageStore(diskDirectory: scratchDirectory)
        XCTAssertNotNil(reopened.cachedImage(for: id), "the imported image must survive as a real file on disk, not just in the in-memory cache")
    }

    // MARK: - 2. SVG import → retrieval round trip, pixels inspected

    func test_importSVG_rasterizesRealShapesAtRealPixels() throws {
        let fileURL = try write(Self.sampleSVG, extension: "svg")

        let id = try store.importImage(fromFileAt: fileURL)
        let retrieved = try XCTUnwrap(store.cachedImage(for: id))

        guard let tiff = retrieved.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            XCTFail("the retrieved image has no bitmap representation to sample")
            return
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)

        let centre = try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2))
        XCTAssertEqual(centre.redComponent, 1.0, accuracy: 0.15, "the SVG's orange circle did not rasterize at the image's centre — SVG import is not producing real pixels")
        XCTAssertEqual(centre.greenComponent, 0.4, accuracy: 0.15)
        XCTAssertEqual(centre.blueComponent, 0.0, accuracy: 0.15)
        XCTAssertGreaterThan(centre.alphaComponent, 0.5, "the centre must be opaque")

        let outsideEverything = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1))
        XCTAssertLessThan(outsideEverything.alphaComponent, 0.5, "a point outside every shape in the source SVG rasterized as non-transparent — the whole canvas may just be getting filled")
    }

    func test_importSVG_throughTheFileBasedEntryPoint_succeeds() throws {
        let fileURL = try write(Self.sampleSVG, extension: "svg")
        let id = try store.importImage(fromFileAt: fileURL)
        XCTAssertNotNil(store.cachedImage(for: id))
    }

    func test_svgSourceFileCanBeDeletedAfterImport_iconStillRetrievable() throws {
        let fileURL = try write(Self.sampleSVG, extension: "svg")
        let id = try store.importImage(fromFileAt: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        XCTAssertNotNil(store.cachedImage(for: id), "the icon must not depend on the original picked file still existing")
    }

    // MARK: - 3. Rejection paths

    func test_importGarbageData_throwsNotAnImage() throws {
        let fileURL = try write(Data("this is not an image, just plain text bytes".utf8), extension: "png")
        XCTAssertThrowsError(try store.importImage(fromFileAt: fileURL)) { error in
            guard let importError = error as? SpaceIconImageStore.ImportError, importError == .notAnImage else {
                XCTFail("expected .notAnImage, got \(error)")
                return
            }
        }
    }

    func test_importEmptyFile_throwsRatherThanSilentlyDoingNothing() throws {
        let fileURL = try write(Data(), extension: "png")
        XCTAssertThrowsError(try store.importImage(fromFileAt: fileURL))
    }

    func test_importOversizedFile_throwsFileTooLarge() throws {
        let oversized = Data(repeating: 0x41, count: SpaceIconImageStore.maxSourceFileBytes + 1)
        let fileURL = try write(oversized, extension: "png")
        XCTAssertThrowsError(try store.importImage(fromFileAt: fileURL)) { error in
            guard let importError = error as? SpaceIconImageStore.ImportError,
                  case .fileTooLarge(let actual, let max) = importError
            else {
                XCTFail("expected .fileTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(actual, oversized.count)
            XCTAssertEqual(max, SpaceIconImageStore.maxSourceFileBytes)
        }
    }

    func test_importSVGWithHugeDeclaredDimensions_throwsDimensionsTooLarge() throws {
        let hugeDimension = SpaceIconImageStore.maxSourceDimension + 5000
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(hugeDimension)\" height=\"\(hugeDimension)\"><rect width=\"\(hugeDimension)\" height=\"\(hugeDimension)\" fill=\"red\"/></svg>"
        let fileURL = try write(svg, extension: "svg")

        XCTAssertThrowsError(try store.importImage(fromFileAt: fileURL)) { error in
            guard let importError = error as? SpaceIconImageStore.ImportError,
                  case .dimensionsTooLarge(let actual, let max) = importError
            else {
                XCTFail("expected .dimensionsTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(actual, CGFloat(hugeDimension), accuracy: 0.5)
            XCTAssertEqual(max, CGFloat(SpaceIconImageStore.maxSourceDimension))
        }
    }

    func test_importUnsupportedExtension_throwsUnsupportedFileType() throws {
        let fileURL = try write("hello", extension: "txt")
        XCTAssertThrowsError(try store.importImage(fromFileAt: fileURL)) { error in
            guard let importError = error as? SpaceIconImageStore.ImportError,
                  case .unsupportedFileType(let ext) = importError
            else {
                XCTFail("expected .unsupportedFileType, got \(error)")
                return
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    func test_everyImportError_hasARealLocalizedDescription() {
        let errors: [SpaceIconImageStore.ImportError] = [
            .sourceUnreadable,
            .unsupportedFileType(extension: "pdf"),
            .notAnImage,
            .fileTooLarge(actualBytes: 20_000_000, maxBytes: 10_000_000),
            .dimensionsTooLarge(actualPoints: 9000, maxPoints: 8000),
            .emptyImage,
            .rasterizationFailed,
            .writeFailed(underlying: "disk full"),
        ]
        for error in errors {
            let description = error.errorDescription
            XCTAssertNotNil(description, "\(error) has no errorDescription")
            XCTAssertFalse(description?.isEmpty ?? true, "\(error) has an empty errorDescription")
        }
    }

    // MARK: - 4. Unknown id

    func test_cachedImage_returnsNilForAnIDNothingWasEverImportedUnder() {
        XCTAssertNil(store.cachedImage(for: SpaceIconImageID()))
    }

    // MARK: - Garbage collection

    func test_pruneOrphaned_removesEverythingNotInTheLiveSet() throws {
        let png = try makeOrangePNGData()
        let keptID = try store.importImage(fromFileAt: try write(png, extension: "png"))
        let orphanedID = try store.importImage(fromFileAt: try write(png, extension: "png"))

        store.pruneOrphaned(keeping: [keptID])

        XCTAssertNotNil(store.cachedImage(for: keptID), "an id in the live set must survive pruning")
        XCTAssertNil(store.cachedImage(for: orphanedID), "an id not in the live set must be removed by pruning")
    }
}
