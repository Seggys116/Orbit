import CloudKit
import Foundation
import Security

// MARK: - Availability

public enum SyncAvailability: Equatable, Sendable {
    case ready
    case containerNotEntitled(containerIdentifier: String)

    public var isReady: Bool { self == .ready }
}

public enum SyncEntitlements {

    public static let containerIdentifiersKey = "com.apple.developer.icloud-container-identifiers"

    nonisolated public static func entitledContainerIdentifiers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        guard let value = SecTaskCopyValueForEntitlement(task, containerIdentifiersKey as CFString, nil) else {
            return []
        }
        return (value as? [String]) ?? []
    }

    nonisolated public static func availability(forContainer identifier: String) -> SyncAvailability {
        entitledContainerIdentifiers().contains(identifier)
            ? .ready
            : .containerNotEntitled(containerIdentifier: identifier)
    }
}

// MARK: - The seam

@MainActor
public protocol SyncTransport: AnyObject {

    var isActivated: Bool { get }

    func activate(delegate: any CKSyncEngineDelegate, stateSerialization: CKSyncEngine.State.Serialization?) throws

    func accountStatus() async throws -> CKAccountStatus

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }

    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])

    func fetchChanges() async throws
    func sendChanges() async throws
}

public enum SyncTransportError: Error, LocalizedError, Sendable {
    case containerNotEntitled(identifier: String)
    case alreadyActivated

    public var errorDescription: String? {
        switch self {
        case .containerNotEntitled(let identifier):
            return "This build of Orbit isn't signed for the iCloud container \(identifier)."
        case .alreadyActivated:
            return "The iCloud sync transport was activated twice."
        }
    }
}

// MARK: - The production transport

@MainActor
public final class CloudKitSyncTransport: SyncTransport {

    private let containerIdentifier: String
    private let availabilityProbe: @Sendable (String) -> SyncAvailability
    private var container: CKContainer?
    private var syncEngine: CKSyncEngine?
    private let subscriptionID: CKSubscription.ID

    public init(
        containerIdentifier: String,
        subscriptionID: CKSubscription.ID,
        availabilityProbe: @escaping @Sendable (String) -> SyncAvailability = SyncEntitlements.availability(forContainer:)
    ) {
        self.containerIdentifier = containerIdentifier
        self.subscriptionID = subscriptionID
        self.availabilityProbe = availabilityProbe
    }

    public var isActivated: Bool { syncEngine != nil }

    public func activate(delegate: any CKSyncEngineDelegate, stateSerialization: CKSyncEngine.State.Serialization?) throws {
        guard syncEngine == nil else { throw SyncTransportError.alreadyActivated }
        // Must run before CKContainer(identifier:): it raises, not throws, for a container the process isn't entitled to.
        guard case .ready = availabilityProbe(containerIdentifier) else {
            throw SyncTransportError.containerNotEntitled(identifier: containerIdentifier)
        }
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: delegate
        )
        configuration.subscriptionID = subscriptionID
        syncEngine = CKSyncEngine(configuration)
    }

    public func accountStatus() async throws -> CKAccountStatus {
        guard let container else { throw SyncTransportError.containerNotEntitled(identifier: containerIdentifier) }
        return try await container.accountStatus()
    }

    public var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        syncEngine?.state.pendingRecordZoneChanges ?? []
    }

    public var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
        syncEngine?.state.pendingDatabaseChanges ?? []
    }

    public func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        syncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    public func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        syncEngine?.state.remove(pendingRecordZoneChanges: changes)
    }

    public func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        syncEngine?.state.add(pendingDatabaseChanges: changes)
    }

    public func fetchChanges() async throws {
        guard let syncEngine else { return }
        try await syncEngine.fetchChanges()
    }

    public func sendChanges() async throws {
        guard let syncEngine else { return }
        try await syncEngine.sendChanges()
    }
}
