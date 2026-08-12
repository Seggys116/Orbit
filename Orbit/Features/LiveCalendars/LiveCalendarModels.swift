import Foundation

struct LiveCalendarEvent: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    // nil means the row shows a countdown and no Join button — never a Join button that goes nowhere.
    var joinURL: URL?

    func isLive(at now: Date) -> Bool { now >= startDate && now < endDate }

    func secondsUntilStart(from now: Date) -> TimeInterval { startDate.timeIntervalSince(now) }
}

enum MeetingLinkDetector {

    static let meetingHosts: [String] = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "chime.aws",
        "bluejeans.com",
        "gotomeeting.com",
        "around.co",
        "riverside.fm",
        "discord.gg",
    ]

    static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func firstMeetingURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeetingURL(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            if let found = scan(text) { return found }
        }
        return nil
    }

    static func scan(_ text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: URL?
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let candidate = match?.url, isMeetingURL(candidate) else { return }
            found = candidate
            stop.pointee = true
        }
        return found
    }
}

enum LiveCalendarCountdown {

    static func text(for event: LiveCalendarEvent, now: Date, calendar: Calendar = .current) -> String {
        let seconds = event.secondsUntilStart(from: now)

        if seconds <= 0 {
            let elapsed = Int((-seconds / 60).rounded(.down))
            return elapsed < 1 ? "now" : "\(elapsed)m ago"
        }

        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }

        if calendar.isDate(event.startDate, inSameDayAs: now) {
            let hours = Int((Double(minutes) / 60).rounded(.down))
            let remainder = minutes % 60
            return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(event.startDate, inSameDayAs: tomorrow) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Event tomorrow at \(formatter.string(from: event.startDate))"
        }

        let days = Int((seconds / 86_400).rounded(.up))
        return "in \(days)d"
    }

    static let refreshInterval: TimeInterval = 30
}

enum LiveCalendarLeadTime: String, CaseIterable, Sendable {
    case tenMinutes
    case fiveMinutes
    case twoMinutes

    var title: String {
        switch self {
        case .tenMinutes: return "Ten Minutes Before"
        case .fiveMinutes: return "Five Minutes Before"
        case .twoMinutes: return "Two Minutes Before"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .tenMinutes: return 10 * 60
        case .fiveMinutes: return 5 * 60
        case .twoMinutes: return 2 * 60
        }
    }

    static let `default` = LiveCalendarLeadTime.twoMinutes
}

extension LiveCalendarEvent {
    func shouldOfferJoin(at now: Date, leadTime: LiveCalendarLeadTime) -> Bool {
        guard joinURL != nil else { return false }
        guard now < endDate else { return false }
        return startDate.timeIntervalSince(now) <= leadTime.interval
    }
}

enum CalendarSiteMatcher {

    static let calendarHosts: [String] = [
        "calendar.google.com",
        "outlook.office.com",
        "outlook.office365.com",
        "outlook.live.com",
        "calendar.yahoo.com",
        "fastmail.com",
        "app.fastmail.com",
        "cal.com",
        "calendar.proton.me",
        "app.cron.com",
        "notion.so",
    ]

    // Outlook mail/calendar share a host and Notion's calendar is a path, so those also check the path.
    static func isCalendar(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()

        switch host {
        case "calendar.google.com", "calendar.yahoo.com", "calendar.proton.me", "app.cron.com":
            return true
        case "cal.com":
            return true
        default:
            break
        }
        if host.hasSuffix("outlook.office.com") || host.hasSuffix("outlook.office365.com") || host.hasSuffix("outlook.live.com") {
            return path.contains("calendar")
        }
        if host.hasSuffix("fastmail.com") || host.hasSuffix("notion.so") {
            return path.contains("calendar")
        }
        return false
    }
}

// MARK: - Event emoji
// Symlinked into OrbitTests as a reused source, so it must stay free of AppEnvironment dependencies. See OrbitTests/README.md.

enum EventEmoji {

    static func leading(in title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, isEmojiScalar(first) else { return nil }
        // Whole grapheme cluster, so a flag, skin-tone modifier or ZWJ sequence survives as one character.
        return trimmed.first.map(String.init)
    }

    static func stripLeading(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard leading(in: trimmed) != nil else { return trimmed }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
    }
}
