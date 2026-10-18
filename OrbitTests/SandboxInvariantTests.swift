//  Process-model invariants for WebKit: web content runs in sandboxed system XPC services, and the browser
//  process carries no sandbox or hardened-runtime exception. The evaluator is proven against synthetic trees,
//  then applied to Orbit's real entitlements file, a live WKWebView's services, and a running Orbit if one exists.

import AppKit
import WebKit
import XCTest

final class SandboxInvariantTests: XCTestCase {

    // MARK: - Synthetic process trees

    private static let serviceDirectory =
        "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"

    private func browser(entitlements: Set<String>? = ["com.apple.security.cs.disable-library-validation"]) -> ProbedProcess {
        ProbedProcess(
            pid: 100,
            parentPID: 1,
            executablePath: "/Applications/Orbit.app/Contents/MacOS/Orbit",
            isSandboxed: false,
            grantedEntitlements: entitlements
        )
    }

    private func service(pid: pid_t, name: String, sandboxed: Bool? = true) -> ProbedProcess {
        ProbedProcess(
            pid: pid,
            parentPID: 1,
            executablePath: "\(Self.serviceDirectory)/\(name).xpc/Contents/MacOS/\(name)",
            isSandboxed: sandboxed
        )
    }

    private func healthyServices() -> [ProbedProcess] {
        [
            service(pid: 101, name: "com.apple.WebKit.WebContent"),
            service(pid: 102, name: "com.apple.WebKit.GPU"),
            service(pid: 103, name: "com.apple.WebKit.Networking"),
        ]
    }

    private func evaluate(
        browser: ProbedProcess? = nil,
        services: [ProbedProcess],
        renderedAPage: Bool = true
    ) -> [ProcessModelViolation] {
        ProcessModelInvariant.violations(
            browser: browser ?? self.browser(),
            services: services,
            renderedAPage: renderedAPage
        )
    }

    // MARK: - The healthy case

    func testACorrectlyConfinedProcessTreeProducesNoViolations() {
        let violations = evaluate(services: healthyServices())
        XCTAssertEqual(
            violations, [],
            "a process tree matching a correctly configured WebKit browser was reported as broken, so "
            + "these invariants would fire on a healthy build and be deleted the first time they did: "
            + violations.map(\.description).joined(separator: "\n")
        )
    }

    func testABrowserThatHasNotRenderedAnythingIsNotAccusedOfRenderingInProcess() {
        XCTAssertEqual(
            evaluate(services: [], renderedAPage: false), [],
            "an idle browser with no WebKit services yet was reported as rendering in process. The "
            + "WebContent presence invariant is conditional on a page having actually rendered."
        )
    }

    // MARK: - Every silent regression the evaluator exists to catch

    func testRenderingWithNoWebContentProcessIsCaught() {
        let violations = evaluate(services: [], renderedAPage: true)
        XCTAssertTrue(
            violations.contains { $0.invariant.contains("separate WebContent process") },
            "a page rendered with no WebContent process anywhere and nothing objected: \(violations)"
        )
    }

    func testAWebContentProcessThatIsTheBrowserItselfDoesNotCount() {
        let impostor = ProbedProcess(
            pid: 100,
            parentPID: 1,
            executablePath: "\(Self.serviceDirectory)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            isSandboxed: true
        )
        XCTAssertTrue(
            evaluate(services: [impostor]).contains { $0.invariant.contains("separate WebContent process") },
            "a WebContent role sharing the browser's own pid was accepted as a separate process."
        )
    }

    func testAnUnconfinedWebContentProcessIsCaught() {
        var services = healthyServices()
        services[0] = service(pid: 101, name: "com.apple.WebKit.WebContent", sandboxed: false)
        XCTAssertTrue(
            evaluate(services: services).contains { $0.invariant.contains("inside a sandbox") },
            "a WebContent process reporting sandbox_check == 0 was accepted. That is the most valuable "
            + "assertion in this file: it executes attacker-controlled JavaScript."
        )
    }

    func testAnUnconfinedGPUProcessIsCaught() {
        var services = healthyServices()
        services[1] = service(pid: 102, name: "com.apple.WebKit.GPU", sandboxed: false)
        XCTAssertTrue(evaluate(services: services).contains { $0.invariant.contains("inside a sandbox") })
    }

    func testAnUnconfinedNetworkingProcessIsCaught() {
        var services = healthyServices()
        services[2] = service(pid: 103, name: "com.apple.WebKit.Networking", sandboxed: false)
        XCTAssertTrue(
            evaluate(services: services).contains { $0.invariant.contains("inside a sandbox") },
            "the networking process, which handles every byte an attacker sends, was accepted unconfined."
        )
    }

