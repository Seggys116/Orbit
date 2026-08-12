import XCTest

final class UpdaterAppcastFixtureTests: XCTestCase {

    private struct FeedItem {
        var title: String = ""
        var hasChannelElement = false
        var channelText: String = ""
        var enclosureURL: String?
        var enclosureEdSignature: String?
    }

    private final class AppcastItemCollector: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        private var current: FeedItem?
        private var elementStack: [String] = []
        private var characterBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elementStack.append(elementName)
            characterBuffer = ""

            switch elementName {
            case "item":
                current = FeedItem()
            case "sparkle:channel":
                current?.hasChannelElement = true
            case "enclosure":
                current?.enclosureURL = attributeDict["url"]
                current?.enclosureEdSignature = attributeDict["sparkle:edSignature"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            characterBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            defer { elementStack.removeLast() }

            switch elementName {
            case "title":
                if elementStack.count >= 2, elementStack[elementStack.count - 2] == "item" {
                    current?.title = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "sparkle:channel":
                current?.channelText = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "item":
                if let current { items.append(current) }
                current = nil
            default:
                break
            }
            characterBuffer = ""
        }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)          // OrbitTests/UpdaterAppcastFixtureTests.swift
            .deletingLastPathComponent()          // OrbitTests/
            .appendingPathComponent("Fixtures/appcast-signed.txt")
    }

    private func parseFixture() throws -> [FeedItem] {
        let data = try Data(contentsOf: Self.fixtureURL)
        let parser = XMLParser(data: data)
        let collector = AppcastItemCollector()
        parser.delegate = collector
        XCTAssertTrue(parser.parse(), "the checked-in appcast fixture is not well-formed XML: \(parser.parserError?.localizedDescription ?? "unknown error")")
        return collector.items
    }

    private func item(titled title: String, in items: [FeedItem]) throws -> FeedItem {
        try XCTUnwrap(items.first { $0.title == title }, "no <item> titled \"\(title)\" in the fixture — items were: \(items.map(\.title))")
    }

    // MARK: - The fixture itself, sanity-checked

    func test_theFixtureContainsExactlyTheTwoExpectedItems() throws {
        let items = try parseFixture()
        XCTAssertEqual(
            Set(items.map(\.title)), ["1.0.0", "1.0.1-beta.1"],
            "the checked-in fixture no longer has the two items this suite was written against; if it was regenerated, this test (and the assertions below) need to be revisited against the new content"
        )
    }

    // MARK: - 1. Channel gating: beta carries the channel, stable does not

    func test_theBetaItem_carriesTheBetaChannelElement() throws {
        let items = try parseFixture()
        let beta = try item(titled: "1.0.1-beta.1", in: items)
        XCTAssertTrue(beta.hasChannelElement, "the beta item must carry a <sparkle:channel> element, or UpdaterController.allowedChannels(for:) can never find it via the \"beta\" channel")
        XCTAssertEqual(beta.channelText, "beta", "the channel name must exactly match UpdaterController.prereleaseChannelName (\"beta\") — Sparkle treats channel names as opaque, case-sensitive strings, so any other spelling makes the item permanently unreachable")
    }

    func test_theStableItem_carriesNoChannelElement() throws {
        let items = try parseFixture()
        let stable = try item(titled: "1.0.0", in: items)
        XCTAssertFalse(
            stable.hasChannelElement,
            "a stable item must carry no <sparkle:channel> element at all — Sparkle's own contract is that the default channel is always included, so a stray channel element here would need every user, opted in or not, to already be in that channel to ever see it, effectively hiding a stable release"
        )
    }

    // MARK: - 2. Enclosure URLs: absolute, and each item points at its OWN tag

    func test_everyEnclosureURL_isAbsolute() throws {
        let items = try parseFixture()
        for feedItem in items {
            let urlString = try XCTUnwrap(feedItem.enclosureURL, "\(feedItem.title) has no <enclosure url>")
            let url = try XCTUnwrap(URL(string: urlString), "\(feedItem.title)'s enclosure URL does not parse: \(urlString)")
            XCTAssertNotNil(url.scheme, "\(feedItem.title)'s enclosure URL \"\(urlString)\" has no scheme — a relative URL here would fail to resolve once the appcast is served from GitHub Pages rather than read from disk")
            XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""), "\(feedItem.title)'s enclosure URL \"\(urlString)\" must be served over http(s)")
        }
    }

    func test_eachItemsEnclosureURL_pointsAtItsOwnReleaseTagNotAScharedOrOtherItemsPath() throws {
        let items = try parseFixture()
        let stable = try item(titled: "1.0.0", in: items)
        let beta = try item(titled: "1.0.1-beta.1", in: items)

        let stableURL = try XCTUnwrap(stable.enclosureURL)
        let betaURL = try XCTUnwrap(beta.enclosureURL)

        XCTAssertTrue(
            stableURL.contains("/releases/download/v1.0.0/"),
            "1.0.0's enclosure must point at the v1.0.0 release tag; got \(stableURL)"
        )
        XCTAssertTrue(
            betaURL.contains("/releases/download/v1.0.1-beta.1/"),
            "1.0.1-beta.1's enclosure must point at the v1.0.1-beta.1 release tag; got \(betaURL)"
        )
        XCTAssertNotEqual(
            stableURL, betaURL,
            "two different appcast items resolved to the identical enclosure URL — one of them would silently offer the wrong binary"
        )
        XCTAssertFalse(
            stableURL.contains("v1.0.1-beta.1") || betaURL.contains("v1.0.0/"),
            "an item's enclosure URL leaked the other item's release tag — a shared/templated URL bug, not a per-item one"
        )
    }

    // MARK: - 3. Every enclosure is signed — the CI pipeline's one already-real regression

    func test_everyEnclosure_carriesANonEmptyEdSignature() throws {
        let items = try parseFixture()
        XCTAssertFalse(items.isEmpty, "test precondition: the fixture must contain items, or this proves nothing")
        for feedItem in items {
            let signature = feedItem.enclosureEdSignature
            XCTAssertNotNil(signature, "\(feedItem.title)'s <enclosure> has no sparkle:edSignature attribute at all — Sparkle will refuse to install this update. This is the exact regression the release pipeline shipped once: unsigned enclosures that nothing caught.")
            XCTAssertFalse(
                (signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(feedItem.title)'s sparkle:edSignature is present but empty — as inert as having no signature at all"
            )
            // Must check length, not just non-empty: a real EdDSA signature is a base64-encoded 64-byte value, so this guards against a placeholder like "TODO" being waved through by the non-empty check above.
            XCTAssertGreaterThan(
                (signature ?? "").count, 40,
                "\(feedItem.title)'s sparkle:edSignature (\"\(signature ?? "")\") is far shorter than a real base64 EdDSA signature — this looks like a placeholder, not a real one"
            )
        }
    }
}
