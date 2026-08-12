import Foundation

// On disk: State/state.json (current), State/Backups/state-<ISO8601>.json (rolling), State/.state-<uuid>.tmp (transient write target).

// MARK: - A backup on disk

nonisolated public struct StateBackup: Identifiable, Hashable, Sendable {
    public var url: URL
    public var capturedAt: Date

    public var id: URL { url }

    public init(url: URL, capturedAt: Date) {
        self.url = url
        self.capturedAt = capturedAt
    }
}

// MARK: - Retention

nonisolated public enum StateBackupRetention {

    public static let defaultSameDayLimit = 10

    public static let dailyTierDays = 10

    public static let weeklyTierDays = 31

    public static let monthlyTierDays = 366

    public enum Bucket: Hashable, Sendable {
        case today
        case day(Int)
        case week(week: Int, year: Int)
        case month(month: Int, year: Int)
    }

    public static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> Bucket? {
        let startOfBackupDay = calendar.startOfDay(for: date)
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack = calendar.dateComponents([.day], from: startOfBackupDay, to: startOfToday).day ?? 0

        if daysBack <= 0 { return .today }
        if daysBack <= dailyTierDays { return .day(daysBack) }
        if daysBack <= weeklyTierDays {
            let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
            return .week(week: components.weekOfYear ?? 0, year: components.yearForWeekOfYear ?? 0)
        }
        if daysBack <= monthlyTierDays {
            let components = calendar.dateComponents([.month, .year], from: date)
            return .month(month: components.month ?? 0, year: components.year ?? 0)
        }
        return nil
    }

    public static func backupsToKeep(
        from backups: [StateBackup],
        now: Date,
        sameDayLimit: Int = defaultSameDayLimit,
        calendar: Calendar = .current
    ) -> [StateBackup] {
        let todayCapacity = max(1, sameDayLimit)
        var used: [Bucket: Int] = [:]
        var kept: [StateBackup] = []

        for backup in backups.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            guard let bucket = bucket(for: backup.capturedAt, now: now, calendar: calendar) else { continue }
            let capacity = (bucket == .today) ? todayCapacity : 1
            let usedSlots = used[bucket] ?? 0
            guard usedSlots < capacity else { continue }
            used[bucket] = usedSlots + 1
            kept.append(backup)
        }

        return kept
    }

    public static func backupsToPrune(
        from backups: [StateBackup],
        now: Date,
        sameDayLimit: Int = defaultSameDayLimit,
        calendar: Calendar = .current
    ) -> [StateBackup] {
        let keptURLs = Set(
            backupsToKeep(from: backups, now: now, sameDayLimit: sameDayLimit, calendar: calendar).map(\.url)
        )
        return backups.filter { !keptURLs.contains($0.url) }
    }
}

public enum StateStoreError: Error, LocalizedError, Sendable {
    case fileMissing
    case noValidState(reason: String)
    case encodingFailed(reason: String)
    case decodingFailed(reason: String)
    case ioFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "No saved Orbit state was found."
        case .noValidState(let reason):
            return "Orbit's saved state and every backup are unreadable: \(reason)"
        case .encodingFailed(let reason):
            return "Failed to encode Orbit's state: \(reason)"
        case .decodingFailed(let reason):
            return "Failed to decode Orbit's state: \(reason)"
        case .ioFailed(let reason):
            return "Failed to write Orbit's state to disk: \(reason)"
        }
    }
}

