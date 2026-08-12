import Foundation

public enum SchemaMigration {

    public static let currentVersion = OrbitState.currentSchemaVersion

    public struct MigrationDescriptor: Sendable, Equatable {
        public let fromVersion: Int
        public let summary: String

        public init(fromVersion: Int, summary: String) {
            self.fromVersion = fromVersion
            self.summary = summary
        }
    }

    // Steps must be registered in ascending `fromVersion` order with no gaps; `migrate(_:)` walks them one version at a time up to `currentVersion`.
    public static let registry: [MigrationDescriptor] = [
        MigrationDescriptor(
            fromVersion: 1,
            summary: "v1 identity: current shape, no migration necessary."
        ),
    ]

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case futureSchemaVersion(Int)
        case missingMigrationStep(fromVersion: Int)
        case malformedDocument(reason: String)

        public var errorDescription: String? {
            switch self {
            case .futureSchemaVersion(let version):
                return "This Orbit document was written by a newer version of the app (schema \(version)); this build only understands up to schema \(SchemaMigration.currentVersion)."
            case .missingMigrationStep(let version):
                return "No migration is registered to bring a schema \(version) document forward."
            case .malformedDocument(let reason):
                return "The saved Orbit document is malformed: \(reason)"
            }
        }
    }

    // Runs on raw JSON, not decoded `OrbitState`, so older shapes with missing/renamed keys survive long enough to be transformed.
    public static func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var document = json
        var version = (document["schemaVersion"] as? Int) ?? 1

        guard version <= currentVersion else {
            throw Error.futureSchemaVersion(version)
        }

        while version < currentVersion {
            guard registry.contains(where: { $0.fromVersion == version }) else {
                throw Error.missingMigrationStep(fromVersion: version)
            }
            try apply(stepFrom: version, to: &document)
            version += 1
            document["schemaVersion"] = version
        }

        document["schemaVersion"] = currentVersion
        return document
    }

    private static func apply(stepFrom version: Int, to document: inout [String: Any]) throws {
        switch version {
        case 1:
            // v1 -> v2 template, unreachable while currentSchemaVersion == 1; copy this arm's shape when v2 ships.
            break
        default:
            throw Error.missingMigrationStep(fromVersion: version)
        }
    }
}
