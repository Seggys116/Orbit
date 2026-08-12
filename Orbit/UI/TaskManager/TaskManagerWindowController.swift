import AppKit
import Combine
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class TaskManagerModel {

    static let refreshInterval: TimeInterval = 1.5

    private(set) var processes: [OrbitProcessInfo] = []
    // nil until the first two samples: CPU is a rate, so the first sample has nothing
    // to compare against, and 0.0% would read as measured rather than as not-yet-known.
    private(set) var hasMeasuredCPU = false

    var selectedProcessID: pid_t?

    private var baseline = OrbitProcessMonitor.Baseline.none
    private var timer: Timer?

    var selectedProcess: OrbitProcessInfo? {
        guard let selectedProcessID else { return nil }
        return processes.first { $0.processID == selectedProcessID }
    }

    var endProcessRefusal: OrbitProcessMonitor.EndProcessRefusal? {
        guard let selectedProcess else { return .notAnOrbitProcess }
        return OrbitProcessMonitor.refusalForEndingProcess(selectedProcess.processID)
    }

    var canEndSelectedProcess: Bool { selectedProcess != nil && endProcessRefusal == nil }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let hadBaseline = !baseline.isEmpty
        let sample = OrbitProcessMonitor.sample(against: baseline)
        baseline = sample.baseline
        processes = sample.processes
        if hadBaseline { hasMeasuredCPU = true }

        if let selectedProcessID, !processes.contains(where: { $0.processID == selectedProcessID }) {
            self.selectedProcessID = nil
        }
    }

    @discardableResult
    func endSelectedProcess() -> OrbitProcessMonitor.EndProcessRefusal? {
        guard let selectedProcess else { return .notAnOrbitProcess }
        let refusal = OrbitProcessMonitor.endProcess(selectedProcess.processID)
        if refusal == nil { selectedProcessID = nil }
        refresh()
        return refusal
    }
}

// MARK: - Window

@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: TaskManagerWindowController?

    private let model = TaskManagerModel()

    @discardableResult
    static func show() -> TaskManagerWindowController {
        if let shared {
            shared.model.start()
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return shared
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.center()
        window.setFrameAutosaveName("OrbitTaskManagerWindow")
        window.minSize = NSSize(width: 420, height: 260)

        let controller = TaskManagerWindowController(window: window)
        window.contentView = NSHostingView(rootView: TaskManagerView(model: controller.model))
        window.delegate = controller
        shared = controller

        controller.model.start()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
