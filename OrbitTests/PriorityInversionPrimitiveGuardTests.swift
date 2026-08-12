//  Scans Orbit/** for primitives libRPAC interposes (dispatch_semaphore_*, dispatch_group_wait,
//  xpc_connection_send_message_with_reply_sync, NSCondition). Don't allow-list reflexively — cross the async boundary.

import XCTest

final class PriorityInversionPrimitiveGuardTests: XCTestCase {

    static let blockingPrimitives: [String] = [
        "DispatchSemaphore",
        "DispatchGroup",
        "dispatch_semaphore_",
        "dispatch_group_wait",
        "NSCondition",
        "xpc_connection_send_message_with_reply_sync",
        "synchronousRemoteObjectProxy",
    ]

    static let allowed: [String] = []

    func test_noShippingSourceBlocksAThreadOnAPrimitiveTheHangCheckerReports() throws {
        let sources = try sourceFiles(under: productionRoot())
        XCTAssertGreaterThan(
            sources.count, 100,
            "Walked \(sources.count) source files under Orbit/. That is far too few — the path resolution below is wrong, and this test is passing because it is looking at nothing."
        )

        var offences: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
            for (line, code) in Self.codeLines(in: text) {
                for primitive in Self.blockingPrimitives where code.contains(primitive) {
                    let entry = "\(relative):\(line): \(primitive) — \(code.trimmingCharacters(in: .whitespaces).prefix(140))"
                    guard !Self.allowed.contains(where: { entry.contains($0) }) else { continue }
                    offences.append(entry)
                }
            }
        }

