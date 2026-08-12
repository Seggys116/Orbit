import XCTest

final class BlockingModalTestHazardGuardTests: XCTestCase {

    private struct Hazard {
        let name: String
        let pattern: String
    }

    private static let hazards: [Hazard] = [
        Hazard(name: "NSMenu popUp (modal menu-tracking loop)", pattern: #"\.popUp\s*\("#),

        Hazard(name: "runModal (blocking modal session)", pattern: #"\.runModal\s*\("#),

        Hazard(name: "beginModalSession (manual modal-session pump)", pattern: #"\bbeginModalSession\s*\("#),
        Hazard(name: "runModalSession (manual modal-session pump)", pattern: #"\.runModalSession\s*\("#),

        Hazard(name: "beginSheetModal (real on-screen sheet)", pattern: #"\bbeginSheetModal\s*\("#),
    ]

    private static let exemptionMarker = "ORBIT-BLOCKING-MODAL-SELF-TERMINATES:"

    private func rootsToScan() throws -> [URL] {
        let repositoryRoot = URL(fileURLWithPath: #filePath) // OrbitAppTests/BlockingModalTestHazardGuardTests.swift
            .deletingLastPathComponent()                      // OrbitAppTests/
            .deletingLastPathComponent()                       // repository root
        return ["OrbitTests", "OrbitAppTests", "OrbitDemo"]
            .map { repositoryRoot.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testNoTestSourceCallsABlockingAppKitModalAPIUnexempted() throws {
        let roots = try rootsToScan()
        XCTAssertFalse(roots.isEmpty, "None of OrbitTests/, OrbitAppTests/, OrbitDemo/ were found on disk — this guard's own root resolution is broken.")

        var offences: [String] = []
        var filesScanned = 0

        for root in roots {
            for fileURL in try Self.swiftFiles(under: root) {
                guard fileURL.lastPathComponent != "BlockingModalTestHazardGuardTests.swift" else { continue }
                guard try !Self.isSymbolicLink(fileURL) else { continue }
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    XCTFail("Could not read \(fileURL.path) to scan for blocking modal calls.")
                    continue
                }
                filesScanned += 1

                let originalLines = contents.components(separatedBy: "\n")
                let strippedLines = Self.sourceStrippingComments(contents).components(separatedBy: "\n")
                guard strippedLines.count == originalLines.count else {
                    XCTFail("Comment-stripping changed \(fileURL.path)'s line count — this guard's line-number bookkeeping is broken and cannot be trusted for this file.")
                    continue
                }

                for hazard in Self.hazards {
                    guard let regex = try? NSRegularExpression(pattern: hazard.pattern) else { continue }
                    for (index, strippedLine) in strippedLines.enumerated() {
                        let range = NSRange(strippedLine.startIndex..<strippedLine.endIndex, in: strippedLine)
                        guard regex.firstMatch(in: strippedLine, range: range) != nil else { continue }

                        let originalLine = originalLines[index]
                        if let markerRange = originalLine.range(of: Self.exemptionMarker) {
                            let explanation = originalLine[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)
                            if !explanation.isEmpty { continue }
                        }

                        let lineNumber = index + 1
                        offences.append("\(Self.relativePath(of: fileURL)):\(lineNumber) — \(hazard.name)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(filesScanned, 0, "Scanned zero .swift files across \(roots.map(\.path)) — this guard's directory walk is broken (it should find hundreds).")

        XCTAssertTrue(
            offences.isEmpty,
            """
            The following test-tree source line(s) call a blocking AppKit modal API directly, \
            which hangs an unattended run waiting for a human to click a button that will never \
            come: \(offences.joined(separator: "; ")). Fix it the way this repository already \
            fixes this defect elsewhere — build the real control/menu and invoke its target/action \
            directly instead of presenting it (see `Orbit/UI/Content/OrbitContextMenu.swift`'s \
            `buildContextMenuEntries` vs `presentContextMenu`, and \
            `OrbitAppTests/OrbitPopupButtonTests.swift`), or assert the pure decision function a \
            delegate call would consult instead of driving the delegate call itself (see \
            `AppEnvironment.refusalWithoutPrompting(for:)` and \
            `OrbitAppTests/SiteControlWiringTests.swift`'s notification-permission tests). If this \
            call site is a rare, genuine exception that provably ends itself without a human — see \
            this file's header — annotate its exact line with \
            "\(Self.exemptionMarker) <why, and how it self-terminates>".
            """
        )
    }

    // MARK: - Directory walk

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink ?? false
    }

    private static func relativePath(of url: URL) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootPath = repositoryRoot.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    // MARK: - Comment stripping (same technique as `TestFileCoverageGuardTests`)
    private static func sourceStrippingComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var inLineComment = false
        var blockDepth = 0
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let following: Character? = next < source.endIndex ? source[next] : nil

            if character == "\n" {
                inLineComment = false
                out.append(character)
                index = next
                continue
            }
            if inLineComment {
                out.append(" ")
                index = next
                continue
            }
            if blockDepth > 0 {
                if character == "*", following == "/" {
                    blockDepth -= 1
                    out.append("  ")
                    index = source.index(after: next)
                    continue
                }
                if character == "/", following == "*" {
                    blockDepth += 1
                    out.append("  ")
                    index = source.index(after: next)
                    continue
                }
                out.append(" ")
                index = next
                continue
            }
            if character == "/", following == "/" {
                inLineComment = true
                out.append("  ")
                index = source.index(after: next)
                continue
            }
            if character == "/", following == "*" {
                blockDepth = 1
                out.append("  ")
                index = source.index(after: next)
                continue
            }
            out.append(character)
            index = next
        }
        return out
    }
}
