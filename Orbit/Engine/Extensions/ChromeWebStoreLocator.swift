import Foundation

nonisolated public enum ChromeWebStoreLocator {

    public static func extensionID(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChromeWebStoreError.unrecognizedInput(input)
        }

        guard trimmed.contains("/") || trimmed.contains(":") else {
            guard ChromeExtensionID.isValid(trimmed) else {
                throw ChromeWebStoreError.invalidExtensionID(trimmed)
            }
            return trimmed
        }

        var components = URLComponents(string: trimmed)
        if components?.host == nil {
            components = URLComponents(string: "https://" + trimmed)
        }
        guard let components, let host = components.host?.lowercased() else {
            throw ChromeWebStoreError.unrecognizedInput(input)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ChromeWebStoreError.unrecognizedInput(input)
        }

        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let candidateID: String
        switch host {
        case "chromewebstore.google.com":
            guard pathComponents.count >= 2, pathComponents[0] == "detail" else {
                throw ChromeWebStoreError.unrecognizedInput(input)
            }
            let remaining = Array(pathComponents[1...])
            candidateID = remaining.count == 1 ? remaining[0] : remaining[1]

        case "chrome.google.com":
            guard pathComponents.count >= 3, pathComponents[0] == "webstore", pathComponents[1] == "detail" else {
                throw ChromeWebStoreError.unrecognizedInput(input)
            }
            let remaining = Array(pathComponents[2...])
            candidateID = remaining.count == 1 ? remaining[0] : remaining[1]

        default:
            throw ChromeWebStoreError.unrecognizedInput(input)
        }

        guard ChromeExtensionID.isValid(candidateID) else {
            throw ChromeWebStoreError.invalidExtensionID(candidateID)
        }
        return candidateID
    }

    public static func detailURL(forExtensionID id: String) throws -> URL {
        guard ChromeExtensionID.isValid(id) else {
            throw ChromeWebStoreError.invalidExtensionID(id)
        }
        guard let url = URL(string: ArcExtensionInventory.webStoreDetailPrefix + id) else {
            throw ChromeWebStoreError.invalidExtensionID(id)
        }
        return url
    }
}
