import XCTest

final class ReleasePipelineTests: XCTestCase {

    // MARK: - Locating and running the real script

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // OrbitTests/ReleasePipelineTests.swift
            .deletingLastPathComponent()         // OrbitTests/
            .deletingLastPathComponent()         // <repo root>
    }

    private static var releaseScript: URL {
        repoRoot.appendingPathComponent("Scripts/release")
    }

    private struct Run {
        let status: Int32
        let output: String

        var succeeded: Bool { status == 0 }
    }

    @discardableResult
    private func release(
        _ arguments: [String],
        clearingNotaryCredentials: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Run {
        let process = Process()
        process.executableURL = Self.releaseScript
        process.arguments = arguments
        process.currentDirectoryURL = Self.repoRoot

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        if clearingNotaryCredentials {
            for name in [
                "ORBIT_NOTARY_KEYCHAIN_PROFILE",
                "APPLE_NOTARY_KEY_PATH",
                "APPLE_NOTARY_KEY_ID",
                "APPLE_NOTARY_ISSUER_ID",
                "APPLE_ID",
                "APPLE_APP_SPECIFIC_PASSWORD",
                "APPLE_TEAM_ID",
            ] {
                environment.removeValue(forKey: name)
            }
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(
            output.contains("Traceback (most recent call last)"),
            "Scripts/release \(arguments.joined(separator: " ")) crashed instead of reporting an error:\n\(output)",
            file: file,
            line: line
        )
        return Run(status: process.terminationStatus, output: output)
    }

    // MARK: - Version resolution

    func testVersionReportsTheChromiumVersionFromTheManifest() throws {
        let manifestURL = Self.repoRoot.appendingPathComponent("Chromium/chromium-version.json")
        let manifest = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: manifestURL)
        ) as? [String: Any]
        let expectedChromium = try XCTUnwrap(manifest?["chromium_version"] as? String)

        let run = try release(["version", "--json", "--manifest-only"])
        XCTAssertTrue(run.succeeded, "version --json failed:\n\(run.output)")

        let reported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any],
            "version --json did not print JSON:\n\(run.output)"
        )
        XCTAssertEqual(reported["chromium_version"] as? String, expectedChromium)
    }

    func testVersionNamesTheDiskImageAfterTheRequestedVersion() throws {
        let run = try release(["version", "--json", "--manifest-only", "--set", "9.8.7"])
        XCTAssertTrue(run.succeeded, run.output)
        let reported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(reported["marketing_version"] as? String, "9.8.7")

        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        let architecture = (machine == "aarch64") ? "arm64" : machine
        XCTAssertEqual(
            reported["dmg_name"] as? String, "Orbit-9.8.7-\(architecture).dmg",
            "the disk image name must be derived from the version, not hard-coded"
        )
    }

    // MARK: - Entitlements

    func testEveryEntitlementsFileMatchesTheRoleTable() throws {
        let run = try release(["entitlements", "--check"])
        XCTAssertTrue(
            run.succeeded,
            "an entitlements file has drifted from the role table in Scripts/release_manager.py. "
            + "Regenerate with `Scripts/release entitlements --write` rather than editing the plist:\n"
            + run.output
        )
    }

    func testRendererGetsJITButNotUnsignedExecutableMemory() throws {
        let granted = try grantedEntitlements(role: "renderer")
        XCTAssertTrue(granted.contains("com.apple.security.cs.allow-jit"))
        XCTAssertFalse(
            granted.contains("com.apple.security.cs.allow-unsigned-executable-memory"),
            "the renderer must not be granted unsigned executable memory: it is the process that "
            + "runs untrusted script, and allow-jit already covers V8's MAP_JIT regions"
        )
        XCTAssertFalse(
            granted.contains("com.apple.security.cs.allow-dyld-environment-variables"),
            "a helper that honours DYLD_INSERT_LIBRARIES is a code-injection surface on the "
            + "process that parses untrusted web content"
        )
    }

    func testAlertsHelperGetsNeitherJITNorExecutableMemory() throws {
        let granted = try grantedEntitlements(role: "alerts")
        XCTAssertFalse(granted.contains("com.apple.security.cs.allow-jit"))
        XCTAssertFalse(granted.contains("com.apple.security.cs.allow-unsigned-executable-memory"))
    }

    /// No role holds this key: the CDM runs as a kCdm utility process with no entitlements at all.
    func testNoRoleIsGrantedUnsignedExecutableMemory() throws {
        for role in ["app", "utility", "renderer", "gpu", "alerts"] {
            XCTAssertFalse(
                try grantedEntitlements(role: role)
                    .contains("com.apple.security.cs.allow-unsigned-executable-memory"),
                "\(role) must not be granted unsigned executable memory: it lets a process build "
                + "and run code in ordinary anonymous memory, which is weaker than allow-jit and is "
                + "what almost every exploit chain wants. Chromium grants it to nothing."
            )
        }
        let run = try release(["entitlements", "--print", "plugin"])
        XCTAssertFalse(
            run.succeeded,
            "the plugin role is back. It exists only to host a third-party CDM, which a direct "
            + "Chromium embed does not do, and it was the sole holder of "
            + "allow-unsigned-executable-memory:\n\(run.output)"
        )
    }

    func testEveryRoleDisablesLibraryValidationBecauseTheFrameworkIsDlopened() throws {
        for role in ["app", "utility", "renderer", "gpu", "alerts"] {
            XCTAssertTrue(
                try grantedEntitlements(role: role)
                    .contains("com.apple.security.cs.disable-library-validation"),
                "\(role) dlopens Chromium code at runtime and cannot do so under library "
                + "validation"
            )
        }
    }

    func testEveryEntitlementsFileIsStrictWellFormedXML() throws {
        for name in Self.entitlementFileNames {
            let url = Self.repoRoot.appendingPathComponent("Orbit/Resources/\(name)")
            let data = try Data(contentsOf: url)

            let parser = XMLParser(data: data)
            XCTAssertTrue(
                parser.parse(),
                "\(name) is not well-formed XML, so codesign will reject it: "
                + "\(parser.parserError?.localizedDescription ?? "unknown error")"
            )

            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for comment in Self.xmlComments(in: text) {
                XCTAssertFalse(
                    comment.contains("--"),
                    "\(name) has a comment containing a double hyphen, which XML forbids and "
                    + "codesign rejects (plutil -lint will not catch it): \(comment.prefix(120))"
                )
            }
        }
    }

    // MARK: - Bundle structure validation

    func testVerifyAcceptsACorrectlyShapedBundle() throws {
        let app = try makeBundle()
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertTrue(run.succeeded, "a correctly shaped bundle was rejected:\n\(run.output)")
    }

    // MARK: - The in-app updater has to survive the build too

    func testVerifyRejectsABundleWithNoSparkleFramework() throws {
        let app = try makeBundle(omittingSparkleFramework: true)
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertFalse(run.succeeded, "a bundle with no updater at all was accepted:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("Sparkle.framework embedded"),
            "the failure must name the missing framework:\n\(run.output)"
        )
    }

    func testVerifyRejectsASparkleFrameworkWhoseCurrentVersionDangles() throws {
        let app = try makeBundle(sparkleCurrentVersionSymlinkTarget: "C")
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertFalse(run.succeeded, "a dangling Versions/Current was accepted:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("Sparkle Versions/Current resolves"),
            "the failure must name the symlink that resolves to nothing:\n\(run.output)"
        )
    }

    func testVerifyRejectsABundleWithNoSparklePublicKey() throws {
        let app = try makeBundle(sparklePublicKey: nil)
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertFalse(run.succeeded, "a bundle with no signing key was accepted:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("SUPublicEDKey"),
            "the failure must name the missing key:\n\(run.output)"
        )
    }

    func testVerifyRejectsTheSparklePublicKeyPlaceholder() throws {
        let app = try makeBundle(sparklePublicKey: Self.sparklePublicKeyPlaceholder)
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertFalse(run.succeeded, "the placeholder key was accepted:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("SUPublicEDKey"),
            "the failure must name the key:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("placeholder"),
            "the rejection must recognise this as the placeholder rather than as some "
            + "arbitrary malformed key, or this test and "
            + "SPARKLE_PUBLIC_KEY_PLACEHOLDER in Scripts/release_manager.py have "
            + "drifted apart:\n\(run.output)"
        )
    }

    func testVerifyRejectsAPlainHTTPFeedURL() throws {
        let app = try makeBundle(sparkleFeedURL: "http://seggys116.github.io/Orbit/appcast.xml")
        let run = try release(["verify", "--app", app.path, "--structure-only"])
        XCTAssertFalse(run.succeeded, "a plain HTTP update feed was accepted:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("SUFeedURL"),
            "the failure must name the feed URL:\n\(run.output)"
        )
    }

    // MARK: - The shipped Info.plist, not a fixture

    private static var shippedInfoPlist: URL {
        repoRoot.appendingPathComponent("Orbit/Resources/Info.plist")
    }

    // plutil -lint accepts a comment containing '--'; every strict XML reader
    // rejects it, so the file parses in Xcode and not in the release tooling.
    func testTheShippedInfoPlistIsStrictWellFormedXML() throws {
        let data = try Data(contentsOf: Self.shippedInfoPlist)
        let parser = XMLParser(data: data)
        XCTAssertTrue(
            parser.parse(),
            "Orbit/Resources/Info.plist is not well-formed XML: "
            + (parser.parserError?.localizedDescription ?? "unknown")
            + " at line \(parser.lineNumber). A '--' inside an <!-- --> comment is the usual cause."
        )
    }

    func testTheShippedSparklePublicKeyIsAUsableEd25519Key() throws {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.shippedInfoPlist), format: nil
        ) as? [String: Any]
        let key = try XCTUnwrap(plist?["SUPublicEDKey"] as? String, "SUPublicEDKey is missing")
        XCTAssertFalse(
            key.hasPrefix("PLACEHOLDER"),
            "SUPublicEDKey is still the placeholder; no release can install an update"
        )
        let decoded = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey is not valid base64")
        XCTAssertEqual(decoded.count, 32, "an ed25519 public key is 32 bytes, this one is \(decoded.count)")
    }

    // MARK: - Credential-dependent steps fail loudly rather than quietly

    func testNotarizeWithoutCredentialsFailsAndExplainsEveryOption() throws {
        let scratch = try makeScratchDirectory()
        let payload = scratch.appendingPathComponent("Orbit.zip")
        try Data("not a real archive".utf8).write(to: payload)

        let run = try release(
            ["notarize", "--file", payload.path],
            clearingNotaryCredentials: true
        )
        XCTAssertFalse(run.succeeded, "notarize claimed to succeed with no credentials:\n\(run.output)")
        for expected in [
            "ORBIT_NOTARY_KEYCHAIN_PROFILE",
            "APPLE_NOTARY_KEY_PATH",
            "APPLE_APP_SPECIFIC_PASSWORD",
            "notarytool store-credentials",
        ] {
            XCTAssertTrue(
                run.output.contains(expected),
                "the failure must tell a maintainer about \(expected):\n\(run.output)"
            )
        }
    }

    func testNotarizeRejectsAHalfConfiguredAPIKey() throws {
        let scratch = try makeScratchDirectory()
        let payload = scratch.appendingPathComponent("Orbit.zip")
        try Data("not a real archive".utf8).write(to: payload)

        let process = Process()
        process.executableURL = Self.releaseScript
        process.arguments = ["notarize", "--file", payload.path]
        process.currentDirectoryURL = Self.repoRoot
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        for name in ["ORBIT_NOTARY_KEYCHAIN_PROFILE", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD"] {
            environment.removeValue(forKey: name)
        }
        environment["APPLE_NOTARY_KEY_ID"] = "ABCDE12345"
        environment.removeValue(forKey: "APPLE_NOTARY_KEY_PATH")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(
            output.contains("half-configured"),
            "a key id with no key file must be reported as half-configured, not ignored:\n\(output)"
        )
    }

    // MARK: - Argument handling

    func testAnUnknownSubcommandIsRejected() throws {
        let run = try release(["notarise"])   // the British spelling is not a subcommand
        XCTAssertFalse(run.succeeded)
        XCTAssertTrue(
            run.output.contains("invalid choice") || run.output.contains("usage:"),
            run.output
        )
    }

    func testSignRequiresAnAppToSign() throws {
        let run = try release(["sign", "--adhoc"])
        XCTAssertFalse(run.succeeded, "sign with no --app must not do anything:\n\(run.output)")
        XCTAssertTrue(run.output.contains("--app"), run.output)
    }

    func testSignRefusesAPathThatIsNotABundle() throws {
        let scratch = try makeScratchDirectory()
        let run = try release([
            "sign", "--adhoc", "--app", scratch.appendingPathComponent("Nothing.app").path,
        ])
        XCTAssertFalse(run.succeeded)
        XCTAssertTrue(run.output.contains("no app bundle at"), run.output)
    }

    func testEntitlementsRejectsAnUnknownRole() throws {
        let run = try release(["entitlements", "--print", "compositor"])
        XCTAssertFalse(run.succeeded)
        XCTAssertTrue(run.output.contains("unknown role"), run.output)
        XCTAssertTrue(
            run.output.contains("renderer"),
            "an unknown role should list the roles that do exist:\n\(run.output)"
        )
    }

    // MARK: - Fixtures

    private static let entitlementFileNames = [
        "Orbit.entitlements",
        "OrbitHelper.entitlements",
        "OrbitHelper-Renderer.entitlements",
        "OrbitHelper-GPU.entitlements",
        "OrbitHelper-Alerts.entitlements",
    ]

    private static let sparklePublicKeyFixture =
        Data("OrbitReleasePipelineTestsFixture".utf8).base64EncodedString()

    private static let sparklePublicKeyPlaceholder =
        "PLACEHOLDER.RUN.generate_keys.SEE.refs/RELEASING.md"

    private var scratchDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        try super.tearDownWithError()
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitReleaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private func grantedEntitlements(role: String) throws -> Set<String> {
        let run = try release(["entitlements", "--print", role])
        XCTAssertTrue(run.succeeded, "entitlements --print \(role) failed:\n\(run.output)")
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(run.output.utf8), format: nil
        ) as? [String: Any]
        let dictionary = try XCTUnwrap(parsed, "entitlements --print \(role) did not emit a plist")
        return Set(dictionary.compactMap { key, value in (value as? Bool) == true ? key : nil })
    }

    private func makeBundle(
        sparkleFeedURL: String? = "https://seggys116.github.io/Orbit/appcast.xml",
        sparklePublicKey: String? = ReleasePipelineTests.sparklePublicKeyFixture,
        omittingSparkleFramework: Bool = false,
        sparkleCurrentVersionSymlinkTarget: String = "B"
    ) throws -> URL {
        let manager = FileManager.default
        let root = try makeScratchDirectory()
        let app = root.appendingPathComponent("Orbit.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)

        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let mainBinary = macOS.appendingPathComponent("Orbit")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: mainBinary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainBinary.path)

        var applicationInfo: [String: Any] = [
            "CFBundleIdentifier": "com.zak-noble-clarke.Orbit",
            "CFBundleExecutable": "Orbit",
        ]
        if let sparkleFeedURL {
            applicationInfo["SUFeedURL"] = sparkleFeedURL
        }
        if let sparklePublicKey {
            applicationInfo["SUPublicEDKey"] = sparklePublicKey
        }
        try writePlist(applicationInfo, to: contents.appendingPathComponent("Info.plist"))

        // No engine bridge exists yet: verify_structure checks only the app
        // bundle, its main executable, Info.plist and Sparkle.framework.
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)

        if !omittingSparkleFramework {
            let sparkle = frameworks.appendingPathComponent("Sparkle.framework", isDirectory: true)
            let versionB = sparkle.appendingPathComponent("Versions/B", isDirectory: true)
            try manager.createDirectory(at: versionB, withIntermediateDirectories: true)
            try manager.createDirectory(
                at: versionB.appendingPathComponent("Resources", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("binary".utf8).write(to: versionB.appendingPathComponent("Sparkle"))

            let autoupdate = versionB.appendingPathComponent("Autoupdate")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: autoupdate)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: autoupdate.path)

            let updaterApp = versionB.appendingPathComponent("Updater.app", isDirectory: true)
            let updaterMacOS = updaterApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try manager.createDirectory(at: updaterMacOS, withIntermediateDirectories: true)
            let updater = updaterMacOS.appendingPathComponent("Updater")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: updater)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updater.path)
            try writePlist(
                [
                    "CFBundleExecutable": "Updater",
                    "CFBundleIdentifier": "org.sparkle-project.Sparkle.Updater",
                    "LSUIElement": true,
                ],
                to: updaterApp.appendingPathComponent("Contents/Info.plist")
            )

            try manager.createSymbolicLink(
                atPath: sparkle.appendingPathComponent("Versions/Current").path,
                withDestinationPath: sparkleCurrentVersionSymlinkTarget
            )
            for name in ["Autoupdate", "Updater.app", "Sparkle", "Resources"] {
                try manager.createSymbolicLink(
                    atPath: sparkle.appendingPathComponent(name).path,
                    withDestinationPath: "Versions/Current/\(name)"
                )
            }
        }

        return app
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0
        )
        try data.write(to: url)
    }

    // MARK: - Small parsers used by the assertions above

    private static func xmlComments(in text: String) -> [String] {
        var comments: [String] = []
        var remainder = Substring(text)
        while let start = remainder.range(of: "<!--") {
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: "-->") else { break }
            comments.append(String(afterStart[..<end.lowerBound]))
            remainder = afterStart[end.upperBound...]
        }
        return comments
    }
}