public actor StateStore {

    public static let shared = StateStore()

    // MARK: - Immutable, Sendable configuration (safe to touch `nonisolated`)

    public nonisolated let rootDirectory: URL
    public nonisolated let stateFileURL: URL
    public nonisolated let backupsDirectory: URL

    public nonisolated let maxBackups: Int

    // MARK: - Actor-isolated debounce state

    private var pendingState: OrbitState?
    private var debounceTask: Task<Void, Never>?

    private var debouncedSaveFailureHandler: (@Sendable (Error) -> Void)?

    public func onDebouncedSaveFailure(_ handler: @escaping @Sendable (Error) -> Void) {
        debouncedSaveFailureHandler = handler
    }

    private static let debounceDuration: Duration = .milliseconds(750)

    // MARK: - Init

    public init(rootDirectory: URL? = nil, maxBackups: Int = 10) {
        let base = rootDirectory ?? StateStore.defaultRootDirectory()
        self.rootDirectory = base
        self.stateFileURL = base.appendingPathComponent("state.json", isDirectory: false)
        self.backupsDirectory = base.appendingPathComponent("Backups", isDirectory: true)
        self.maxBackups = max(1, maxBackups)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    public nonisolated static func defaultRootDirectory() -> URL { OrbitDataRoot.processDefault.state }

    // MARK: - Load

    public nonisolated func load() throws -> OrbitState {
        do {
            return try Self.decodeState(from: stateFileURL)
        } catch {
            return try recoverFromNewestValidBackup(originalError: error)
        }
    }

    private nonisolated func recoverFromNewestValidBackup(originalError: Error) throws -> OrbitState {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let candidates = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for backupURL in candidates {
            if let state = try? Self.decodeState(from: backupURL) {
                return state
            }
        }

        let reason = (originalError as? LocalizedError)?.errorDescription ?? String(describing: originalError)
        throw StateStoreError.noValidState(reason: reason)
    }

    private nonisolated static func decodeState(from url: URL) throws -> OrbitState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StateStoreError.fileMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StateStoreError.ioFailed(reason: error.localizedDescription)
        }

        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StateStoreError.decodingFailed(reason: error.localizedDescription)
        }
        guard let raw = rawObject as? [String: Any] else {
            throw StateStoreError.decodingFailed(reason: "Top-level JSON was not an object.")
        }

        let migrated = try SchemaMigration.migrate(raw)

        let migratedData: Data
        do {
            migratedData = try JSONSerialization.data(withJSONObject: migrated)
        } catch {
            throw StateStoreError.decodingFailed(reason: "Migrated document could not be re-serialised: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OrbitState.self, from: migratedData)
        } catch {
            throw StateStoreError.decodingFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Debounced save

    public func scheduleSave(_ state: OrbitState) {
        pendingState = state
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: StateStore.debounceDuration)
            guard !Task.isCancelled else { return }
            await self?.flushPendingSave()
        }
    }

    private func flushPendingSave() async {
        guard let toSave = pendingState else { return }
        pendingState = nil
        do {
            try Self.write(toSave, stateFileURL: stateFileURL, backupsDirectory: backupsDirectory, maxBackups: maxBackups)
        } catch {
            debouncedSaveFailureHandler?(error)
        }
    }

    public func cancelPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingState = nil
    }

    // MARK: - Synchronous, termination-safe save

    @discardableResult
    public nonisolated func saveNow(_ state: OrbitState) throws -> URL {
        try Self.write(state, stateFileURL: stateFileURL, backupsDirectory: backupsDirectory, maxBackups: maxBackups)
        return stateFileURL
    }

    // MARK: - Shared write path

    private nonisolated static func write(
        _ state: OrbitState,
        stateFileURL: URL,
        backupsDirectory: URL,
        maxBackups: Int
    ) throws {
        // Every write funnels through here so an Incognito Profile/Space never reaches state.json.
        let persistable = state.strippingEphemeralEntities()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(persistable)
        } catch {
            throw StateStoreError.encodingFailed(reason: error.localizedDescription)
        }

        let directory = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw StateStoreError.ioFailed(reason: error.localizedDescription)
        }

        if FileManager.default.fileExists(atPath: stateFileURL.path) {
            try? backupExistingStateFile(stateFileURL: stateFileURL, backupsDirectory: backupsDirectory, maxBackups: maxBackups)
        }

        do {
            if FileManager.default.fileExists(atPath: stateFileURL.path) {
                _ = try FileManager.default.replaceItemAt(stateFileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: stateFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw StateStoreError.ioFailed(reason: error.localizedDescription)
        }
    }

    private nonisolated static func backupExistingStateFile(
        stateFileURL: URL,
        backupsDirectory: URL,
        maxBackups: Int
    ) throws {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var backupURL = backupsDirectory.appendingPathComponent("state-\(stamp).json", isDirectory: false)
        var disambiguator = 1
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = backupsDirectory.appendingPathComponent("state-\(stamp)-\(disambiguator).json", isDirectory: false)
            disambiguator += 1
        }
        try FileManager.default.copyItem(at: stateFileURL, to: backupURL)
        try pruneBackups(in: backupsDirectory, keeping: maxBackups)
    }

    private nonisolated static func pruneBackups(in directory: URL, keeping maxBackups: Int) throws {
        let all = backups(in: directory)
        let stale = StateBackupRetention.backupsToPrune(from: all, now: Date(), sameDayLimit: maxBackups)
        for backup in stale {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    // MARK: - Reading the backups (Restore Data)

    public nonisolated func availableBackups() -> [StateBackup] {
        Self.backups(in: backupsDirectory)
    }

    private nonisolated static func backups(in directory: URL) -> [StateBackup] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StateBackup? in
                guard let date = capturedDate(of: url) else { return nil }
                return StateBackup(url: url, capturedAt: date)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    nonisolated static func capturedDate(of url: URL) -> Date? {
        if let parsed = capturedDate(fromBackupFileName: url.lastPathComponent) {
            return parsed
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated static func capturedDate(fromBackupFileName name: String) -> Date? {
        let prefix = "state-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))

        guard let tIndex = stamp.firstIndex(of: "T") else { return nil }
        let timeStart = stamp.index(after: tIndex)
        guard let zIndex = stamp[timeStart...].firstIndex(of: "Z") else { return nil }

        let datePart = String(stamp[stamp.startIndex..<tIndex])
        let timePart = String(stamp[timeStart..<zIndex]).replacingOccurrences(of: "-", with: ":")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: datePart + "T" + timePart + "Z")
    }

    public nonisolated func decodeBackup(_ backup: StateBackup) throws -> OrbitState {
        try Self.decodeState(from: backup.url)
    }
}
