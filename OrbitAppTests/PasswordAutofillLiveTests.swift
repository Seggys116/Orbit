//  Password autofill on a real page: which fields the page script finds and how it classifies them, what the engine reports when one is
//  focused, a fill into a controlled input, the refusal for a frame of another site, and the sign-in capture. The pages are loaded with an
//  https base URL (loadHTMLString) so the frame's security origin is a secure one without a server; the iframe case uses a local server.
//
//  The page script reports a focus only after trusted input, so the tests focus a field with a real click: an NSEvent mouse down and up
//  delivered to the hosted web view, which reaches the page as isTrusted events (the same route as PageLinkNavigationLiveTests). A script's
//  own el.focus() is what the negative tests use.

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Orbit

/// Stands in for Passwords: hands over one password for any login and records what it was asked for.
@MainActor
private final class LivePasswordsStub: SystemPasswordsProviding {
    let password: String
    private(set) var requests: [String] = []

    init(password: String) { self.password = password }

    var state: SystemPasswordsState { .paired }
    var canFillOneTimeCodes: Bool { false }
    func cachedLogins(forHost host: String) -> [SystemPasswordLogin]? { nil }
    func logins(forHost host: String) async throws -> [SystemPasswordLogin] { [] }

    func password(forUsername username: String, host: String) async throws -> String {
        requests.append("\(username)@\(host)")
        return password
    }

