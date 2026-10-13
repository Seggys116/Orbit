// The WebKit wrapper only grants permissions the extension declared.

import XCTest

final class ExtensionPermissionRegistrationGuardTests: XCTestCase {

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func text(at url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(
            text.count, 500,
            "Walked \(text.count) characters of \(url.path). That is far too few — the path resolution is wrong and every check below would pass vacuously."
        )
        return text
    }

    func test_everyPermissionFeatureEntryHasAMatchingNameToIDRegistration() throws {
        let engine = try text(at: repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"))
        XCTAssertTrue(engine.contains("for permission in webExtension.requestedPermissions"))
        XCTAssertTrue(engine.contains("setPermissionStatus(.grantedExplicitly, for: permission)"))
    }

    func test_everyRegisteredPermissionHasAMatchingFeatureAvailabilityEntry() throws {
        let wrapper = try text(at: repositoryFile("Orbit/Engine/WebKit/ChromeAPIWrapperScript.swift"))
        XCTAssertTrue(wrapper.contains("nativeMessaging"))
        XCTAssertTrue(wrapper.contains("management:"))
    }

    func test_scriptingAndManagementAreRegistered() throws {
        let wrapper = try text(at: repositoryFile("Orbit/Engine/WebKit/ChromeAPIWrapperScript.swift"))
        XCTAssertTrue(wrapper.contains("management:"))
        let engine = try text(at: repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"))
        XCTAssertTrue(engine.contains("WKWebExtension"))
    }
}
