import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class DiagnosticChannelConsoleNoiseTests: XCTestCase {

    private var writtenPreferenceKeys: Set<String> = []

    override func tearDown() {
        for key in writtenPreferenceKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        writtenPreferenceKeys.removeAll()
        super.tearDown()
    }

    private func setPreference(_ key: String, _ value: Bool) {
        writtenPreferenceKeys.insert(key)
        UserDefaults.standard.set(value, forKey: key)
    }

    private func channelsNotForcedByEnvironment() -> [DiagnosticChannel] {
        let environment = ProcessInfo.processInfo.environment
        let masterIsSet = !(environment["ORBIT_LOG_UI"] ?? "").isEmpty
        return DiagnosticChannel.allCases.filter { channel in
            if masterIsSet { return false }
            let names = [channel.environmentName] + channel.legacyEnvironmentNames
            return names.allSatisfy { (environment[$0] ?? "").isEmpty }
        }
    }

    // MARK: - 1. The switching contract

    func test_everyChannelIsOffByDefault() {
        let channels = channelsNotForcedByEnvironment()
        XCTAssertFalse(
            channels.isEmpty,
            "The environment has forced every diagnostic channel, so this run could not measure the default state."
        )
        for channel in channels {
            UserDefaults.standard.removeObject(forKey: channel.preferenceKey)
            XCTAssertFalse(
                channel.isEnabled,
                "\(channel.rawValue) logs by default. Every one of these fires on a hot browsing path; the console has to stay readable without anyone asking it to."
            )
        }
    }

    func test_documentedEnvironmentNamesAndPreferenceKeysAreStable() {
        let expected: [DiagnosticChannel: (String, String)] = [
            .toolbarColour: ("ORBIT_LOG_TOOLBAR_COLOUR", "OrbitLogToolbarColour"),
            .toolbarFrame: ("ORBIT_LOG_TOOLBAR_FRAME", "OrbitLogToolbarFrame"),
            .toolbarHitTest: ("ORBIT_LOG_TOOLBAR_HIT_TEST", "OrbitLogToolbarHitTest"),
            .toolbarViewTree: ("ORBIT_LOG_TOOLBAR_VIEW_TREE", "OrbitLogToolbarViewTree"),
            .contentCard: ("ORBIT_LOG_CONTENT_CARD", "OrbitLogContentCard"),
            .webContentsAttachment: ("ORBIT_LOG_WEB_CONTENTS_ATTACHMENT", "OrbitLogWebContentsAttachment"),
            .contentColumn: ("ORBIT_LOG_CONTENT_COLUMN", "OrbitLogContentColumn"),
        ]
        XCTAssertEqual(
            Set(expected.keys), Set(DiagnosticChannel.allCases),
            "A channel was added or removed without updating the names this test pins. Every channel is documented by name somewhere a person is expected to type it."
        )
        for (channel, names) in expected {
            XCTAssertEqual(channel.environmentName, names.0)
            XCTAssertEqual(channel.preferenceKey, names.1)
        }
    }

    func test_preferenceSwitchesOnOneChannelAndNoOther() {
        guard let subject = channelsNotForcedByEnvironment().first(where: { $0 == .toolbarColour })
            ?? channelsNotForcedByEnvironment().first
        else { return XCTFail("No measurable channel in this environment.") }

        setPreference(subject.preferenceKey, true)
        XCTAssertTrue(subject.isEnabled, "\(subject.rawValue) did not switch on from its documented preference key.")

        for other in channelsNotForcedByEnvironment() where other != subject {
            XCTAssertFalse(
                other.isEnabled,
                "Switching on \(subject.rawValue) also switched on \(other.rawValue). Asking for one probe must not reopen the whole flood."
            )
        }

        UserDefaults.standard.removeObject(forKey: subject.preferenceKey)
        XCTAssertFalse(subject.isEnabled, "\(subject.rawValue) stayed on after its preference was removed.")
    }

    func test_masterPreferenceSwitchesEveryChannelOn() {
        let channels = channelsNotForcedByEnvironment()
        guard !channels.isEmpty else { return XCTFail("No measurable channel in this environment.") }
        setPreference("OrbitLogUI", true)
        for channel in channels {
            XCTAssertTrue(channel.isEnabled, "The OrbitLogUI master switch left \(channel.rawValue) off.")
        }
        UserDefaults.standard.removeObject(forKey: "OrbitLogUI")
        for channel in channels {
            XCTAssertFalse(channel.isEnabled, "\(channel.rawValue) stayed on after the OrbitLogUI master switch was removed.")
        }
    }

    func test_legacyProbeTreeEnvironmentSpellingIsStillAccepted() {
        XCTAssertEqual(
            DiagnosticChannel.toolbarViewTree.legacyEnvironmentNames, ["ORBIT_PROBE_TREE"],
            "The pre-existing ORBIT_PROBE_TREE spelling was dropped. It is the one runtime switch that already shipped."
        )
        for channel in DiagnosticChannel.allCases where channel != .toolbarViewTree {
            XCTAssertTrue(
                channel.legacyEnvironmentNames.isEmpty,
                "\(channel.rawValue) grew an undocumented alias; there is exactly one, and it exists for back-compatibility."
            )
        }
    }

    // MARK: - 2. The noisy path is actually wired to the gate

    func test_toolbarColourProbe_isSilentByDefaultAndSpeaksWhenAskedFor() throws {
        #if DEBUG
        guard channelsNotForcedByEnvironment().contains(.toolbarColour) else {
            throw XCTSkip("ORBIT_LOG_TOOLBAR_COLOUR is set in this environment, so the default state cannot be measured here.")
        }
        let store = try OSLogStore(scope: .currentProcessIdentifier)

        UserDefaults.standard.removeObject(forKey: DiagnosticChannel.toolbarColour.preferenceKey)
        let quietMark = Date()
        renderAToolbarHeader()
        let quiet = try colourLines(from: store, since: quietMark)
        XCTAssertTrue(
            quiet.isEmpty,
            """
            The [colour] probe still logs with nothing asked for. It fires once per navigation per pane, at privacy: .public, \
            in the DEBUG build the user browses in, and it is a large part of what they were reading as Chromium errors. \
            Emitted: \(quiet)
            """
        )

        setPreference(DiagnosticChannel.toolbarColour.preferenceKey, true)
        let loudMark = Date()
        renderAToolbarHeader()
        let loud = try colourLines(from: store, since: loudMark)
        XCTAssertFalse(
            loud.isEmpty,
            """
            The [colour] probe stayed silent with ORBIT_LOG_TOOLBAR_COLOUR/OrbitLogToolbarColour switched on. \
            The diagnostic must survive in full -- quieting it by default is only acceptable because it can still be had on demand. \
            It is what makes 'the header paints a colour from a page I visited earlier' a seconds-long diagnosis.
            """
        )
        let sample = try XCTUnwrap(loud.first)
        for field in ["url=", "declared=", "live=", "hint=", "contents=", "painted=", "glyphs="] {
            XCTAssertTrue(sample.contains(field), "The [colour] record lost its \(field) field: \(sample)")
        }
        #else
        throw XCTSkip("The toolbar self-check probes are compiled out of Release builds.")
        #endif
    }

    // MARK: - Harness

    private lazy var env: AppEnvironment = AppEnvironment.demo

    @discardableResult
    private func renderAToolbarHeader() -> NSWindow {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Noise Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://www.google.com/search?q=orbit")!, title: "")
        env.state.tabs[tab.id] = tab
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        let size = CGSize(width: 900, height: 400)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(
            rootView: VStack(spacing: 0) {
                ToolbarView(tab: tab).environment(env)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        )
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.orderOut(nil)
        return window
    }

    private func colourLines(from store: OSLogStore, since mark: Date) throws -> [String] {
        let position = store.position(date: mark)
        let entries = try store.getEntries(
            at: position,
            matching: NSPredicate(format: "subsystem == %@ AND category == %@", "com.orbit.browser", "ToolbarSelfCheck")
        )
        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .map(\.composedMessage)
            .filter { $0.contains("[colour]") }
    }
}