    func save(username: String, password: String, host: String) async throws -> SystemPasswordsSaveOutcome { .saved }
    func oneTimeCodes(pageURL: URL, username: String?) async throws -> [SystemPasswordOneTimeCode] { [] }
    func didFillOneTimeCode(pageURL: URL, username: String) async {}
    func requestPairing(over window: NSWindow?) {}
    func openPasswordsApp() {}
}

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class PasswordAutofillLiveTests: XCTestCase {

    // MARK: - Fixtures

    @MainActor
    private final class Recorder: WebContentsDelegate {
        var allows = true
        private(set) var focuses: [PasswordFieldFocus] = []
        private(set) var dismissals = 0
        private(set) var submissions: [PasswordSubmission] = []

        func webContentsAllowsPasswordAutofill(_ contents: WebContents) -> Bool { allows }

        func webContents(_ contents: WebContents, didFocusPasswordField field: PasswordFieldFocus) {
            focuses.append(field)
        }

        func webContentsDidDismissPasswordField(_ contents: WebContents) {
            dismissals += 1
        }

        func webContents(_ contents: WebContents, didCapturePasswordSubmission submission: PasswordSubmission) {
            submissions.append(submission)
        }
    }

    private struct Page {
        let contents: WebKitWebContents
        let recorder: Recorder
        let window: NSWindow

        func close() {
            window.orderOut(nil)
            contents.close()
        }
    }

    private static let secureBase = "https://login.example.test/"

    private func host(_ contents: WebKitWebContents, recorder: Recorder) -> Page {
        contents.delegate = recorder
        return Page(contents: contents, recorder: recorder, window: LiveContextMenuGesture.host(contents))
    }

    private func openPage(
        _ html: String,
        baseURL: String = PasswordAutofillLiveTests.secureBase,
        allows: Bool = true
    ) async throws -> Page {
        let contents = try await WebKitLiveEngineHost.makeContents()
        let recorder = Recorder()
        recorder.allows = allows
        let page = host(contents, recorder: recorder)
        contents.loadHTML(html, baseURL: URL(string: baseURL)!)
        try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
        try await Task.sleep(for: .milliseconds(300))
        return page
    }

    /// Records a failure, instead of throwing, when `condition` is still false after `timeout`.
    private func waitFor(
        _ message: String, timeout: Duration = .seconds(8), file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The kind the page script gives every input that has an id: "" for one it ignores.
    private func classification(of contents: WebKitWebContents) async throws -> [String: String] {
        let value = try await contents.webView.callAsyncJavaScript(
            "return window.__orbitPasswords ? window.__orbitPasswords.inspect() : null;",
            arguments: [:],
            in: nil,
            contentWorld: WebKitPasswordAutofill.world
        )
        let rows = try XCTUnwrap(value as? [[String: Any]], "the page script was not running in its own world")
        var kinds: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, !id.isEmpty { kinds[id] = row["kind"] as? String ?? "" }
        }
        return kinds
    }

    /// What a script can do without any person: `el.focus()`. The page script must not report it.
    private func scriptFocus(_ id: String, in contents: WebKitWebContents) async throws {
        _ = try await contents.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
    }

    /// One real left click at the point `script` returns as `{x, y}` in CSS pixels of the top frame's viewport, delivered as trusted mouse events.
    /// Resolved by a manual hit test, not NSWindow.sendEvent, as in PageLinkNavigationLiveTests.
    private func trustedClick(atViewportScript script: String, in page: Page) async throws {
        let json = try await pageString("JSON.stringify((function(){ \(script) })())", in: page.contents)
        let point = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        let webView = page.contents.webView
        let zoom = CGFloat(page.contents.zoomFactor)
        let x = CGFloat(point["x"] ?? 0) * zoom
        let y = CGFloat(point["y"] ?? 0) * zoom
        let local = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        let inWindow = webView.convert(local, to: nil)
        page.window.contentView?.layoutSubtreeIfNeeded()
        let resolved = try XCTUnwrap(page.window.contentView?.superview?.hitTest(inWindow), "nothing is under the click at \(inWindow)")

        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: page.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
            )
        }
        if let down = event(.leftMouseDown, pressure: 1) { resolved.mouseDown(with: down) }
        if let up = event(.leftMouseUp, pressure: 0) { resolved.mouseUp(with: up) }
    }

    private func trustedClick(onElement expression: String, in page: Page) async throws {
        try await trustedClick(
            atViewportScript: "var r = (\(expression)).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 };",
            in: page
        )
    }

    /// Focuses a field the way a person does, with a real click, and waits for the report that follows. The first gesture can land before the page
    /// is hit-testable, so it is repeated a few times.
    private func focus(_ id: String, in page: Page, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = page.recorder.focuses.count
        for _ in 0..<4 {
            try await trustedClick(onElement: "document.getElementById('\(id)')", in: page)
            let deadline = ContinuousClock.now + .milliseconds(1500)
            while page.recorder.focuses.count == before, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if page.recorder.focuses.count > before { return }
        }
        XCTFail("a real click on #\(id) was never reported", file: file, line: line)
    }

    /// The centre of a field of a same-origin frame, in the top frame's viewport.
    private static func frameFieldCentre(frame: String, field: String) -> String {
        """
        var f = document.getElementById('\(frame)');
        var i = f.contentDocument.getElementById('\(field)').getBoundingClientRect();
        var o = f.getBoundingClientRect();
        return { x: o.left + f.clientLeft + i.left + i.width / 2, y: o.top + f.clientTop + i.top + i.height / 2 };
        """
    }

    /// The credentials of a login saved for `origin`.
    private func credentials(_ origin: String, _ username: String, _ password: String) -> PasswordFillCredentials {
        PasswordFillCredentials(origin: URL(string: origin)!, username: username, password: password)
    }

    private func pageString(_ script: String, in contents: WebKitWebContents) async throws -> String {
        let value = try await contents.evaluateJavaScript(script)
        return try XCTUnwrap(value as? String)
    }

    private func cssRect(_ json: String) throws -> CGRect {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        return CGRect(x: object["x"] ?? 0, y: object["y"] ?? 0, width: object["w"] ?? 0, height: object["h"] ?? 0)
    }

    private func expectedScreenRect(_ css: CGRect, in page: Page) throws -> CGRect {
        let view = page.contents.view
        let onScreen = page.window.convertToScreen(view.convert(view.bounds, to: nil))
        return try XCTUnwrap(PasswordFieldGeometry.screenRect(cssRect: css, zoom: page.contents.zoomFactor, viewFrameOnScreen: onScreen))
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1.5, "x", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1.5, "y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1.5, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1.5, "height", file: file, line: line)
    }

    private static let loginForm = """
    <html><body style="margin:0;font:14px sans-serif">
    <form id="f" action="/session">
      <input id="user" type="email" name="email" autocomplete="username">
      <input id="pass" type="password" name="password" autocomplete="current-password">
    </form></body></html>
    """

    /// Stands in for a React-controlled input: a tracker on the instance remembers the last value it wrote, and a change counts only when the
    /// value the `input` listener reads differs from it. A page-world `el.value = x` updates the tracker and is invisible; the native setter is not.
    private static let controlledForm = """
    <html><body style="margin:0;font:14px sans-serif">
    <form id="f" action="/session">
      <input id="hp" type="text" name="email_confirm" style="display:none">
      <input id="u" type="email" name="email" autocomplete="username">
      <input id="p" type="password" name="password" autocomplete="current-password">
    </form>
    <script>
    window.__state = { u: '', p: '', hp: '', events: [] };
    var nativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    ['u', 'p', 'hp'].forEach(function (id) {
      var el = document.getElementById(id);
      var tracked = '';
      Object.defineProperty(el, 'value', {
        configurable: true,
        get: function () { return nativeValue.get.call(this); },
        set: function (v) { tracked = String(v); nativeValue.set.call(this, v); }
      });
      el.addEventListener('input', function (event) {
        var current = nativeValue.get.call(event.target);
        if (current !== tracked) { tracked = current; window.__state[id] = current; window.__state.events.push(id + ':input'); }
      });
      el.addEventListener('change', function () { window.__state.events.push(id + ':change'); });
    });
    </script></body></html>
    """

    // MARK: - Detection and classification

    func testTheScriptClassifiesLoginMultiStepSignUpAndFormlessFieldsAndIgnoresHiddenOnes() throws {
        let html = """
        <html><body style="margin:0;font:14px sans-serif">
        <form id="login" action="/session">
          <input id="hp1" type="text" name="website" style="display:none">
          <input id="hp2" type="text" name="email_confirm" style="position:absolute;left:-9999px;top:0">
          <input id="hp3" type="text" name="spacer" style="width:0;height:0;border:0;padding:0">
          <input id="hp4" type="text" name="honeypot">
          <input id="hp5" type="text" name="nickname" disabled>
          <input id="hp6" type="text" name="handle" readonly>
          <input id="user" type="email" name="email" autocomplete="username">
          <input id="pass" type="password" name="password" autocomplete="current-password">
        </form>
        <form id="step1"><input id="stepUser" type="text" name="login" placeholder="Email or phone"></form>
        <form id="step2"><input id="stepPass" type="password" name="pw"></form>
        <form id="signup" action="/register">
          <input id="regUser" type="email" name="email">
          <input id="regPass" type="password" name="pw1">
          <input id="regConfirm" type="password" name="pw2">
        </form>
        <div id="bare"><input id="bareUser" type="text" name="username"><input id="barePass" type="password" name="pass"></div>
        <input id="search" type="text" name="q" placeholder="Search">
        <input id="otp" type="text" name="code" autocomplete="one-time-code">
        </body></html>
        """
        let kinds = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> [String: String] in
            let page = try await self.openPage(html)
            defer { page.close() }
            return try await self.classification(of: page.contents)
        }

        XCTAssertEqual(kinds["user"], "username")
        XCTAssertEqual(kinds["pass"], "currentPassword")
        XCTAssertEqual(kinds["stepUser"], "username", "the first step of a multi-step sign-in has a username and no password")
        XCTAssertEqual(kinds["stepPass"], "currentPassword", "the second step has a password and no username")
        XCTAssertEqual(kinds["regUser"], "username")
        XCTAssertEqual(kinds["regPass"], "newPassword", "two password fields are a new password and its confirmation")
        XCTAssertEqual(kinds["regConfirm"], "newPassword")
        XCTAssertEqual(kinds["bareUser"], "username", "fields outside any form are found too")
        XCTAssertEqual(kinds["barePass"], "currentPassword")
        XCTAssertEqual(kinds["otp"], "oneTimeCode", "a one-time code field is its own kind, offered codes from Passwords")
        for ignored in ["hp1", "hp2", "hp3", "hp4", "hp5", "hp6", "search"] {
            XCTAssertEqual(kinds[ignored], "", "\(ignored) is hidden, zero-size, off-page, disabled, read-only, a honeypot or a search box")
        }
    }

    func testAFieldAddedLaterAndOneInsideAnOpenShadowRootAreFound() throws {
        let html = """
        <html><body style="margin:0;font:14px sans-serif"><div id="host"></div>
        <script>
        var root = document.getElementById('host').attachShadow({ mode: 'open' });
        root.innerHTML = '<form><input id="shadowUser" type="email" name="email" autocomplete="username"><input id="shadowPass" type="password" autocomplete="current-password"></form>';
        setTimeout(function () {
          var form = document.createElement('form');
          form.innerHTML = '<input id="lateUser" type="email" autocomplete="username"><input id="latePass" type="password" autocomplete="current-password">';
          document.body.appendChild(form);
        }, 150);
        </script></body></html>
        """
        let (kinds, focused) = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> ([String: String], [PasswordFieldKind]) in
            let page = try await self.openPage(html)
            defer { page.close() }
            try await Task.sleep(for: .milliseconds(400))
            let kinds = try await self.classification(of: page.contents)

            try await self.trustedClick(onElement: "document.getElementById('host').shadowRoot.getElementById('shadowUser')", in: page)
            try await self.waitFor("clicking a field inside a shadow root reported nothing") { page.recorder.focuses.contains { $0.kind == .username } }
            try await self.trustedClick(onElement: "document.getElementById('latePass')", in: page)
            try await self.waitFor("clicking a field added after load reported nothing") { page.recorder.focuses.contains { $0.kind == .currentPassword } }
            // A click on a field that is already focused is reported again, as a click, so repeats of one kind in a row are one field.
            var kindsInOrder: [PasswordFieldKind] = []
            for kind in page.recorder.focuses.map(\.kind) where kindsInOrder.last != kind { kindsInOrder.append(kind) }
            return (kinds, kindsInOrder)
        }
        XCTAssertEqual(kinds["shadowUser"], "username")
        XCTAssertEqual(kinds["shadowPass"], "currentPassword")
        XCTAssertEqual(kinds["lateUser"], "username")
        XCTAssertEqual(kinds["latePass"], "currentPassword")
        XCTAssertEqual(focused, [.username, .currentPassword])
    }

    // MARK: - Focus reports

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testFocusingAFieldReportsItsKindFrameOriginAndScreenRectAtAnyZoom

    func testFocusingAFieldReportsItsKindFrameOriginAndScreenRectAtAnyZoom() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.loginForm)
            defer { page.close() }

            try await self.focus("user", in: page)
            let first = try XCTUnwrap(page.recorder.focuses.first)
            XCTAssertEqual(first.kind, .username)
            XCTAssertEqual(first.frameOrigin.absoluteString, "https://login.example.test")
            XCTAssertTrue(first.isSecure)
            XCTAssertTrue(first.isMainFrame)
            XCTAssertEqual(first.trigger, .focus)
            let css = try self.cssRect(try await self.pageString(
                "JSON.stringify((function(){var r=document.getElementById('user').getBoundingClientRect();return {x:r.left,y:r.top,w:r.width,h:r.height};})())",
                in: page.contents
            ))
            self.assertRect(first.screenRect, try self.expectedScreenRect(css, in: page))

            page.contents.setZoomFactor(1.5)
            try await self.waitFor("the zoom never applied") { abs(page.contents.zoomFactor - 1.5) < 0.01 }
            try await Task.sleep(for: .milliseconds(300))
            _ = try await page.contents.evaluateJavaScript("document.activeElement.blur(); true")
            try await self.focus("pass", in: page)
            try await self.waitFor("no password field report arrived") { page.recorder.focuses.contains { $0.kind == .currentPassword } }
            let second = try XCTUnwrap(page.recorder.focuses.last { $0.kind == .currentPassword })
            XCTAssertEqual(second.kind, .currentPassword)
            let zoomedCSS = try self.cssRect(try await self.pageString(
                "JSON.stringify((function(){var r=document.getElementById('pass').getBoundingClientRect();return {x:r.left,y:r.top,w:r.width,h:r.height};})())",
                in: page.contents
            ))
            self.assertRect(second.screenRect, try self.expectedScreenRect(zoomedCSS, in: page))
            page.contents.setZoomFactor(1.0)
        }
    }

    func testAFieldInAFrameIsPlacedUsingTheFramesOffsetInTheTopPage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body style=\"margin:0\"><iframe id=\"f\" src=\"/inner\" style=\"position:absolute;left:120px;top:180px;width:500px;height:240px;border:0\"></iframe></body></html>"
                ),
                "/inner": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body style=\"margin:0\"><form style=\"margin:30px 0 0 25px\"><input id=\"cu\" type=\"email\" autocomplete=\"username\"><input id=\"cp\" type=\"password\" autocomplete=\"current-password\"></form></body></html>"
                ),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            let recorder = Recorder()
            let page = self.host(contents, recorder: recorder)
            defer { page.close() }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(600))

            try await self.trustedClick(atViewportScript: Self.frameFieldCentre(frame: "f", field: "cu"), in: page)
            try await self.waitFor("the frame's field was never placed") { !recorder.focuses.isEmpty }
            let field = try XCTUnwrap(recorder.focuses.first)
            XCTAssertFalse(field.isMainFrame)
            XCTAssertEqual(field.kind, .username)
            let css = try self.cssRect(try await self.pageString(
                "JSON.stringify((function(){var f=document.getElementById('f');var i=f.contentDocument.getElementById('cu').getBoundingClientRect();var o=f.getBoundingClientRect();return {x:o.left+f.clientLeft+i.left,y:o.top+f.clientTop+i.top,w:i.width,h:i.height};})())",
                in: contents
            ))
            self.assertRect(field.screenRect, try self.expectedScreenRect(css, in: page))

            let outcome = await contents.fillPassword(
                into: field.token,
                credentials: self.credentials(server.baseURL.absoluteString, "framed", "framed-pw")
            )
            XCTAssertEqual(outcome, .filled(username: true, password: true), "an http login fills an http frame of its own origin")
            let filled = try await self.pageString(
                "document.getElementById('f').contentDocument.getElementById('cu').value + '|' + document.getElementById('f').contentDocument.getElementById('cp').value",
                in: contents
            )
            XCTAssertEqual(filled, "framed|framed-pw")
        }
    }

    // MARK: - Only a person raises the suggestion panel

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAFocusFromPageScriptIsNotReportedButARealClickIs

    func testAFocusFromPageScriptIsNotReportedButARealClickIs() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.loginForm)
            defer { page.close() }

            // Everything a page can do on its own: focus(), and events it dispatches (isTrusted is false for those).
            try await self.scriptFocus("user", in: page.contents)
            _ = try await page.contents.evaluateJavaScript(
                """
                var p = document.getElementById('pass');
                p.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, composed: true }));
                p.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, composed: true }));
                p.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
                p.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, composed: true }));
                p.focus();
                true
                """
            )
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(page.recorder.focuses.isEmpty, "a focus raised by page script was reported: \(page.recorder.focuses.map(\.kind))")

            _ = try await page.contents.evaluateJavaScript("document.activeElement.blur(); true")
            try await self.focus("user", in: page)
            XCTAssertEqual(page.recorder.focuses.first?.kind, .username, "a real click on the field still reports it")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testARealClickElsewhereDoesNotLetAScriptRaiseAField

    func testARealClickElsewhereDoesNotLetAScriptRaiseAField() throws {
        let html = Self.loginForm.replacingOccurrences(
            of: "</body>",
            with: "<div id=\"blank\" style=\"position:absolute;left:0;top:300px;width:400px;height:120px\"></div></body>"
        )
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(html)
            defer { page.close() }
            try await self.trustedClick(onElement: "document.getElementById('blank')", in: page)
            try await self.scriptFocus("pass", in: page.contents)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(page.recorder.focuses.isEmpty, "a click on something else was taken as input on the field")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testTabbingToTheNextFieldIsReported

    func testTabbingToTheNextFieldIsReported() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.loginForm)
            defer { page.close() }
            try await self.focus("user", in: page)
            XCTAssertFalse(page.recorder.focuses.contains { $0.kind == .currentPassword })

            let webView = page.contents.webView
            page.window.makeFirstResponder(webView)
            func tab(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: page.window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48
                )
            }
            for _ in 0..<3 where !page.recorder.focuses.contains(where: { $0.kind == .currentPassword }) {
                if let down = tab(.keyDown) { webView.keyDown(with: down) }
                if let up = tab(.keyUp) { webView.keyUp(with: up) }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertTrue(page.recorder.focuses.contains { $0.kind == .currentPassword }, "Tab to the password field was not reported")
        }
    }

    // MARK: - Capturing needs real input in the form

    /// A submit event alone only parks the sign-in; it is delivered once the page it led to loads without a sign-in form of its own, so these
    /// pages really navigate (a local server) and the test waits for that decision.
    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAScriptDrivenSubmitWithNoRealInputIsNotCapturedButOneAfterARealClickIs

    func testAScriptDrivenSubmitWithNoRealInputIsNotCapturedButOneAfterARealClickIs() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: """
                    <html><body style="margin:0;font:14px sans-serif">
                    <form id="f" action="/session">
                      <input id="u" type="email" name="email" autocomplete="username">
                      <input id="p" type="password" name="password" autocomplete="current-password">
                    </form></body></html>
                    """
                ),
                "/session": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body>Welcome back</body></html>"
                ),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            let recorder = Recorder()
            let page = self.host(contents, recorder: recorder)
            defer { page.close() }

            let fillAndSubmit = """
            document.getElementById('u').value = 'mallory@example.test';
            document.getElementById('p').value = 'script-pw';
            document.getElementById('f').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
            document.getElementById('f').requestSubmit();
            true
            """

            // No real input anywhere in the form: the submit events are the page's own.
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(600))
            _ = try await contents.evaluateJavaScript(fillAndSubmit)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(3))
            XCTAssertTrue(recorder.submissions.isEmpty, "a sign-in no person touched was captured: \(recorder.submissions.count)")

            // The same flow after a real click in the form is a real sign-in.
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(600))
            try await self.focus("u", in: page)
            _ = try await contents.evaluateJavaScript(fillAndSubmit)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitFor("a script-driven submit after a real click was not captured", timeout: .seconds(15)) { !recorder.submissions.isEmpty }
            let submission = try XCTUnwrap(recorder.submissions.first)
            XCTAssertEqual(submission.username, "mallory@example.test")
            XCTAssertEqual(submission.password, "script-pw")
        }
    }

    // MARK: - Filling

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAFillReachesAControlledInputAndLeavesAHiddenFieldAlone

    func testAFillReachesAControlledInputAndLeavesAHiddenFieldAlone() throws {
        let state = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> String in
            let page = try await self.openPage(Self.controlledForm)
            defer { page.close() }

            let before = try await self.pageString("JSON.stringify(window.__state)", in: page.contents)
            XCTAssertTrue(before.contains("\"u\":\"\""), "the page starts with nothing filled: \(before)")

            try await self.focus("u", in: page)
            let field = try XCTUnwrap(page.recorder.focuses.first)

            let outcome = await page.contents.fillPassword(
                into: field.token,
                credentials: self.credentials("https://login.example.test", "alice@example.test", "hunter2-correct")
            )
            XCTAssertEqual(outcome, .filled(username: true, password: true))
            return try await self.pageString("JSON.stringify(window.__state)", in: page.contents)
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
        XCTAssertEqual(object["u"] as? String, "alice@example.test", "the controlled username input never saw the value")
        XCTAssertEqual(object["p"] as? String, "hunter2-correct", "the controlled password input never saw the value")
        XCTAssertEqual(object["hp"] as? String, "", "a hidden field was filled")
        let events = try XCTUnwrap(object["events"] as? [String])
        XCTAssertTrue(events.contains("u:input") && events.contains("p:input"), "input events were not dispatched: \(events)")
        XCTAssertTrue(events.contains("u:change") && events.contains("p:change"), "change events were not dispatched: \(events)")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAFillIsRefusedForAFrameWhoseSiteIsNotTheLoginsSite

    func testAFillIsRefusedForAFrameWhoseSiteIsNotTheLoginsSite() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.controlledForm)
            defer { page.close() }
            try await self.focus("u", in: page)
            let token = try XCTUnwrap(page.recorder.focuses.first).token

            for origin in ["https://other.test", "https://login.example.test.evil.com", "https://notexample.test", "https://example.com", "http://other.test"] {
                let outcome = await page.contents.fillPassword(
                    into: token, credentials: self.credentials(origin, "mallory", "stolen-pw")
                )
                XCTAssertEqual(outcome, .refusedSiteMismatch, "a login saved for \(origin) was accepted by a frame of example.test")
            }
            let after = try await self.pageString("JSON.stringify(window.__state)", in: page.contents)
            XCTAssertTrue(after.contains("\"u\":\"\"") && after.contains("\"p\":\"\""), "the refused fill still reached the page: \(after)")

            let unknown = await page.contents.fillPassword(
                into: "f0000000000000000000000000000000", credentials: self.credentials("https://example.test", "a", "b")
            )
            XCTAssertEqual(unknown, .fieldUnavailable, "a token the page never reported must not name a field")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAnHTTPSLoginIsNeverFilledIntoAnHTTPFrameButAnHTTPLoginMayBe

    func testAnHTTPSLoginIsNeverFilledIntoAnHTTPFrameButAnHTTPLoginMayBe() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let insecure = try await self.openPage(Self.loginForm, baseURL: "http://login.example.test/")
            defer { insecure.close() }
            try await self.focus("user", in: insecure)
            let field = try XCTUnwrap(insecure.recorder.focuses.first)
            XCTAssertFalse(field.isSecure)

            for origin in ["https://example.test", "https://login.example.test"] {
                let refused = await insecure.contents.fillPassword(into: field.token, credentials: self.credentials(origin, "alice", "pw"))
                XCTAssertEqual(refused, .refusedInsecure, "an https login must never reach an http page (\(origin))")
            }
            let untouched = try await self.pageString(
                "document.getElementById('user').value + '|' + document.getElementById('pass').value", in: insecure.contents
            )
            XCTAssertEqual(untouched, "|", "a refused fill still reached the page")

            let explicit = await insecure.contents.fillPassword(into: field.token, credentials: self.credentials("http://example.test", "alice", "pw"))
            XCTAssertEqual(explicit, .filled(username: true, password: true), "an http login on an http page is the explicit choice under the warning")

            let local = try await self.openPage(Self.loginForm, baseURL: "http://localhost:8123/")
            defer { local.close() }
            try await self.focus("user", in: local)
            let localField = try XCTUnwrap(local.recorder.focuses.first)
            XCTAssertTrue(localField.isSecure, "http on localhost is a trustworthy origin")
            let httpsOnLocal = await local.contents.fillPassword(into: localField.token, credentials: self.credentials("https://localhost:8443", "dev", "dev-pw"))
            XCTAssertEqual(httpsOnLocal, .refusedInsecure, "even localhost over http never takes an https login")
            let filled = await local.contents.fillPassword(into: localField.token, credentials: self.credentials("http://localhost:3000", "dev", "dev-pw"))
            XCTAssertEqual(filled, .filled(username: true, password: true))
        }
    }

    func testAFillIsRefusedWhenTheFrameHasMovedToAnotherOriginSinceTheFieldWasReported() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let field = "<input id=\"cu\" type=\"email\" autocomplete=\"username\"><input id=\"cp\" type=\"password\" autocomplete=\"current-password\">"
            let second = try LiveHTTPTestServer(routes: [
                "/inner": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: """
                    <html><body style="margin:0"><form style="margin:30px 0 0 25px">\(field)</form>
                    <script>setInterval(function () {
                      parent.postMessage({ u: document.getElementById('cu').value, p: document.getElementById('cp').value }, '*');
                    }, 100);</script></body></html>
                    """
                ),
            ])
            defer { second.stop() }
            let first = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: """
                    <html><body style="margin:0"><iframe id="f" src="/inner" style="position:absolute;left:120px;top:180px;width:500px;height:240px;border:0"></iframe>
                    <script>
                    window.__child = '';
                    window.addEventListener('message', function (e) {
                      if (e.data && typeof e.data.u === 'string') { window.__child = e.data.u + '|' + e.data.p; }
                    });
                    </script></body></html>
                    """
                ),
                "/inner": LiveHTTPTestServer.Route(
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body style=\"margin:0\"><form style=\"margin:30px 0 0 25px\">\(field)</form></body></html>"
                ),
            ])
            defer { first.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            let recorder = Recorder()
            let page = self.host(contents, recorder: recorder)
            defer { page.close() }
            contents.load(first.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(600))

            try await self.trustedClick(atViewportScript: Self.frameFieldCentre(frame: "f", field: "cu"), in: page)
            try await self.waitFor("the frame's field was never reported") { !recorder.focuses.isEmpty }
            let reported = try XCTUnwrap(recorder.focuses.first)
            XCTAssertFalse(reported.isMainFrame)
            XCTAssertEqual(reported.frameOrigin.absoluteString, first.baseURL.absoluteString)

            // The same frame goes to another origin of the same host. Its WKFrameInfo, and so the field's recorded origin, is a snapshot of the old one.
            _ = try await contents.evaluateJavaScript(
                "window.__child = ''; document.getElementById('f').src = 'http://127.0.0.1:\(second.port)/inner'; true"
            )
            var moved = false
            for _ in 0..<80 where !moved {
                try await Task.sleep(for: .milliseconds(100))
                moved = try await self.pageString("String(window.__child)", in: contents) == "|"
            }
            XCTAssertTrue(moved, "the frame's new page never reported its (empty) fields")

            let outcome = await contents.fillPassword(
                into: reported.token, credentials: self.credentials(first.baseURL.absoluteString, "framed", "framed-pw")
            )
            XCTAssertEqual(outcome, .refusedSiteMismatch, "the fill ran in a frame that is no longer on the origin that reported the field")
            try await Task.sleep(for: .milliseconds(400))
            let child = try await self.pageString("String(window.__child)", in: contents)
            XCTAssertEqual(child, "|", "the refused fill still wrote into the frame's new page")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testMultiStepFillTakesTheUsernameFirstAndTheNextStepOffersTheSameLoginFirst

    func testMultiStepFillTakesTheUsernameFirstAndTheNextStepOffersTheSameLoginFirst() throws {
        let html = """
        <html><body style="margin:0;font:14px sans-serif">
        <form id="step1"><input id="stepUser" type="email" name="email" autocomplete="username"></form>
        <form id="step2"><input id="stepPass" type="password" autocomplete="current-password"></form>
        </body></html>
        """
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(html)
            defer { page.close() }
            try await self.focus("stepUser", in: page)
            let userField = try XCTUnwrap(page.recorder.focuses.first)

            let outcome = await page.contents.fillPassword(
                into: userField.token,
                credentials: self.credentials("https://example.test", "carol", "carol-pw")
            )
            XCTAssertEqual(outcome, .filled(username: true, password: false), "only the fields present are filled")
            let typed = try await self.pageString(
                "document.getElementById('stepUser').value + '|' + document.getElementById('stepPass').value", in: page.contents
            )
            XCTAssertEqual(typed, "carol|", "the password step's field must stay empty until its own step")

            try await self.focus("stepPass", in: page)
            let passField = try XCTUnwrap(page.recorder.focuses.last)
            XCTAssertEqual(passField.kind, .currentPassword)
            XCTAssertEqual(passField.preferredUsername, "carol", "the password step should offer the login the username step used")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testChoosingARowFillsThePasswordPasswordsHandsOver

    func testChoosingARowFillsThePasswordPasswordsHandsOver() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.controlledForm)
            defer { page.close() }
            let passwords = LivePasswordsStub(password: "fran-pw-9")
            let ui = PasswordAutofillUI.shared
            ui.passwords = passwords
            defer { ui.passwords = SystemPasswords.shared }

            try await self.focus("u", in: page)
            let field = try XCTUnwrap(page.recorder.focuses.first)
            ui.fill(SystemPasswordLogin(username: "fran@example.test"), into: field, contents: page.contents)

            var filled = ""
            for _ in 0..<80 where filled != "fran@example.test|fran-pw-9" {
                try await Task.sleep(for: .milliseconds(50))
                filled = try await self.pageString("document.getElementById('u').value + '|' + document.getElementById('p').value", in: page.contents)
            }
            XCTAssertEqual(filled, "fran@example.test|fran-pw-9")
            XCTAssertEqual(passwords.requests, ["fran@example.test@login.example.test"], "Passwords is asked for the frame's own host")
        }
    }

    // MARK: - Capturing a sign-in

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testASignInThatRemovesItsPasswordFieldIsCapturedOnce

    func testASignInThatRemovesItsPasswordFieldIsCapturedOnce() throws {
        let html = """
        <html><body style="margin:0;font:14px sans-serif">
        <form id="f" action="/session">
          <input id="u" type="email" name="email" autocomplete="username">
          <input id="p" type="password" name="password" autocomplete="current-password">
        </form>
        <script>
        document.getElementById('f').addEventListener('submit', function (event) {
          event.preventDefault();
          document.getElementById('p').remove();
        });
        </script></body></html>
        """
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(html)
            defer { page.close() }
            try await self.focus("u", in: page)
            let token = try XCTUnwrap(page.recorder.focuses.first).token
            _ = await page.contents.fillPassword(
                into: token,
                credentials: self.credentials("https://example.test", "dana@example.test", "dana-pw-1")
            )
            _ = try await page.contents.evaluateJavaScript("document.getElementById('f').requestSubmit(); true")

            try await self.waitFor("the sign-in was never captured") { !page.recorder.submissions.isEmpty }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(page.recorder.submissions.count, 1, "the submit event and the removal are one sign-in")
            let submission = try XCTUnwrap(page.recorder.submissions.first)
            XCTAssertEqual(submission.username, "dana@example.test")
            XCTAssertEqual(submission.password, "dana-pw-1")
            XCTAssertFalse(submission.isNewPassword)
            XCTAssertEqual(submission.origin.absoluteString, "https://login.example.test")
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN testAOneTimeCodeFillsASingleFieldOrARowOfBoxes

    func testAOneTimeCodeFillsASingleFieldOrARowOfBoxes() throws {
        let html = """
        <html><body style="margin:0;font:14px sans-serif">
        <form id="single"><input id="code" type="text" name="code" autocomplete="one-time-code"></form>
        <form id="boxes">
          <input id="b1" type="text" maxlength="1"><input id="b2" type="text" maxlength="1"><input id="b3" type="text" maxlength="1">
          <input id="b4" type="text" maxlength="1"><input id="b5" type="text" maxlength="1"><input id="b6" type="text" maxlength="1">
        </form>
        <form id="login"><input id="user" type="email" autocomplete="username"></form>
        </body></html>
        """
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(html)
            defer { page.close() }

            try await self.focus("code", in: page)
            let single = try XCTUnwrap(page.recorder.focuses.last)
            XCTAssertEqual(single.kind, .oneTimeCode)
            let filled = await page.contents.fillOneTimeCode("482913", into: single.token, frameOrigin: single.frameOrigin)
            XCTAssertEqual(filled, .filled(username: false, password: true))

            try await self.focus("b1", in: page)
            let box = try XCTUnwrap(page.recorder.focuses.last)
            XCTAssertEqual(box.kind, .oneTimeCode)
            _ = await page.contents.fillOneTimeCode("739105", into: box.token, frameOrigin: box.frameOrigin)

            let values = try await self.pageString(
                "document.getElementById('code').value + '|' + ['b1','b2','b3','b4','b5','b6'].map(function (id) { return document.getElementById(id).value; }).join('')",
                in: page.contents
            )
            XCTAssertEqual(values, "482913|739105")

            let refused = await page.contents.fillOneTimeCode("<b>1</b>", into: single.token, frameOrigin: single.frameOrigin)
            XCTAssertEqual(refused, .fieldUnavailable, "only letters and digits ever reach a code field")
            let elsewhere = await page.contents.fillOneTimeCode("123456", into: single.token, frameOrigin: URL(string: "https://other.test")!)
            XCTAssertEqual(elsewhere, .refusedSiteMismatch)

            try await self.focus("user", in: page)
            let user = try XCTUnwrap(page.recorder.focuses.last)
            let notACodeField = await page.contents.fillOneTimeCode("123456", into: user.token, frameOrigin: user.frameOrigin)
            XCTAssertEqual(notACodeField, .fieldUnavailable)
        }
    }

    // MARK: - Pages that get nothing

    func testAPrivateSessionNeverRunsTheScriptOrReportsAField() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let session = try engine.session(identifier: "password-autofill-private", persistent: false)
            let contents = try XCTUnwrap(try engine.makeWebContents(session: session, initialURL: nil) as? WebKitWebContents)
            let recorder = Recorder()
            let page = self.host(contents, recorder: recorder)
            defer { page.close() }
            contents.loadHTML(Self.loginForm, baseURL: URL(string: Self.secureBase)!)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            try await self.trustedClick(onElement: "document.getElementById('user')", in: page)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(recorder.focuses.isEmpty, "a private page was reported to the app")
            let probe = try await contents.webView.callAsyncJavaScript(
                "return typeof window.__orbitPasswords;", arguments: [:], in: nil, contentWorld: WebKitPasswordAutofill.world
            )
            XCTAssertEqual(probe as? String, "undefined", "the script must not even be installed for a non-persistent session")
        }
    }

    func testAnOwnerThatSaysNoGetsNoReportsAndNoFill() throws {
        try WebKitLiveEngineHost.runLive(timeout: 90) {
            let page = try await self.openPage(Self.loginForm, allows: false)
            defer { page.close() }
            try await self.trustedClick(onElement: "document.getElementById('user')", in: page)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(page.recorder.focuses.isEmpty)
            let outcome = await page.contents.fillPassword(
                into: "f0123456789abcdef0123456789abcdef",
                credentials: self.credentials("https://example.test", "a", "b")
            )
            XCTAssertEqual(outcome, .fieldUnavailable)
        }
    }
}
