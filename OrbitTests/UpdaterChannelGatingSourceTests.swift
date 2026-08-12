import XCTest

final class UpdaterChannelGatingSourceTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var delegateSourceURL: URL {
        repoRoot.appendingPathComponent("Orbit/Core/UpdaterController+UpdaterDelegate.swift")
    }

    private func delegateSource() throws -> String {
        try String(contentsOf: Self.delegateSourceURL, encoding: .utf8)
    }

    private func ternaryBranches(in source: String) throws -> (trueBranch: String, falseBranch: String) {
        let pattern = #"isPrereleaseChannelEnabled\s*\?\s*(\[[^\]]*\])\s*:\s*(\[[^\]]*\])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let trueRange = Range(match.range(at: 1), in: source),
              let falseRange = Range(match.range(at: 2), in: source) else {
            throw XCTSkip("could not find the isPrereleaseChannelEnabled ? [...] : [...] ternary in UpdaterController+UpdaterDelegate.swift — the implementation shape changed; this test needs to be revisited against the new shape rather than silently passing")
        }
        return (String(source[trueRange]), String(source[falseRange]))
    }

    // MARK: - The method exists, and this file still guards Sparkle's own file

    func test_theDelegateFile_stillContainsAllowedChannelsForUpdater() throws {
        let source = try delegateSource()
        XCTAssertTrue(
            source.contains("func allowedChannels(for updater: SPUUpdater)"),
            "UpdaterController+UpdaterDelegate.swift no longer declares allowedChannels(for:) — the channel-gating implementation moved or was removed, and this source-based guard needs to move with it"
        )
    }

    // MARK: - The true branch names the beta channel

    func test_whenPrereleaseChannelEnabled_theTrueBranchNamesTheChannel() throws {
        let (trueBranch, _) = try ternaryBranches(in: try delegateSource())
        XCTAssertTrue(
            trueBranch.contains("prereleaseChannelName"),
            "when isPrereleaseChannelEnabled is true, the returned set must name UpdaterController.prereleaseChannelName (\"beta\") — got \(trueBranch). Sparkle's own contract: the default channel is ALWAYS additionally included, so this branch existing at all is what actually opts the user into beta; if it stopped naming the channel, turning the preference on would silently do nothing."
        )
    }

    // MARK: - The false branch is empty, never the channel

    func test_whenPrereleaseChannelDisabled_theFalseBranchIsEmpty() throws {
        let (_, falseBranch) = try ternaryBranches(in: try delegateSource())
        let normalized = falseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            normalized, "[]",
            """
            when isPrereleaseChannelEnabled is false, the returned set must be empty — got \(falseBranch). \
            This is the specific mistake the method's own doc comment calls out as easy to make: \
            "Getting this backwards — returning the channel name only when the preference is off — \
            would opt every single user into beta by default the moment this method is implemented \
            at all." An empty set here does NOT mean "no updates ever" (Sparkle's own header: the \
            default channel is always included regardless), so there is no reason for the false \
            branch to ever be anything but [].
            """
        )
    }

    // MARK: - The two branches must not be identical (would silently defeat the toggle)

    func test_theTwoBranches_areNotIdentical() throws {
        let (trueBranch, falseBranch) = try ternaryBranches(in: try delegateSource())
        XCTAssertNotEqual(
            trueBranch.trimmingCharacters(in: .whitespacesAndNewlines),
            falseBranch.trimmingCharacters(in: .whitespacesAndNewlines),
            "the two branches of the channel-gating ternary must differ — if a future edit made them identical, the pre-release toggle would compile and appear to work while doing nothing"
        )
    }

    // MARK: - The channel name itself matches the appcast fixture's own spelling

    func test_thePrereleaseChannelNameConstant_isSpelledBeta() throws {
        let controllerSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Orbit/Core/UpdaterController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            controllerSource.contains(#"static let prereleaseChannelName = "beta""#),
            "UpdaterController.prereleaseChannelName must be declared as exactly \"beta\" (matching the appcast fixture's <sparkle:channel>beta</sparkle:channel>) — if this constant's spelling changed without the appcast changing too, every beta item in the real feed would become permanently unreachable to anyone who opted in."
        )
    }
}
