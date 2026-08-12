import XCTest
@testable import Orbit

struct SeededSplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class BoostShuffleTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BoostShuffle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private var boostsFileURL: URL {
        scratchDirectory.appendingPathComponent("boosts.json", isDirectory: false)
    }

    private static let fonts = ["Helvetica Neue", "Iowan Old Style", "Menlo", "Optima", "Palatino"]

    // MARK: - It really changes the stored Boost

    func test_shuffle_changesTheStoredBoostsVisualFields() throws {
        let store = BoostStore(fileURL: boostsFileURL)
        let created = store.createBoost(name: "Shuffle Me", host: "example.com")

        XCTAssertNil(created.backgroundColor, "a fresh Boost must start unpainted or the assertions below prove nothing")
        XCTAssertNil(created.textColor)
        XCTAssertNil(created.accentColor)
        XCTAssertNil(created.fontFamily)

        var generator = SeededSplitMix64(seed: 0xC0FFEE)
        let shuffled = BoostShuffle.shuffled(created, fontCandidates: Self.fonts, using: &generator)
        store.updateBoost(created.id) { boost in
            boost.backgroundColor = shuffled.backgroundColor
            boost.textColor = shuffled.textColor
            boost.accentColor = shuffled.accentColor
            boost.fontFamily = shuffled.fontFamily
        }
        try store.saveNow()

        let reloaded = try XCTUnwrap(BoostStore(fileURL: boostsFileURL).boost(created.id))
        XCTAssertNotNil(reloaded.backgroundColor, "Shuffle produced no background colour")
        XCTAssertNotNil(reloaded.textColor, "Shuffle produced no text colour")
        XCTAssertNotNil(reloaded.accentColor, "Shuffle produced no accent colour")
        let font = try XCTUnwrap(reloaded.fontFamily, "Shuffle produced no font")
        XCTAssertTrue(
            Self.fonts.contains(font),
            "Shuffle must pick from the candidate list the editor's own font control offers, not invent a family"
        )

        let css = BoostCompiler.compiledCSS(for: reloaded)
        XCTAssertTrue(css.contains("background-color"), "the shuffled background never reached the stylesheet")
        XCTAssertTrue(css.contains("color:"), "the shuffled text colour never reached the stylesheet")
        XCTAssertTrue(css.contains("accent-color"), "the shuffled accent never reached the stylesheet")
        XCTAssertTrue(css.contains(font), "the shuffled font never reached the stylesheet")
    }

    func test_shuffle_producesADifferentResultOnEachInvocation() {
        let boost = Boost(name: "Shuffle Me", host: "example.com")
        var generator = SeededSplitMix64(seed: 1)

        var seenBackgrounds: Set<[Double]> = []
        var seenAccents: Set<[Double]> = []
        for _ in 0..<25 {
            let shuffled = BoostShuffle.shuffled(boost, fontCandidates: Self.fonts, using: &generator)
            let background = try? XCTUnwrap(shuffled.backgroundColor)
            let accent = try? XCTUnwrap(shuffled.accentColor)
            if let background { seenBackgrounds.insert([background.red, background.green, background.blue]) }
            if let accent { seenAccents.insert([accent.red, accent.green, accent.blue]) }
        }

        XCTAssertEqual(
            seenBackgrounds.count, 25,
            "25 shuffles produced \(seenBackgrounds.count) distinct backgrounds — Shuffle is returning canned results"
        )
        XCTAssertGreaterThan(
            seenAccents.count, 20,
            "the accent colour is barely moving across 25 shuffles"
        )
    }

    func test_shuffle_isDeterministicForAGivenSeed() {
        let boost = Boost(name: "Shuffle Me", host: "example.com")

        var first = SeededSplitMix64(seed: 42)
        var second = SeededSplitMix64(seed: 42)
        let a = BoostShuffle.shuffled(boost, fontCandidates: Self.fonts, using: &first)
        let b = BoostShuffle.shuffled(boost, fontCandidates: Self.fonts, using: &second)

        XCTAssertEqual(a.backgroundColor, b.backgroundColor)
        XCTAssertEqual(a.textColor, b.textColor)
        XCTAssertEqual(a.accentColor, b.accentColor)
        XCTAssertEqual(a.fontFamily, b.fontFamily)
    }

    // MARK: - Every generated scheme has to be usable

    func test_everyGeneratedPalette_clearsTheContrastFloor() {
        var generator = SeededSplitMix64(seed: 0xBEEF)
        for iteration in 0..<500 {
            let palette = BoostShuffle.randomPalette(using: &generator)
            let ratio = BoostShuffle.contrastRatio(palette.background, palette.text)
            XCTAssertGreaterThanOrEqual(
                ratio, BoostShuffle.minimumContrastRatio,
                "iteration \(iteration) generated text at \(ratio):1 against its background — unreadable"
            )
        }
    }

    func test_contrastRatio_matchesTheWCAGAnchors() {
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(BoostShuffle.contrastRatio(black, white), 21.0, accuracy: 0.01)
        XCTAssertEqual(BoostShuffle.contrastRatio(white, white), 1.0, accuracy: 0.0001)
    }

    func test_hslConversion_hitsItsDefinedCorners() {
        let red = BoostShuffle.hsl(0, 1, 0.5)
        XCTAssertEqual(red.red, 1, accuracy: 0.001)
        XCTAssertEqual(red.green, 0, accuracy: 0.001)
        XCTAssertEqual(red.blue, 0, accuracy: 0.001)

        let green = BoostShuffle.hsl(120, 1, 0.5)
        XCTAssertEqual(green.green, 1, accuracy: 0.001)

        let blue = BoostShuffle.hsl(240, 1, 0.5)
        XCTAssertEqual(blue.blue, 1, accuracy: 0.001)

        let grey = BoostShuffle.hsl(217, 0, 0.42)
        XCTAssertEqual(grey.red, 0.42, accuracy: 0.001)
        XCTAssertEqual(grey.green, 0.42, accuracy: 0.001)
        XCTAssertEqual(grey.blue, 0.42, accuracy: 0.001)
    }

    // MARK: - What Shuffle must NOT touch

    func test_shuffle_leavesZapCodeSizeAndCaseAlone() {
        var boost = Boost(name: "Shuffle Me", host: "example.com")
        boost.zappedSelectors = ["#ads", ".promo"]
        boost.customCSS = "body { letter-spacing: 0.02em; }"
        boost.customJavaScript = "document.title = 'kept';"
        boost.pageSizeScale = 1.25
        boost.textCase = .uppercase
        boost.invertLightness = true
        boost.contrast = 1.4
        boost.brightness = 0.8
        boost.saturation = 0.5

        var generator = SeededSplitMix64(seed: 7)
        let shuffled = BoostShuffle.shuffled(boost, fontCandidates: Self.fonts, using: &generator)

        XCTAssertEqual(shuffled.zappedSelectors, ["#ads", ".promo"])
        XCTAssertEqual(shuffled.customCSS, "body { letter-spacing: 0.02em; }")
        XCTAssertEqual(shuffled.customJavaScript, "document.title = 'kept';")
        XCTAssertEqual(shuffled.pageSizeScale, 1.25)
        XCTAssertEqual(shuffled.textCase, .uppercase)
        XCTAssertTrue(shuffled.invertLightness)
        XCTAssertEqual(shuffled.contrast, 1.4)
        XCTAssertEqual(shuffled.brightness, 0.8)
        XCTAssertEqual(shuffled.saturation, 0.5)
        XCTAssertEqual(shuffled.id, boost.id, "Shuffle re-paints a Boost; it does not replace it")
        XCTAssertEqual(shuffled.name, boost.name, "Shuffle is not Rename")
        XCTAssertEqual(shuffled.host, boost.host)
    }

    // MARK: - Persistence: this work must add no new persisted keys

    /// Shuffle must add no new persisted field to `Boost`; a new field
    /// decoded with `decode` instead of `decodeIfPresent` would break every existing user's `state.json`.
    func test_shuffledBoost_encodesExactlyThePreExistingKeySet() throws {
        var generator = SeededSplitMix64(seed: 0xD1CE)
        let shuffled = BoostShuffle.shuffled(
            Boost(name: "Shuffle Me", host: "example.com"),
            fontCandidates: Self.fonts,
            using: &generator
        )

        let encoded = try JSONEncoder().encode(shuffled)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        let expected: Set<String> = [
            "id", "name", "host", "isEnabled",
            "zappedSelectors", "customCSS", "customJavaScript",
            "backgroundColor", "textColor", "accentColor", "fontFamily",
            "invertLightness", "contrast", "brightness", "saturation", "pageSizeScale", "textCase",
            "createdAt", "updatedAt",
        ]
        XCTAssertEqual(
            Set(object.keys), expected,
            """
            The persisted shape of `Boost` changed. Every field must be read with \
            `decodeIfPresent` and a default in `Boost.init(from:)`, or every \
            existing state.json stops loading — see that initializer's doc comment.
            """
        )
    }

    func test_stateJSONStrippedOfEveryFieldShuffleWrites_stillLoads() throws {
        let store = StateStore(rootDirectory: scratchDirectory)

        let profile = Profile(name: "Personal")
        let space = Space(name: "Work", profileID: profile.id)
        let tab = Tab(spaceID: space.id, url: URL(string: "https://example.com/")!)

        var generator = SeededSplitMix64(seed: 0x5EED)
        let shuffled = BoostShuffle.shuffled(
            Boost(name: "Shuffled", host: "example.com", zappedSelectors: ["#ads"]),
            fontCandidates: Self.fonts,
            using: &generator
        )

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.tabs = [tab.id: tab]
        document.boosts = [shuffled]
        document.activeSpaceID = space.id
        try store.saveNow(document)

        let stateURL = scratchDirectory.appendingPathComponent("state.json", isDirectory: false)
        let shuffleKeys = ["backgroundColor", "textColor", "accentColor", "fontFamily"]

        let beforeText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in shuffleKeys {
            XCTAssertTrue(
                beforeText.contains("\"\(key)\""),
                "\(key) was never written, so this test would strip nothing"
            )
        }

        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: stateURL)) as? [String: Any]
        )
        var rawBoosts = try XCTUnwrap(raw["boosts"] as? [[String: Any]])
        for index in rawBoosts.indices {
            for key in shuffleKeys { rawBoosts[index].removeValue(forKey: key) }
        }
        raw["boosts"] = rawBoosts
        try JSONSerialization.data(withJSONObject: raw).write(to: stateURL, options: .atomic)

        let strippedText = try String(contentsOf: stateURL, encoding: .utf8)
        for key in shuffleKeys {
            XCTAssertFalse(
                strippedText.contains("\"\(key)\""),
                "\(key) is still in the fixture — this test would pass without proving anything"
            )
        }

        let reloaded = try StateStore(rootDirectory: scratchDirectory).load()

        XCTAssertEqual(
            reloaded.boosts.count, 1,
            "a state.json with no shuffled colours failed to load through the real load path"
        )
        XCTAssertEqual(reloaded.spaces.count, 1, "the rest of the document must come back too, not just the Boosts")
        XCTAssertEqual(reloaded.tabs.count, 1)
        XCTAssertEqual(reloaded.profiles.count, 1)

        let reloadedBoost = try XCTUnwrap(reloaded.boosts.first)
        XCTAssertNil(reloadedBoost.backgroundColor)
        XCTAssertNil(reloadedBoost.textColor)
        XCTAssertNil(reloadedBoost.accentColor)
        XCTAssertNil(reloadedBoost.fontFamily)
        XCTAssertEqual(reloadedBoost.zappedSelectors, ["#ads"], "the untouched half of the Boost must survive")
    }

    // MARK: - What Shuffle must NOT touch, continued

    func test_shuffle_withNoFontCandidates_keepsTheExistingFont() {
        var boost = Boost(name: "Shuffle Me", host: "example.com")
        boost.fontFamily = "Iowan Old Style"

        var generator = SeededSplitMix64(seed: 9)
        let shuffled = BoostShuffle.shuffled(boost, fontCandidates: [], using: &generator)

        XCTAssertEqual(shuffled.fontFamily, "Iowan Old Style")
        XCTAssertNotNil(shuffled.backgroundColor, "the colours must still shuffle when the font list is empty")
    }
}