    func testAnUnreadableSandboxStateIsNotTreatedAsConfined() {
        var services = healthyServices()
        services[0] = service(pid: 101, name: "com.apple.WebKit.WebContent", sandboxed: nil)
        XCTAssertFalse(
            evaluate(services: services).isEmpty,
            "a service whose sandbox state could not be read passed. A broken detector must fail, not pass."
        )
    }

    func testAnUnknownWebKitServiceIsHeldToTheSameStandard() {
        var services = healthyServices()
        services.append(service(pid: 104, name: "com.apple.WebKit.Plugin.64", sandboxed: false))
        XCTAssertFalse(evaluate(services: services).isEmpty)
    }

    func testEveryBrowserEntitlementExceptionIsCaught() {
        for key in ProcessModelInvariant.forbiddenBrowserEntitlements.keys.sorted() {
            let violations = evaluate(
                browser: browser(entitlements: ["com.apple.security.cs.disable-library-validation", key]),
                services: healthyServices()
            )
            XCTAssertTrue(
                violations.contains { $0.offender.contains(key) },
                "\(key) on the browser process was not caught, and it is silent."
            )
        }
    }

    func testATemporarySandboxExceptionOnTheBrowserIsCaught() {
        let key = ProcessModelInvariant.temporaryExceptionPrefix + "files.home-relative-path.read-write"
        XCTAssertTrue(
            evaluate(browser: browser(entitlements: [key]), services: healthyServices())
                .contains { $0.offender.contains(key) }
        )
    }

    func testABrowserWithAnUnreadableSignatureIsNotWaved() {
        XCTAssertFalse(
            evaluate(browser: browser(entitlements: nil), services: healthyServices()).isEmpty,
            "an unreadable signature let the entitlement check pass without checking anything."
        )
    }

    func testTheCensusNamesEveryProcessSoAFailureCanBeActedOn() {
        let census = ProcessModelInvariant.census(browser: browser(), services: healthyServices())
        XCTAssertTrue(census.contains("pid 101"), census)
        XCTAssertFalse(census.contains("NOT SANDBOXED"), census)
        XCTAssertTrue(
            ProcessModelInvariant.census(browser: browser(), services: []).contains("no WebKit service processes"),
            "an empty tree must say so in words rather than print a blank list."
        )
    }

    // MARK: - The real browser entitlements

    func testOrbitsSignedEntitlementsFileCarriesNoException() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit/Resources/Orbit.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        let keys = Set(try XCTUnwrap(plist, "Orbit.entitlements is not a property list dictionary").keys)

