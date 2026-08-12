import CloudKit
import Foundation

nonisolated public enum SyncStatus: Equatable, Sendable {

    case disabled

    case off

    case unavailable(reason: UnavailableReason)

    case idle(lastSyncedAt: Date?)

    case syncing

    case error(message: String)

    nonisolated public enum UnavailableReason: Equatable, Sendable {
        case noAccount
        case restricted
        case couldNotDetermine
        case temporarilyUnavailable

        case containerNotConfigured

        public init?(accountStatus: CKAccountStatus) {
            switch accountStatus {
            case .available:
                return nil
            case .noAccount:
                self = .noAccount
            case .restricted:
                self = .restricted
            case .couldNotDetermine:
                self = .couldNotDetermine
            case .temporarilyUnavailable:
                self = .temporarilyUnavailable
            @unknown default:
                self = .couldNotDetermine
            }
        }

        public var userFacingMessage: String {
            switch self {
            case .noAccount:
                return "Not signed in to iCloud. Orbit is working locally."
            case .restricted:
                return "iCloud is restricted on this Mac. Orbit is working locally."
            case .couldNotDetermine:
                return "Orbit couldn't check your iCloud account. Working locally for now."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Orbit is working locally and will retry."
            case .containerNotConfigured:
                return "This build of Orbit isn't set up for iCloud. Everything is saved on this Mac."
            }
        }
    }

    public var isActivelyWorking: Bool {
        if case .syncing = self { return true }
        return false
    }

    public var isSynced: Bool {
        if case .idle(let lastSyncedAt) = self { return lastSyncedAt != nil }
        return false
    }

    public var userFacingMessage: String {
        switch self {
        case .disabled:
            return "iCloud sync isn't running yet."
        case .off:
            return "iCloud sync is off. Everything is saved on this Mac."
        case .unavailable(let reason):
            return reason.userFacingMessage
        case .idle(let lastSyncedAt):
            guard let lastSyncedAt else { return "Waiting to sync with iCloud…" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: Date()))."
        case .syncing:
            return "Syncing with iCloud…"
        case .error(let message):
            return message
        }
    }
}
