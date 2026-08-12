import AppKit
import Foundation

@MainActor
enum DefaultBrowserStatus {

    static let freshness: TimeInterval = 5

    private static var cachedAnswer: Bool?
    private static var answeredAt: Date?

    static var isDefault: Bool {
        if let cachedAnswer, let answeredAt, Date().timeIntervalSince(answeredAt) < freshness {
            return cachedAnswer
        }
        let answer = DefaultBrowser.isDefault
        cachedAnswer = answer
        answeredAt = Date()
        return answer
    }

    static func invalidate() {
        cachedAnswer = nil
        answeredAt = nil
    }
}
