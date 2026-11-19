import CloudKit
import Foundation

nonisolated public struct SyncProblem: Equatable, Sendable {

    nonisolated public enum Kind: Equatable, Sendable {
        case schemaNotDeployed(recordType: String?)
        case quotaExceeded
        case network
        case notAuthenticated
        case zoneMissing
        case unreadableRemoteData(count: Int)
        case batchTooLarge
        case permissionDenied
        case conflict
        case rateLimited(retryAfter: TimeInterval?)
        case interrupted
        case unknown(codeName: String?)
    }

    public let kind: Kind
    public let message: String
    public let recoveryHint: String

    public init(kind: Kind, message: String, recoveryHint: String) {
        self.kind = kind
        self.message = message
        self.recoveryHint = recoveryHint
    }

    public var isTransient: Bool {
        switch kind {
        case .network, .rateLimited, .interrupted: return true
        default: return false
        }
    }

    public var isPermanent: Bool {
        switch kind {
        case .schemaNotDeployed, .permissionDenied, .unknown: return true
        default: return false
        }
    }

    public var suggestsForceOverwrite: Bool {
        switch kind {
        case .conflict, .zoneMissing, .unknown, .unreadableRemoteData: return true
        default: return false
        }
    }

    public var requiresICloudReset: Bool {
        if case .unreadableRemoteData = kind { return true }
        return false
    }

    public var isSchemaProblem: Bool {
        if case .schemaNotDeployed = kind { return true }
        return false
    }

    // MARK: Classification

    nonisolated public static func classify(_ error: Error, recordType: String? = nil) -> SyncProblem {
        let text = descriptions(of: error).joined(separator: "\n")
        if isMissingSchemaMessage(text) {
            return schemaNotDeployed(recordType: schemaRecordType(in: text) ?? recordType)
        }
        guard let ckError = error as? CKError else {
            return SyncProblem(
                kind: .unknown(codeName: nil),
                message: error.localizedDescription,
                recoveryHint: unknownHint
            )
        }
        if ckError.code == .partialFailure {
            return classifyPartialFailure(ckError, recordType: recordType)
        }
        return classifyCode(ckError, recordType: recordType)
    }

    nonisolated public static func unreadableRemoteData(count: Int, recordTypes: Set<String>) -> SyncProblem {
        let items = count == 1 ? "1 item" : "\(count) items"
        let kinds = recordTypes.sorted().joined(separator: ", ")
        return SyncProblem(
            kind: .unreadableRemoteData(count: count),
            message: "\(items) Orbit has stored in iCloud (\(kinds)) can't be read, so iCloud's copy needs to be reset.",
            recoveryHint: "Wiping Orbit's iCloud data deletes only what Orbit stores in your iCloud account and uploads what is on this Mac in its place. Nothing else in iCloud is touched, and nothing on this Mac is deleted."
        )
    }

    nonisolated public static func incompleteRecovery() -> SyncProblem {
        SyncProblem(
            kind: .network,
            message: "Orbit couldn't finish clearing the data in iCloud, so nothing was changed.",
            recoveryHint: "Check your internet connection and try again."
        )
    }

    private static func classifyCode(_ error: CKError, recordType: String?) -> SyncProblem {
        switch error.code {
        case .quotaExceeded:
            return SyncProblem(
                kind: .quotaExceeded,
                message: "iCloud storage is full. Orbit will keep working locally until there's room to sync again.",
                recoveryHint: "Free up iCloud storage in System Settings, then choose Try Again."
            )
        case .networkUnavailable, .networkFailure:
            return SyncProblem(
                kind: .network,
                message: "Orbit couldn't reach iCloud. It will keep working locally and retry when the connection is back.",
                recoveryHint: "Check your internet connection."
            )
        case .serviceUnavailable, .accountTemporarilyUnavailable:
            return SyncProblem(
                kind: .network,
                message: "iCloud is temporarily unavailable. Orbit will keep working locally and retry.",
                recoveryHint: "Wait a moment, then choose Try Again."
            )
        case .requestRateLimited, .zoneBusy:
            return SyncProblem(
                kind: .rateLimited(retryAfter: error.retryAfterSeconds),
                message: "iCloud asked Orbit to slow down. Orbit will retry shortly.",
                recoveryHint: "No action needed."
            )
        case .notAuthenticated:
            return SyncProblem(
                kind: .notAuthenticated,
                message: "You're not signed in to iCloud on this Mac. Orbit is working locally.",
                recoveryHint: "Sign in to iCloud in System Settings, then choose Try Again."
            )
        case .zoneNotFound, .userDeletedZone:
            return SyncProblem(
                kind: .zoneMissing,
                message: "Orbit's data in iCloud is missing. This usually means iCloud data for Orbit was deleted from another device or from iCloud settings.",
                recoveryHint: "Choose Replace iCloud with This Mac to recreate it from what is on this Mac."
            )
        case .limitExceeded:
            return SyncProblem(
                kind: .batchTooLarge,
                message: "Orbit tried to send too many changes at once and iCloud refused the batch.",
                recoveryHint: "Choose Try Again. Orbit sends changes in smaller groups."
            )
        case .permissionFailure:
            return SyncProblem(
                kind: .permissionDenied,
                message: "iCloud refused permission to change Orbit's data (permission failure).",
                recoveryHint: "Check that iCloud is enabled for Orbit in System Settings, then choose Try Again."
            )
        case .serverRecordChanged:
            return SyncProblem(
                kind: .conflict,
                message: "iCloud has newer changes than this Mac for some items, and Orbit couldn't merge them automatically.",
                recoveryHint: "Choose Try Again. If it keeps happening, replace one side with the other."
            )
        case .operationCancelled, .changeTokenExpired:
            return SyncProblem(
                kind: .interrupted,
                message: "The iCloud sync was interrupted. Orbit will retry.",
                recoveryHint: "No action needed."
            )
        default:
            let name = codeName(error.code)
            let detail = detailDescription(of: error)
            let subject = recordType.map { "Couldn't sync a \($0) record to iCloud" } ?? "iCloud sync error"
            return SyncProblem(
                kind: .unknown(codeName: name),
                message: "\(subject) (\(name)): \(detail)",
                recoveryHint: unknownHint
            )
        }
    }

    private static let unknownHint = "Choose Try Again. If it keeps failing, you can replace what is in iCloud with this Mac, or this Mac with what is in iCloud."

    private static func classifyPartialFailure(_ error: CKError, recordType: String?) -> SyncProblem {
        let subErrors = (error.partialErrorsByItemID ?? [:]).values.filter { ($0 as? CKError)?.code != .batchRequestFailed }
        let problems = subErrors.map { classify($0, recordType: recordType) }
        if let worst = problems.min(by: { severity($0.kind) < severity($1.kind) }) {
            return worst
        }
        let name = codeName(error.code)
        return SyncProblem(
            kind: .unknown(codeName: name),
            message: "iCloud sync error (\(name)): \(detailDescription(of: error))",
            recoveryHint: unknownHint
        )
    }

    private static func severity(_ kind: Kind) -> Int {
        switch kind {
        case .schemaNotDeployed: return 0
        case .permissionDenied: return 1
        case .quotaExceeded: return 2
        case .notAuthenticated: return 3
        case .zoneMissing: return 4
        case .unreadableRemoteData: return 4
        case .batchTooLarge: return 5
        case .unknown: return 6
        case .conflict: return 7
        case .network: return 8
        case .rateLimited: return 9
        case .interrupted: return 10
        }
    }

    // MARK: Production schema

    private static func isMissingSchemaMessage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("cannot create new type") || lowered.contains("production schema")
    }

    private static func schemaRecordType(in text: String) -> String? {
        let marker = "Cannot create new type "
        guard let range = text.range(of: marker, options: .caseInsensitive) else { return nil }
        let name = text[range.upperBound...].prefix { !$0.isWhitespace && $0 != "," && $0 != "\"" && $0 != "'" }
        return name.isEmpty ? nil : String(name)
    }

    private static func schemaNotDeployed(recordType: String?) -> SyncProblem {
        let subject = recordType.map { "the \($0) record type" } ?? "one of Orbit's record types"
        return SyncProblem(
            kind: .schemaNotDeployed(recordType: recordType),
            message: "This build's iCloud container has no deployed schema for \(subject), so nothing can be uploaded until the schema is deployed to Production in the CloudKit console. Overwriting data in iCloud or on this Mac will not help.",
            recoveryHint: "In the CloudKit console, open the Orbit container, choose Deploy Schema Changes and deploy the Development schema to Production. Then choose Try Again."
        )
    }

    // MARK: Text extraction

    private static func descriptions(of error: Error, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        let nsError = error as NSError
        var result = [error.localizedDescription]
        for value in nsError.userInfo.values {
            if let string = value as? String { result.append(string) }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            result += descriptions(of: underlying, depth: depth + 1)
        }
        if let partial = (error as? CKError)?.partialErrorsByItemID {
            for sub in partial.values { result += descriptions(of: sub, depth: depth + 1) }
        }
        return result
    }

    private static func detailDescription(of error: Error) -> String {
        var detail = error.localizedDescription
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingText = underlying.localizedDescription
            if !underlyingText.isEmpty, !detail.contains(underlyingText) {
                detail += " (\(underlyingText))"
            }
        }
        return detail
    }

    nonisolated public static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return "CKError \(code.rawValue)"
        }
    }
}
