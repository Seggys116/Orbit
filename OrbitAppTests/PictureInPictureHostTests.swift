import XCTest
import WebKit
@testable import Orbit

/// Picture-in-picture's Restore button does nothing for a page with no window, so a floating background page
/// is kept in a stand-in window.
@MainActor
final class PictureInPictureHostTests: XCTestCase {

    private func makeWebView() -> OrbitWebView {
        OrbitWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: WKWebViewConfiguration())
    }

    func testAFloatingPageWithNoPaneIsHeldInAStandInWindow() {
        let webView = makeWebView()
        defer { webView.setFloatingInPictureInPicture(false) }

        webView.setFloatingInPictureInPicture(true)

        let host = webView.window as? PictureInPictureHostWindow
        XCTAssertNotNil(host, "A floating page with no pane must have a window or its Restore button does nothing.")
        XCTAssertEqual(host?.isVisible, true, "The stand-in has to be ordered in; an unshown window does not help.")
        XCTAssertFalse(webView.isInRealWindow, "The stand-in is not a pane, so the page must still count as having no real window.")
    }

    func testTheStandInIsInvisibleAndInertToTheUser() throws {
        let webView = makeWebView()
        defer { webView.setFloatingInPictureInPicture(false) }
        webView.setFloatingInPictureInPicture(true)

        let host = try XCTUnwrap(webView.window as? PictureInPictureHostWindow)

        XCTAssertTrue(host.ignoresMouseEvents)
        XCTAssertLessThan(host.alphaValue, 0.05)
        XCTAssertFalse(host.canBecomeKey)
        XCTAssertFalse(host.canBecomeMain)
        XCTAssertTrue(host.isExcludedFromWindowsMenu)
    }

    func testLeavingPictureInPictureTakesThePageBackOutOfTheStandIn() throws {
        let webView = makeWebView()
        webView.setFloatingInPictureInPicture(true)
        let host = try XCTUnwrap(webView.window as? PictureInPictureHostWindow)

        webView.setFloatingInPictureInPicture(false)

        XCTAssertNil(webView.window, "Once it stops floating the page is an ordinary windowless background tab again.")
        XCTAssertFalse(host.isVisible)
    }

    func testAPaneTakingThePageReleasesTheStandIn() throws {
        let webView = makeWebView()
        webView.setFloatingInPictureInPicture(true)
        let host = try XCTUnwrap(webView.window as? PictureInPictureHostWindow)
        let pane = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false
        )
        pane.isReleasedWhenClosed = false
        defer { webView.removeFromSuperview() }

        pane.contentView?.addSubview(webView)

        XCTAssertTrue(webView.window === pane)
        XCTAssertTrue(webView.isInRealWindow)
        XCTAssertFalse(host.isVisible, "The page is on screen in a pane, so the stand-in must go.")
        webView.setFloatingInPictureInPicture(false)
        XCTAssertTrue(webView.window === pane, "Leaving picture-in-picture must not pull a page out of the pane showing it.")
    }

    func testAPageAlreadyInAPaneIsNotParked() {
        let webView = makeWebView()
        let pane = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false
        )
        pane.isReleasedWhenClosed = false
        pane.contentView?.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.setFloatingInPictureInPicture(true)

        XCTAssertTrue(webView.window === pane)
    }

    func testFloatingTwiceKeepsOneStandIn() throws {
        let webView = makeWebView()
        defer { webView.setFloatingInPictureInPicture(false) }
        webView.setFloatingInPictureInPicture(true)
        let first = try XCTUnwrap(webView.window)

        webView.setFloatingInPictureInPicture(true)

        XCTAssertTrue(webView.window === first)
    }
}
