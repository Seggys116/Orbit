import Foundation
import XCTest

final class MeetingLinkDetectorTests: XCTestCase {

    func test_recognisesTheCommonMeetingHosts() {
        let urls = [
            "https://meet.google.com/abc-defg-hij",
            "https://zoom.us/j/1234567890",
            "https://acme.zoom.us/j/1234567890",
            "https://eu01web.zoom.us/j/1234567890",
            "https://teams.microsoft.com/l/meetup-join/xyz",
            "https://acme.webex.com/meet/someone",
            "https://whereby.com/orbit",
            "https://meet.jit.si/OrbitStandup",
        ]
        for string in urls {
            XCTAssertTrue(MeetingLinkDetector.isMeetingURL(URL(string: string)!), "\(string) is a meeting link")
        }
    }

    func test_doesNotTreatAnOrdinaryLinkAsAMeeting() {
        for string in [
            "https://example.com/meet",
            "https://docs.google.com/document/d/abc",
            "https://notzoom.us.example.com/j/1",
            "https://calendar.google.com/calendar/u/0/r",
        ] {
            XCTAssertFalse(MeetingLinkDetector.isMeetingURL(URL(string: string)!), "\(string) is not a meeting link")
        }
    }

    func test_rejectsANonHTTPScheme() {
        XCTAssertFalse(MeetingLinkDetector.isMeetingURL(URL(string: "zoommtg://zoom.us/join?confno=1")!))
    }

    func test_prefersTheEventsOwnURLField() {
        let found = MeetingLinkDetector.firstMeetingURL(
            url: URL(string: "https://meet.google.com/from-url-field"),
            location: "https://zoom.us/j/from-location",
            notes: "https://whereby.com/from-notes"
        )
        XCTAssertEqual(found?.absoluteString, "https://meet.google.com/from-url-field")
    }

    func test_fallsBackToTheLocationThenTheNotes() {
        XCTAssertEqual(
            MeetingLinkDetector.firstMeetingURL(url: nil, location: "https://zoom.us/j/999", notes: nil)?.host,
            "zoom.us"
        )
        XCTAssertEqual(
            MeetingLinkDetector.firstMeetingURL(url: nil, location: "Meeting Room 3", notes: "Dial in: https://meet.google.com/xyz")?.host,
            "meet.google.com"
        )
    }

    func test_ignoresTheEventsOwnURLWhenItIsNotAMeetingLink() {
        let found = MeetingLinkDetector.firstMeetingURL(
            url: URL(string: "https://www.google.com/calendar/event?eid=abc"),
            location: nil,
            notes: "Join: https://meet.google.com/real-link"
        )
        XCTAssertEqual(found?.absoluteString, "https://meet.google.com/real-link")
    }

    func test_findsALinkBuriedInRealisticInvitationNotes() {
        let notes = """
        Hi all,

        Weekly sync. Agenda in the doc: https://docs.google.com/document/d/abc

        ---------- Join Zoom Meeting ----------
        https://acme.zoom.us/j/8675309?pwd=abcdef

        Meeting ID: 867 5309
        """
        XCTAssertEqual(MeetingLinkDetector.scan(notes)?.host, "acme.zoom.us")
    }

    func test_returnsNilWhenThereIsNoMeetingLinkAnywhere() {
        XCTAssertNil(MeetingLinkDetector.firstMeetingURL(url: nil, location: "Room 3", notes: "Bring the laptop"))
    }
}

final class LiveCalendarCountdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(startingIn seconds: TimeInterval, lasting duration: TimeInterval = 1800) -> LiveCalendarEvent {
        LiveCalendarEvent(
            id: "e",
            title: "Standup",
            startDate: now.addingTimeInterval(seconds),
            endDate: now.addingTimeInterval(seconds + duration),
            joinURL: nil
        )
    }

    func test_theFormatsArcsOwnCapturesShow() {
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 3 * 60), now: now), "in 3m")
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 2 * 60), now: now), "in 2m")
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 37 * 60), now: now), "in 37m")
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: -2 * 60), now: now), "2m ago")
    }

    func test_minutesAreRoundedUpSoTheCountdownNeverUnderstatesTheTimeLeft() {
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 90), now: now), "in 2m")
    }

    func test_aMeetingStartingThisVerySecondReadsNow() {
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 0), now: now), "now")
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: -20), now: now), "now")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func test_theHourScale() {
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 60 * 60), now: now, calendar: utc), "in 1h")
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 90 * 60), now: now, calendar: utc), "in 1h 30m")
    }

    func test_aMeetingTomorrowUsesArcsOwnPhrasing() {
        let text = LiveCalendarCountdown.text(for: event(startingIn: 4 * 3600), now: now, calendar: utc)
        XCTAssertTrue(text.hasPrefix("Event tomorrow at "), "got \(text)")
    }

    func test_aMeetingFurtherOutThanTomorrowFallsBackToDays() {
        XCTAssertEqual(LiveCalendarCountdown.text(for: event(startingIn: 72 * 3600), now: now, calendar: utc), "in 3d")
    }

    func test_aMeetingThatHasEndedIsNotLive() {
        let past = LiveCalendarEvent(
            id: "e",
            title: "Standup",
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-3600),
            joinURL: nil
        )
        XCTAssertFalse(past.isLive(at: now))
    }
}

final class LiveCalendarJoinRowRulesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(startingIn seconds: TimeInterval, join: String?, lasting duration: TimeInterval = 1800) -> LiveCalendarEvent {
        LiveCalendarEvent(
            id: "e",
            title: "Kickoff meeting",
            startDate: now.addingTimeInterval(seconds),
            endDate: now.addingTimeInterval(seconds + duration),
            joinURL: join.flatMap(URL.init(string:))
        )
    }

    func test_theRowAppearsBetweenThreeMinutesAndTwoMinutesAtTheDefaultLeadTime() {
        let link = "https://meet.google.com/abc"
        XCTAssertFalse(event(startingIn: 3 * 60, join: link).shouldOfferJoin(at: now, leadTime: .default))
        XCTAssertTrue(event(startingIn: 2 * 60, join: link).shouldOfferJoin(at: now, leadTime: .default))
    }

    func test_aLongerLeadTimeShowsTheRowEarlier() {
        let subject = event(startingIn: 8 * 60, join: "https://meet.google.com/abc")
        XCTAssertFalse(subject.shouldOfferJoin(at: now, leadTime: .twoMinutes))
        XCTAssertFalse(subject.shouldOfferJoin(at: now, leadTime: .fiveMinutes))
        XCTAssertTrue(subject.shouldOfferJoin(at: now, leadTime: .tenMinutes))
    }

    func test_noJoinRowForAMeetingWithNoVideoLink() {
        XCTAssertFalse(event(startingIn: 60, join: nil).shouldOfferJoin(at: now, leadTime: .default))
    }

    func test_theRowStaysUpWhileTheMeetingIsRunning() {
        let running = event(startingIn: -5 * 60, join: "https://zoom.us/j/1")
        XCTAssertTrue(running.shouldOfferJoin(at: now, leadTime: .default), "Joining late is the commonest case of all")
    }

    func test_theRowGoesOnceTheMeetingHasEnded() {
        let over = event(startingIn: -3600, join: "https://zoom.us/j/1", lasting: 1800)
        XCTAssertFalse(over.shouldOfferJoin(at: now, leadTime: .default))
    }

    func test_leadTimeLabelsAreArcsOwn() {
        XCTAssertEqual(LiveCalendarLeadTime.tenMinutes.title, "Ten Minutes Before")
        XCTAssertEqual(LiveCalendarLeadTime.fiveMinutes.title, "Five Minutes Before")
        XCTAssertEqual(LiveCalendarLeadTime.twoMinutes.title, "Two Minutes Before")
    }
}

final class EventEmojiTests: XCTestCase {

    func test_aLeadingEmojiMovesToTheIconColumn() {
        XCTAssertEqual(EventEmoji.leading(in: "💰 Sponsorship meeting"), "💰")
        XCTAssertEqual(EventEmoji.stripLeading(from: "💰 Sponsorship meeting"), "Sponsorship meeting")
    }

    func test_aTitleWithNoEmojiIsLeftAlone() {
        XCTAssertNil(EventEmoji.leading(in: "Kickoff meeting"))
        XCTAssertEqual(EventEmoji.stripLeading(from: "Kickoff meeting"), "Kickoff meeting")
    }

    func test_aMultiScalarEmojiSurvivesWhole() {
        XCTAssertEqual(EventEmoji.leading(in: "👩‍💻 Pairing"), "👩‍💻")
        XCTAssertEqual(EventEmoji.stripLeading(from: "👩‍💻 Pairing"), "Pairing")
    }

    func test_aDigitIsNotMistakenForAnEmoji() {
        XCTAssertNil(EventEmoji.leading(in: "1:1 with Sam"))
        XCTAssertEqual(EventEmoji.stripLeading(from: "1:1 with Sam"), "1:1 with Sam")
    }
}

final class CalendarSiteMatcherTests: XCTestCase {

    func test_recognisesGoogleCalendar() {
        XCTAssertTrue(CalendarSiteMatcher.isCalendar(URL(string: "https://calendar.google.com/calendar/u/0/r")!))
    }

    func test_recognisesOutlookCalendarButNotOutlookMail() {
        XCTAssertTrue(CalendarSiteMatcher.isCalendar(URL(string: "https://outlook.office.com/calendar/view/week")!))
        XCTAssertFalse(CalendarSiteMatcher.isCalendar(URL(string: "https://outlook.office.com/mail/inbox")!))
    }

    func test_doesNotMatchAnOrdinarySite() {
        for string in ["https://example.com", "https://github.com/orbit", "https://mail.google.com/mail/u/0"] {
            XCTAssertFalse(CalendarSiteMatcher.isCalendar(URL(string: string)!))
        }
    }
}

