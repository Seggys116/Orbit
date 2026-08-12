import Foundation

/// One `chrome.permissions.request` awaiting the user's answer. `requestID` is
/// both the answer token and the identity.
public struct ExtensionPermissionsConsentRequest: Equatable, Identifiable, Sendable {
    public let requestID: UInt64
    public let extensionID: String
    public let extensionName: String
    public let permissions: [String]
    public let origins: [String]
    public let warnings: [String]

    public var id: UInt64 { requestID }

    public init(
        requestID: UInt64,
        extensionID: String,
        extensionName: String,
        permissions: [String],
        origins: [String],
        warnings: [String]
    ) {
        self.requestID = requestID
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.permissions = permissions
        self.origins = origins
        self.warnings = warnings
    }

    private struct Payload: Decodable {
        let extensionId: String
        let extensionName: String
        let permissions: [String]
        let origins: [String]
        let warnings: [String]
    }

    /// `nil` for JSON that does not decode, or that carries no warning text —
    /// the engine only asks when there is something to warn about, so an empty
    /// list is a malformed request rather than a silent prompt.
    public init?(json: String, requestID: UInt64) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.warnings.isEmpty
        else { return nil }
        self.init(
            requestID: requestID,
            extensionID: payload.extensionId,
            extensionName: payload.extensionName,
            permissions: payload.permissions,
            origins: payload.origins,
            warnings: payload.warnings
        )
    }
}
