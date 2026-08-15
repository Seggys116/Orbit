//  A real AppKit right-click into a real page. chrome.contextMenus items only
//  exist once content:: has reported a context-menu gesture, so nothing about
//  the API can be exercised without one -- there is no scripted substitute:
//  an untrusted `contextmenu` event never leaves the renderer.

import AppKit
import Foundation
@testable import Orbit

@MainActor
enum LiveContextMenuGesture {

    static let windowSize = CGSize(width: 900, height: 700)

    /// A bare window, not Orbit's own view tree: the layering is
    /// PageLinkNavigationLiveTests' subject, this only needs the engine view on
    /// screen and sized so the renderer has somewhere to hit-test.
    static func host(_ contents: ChromiumWebContents) -> NSWindow {
        let window = UnconstrainedTestWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        let view = contents.view
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        contents.setVisible(true)
        contents.focus()
        return window
    }

    /// Resolved by a manual hit test, not NSWindow.sendEvent: the XCTest host
    /// has no key window, so real dispatch swallows the event for an unrelated
    /// reason -- see PageLinkNavigationLiveTests.
    @discardableResult
    static func rightClickCentre(of contents: ChromiumWebContents, in window: NSWindow) -> NSView? {
        let view = contents.view
        let frame = view.convert(view.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let resolved = window.contentView?.superview?.hitTest(point) ?? view

        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: pressure
            )
        }

        if let down = event(.rightMouseDown, pressure: 1) { resolved.rightMouseDown(with: down) }
        if let up = event(.rightMouseUp, pressure: 0) { resolved.rightMouseUp(with: up) }
        return resolved
    }

    /// Right-clicks until the engine reports at least one extension item. The
    /// gesture crosses into the renderer and back, and the first one can land
    /// before the page is hit-testable, so a single attempt is a flake.
    static func rightClickUntilExtensionItemsAppear(
        _ contents: ChromiumWebContents,
        in window: NSWindow,
        timeout: Duration = .seconds(15)
    ) async throws -> [ExtensionContextMenuGroup] {
        let deadline = ContinuousClock.now + timeout
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            rightClickCentre(of: contents, in: window)
            try await Task.sleep(for: .milliseconds(250))
            let groups = contents.extensionContextMenuGroups()
            if !groups.isEmpty { return groups }
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: """
                    No chrome.contextMenus item ever matched a real right-click on the page. \
                    Either the gesture never reached the renderer (engine view frame \
                    \(contents.view.convert(contents.view.bounds, to: nil)), window \
                    \(String(describing: contents.view.window))), or the extension's items were \
                    never registered.
                    """
                )
            }
        }
    }
}
