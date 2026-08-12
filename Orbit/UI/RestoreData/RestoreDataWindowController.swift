import AppKit
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class RestoreDataModel {

    private let env: AppEnvironment

    var scope: RestoreDataScope = .sidebar
    private(set) var backups: [StateBackup] = []
    var selectedBackup: StateBackup?

    var onRestored: (() -> Void)?

    var presentError: (Error) -> Void = RestoreDataModel.presentErrorAlert

    init(env: AppEnvironment) {
        self.env = env
    }

    var canRestore: Bool { selectedBackup != nil }

    // Deliberately does not preselect the newest backup: a stray Return would replace the user's Spaces and tabs.
    func reload() {
        backups = env.availableStateBackups()
        if let selectedBackup, !backups.contains(selectedBackup) {
            self.selectedBackup = nil
        }
    }

    @discardableResult
    func restore() -> Bool {
        guard let selectedBackup else { return false }
        do {
            try env.restoreData(from: selectedBackup, scope: scope)
            onRestored?()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: Row labels

    static func label(for backup: StateBackup?) -> String {
        guard let backup else { return "" }
        return timestampFormatter.string(from: backup.capturedAt)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Failure presentation

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This backup could not be restored."
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Window

@MainActor
final class RestoreDataWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: RestoreDataWindowController?

    private var model: RestoreDataModel!

    // env can't default to .frontmost directly: default arguments evaluate in a
    // nonisolated context, and AppEnvironment.frontmost is main-actor isolated.
    @discardableResult
    static func show(env: AppEnvironment? = nil) -> RestoreDataWindowController {
        let env = env ?? .frontmost
        if let shared {
            shared.model.reload()
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return shared
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Restore Data"
        window.center()
        window.setFrameAutosaveName("OrbitRestoreDataWindow")

        let controller = RestoreDataWindowController(window: window)
        let model = RestoreDataModel(env: env)
        model.onRestored = { [weak controller] in controller?.close() }
        controller.model = model
        window.contentView = NSHostingView(rootView: RestoreDataView(model: model))
        window.delegate = controller
        shared = controller

        model.reload()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    #if DEBUG
    static func _test_makeModel(env: AppEnvironment) -> RestoreDataModel {
        let model = RestoreDataModel(env: env)
        model.reload()
        return model
    }
    #endif
}
