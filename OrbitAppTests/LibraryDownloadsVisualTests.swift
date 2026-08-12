//  Pixel layer for LibraryDownloadsView: empty state draws nothing, and
//  in-progress/completed/failed rows are visibly distinct from each other.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class LibraryDownloadsVisualTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let size = CGSize(width: 420, height: 100)

    override func setUp() {
        super.setUp()
        LibraryRouter.shared.selectedSection = .downloads
        LibraryRouter.shared.selection = nil
    }

    override func tearDown() {
        LibraryRouter.shared.selectedSection = .downloads
        LibraryRouter.shared.selection = nil
        super.tearDown()
    }

    // MARK: - Empty state draws nothing

    func test_noDownloads_rendersNothingAtAll() {
        XCTAssertTrue(env.downloads.isEmpty, "test precondition: a fresh demo environment starts with no downloads.")
        let rendered = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)
        XCTAssertNil(
            rendered.boundingBoxOfContent(),
            "With no downloads the list must draw nothing at all — EmptyStatePlaceholderTests.swift documents this as a deliberate rule, and this is the first pixel-level proof of it for LibraryDownloadsView."
        )
    }

    // MARK: - A real download actually paints something, in both appearances

    func test_aCompletedDownload_paintsNonBlankContent_inBothAppearances() {
        seedCompletedDownload(in: env)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: appearance)
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    // MARK: - In-progress vs completed vs failed are visibly distinct states

    // One download driven through all three states, not three separately
    // seeded ones: otherwise file name/byte count differences taint the diff.
    func test_inProgressCompletedAndFailedDownloads_eachRenderVisiblyDifferently() throws {
        let id = seedInProgressDownload(in: env)
        let destination = try XCTUnwrap(env.downloads.first { $0.id == id }?.destinationURL)
        try "fixture bytes".write(to: destination, atomically: true, encoding: .utf8)

        let inProgressRender = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)

        env.downloadStore.updateProgress(
            id: id,
            progress: DownloadProgress(receivedBytes: 4_000_000, totalBytes: 4_000_000, bytesPerSecond: 0, state: .completed)
        )
        let completedRender = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)

        env.downloadStore.updateProgress(
            id: id,
            progress: DownloadProgress(receivedBytes: 400_000, totalBytes: 4_000_000, bytesPerSecond: 0, state: .interrupted)
        )
        let interruptedRender = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(inProgressRender, completedRender, size: Self.size),
            "An in-progress download (with a visible progress bar and a Cancel action) rendered identically to a completed one."
        )
        XCTAssertTrue(
            Self.rendersDiffer(completedRender, interruptedRender, size: Self.size),
            "A completed download and a failed one (interrupted, dimmed icon, Retry action) rendered identically."
        )
        XCTAssertTrue(
            Self.rendersDiffer(inProgressRender, interruptedRender, size: Self.size),
            "An in-progress download and a failed one rendered identically."
        )
    }

    // No file on disk here, unlike the transition test above: the row must
    // fall back to the suggested name and Retry action.
    func test_aDownloadThatFailedWithNoFileOnDisk_stillPaintsARow() {
        seedInterruptedDownload(in: env)
        let rendered = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)
        XCTAssertNotNil(
            rendered.boundingBoxOfContent(),
            "A failed download must still be listed — a row the user cannot see is a download they cannot retry or clear."
        )
    }

    // MARK: - Selecting a row actually changes what is rendered

    func test_selectingADownloadRow_rendersDifferentlyThanNoSelection() {
        let id = seedCompletedDownload(in: env)

        LibraryRouter.shared.selection = nil
        let unselected = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)

        LibraryRouter.shared.selection = .download(id)
        let selected = render(LibraryDownloadsView(searchQuery: "").environment(env), size: Self.size, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(unselected, selected, size: Self.size),
            "Selecting the row (LibraryRouter.shared.selection = .download(id)) did not change anything rendered — LibraryRowCard's isSelected fill/border/shadow is not reaching the row."
        )
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedInProgressDownload(in env: AppEnvironment) -> UUID {
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/report.pdf")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString).pdf"),
            suggestedFileName: "report.pdf",
            mimeType: "application/pdf",
            totalBytes: 4_000_000
        )
        env.downloadStore.updateProgress(
            id: item.id,
            progress: DownloadProgress(receivedBytes: 1_200_000, totalBytes: 4_000_000, bytesPerSecond: 500_000, state: .inProgress)
        )
        return item.id
    }

    @discardableResult
    private func seedCompletedDownload(in env: AppEnvironment) -> UUID {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("completed-\(UUID().uuidString).pdf")
        try? "fixture bytes".write(to: destination, atomically: true, encoding: .utf8)
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/completed.pdf")!,
            destinationURL: destination,
            suggestedFileName: "completed.pdf",
            mimeType: "application/pdf",
            totalBytes: 14
        )
        env.downloadStore.updateProgress(
            id: item.id,
            progress: DownloadProgress(receivedBytes: 14, totalBytes: 14, bytesPerSecond: 0, state: .completed)
        )
        return item.id
    }

    @discardableResult
    private func seedInterruptedDownload(in env: AppEnvironment) -> UUID {
        let item = env.downloadStore.beginDownload(
            sourceURL: URL(string: "https://example.com/failed.pdf")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("failed-\(UUID().uuidString).pdf"),
            suggestedFileName: "failed.pdf",
            mimeType: "application/pdf",
            totalBytes: 2_000_000
        )
        env.downloadStore.updateProgress(
            id: item.id,
            progress: DownloadProgress(receivedBytes: 400_000, totalBytes: 2_000_000, bytesPerSecond: 0, state: .interrupted)
        )
        return item.id
    }

    // MARK: - Helpers

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 4
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}
