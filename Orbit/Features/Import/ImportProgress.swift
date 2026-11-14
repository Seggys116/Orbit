import Foundation

// Every progress number comes from real counts: planned totals are the size of what the reader returned, completed is what was applied.

nonisolated enum ImportItemKind: String, CaseIterable, Sendable, Hashable {
    case spaces
    case tabs
    case bookmarks
    case history
    case extensions
    case sessions
    case siteData

    var title: String {
        switch self {
        case .spaces: "Spaces"
        case .tabs: "Tabs"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .extensions: "Extensions"
        case .sessions: "Signed-in sessions"
        case .siteData: "Site data"
        }
    }

    /// History is the long pole of a real import, so it carries the most weight; the rest are small and quick.
    var weight: Double {
        switch self {
        case .history: 4
        case .bookmarks: 3
        case .tabs, .extensions: 2
        case .spaces, .sessions, .siteData: 1
        }
    }
}

nonisolated enum ImportProgressEvent: Equatable, Sendable {
    case planned(ImportItemKind, total: Int?)
    case advanced(ImportItemKind, completed: Int)
    case finished(ImportItemKind, completed: Int)
}

nonisolated enum ImportProgressCadence {
    /// History rows between progress reports: often enough to look live, rare enough not to flood the main actor.
    static let historyBatch = 50
}

typealias ImportProgressHandler = @MainActor (ImportProgressEvent) -> Void

nonisolated struct ImportProgressItem: Equatable, Identifiable, Sendable {
    var kind: ImportItemKind
    var completed: Int
    var total: Int?
    var isFinished: Bool

    var id: ImportItemKind { kind }

    var fraction: Double {
        if isFinished { return 1 }
        guard let total, total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

nonisolated struct ImportProgress: Equatable, Sendable {
    private(set) var items: [ImportProgressItem] = []

    init() {}

    var isEmpty: Bool { items.isEmpty }

    func item(_ kind: ImportItemKind) -> ImportProgressItem? {
        items.first { $0.kind == kind }
    }

    var overallFraction: Double {
        let totalWeight = items.reduce(0) { $0 + $1.kind.weight }
        guard totalWeight > 0 else { return 0 }
        let done = items.reduce(0) { $0 + $1.kind.weight * $1.fraction }
        return min(max(done / totalWeight, 0), 1)
    }

    var isFinished: Bool {
        !items.isEmpty && items.allSatisfy(\.isFinished)
    }

    mutating func apply(_ event: ImportProgressEvent) {
        switch event {
        case .planned(let kind, let total):
            if let index = items.firstIndex(where: { $0.kind == kind }) {
                items[index].total = total
            } else {
                items.append(ImportProgressItem(kind: kind, completed: 0, total: total, isFinished: false))
            }
        case .advanced(let kind, let completed):
            let index = ensureItem(kind)
            // Never moves backwards: a late, out-of-order report must not make the bar retreat.
            items[index].completed = max(items[index].completed, completed)
        case .finished(let kind, let completed):
            let index = ensureItem(kind)
            items[index].completed = max(items[index].completed, completed)
            items[index].isFinished = true
        }
    }

    mutating func finishAll() {
        for index in items.indices { items[index].isFinished = true }
    }

    private mutating func ensureItem(_ kind: ImportItemKind) -> Int {
        if let index = items.firstIndex(where: { $0.kind == kind }) { return index }
        items.append(ImportProgressItem(kind: kind, completed: 0, total: nil, isFinished: false))
        return items.count - 1
    }
}