        let violations = evaluate(browser: browser(entitlements: keys), services: [], renderedAPage: false)
        XCTAssertEqual(
            violations, [],
            "Orbit.entitlements grants an exception the WebKit process model does not need: "
            + violations.map(\.description).joined(separator: "\n")
        )
    }

    // MARK: - A live WKWebView

    /// Impossible to verify from outside WebKit: that the XPC services' own sandbox profiles are what Apple ships.
    /// What is verified is that the processes actually serving a live web view report as sandboxed to the kernel.
    func testALiveWebViewsServiceProcessesAreSandboxed() async throws {
        XCTAssertTrue(
            ProcessSandboxProbe.isAvailable,
            "sandbox_check is unreachable, so nothing below could tell a confined service from an unconfined one."
        )

        let webView = await loadedProbeWebView()

        let selector = NSSelectorFromString("_webProcessIdentifier")
        XCTAssertTrue(
            webView.responds(to: selector),
            "WKWebView no longer exposes _webProcessIdentifier, so the WebContent process of this web view cannot be identified directly."
        )
        let webContentPID = try XCTUnwrap(
            (webView.value(forKey: "_webProcessIdentifier") as? NSNumber).map { pid_t($0.int32Value) },
            "WKWebView did not report its WebContent process identifier"
        )
        XCTAssertGreaterThan(webContentPID, 0, "no WebContent process is serving a web view that finished loading")

        let owner = getpid()
        let attributed = try XCTUnwrap(
            ProcessSandboxProbe.webKitServices(responsibleTo: owner),
            "service attribution is unavailable; see testAttributionOfWebKitServicesIsReachable"
        )
        var services = attributed
        if !services.contains(where: { $0.pid == webContentPID }) {
            services.append(ProcessSandboxProbe.probe(pid: webContentPID))
        }
        withExtendedLifetime(webView) {}

        // Networking and GPU are checked when attribution finds them: WebKit starts the GPU process on demand, so its absence
        // for a static page proves nothing, while any that does exist must be confined. The test host stands in for the browser;
        // the entitlement audit applies to Orbit's own signature, which the tests above and below cover.
        let host = ProcessSandboxProbe.current()
        let hostWithoutAudit = ProbedProcess(
            pid: host.pid,
            parentPID: host.parentPID,
            executablePath: host.executablePath,
            isSandboxed: host.isSandboxed,
            grantedEntitlements: []
        )
        let violations = ProcessModelInvariant.violations(
            browser: hostWithoutAudit,
            services: services,
            renderedAPage: true
        )
        XCTAssertEqual(
            violations, [],
            violations.map(\.description).joined(separator: "\n\n")
            + "\n\n" + ProcessModelInvariant.census(browser: hostWithoutAudit, services: services)
        )
        XCTAssertTrue(
            services.contains { $0.role == .webContent && $0.isSandboxed == true },
            "no sandboxed WebContent process was observed for a loaded web view"
        )
    }

    private func loadedProbeWebView() async -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let loaded = expectation(description: "the probe page finished loading")
        let delegate = LoadWaiter(loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body>sandbox probe</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 60)
        XCTAssertNil(delegate.failure, "the probe page failed to load: \(String(describing: delegate.failure))")
        withExtendedLifetime(delegate) {}
        return webView
    }

    // MARK: - A running browser

    /// The test process is itself a running browser: it starts a real web view, so WebKit launches real services responsible to it.
    /// A running Orbit, or the pid in ORBIT_SANDBOX_INVARIANT_PID, is checked as well when there is one.
    func testARunningBrowserSatisfiesTheProcessInvariants() async throws {
        XCTAssertTrue(ProcessSandboxProbe.isAvailable)

        let webView = await loadedProbeWebView()
        let webContentPID = try XCTUnwrap(
            (webView.value(forKey: "_webProcessIdentifier") as? NSNumber).map { pid_t($0.int32Value) },
            "WKWebView did not report its WebContent process identifier"
        )
        XCTAssertGreaterThan(webContentPID, 0, "no WebContent process is serving a web view that finished loading")

        let host = ProcessSandboxProbe.current()
        let ownBrowser = ProbedProcess(
            pid: host.pid,
            parentPID: host.parentPID,
            executablePath: host.executablePath,
            isSandboxed: host.isSandboxed,
            grantedEntitlements: []
        )
        var ownServices = try XCTUnwrap(
            ProcessSandboxProbe.webKitServices(responsibleTo: ownBrowser.pid),
            "service attribution is unavailable; see testAttributionOfWebKitServicesIsReachable"
        )
        if !ownServices.contains(where: { $0.pid == webContentPID }) {
            ownServices.append(ProcessSandboxProbe.probe(pid: webContentPID))
        }
        assertInvariants(browser: ownBrowser, services: ownServices, renderedAPage: true)

        let override = ProcessInfo.processInfo.environment["ORBIT_SANDBOX_INVARIANT_PID"].flatMap(pid_t.init)
        let others = override.map { [ProcessSandboxProbe.probe(pid: $0)] } ?? ProcessSandboxProbe.runningOrbitBrowsers()
        for subject in others where subject.pid != ownBrowser.pid {
            let services = try XCTUnwrap(
                ProcessSandboxProbe.webKitServices(responsibleTo: subject.pid),
                "service attribution is unavailable; see testAttributionOfWebKitServicesIsReachable"
            )
            // Whether a page really rendered cannot be observed from outside the process, so WebContent presence is asserted only when a harness attests to it.
            assertInvariants(
                browser: subject,
                services: services,
                renderedAPage: ProcessInfo.processInfo.environment["ORBIT_SANDBOX_INVARIANT_RENDERED"] == "1"
            )
        }
        withExtendedLifetime(webView) {}
    }

    private func assertInvariants(browser: ProbedProcess, services: [ProbedProcess], renderedAPage: Bool) {
        let violations = ProcessModelInvariant.violations(browser: browser, services: services, renderedAPage: renderedAPage)
        XCTAssertEqual(
            violations, [],
            violations.map(\.description).joined(separator: "\n\n")
            + "\n\n" + ProcessModelInvariant.census(browser: browser, services: services)
        )
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private let expectation: XCTestExpectation
    private(set) var failure: Error?

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error
        expectation.fulfill()
    }
}