@MainActor
final class LiveCalendarStoreTests: XCTestCase {

    private var suiteName: String!
    private var suite: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "LiveCalendarStoreTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        LiveCalendarSettings.defaults = suite
    }

    override func tearDown() {
        LiveCalendarSettings.defaults = .standard
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    private func event(_ id: String, startingIn seconds: TimeInterval, lasting duration: TimeInterval = 1800, join: String? = nil) -> LiveCalendarEvent {
        LiveCalendarEvent(
            id: id,
            title: id,
            startDate: now.addingTimeInterval(seconds),
            endDate: now.addingTimeInterval(seconds + duration),
            joinURL: join.flatMap(URL.init(string:))
        )
    }

    private func source(
        authorization: LiveCalendarStore.Authorization,
        events: [LiveCalendarEvent],
        onEvents: (@MainActor () -> Void)? = nil
    ) -> LiveCalendarStore.EventSource {
        LiveCalendarStore.EventSource(
            authorization: { authorization },
            requestAccess: { authorization == .granted },
            events: { _, _ in onEvents?(); return events }
        )
    }

    func test_withTheFeatureOffNothingIsReadAtAll() {
        LiveCalendarSettings.isEnabled = false
        var readCount = 0
        let store = LiveCalendarStore()

        store.refresh(source: source(authorization: .granted, events: [event("a", startingIn: 600)], onEvents: { readCount += 1 }), now: now)

        XCTAssertEqual(readCount, 0, "A switched-off feature must not read the user's calendar")
        XCTAssertNil(store.nextEvent)
    }

    func test_whenAccessIsDeniedTheStoreSaysSoRatherThanShowingNothing() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()

        store.refresh(source: source(authorization: .denied, events: [event("a", startingIn: 600)]), now: now)

        XCTAssertEqual(store.authorization, .denied)
        XCTAssertNil(store.nextEvent, "Denied means no data, not stale data")
    }

    func test_picksTheSoonestUpcomingMeeting() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()
        store.refresh(
            source: source(authorization: .granted, events: [
                event("later", startingIn: 3600),
                event("soonest", startingIn: 600),
                event("latest", startingIn: 7200),
            ]),
            now: now
        )
        XCTAssertEqual(store.nextEvent?.id, "soonest")
    }

    func test_aMeetingAlreadyInProgressBeatsANearerStartingOne() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()
        store.refresh(
            source: source(authorization: .granted, events: [
                event("upcoming", startingIn: 300),
                event("running", startingIn: -600),
            ]),
            now: now
        )
        XCTAssertEqual(store.nextEvent?.id, "running")
    }

    func test_aMeetingThatHasAlreadyEndedIsNotShown() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()
        store.refresh(
            source: source(authorization: .granted, events: [event("over", startingIn: -7200, lasting: 1800)]),
            now: now
        )
        XCTAssertNil(store.nextEvent)
    }

    func test_withNoMeetingsThereIsNothingToShow() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()
        store.refresh(source: source(authorization: .granted, events: []), now: now)
        XCTAssertEqual(store.authorization, .granted)
        XCTAssertNil(store.nextEvent)
    }

    func test_joinURLIsOfferedOnlyWhenTheMeetingHasOne() {
        LiveCalendarSettings.isEnabled = true
        let store = LiveCalendarStore()

        store.refresh(source: source(authorization: .granted, events: [event("no-link", startingIn: 300)]), now: now)
        XCTAssertNil(store.joinURLForActiveMeeting(), "No video link means no Join button")

        store.refresh(
            source: source(authorization: .granted, events: [event("with-link", startingIn: 300, join: "https://meet.google.com/abc")]),
            now: now
        )
        XCTAssertEqual(store.joinURLForActiveMeeting()?.absoluteString, "https://meet.google.com/abc")
    }

    func test_liveCalendarsShipOff() {
        XCTAssertFalse(LiveCalendarSettings.isEnabled)
    }

    func test_bothSurfacesAreOnOnceTheFeatureItselfIsOn() {
        XCTAssertTrue(LiveCalendarSettings.showsCountdown)
        XCTAssertTrue(LiveCalendarSettings.showsJoinRow)
    }

    func test_theLeadTimeDefaultsToWhatArcsFilmShows() {
        XCTAssertEqual(LiveCalendarSettings.leadTime, .twoMinutes)
    }

    func test_theMenuTogglesSurviveAWriteThenReloadThroughASecondUserDefaults() throws {
        LiveCalendarSettings.showsCountdown = false
        LiveCalendarSettings.leadTime = .tenMinutes

        let reader = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(reader.object(forKey: LiveCalendarSettings.showsCountdownKey) as? Bool, false)
        XCTAssertEqual(reader.string(forKey: LiveCalendarSettings.leadTimeKey), LiveCalendarLeadTime.tenMinutes.rawValue)

        XCTAssertTrue(LiveCalendarSettings.showsJoinRow, "Turning one surface off must not turn the other off")
    }
}
