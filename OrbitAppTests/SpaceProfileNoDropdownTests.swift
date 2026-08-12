import XCTest
@testable import Orbit

/// Profile UI on a Space surface is a deliberate, user-directed divergence
/// from Arc (refs/ARC_PROFILES.md §5.3), not a parity gap to close.
@MainActor
final class SpaceProfileNoDropdownTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?
    private var createdProfileIDs: [ProfileID] = []

    override func setUp() {
        super.setUp()
        originalActiveSpaceID = env.activeSpace?.id
        let profileID = NewSpaceProfileDefault.resolve(in: env)
        scratchSpaceID = env.createSpace(name: "Profile Dropdown Scratch", icon: "sparkles", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
    }

    override func tearDown() {
        if let scratchSpaceID {
            env.deleteSpace(scratchSpaceID)
        }
        if let originalActiveSpaceID {
            env.selectSpace(originalActiveSpaceID)
        }
        env.state.profiles.removeAll { createdProfileIDs.contains($0.id) }
        createdProfileIDs = []
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - Source location

    private static var productionSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    private func source(of relativePath: String) throws -> String {
        let url = Self.productionSourceRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Only the executable lines — comments in these files legitimately
    /// discuss the removed dropdown, and the guard must not fire on its own explanation.
    private func executableLines(of relativePath: String) throws -> [String] {
        try source(of: relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - 1. No dropdown affordance survives in either file

    func testNeitherSpaceSurfacePresentsAProfileDropdown() throws {
        let files = [
            "UI/Spaces/NewSpaceFlowView.swift",
            "UI/Spaces/ManageSpacesView.swift",
        ]
        let bannedConstructors = ["Picker(", "OrbitPopupButton("]

        for file in files {
            let lines = try executableLines(of: file)
            for banned in bannedConstructors {
                let offending = lines.enumerated().filter { $0.element.contains(banned) }
                XCTAssertTrue(
                    offending.isEmpty,
                    "\(file) still constructs a `\(banned)` — a Profile dropdown. Profile UI does not belong on a Space surface at all any more; a Space's Profile is changed from Settings → Profiles' \"Add a Space\" control (Orbit/UI/Settings/ProfilesSettingsPane.swift). Offending line(s): \(offending.map { "\($0.offset + 1)" }.joined(separator: ", "))."
                )
            }
        }
    }

    func testNewSpaceFlowCarriesNoProfileSelectionState() throws {
        let lines = try executableLines(of: "UI/Spaces/NewSpaceFlowView.swift")
        let stateful = lines.filter { $0.contains("@State") && $0.lowercased().contains("profile") }
        XCTAssertTrue(
            stateful.isEmpty,
            "NewSpaceFlowView still holds per-Profile @State: \(stateful). The flow no longer asks which Profile to use."
        )
    }

    /// A whole-tree guard, not a per-file one, so a future agent adding a
    /// new Space-domain file cannot reintroduce Profile UI by omission.
    func testNoSpaceOrLibrarySurfaceCarriesAnyProfileUI() throws {
        let bannedSnippets = [
            "Menu(\"Profile\")",
            "New Profile…",
            "NewProfileSheet(",
            "NSMenuItem(title: \"Profile\"",
        ]
        let scannedRoots = [
            "UI/Sidebar",
            "UI/Spaces",
            "UI/Library",
        ]

        for root in scannedRoots {
            for fileURL in try swiftFiles(under: root) {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: Self.productionSourceRoot.path + "/",
                    with: ""
                )
                let lines = try executableLines(ofAbsolute: fileURL)
                for banned in bannedSnippets {
                    let offending = lines.enumerated().filter { $0.element.contains(banned) }
                    XCTAssertTrue(
                        offending.isEmpty,
                        "\(relativePath) contains `\(banned)` — Profile UI belongs only in Settings (Orbit/UI/Settings/ProfilesSettingsPane.swift) and must not be re-added to a Space surface (Orbit/UI/Sidebar/**, Orbit/UI/Spaces/**, Orbit/UI/Library/**). Offending line(s): \(offending.map { "\($0.offset + 1)" }.joined(separator: ", "))."
                    )
                }
            }
        }
    }

    private func swiftFiles(under relativeRoot: String) throws -> [URL] {
        let root = Self.productionSourceRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    private func executableLines(ofAbsolute url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - 2. The capability the dropdown used to provide still works

    func testProfileSubmenuActionReallyMovesTheSpaceOntoAnotherProfile() {
        let originalProfileID = env.space(scratchSpaceID)!.profileID

        let otherProfileID = env.store.createProfile(name: "Dropdown Removal Scratch Profile")
        createdProfileIDs.append(otherProfileID)
        XCTAssertNotEqual(otherProfileID, originalProfileID, "test precondition: the two Profiles must differ")

        env.store.setProfile(otherProfileID, forSpace: scratchSpaceID)

        XCTAssertEqual(
            env.space(scratchSpaceID)?.profileID, otherProfileID,
            "The Space did not move onto the newly chosen Profile — removing the dropdown removed the capability, which it must not."
        )

        env.store.setProfile(originalProfileID, forSpace: scratchSpaceID)
        XCTAssertEqual(env.space(scratchSpaceID)?.profileID, originalProfileID)
    }

    func testSpaceCreatedWithoutBeingAskedLandsOnARealPersistentProfile() {
        let resolved = NewSpaceProfileDefault.resolve(in: env)
        let profile = env.state.profiles.first { $0.id == resolved }

        XCTAssertNotNil(profile, "The New Space flow's default Profile does not exist in the store.")
        XCTAssertTrue(profile?.isPersistent == true, "The New Space flow defaulted to a non-persistent (Incognito session) Profile.")

        let newSpaceID = env.createSpace(name: "Default Profile Scratch", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: resolved)
        defer { env.deleteSpace(newSpaceID) }
        XCTAssertEqual(env.space(newSpaceID)?.profileID, resolved, "The created Space did not take the resolved default Profile.")
    }

    /// First in the list and oldest by createdAt — wins on every tiebreak except persistence.
    func testEphemeralProfileFirstInTheListIsNotChosenAsTheDefault() {
        let ephemeral = Profile(name: "Scratch Session", isPersistent: false, createdAt: Date(timeIntervalSince1970: 0))
        createdProfileIDs.append(ephemeral.id)
        env.state.profiles.insert(ephemeral, at: 0)

        let resolved = NewSpaceProfileDefault.resolve(in: env)

        XCTAssertNotEqual(resolved, ephemeral.id, "A new Space was put on an ephemeral, non-persistent Profile.")
        XCTAssertTrue(env.state.profiles.first { $0.id == resolved }?.isPersistent == true)
    }
}
