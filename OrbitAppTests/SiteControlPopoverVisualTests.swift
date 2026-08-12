//  SiteControlWiringTests.swift covers the popover's pure logic; this is the pixel layer: declared
//  width, that it paints, and that rows gated on real state actually appear/disappear with it.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class SiteControlPopoverVisualTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let canvasSize = CGSize(width: 420, height: 760)

    // MARK: - A minimal, mutable BrowserEngine stand-in (capabilities toggled after construction)

    private final class FakeEngine: BrowserEngine {
        static let kind: EngineKind = .chromium
        var capabilities: EngineCapabilities = [.extensions]
        var manageableContentSettings: Set<PermissionKind> = Set(PermissionKind.allCases)
        var extensionActivation: ExtensionActivation = .nextLaunch
        var versionDescription = "FakeEngine (SiteControlPopoverVisualTests — no real engine is running)"

        private let session: EngineSession
        init(session: EngineSession) { self.session = session }

        func start() throws {}
        func shutdown() -> Bool { true }
        func tick() {}

        func session(identifier: String, persistent: Bool) throws -> EngineSession { session }
        var defaultSession: EngineSession { session }

        func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
            throw EngineError(code: .engineUnavailable)
        }

        func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
        func addUserScript(_ script: UserScript, session: EngineSession) {}
        func removeUserScript(id: UUID, session: EngineSession) {}
        func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

        func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
            throw EngineError(code: .engineUnavailable)
        }
        func unloadExtension(id: String, session: EngineSession) {}
        func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
    }

    // MARK: - Fixture: attaches a fake, extensions-capable engine and live web contents to the active tab

    @discardableResult
    private func seedPopover() -> (tab: Orbit.Tab, engine: FakeEngine, session: MockEngineSession)? {
        OrbitScreenshotFixtures.configure(env)
        guard let tab = env.activeTab, tab.url.host() != nil else {
            XCTFail("expected OrbitState.demo's active tab (env.activeTab) to carry a real, hosted URL")
            return nil
        }

        let session = MockEngineSession(identifier: "site-control-visual-fixture", isPersistent: true)
        session.setContentSetting(.block, for: .geolocation, url: tab.url)

        let webContents = MockWebContents(session: session)
        webContents.navigationState = NavigationState(
            url: tab.url, title: tab.title, canGoBack: true, canGoForward: false, isLoading: false, progress: 1, security: .secure
        )
        env._test_attachWebContents(webContents, for: tab.id)

        let engine = FakeEngine(session: session)
        env._test_engineOverride = engine
        return (tab, engine, session)
    }

    // MARK: - Declared width

    func test_popover_rendersAtItsDeclaredWidth() {
        guard let (tab, _, _) = seedPopover() else { return }

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(
                SiteControlPopoverView(tab: tab).environment(env).background(Color.red),
                size: Self.canvasSize,
                appearance: appearance
            )
            let box = rendered.boundingBoxOfContent()
            XCTAssertEqual(
                box?.width ?? -1, 300, accuracy: 1,
                "appearance \(appearance.rawValue): SiteControlPopoverView declares .frame(width: 300) but rendered at a different width — exactly the class of 'wrong scale' defect a PNG-only check would miss."
            )
        }
    }

    func test_popover_paintsNonBlankContent_inBothAppearances() {
        guard let (tab, _, _) = seedPopover() else { return }

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let rendered = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: appearance)
            XCTAssertNotNil(rendered.boundingBoxOfContent(), "appearance \(appearance.rawValue)")
        }
    }

    // MARK: - The extensions row appears only when the engine actually supports extensions

    func test_popover_withExtensionsCapableEngine_rendersDifferentlyThanWithout() {
        guard let (tab, engine, _) = seedPopover() else { return }

        engine.capabilities = [.extensions]
        let withExtensions = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        engine.capabilities = []
        let withoutExtensions = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withExtensions, withoutExtensions, size: Self.canvasSize),
            "Removing the .extensions capability did not change anything rendered — SiteControlPopoverView.isExtensionsSectionVisible is not gating the real row."
        )
    }

    // MARK: - A stored permission decision actually adds a row

    func test_popover_withAStoredPermissionDecision_rendersDifferentlyThanWithNone() {
        guard let (tab, _, session) = seedPopover() else { return }

        let withDecision = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        session.setContentSetting(.ask, for: .geolocation, url: tab.url)
        let withoutDecision = render(SiteControlPopoverView(tab: tab).environment(env), size: Self.canvasSize, appearance: .darkAqua)

        XCTAssertTrue(
            Self.rendersDiffer(withDecision, withoutDecision, size: Self.canvasSize),
            "Revoking the site's only stored permission decision (Location) did not change anything rendered — the permission row is not reading real content-setting state."
        )
    }

    // MARK: - Helpers

    private static func rendersDiffer(_ a: RenderedImage, _ b: RenderedImage, size: CGSize) -> Bool {
        let step = 6
        var x = 0
        while x < Int(size.width) {
            var y = 0
            while y < Int(size.height) {
                let lhs = a.color(atX: x, y: y)
                let rhs = b.color(atX: x, y: y)
                let dr = lhs.r - rhs.r, dg = lhs.g - rhs.g, db = lhs.b - rhs.b, da = lhs.a - rhs.a
                if (dr * dr + dg * dg + db * db + da * da).squareRoot() > 0.04 { return true }
                y += step
            }
            x += step
        }
        return false
    }
}
