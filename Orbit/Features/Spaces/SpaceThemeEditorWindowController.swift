import AppKit
import SwiftUI

@MainActor
final class SpaceThemeEditorWindowController: NSWindowController {

    private static var openWindows: [SpaceID: SpaceThemeEditorWindowController] = [:]

    private let spaceID: SpaceID

    @discardableResult
    static func show(spaceID: SpaceID, env: AppEnvironment) -> SpaceThemeEditorWindowController? {
        guard let space = env.space(spaceID) else { return nil }

        if let existing = openWindows[spaceID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Theme — \(space.name)"
        // contentViewController, not contentView: ThemeEditorView's height falls out of its
        // content, and a fixed contentView frame would clip or gap the palette strip.
        window.contentViewController = NSHostingController(
            rootView: SpaceThemeEditorHost(spaceID: spaceID) {
                SpaceThemeEditorWindowController.openWindows[spaceID]?.close()
            }
            .environment(env)
        )
        window.center()

        let controller = SpaceThemeEditorWindowController(window: window, spaceID: spaceID)
        openWindows[spaceID] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    private init(window: NSWindow, spaceID: SpaceID) {
        self.spaceID = spaceID
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension SpaceThemeEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SpaceThemeEditorWindowController.openWindows.removeValue(forKey: spaceID)
    }
}

private struct SpaceThemeEditorHost: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var onDone: () -> Void

    // Renders nothing once the Space is gone, rather than letting the user keep editing a deleted Space.
    var body: some View {
        if let space = env.space(spaceID) {
            ThemeEditorView(
                theme: Binding(
                    get: { env.space(spaceID)?.theme ?? space.theme },
                    set: { env.updateSpaceTheme(spaceID, theme: $0) }
                ),
                spaceID: spaceID,
                onDone: onDone
            )
        }
    }
}