        XCTAssertEqual(
            offences, [],
            """
            Shipping code now blocks a thread on a primitive the Thread Performance Checker \
            reports. If the waiting thread is ever user-interactive (the main thread is, always) \
            and the work being waited on runs at Default, Utility or Background QoS, Xcode will \
            raise "Thread running at User-interactive quality-of-service class waiting on a lower \
            QoS thread" against Orbit — and it will be Orbit's fault, which until now it never was. \
            Prefer crossing the async boundary. Occurrences:
            \(offences.joined(separator: "\n"))
            """
        )
    }

    // MARK: - The inversion the hang checker CANNOT see

    static let deprioritisedTaskPriorities: [String] = [
        ".detached(priority: .utility",
        ".detached(priority: .background",
        ".detached(priority: .low",
        ".detached(priority: TaskPriority.utility",
        ".detached(priority: TaskPriority.background",
        ".detached(priority: TaskPriority.low",
        "Task(priority: .utility",
        "Task(priority: .background",
        "Task(priority: .low",
        "Task(priority: TaskPriority.utility",
        "Task(priority: TaskPriority.background",
        "Task(priority: TaskPriority.low",
    ]

    static let allowedDeprioritisedTasks: [String] = []

    static func stripAllWhitespace(_ string: String) -> String {
        string.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    func test_noShippingSourceAwaitsWorkItDeliberatelyDeprioritised() throws {
        let sources = try sourceFiles(under: productionRoot())
        XCTAssertGreaterThan(
            sources.count, 100,
            "Walked \(sources.count) source files under Orbit/. That is far too few — the path resolution is wrong and this test is passing because it is looking at nothing."
        )

        var offences: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: productionRoot().path + "/", with: "")
            for (line, source) in Self.deprioritisedTaskLines(in: Self.codeLines(in: text)) {
                let entry = "\(relative):\(line): \(source.trimmingCharacters(in: .whitespaces).prefix(140))"
                guard !Self.allowedDeprioritisedTasks.contains(where: { entry.contains($0) }) else { continue }
                offences.append(entry)
            }
        }

        XCTAssertEqual(
            offences, [],
            """
            Shipping code creates a task at a priority below the main actor's. If anything \
            awaits it, the UI is now waiting on work that was deliberately told to run \
            slowly, and no tool will tell you — the Thread Performance Checker cannot see \
            Swift concurrency at all.

            Use `@concurrent` on a `nonisolated` function and a plain `await`. Do NOT reach \
            for a bare `nonisolated` function: this module builds with \
            SWIFT_APPROACHABLE_CONCURRENCY, so `nonisolated async` is \
            `nonisolated(nonsending)` and runs on the CALLER's executor — which means the \
            main actor. That advice was in this very message once, was followed, and put a \
            second of filter parsing on the main thread during launch.

            If the task is genuinely fire-and-forget, add it to \
            `allowedDeprioritisedTasks` with the reason, having first confirmed nothing \
            awaits it. Occurrences:
            \(offences.joined(separator: "\n"))
            """
        )
    }

    static func deprioritisedTaskLines(
        in scanned: [(line: Int, code: String)]
    ) -> [(line: Int, code: String)] {
        let needles = deprioritisedTaskPriorities.map(stripAllWhitespace)
        var hits: [(line: Int, code: String)] = []

        for index in scanned.indices {
            // Window of 3 lines catches a call wrapped across lines; the tail check avoids reporting the same match against multiple line numbers.
            let end = min(index + 3, scanned.endIndex)
            let window = scanned[index..<end].map(\.code).joined()
            let tail = scanned[min(index + 1, end)..<end].map(\.code).joined()
            let tailNormalised = stripAllWhitespace(tail)
            let normalised = stripAllWhitespace(window)

            if needles.contains(where: { normalised.contains($0) && !tailNormalised.contains($0) }) {
                hits.append(scanned[index])
            }
        }

        return hits
    }

    func test_theScanCatchesEverySpellingThatOnceWalkedPastIt() {
        let sample = """
        // A comment naming Task.detached(priority: .utility) must never count.
        func wrapped() async {
            let a = await Task.detached(
                priority: .utility
            ) { 1 }.value
            let b = await Task<Int, Never>.detached(priority: .background) { 2 }.value
            let c = await Task.detached(priority:\t.low) { 3 }.value
            let d = await Task(priority: .utility) { 4 }.value
            let e = await Task.detached(priority: TaskPriority.background) { 5 }.value
        }
        func acceptable() async {
            let f = await Task.detached(priority: .userInitiated) { 6 }.value
            let g = await Task.detached { 7 }.value
            let h = await Task { 8 }.value
        }
        """

        let hits = Self.deprioritisedTaskLines(in: Self.codeLines(in: sample))
        let flagged = hits.map(\.code).map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(
            hits.count, 5,
            """
            The scan must flag exactly the five deprioritised calls and nothing else. \
            A count above five means the sliding window is reporting one call against \
            several lines; below five means a spelling is walking past. Flagged:
            \(flagged.joined(separator: "\n"))
            """
        )

        XCTAssertTrue(
            flagged.contains { $0.contains("let a = await Task.detached(") },
            "A call wrapped across lines must be reported against its first line. Flagged: \(flagged)"
        )
        XCTAssertTrue(
            flagged.contains { $0.contains("Task<Int, Never>.detached") },
            "An explicitly-parameterised Task must not walk past the scan. Flagged: \(flagged)"
        )
        XCTAssertTrue(
            flagged.contains { $0.contains("let c =") },
            "A tab between `priority:` and its value must not walk past the scan. Flagged: \(flagged)"
        )
        XCTAssertTrue(
            flagged.contains { $0.contains("let d = await Task(priority:") },
            "A structured Task(priority:) inverts exactly as a detached one does and must be flagged. Flagged: \(flagged)"
        )

        XCTAssertFalse(
            flagged.contains { $0.contains("userInitiated") },
            "`.userInitiated` is not below the main actor and must not be flagged. Flagged: \(flagged)"
        )
        XCTAssertFalse(
            flagged.contains { $0.contains("let g =") || $0.contains("let h =") },
            "A task with no priority argument names no priority to be wrong about. Flagged: \(flagged)"
        )
        XCTAssertFalse(
            flagged.contains { $0.hasPrefix("//") },
            "A comment naming the pattern — as this very file does throughout — must never be an offence. Flagged: \(flagged)"
        )
    }

    // MARK: - Scanner self-check

    func test_theScannerSeesCodeAndIgnoresComments() {
        let sample = """
        //  A comment that mentions DispatchSemaphore and NSCondition, which is
        //  how this very file documents the rule, and must never be an offence.
        /* A block comment naming dispatch_semaphore_wait, likewise. */
        import Foundation

        func blocking() {
            let sem = DispatchSemaphore(value: 0)   // trailing comment
            _ = sem.wait(timeout: .now() + 1)
            let group = DispatchGroup()
            group.wait()
            let condition = NSCondition()
            condition.wait()
        }
        """

        let flagged = Self.codeLines(in: sample)
            .flatMap { line, code in
                Self.blockingPrimitives.filter { code.contains($0) }.map { (line, $0) }
            }

        XCTAssertEqual(
            flagged.map(\.1).sorted(),
            ["DispatchGroup", "DispatchSemaphore", "NSCondition"],
            "The scanner must flag every blocking primitive that appears in real code, and must flag nothing that appears only in a comment. Flagged: \(flagged)"
        )

        XCTAssertTrue(
            Self.codeLines(in: sample).contains { $0.code.contains("import Foundation") },
            "The scanner dropped a plain line of code. It is stripping too much, and the real-tree test above would pass vacuously."
        )
    }

    // MARK: - Line extraction

    static func codeLines(in text: String) -> [(line: Int, code: String)] {
        var result: [(Int, String)] = []
        var inBlockComment = false

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            var line = rawLine

            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlockComment = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = String(line[line.startIndex..<start.lowerBound]) + String(line[end.upperBound...])
                } else {
                    line = String(line[line.startIndex..<start.lowerBound])
                    inBlockComment = true
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }

            line = Self.strippingTrailingLineComment(line)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append((index + 1, line))
        }
        return result
    }

    static func strippingTrailingLineComment(_ line: String) -> String {
        var insideLiteral = false
        var escaped = false
        var previous: Character?
        var result = ""
        for character in line {
            if escaped {
                escaped = false
                result.append(character)
                previous = character
                continue
            }
            if character == "\\" && insideLiteral {
                escaped = true
                result.append(character)
                previous = character
                continue
            }
            if character == "\"" { insideLiteral.toggle() }
            if character == "/", previous == "/", !insideLiteral {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }

    // MARK: - Walking the tree

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit")
    }

    private func sourceFiles(under root: URL) throws -> [URL] {
        let extensions: Set<String> = ["swift", "m", "mm", "h", "hpp", "cpp", "cc"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) }
    }
}
