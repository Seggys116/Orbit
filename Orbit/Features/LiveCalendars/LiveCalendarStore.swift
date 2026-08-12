import EventKit
import Foundation

enum LiveCalendarSettings {

    static let enabledKey = "OrbitLiveCalendarsEnabled"
    static let showsCountdownKey = "OrbitLiveCalendarShowsCountdown"
    static let showsJoinRowKey = "OrbitLiveCalendarShowsJoinRow"
    static let leadTimeKey = "OrbitLiveCalendarLeadTime"

    #if DEBUG
    static var defaults: UserDefaults = .standard
    #else
    static let defaults: UserDefaults = .standard
    #endif

    // Off until the user turns it on, which is also what triggers the macOS calendar permission prompt.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var showsCountdown: Bool {
        get { defaults.object(forKey: showsCountdownKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showsCountdownKey) }
    }

    static var showsJoinRow: Bool {
        get { defaults.object(forKey: showsJoinRowKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showsJoinRowKey) }
    }

    static var leadTime: LiveCalendarLeadTime {
        get {
            guard let raw = defaults.string(forKey: leadTimeKey),
                  let value = LiveCalendarLeadTime(rawValue: raw)
            else { return .default }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: leadTimeKey) }
    }
}

@MainActor
@Observable
final class LiveCalendarStore {

    static let shared = LiveCalendarStore()

    init() {}

    enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case granted
    }

    // MARK: - The EventKit seam

    struct EventSource: Sendable {
        let authorization: @Sendable @MainActor () -> Authorization
        let requestAccess: @Sendable @MainActor () async -> Bool
        let events: @Sendable @MainActor (Date, Date) -> [LiveCalendarEvent]

        init(
            authorization: @escaping @Sendable @MainActor () -> Authorization,
            requestAccess: @escaping @Sendable @MainActor () async -> Bool,
            events: @escaping @Sendable @MainActor (Date, Date) -> [LiveCalendarEvent]
        ) {
            self.authorization = authorization
            self.requestAccess = requestAccess
            self.events = events
        }

        static func eventKit(store: EKEventStore = LiveCalendarStore.sharedEventStore) -> EventSource {
            EventSource(
                authorization: {
                    switch EKEventStore.authorizationStatus(for: .event) {
                    case .notDetermined: return .notDetermined
                    case .fullAccess: return .granted
                    case .writeOnly, .restricted, .denied: return .denied
                    @unknown default: return .denied
                    }
                },
                requestAccess: {
                    (try? await store.requestFullAccessToEvents()) ?? false
                },
                events: { start, end in
                    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                    return store.events(matching: predicate).compactMap(LiveCalendarStore.reduce)
                }
            )
        }
    }

    static let sharedEventStore = EKEventStore()

    nonisolated static func reduce(_ event: EKEvent) -> LiveCalendarEvent? {
        guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { return nil }
        guard event.status != .canceled else { return nil }
        return LiveCalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            startDate: start,
            endDate: end,
            joinURL: MeetingLinkDetector.firstMeetingURL(
                url: event.url,
                location: event.location,
                notes: event.notes
            )
        )
    }

    // MARK: - State

    private(set) var authorization: Authorization = .notDetermined
    private(set) var nextEvent: LiveCalendarEvent?

    private var refreshTask: Task<Void, Never>?

    // MARK: - Decisions (pure, no EventKit)

    static let lookahead: TimeInterval = 12 * 60 * 60

    // A meeting already in progress beats a nearer-starting one: that's the one with a Join button worth pressing.
    static func selectNextEvent(from events: [LiveCalendarEvent], now: Date) -> LiveCalendarEvent? {
        let live = events
            .filter { $0.isLive(at: now) }
            .min(by: { $0.startDate > $1.startDate })
        if let live { return live }
        return events
            .filter { $0.startDate > now }
            .min(by: { $0.startDate < $1.startDate })
    }

    // MARK: - Driving it

    func refresh(source: EventSource, now: Date = Date()) {
        guard LiveCalendarSettings.isEnabled else {
            authorization = .notDetermined
            nextEvent = nil
            return
        }
        authorization = source.authorization()
        guard authorization == .granted else {
            nextEvent = nil
            return
        }
        let events = source.events(now.addingTimeInterval(-4 * 60 * 60), now.addingTimeInterval(Self.lookahead))
        nextEvent = Self.selectNextEvent(from: events, now: now)
    }

    func connect(source: EventSource = .eventKit()) async {
        _ = await source.requestAccess()
        refresh(source: source)
    }

    func startRefreshing(source: EventSource = .eventKit()) {
        refreshTask?.cancel()
        refresh(source: source)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LiveCalendarCountdown.refreshInterval))
                guard !Task.isCancelled else { return }
                self?.refresh(source: source)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func joinURLForActiveMeeting() -> URL? { nextEvent?.joinURL }
}
