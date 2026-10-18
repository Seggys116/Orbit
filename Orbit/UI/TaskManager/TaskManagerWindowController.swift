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

    var selectedProcessID: pid_t? {
        didSet {
            guard oldValue != selectedProcessID else { return }
            updateEndProcessRefusal()
        }
    }

    // From the rows on screen, not a fresh process list. The view reads this on every pass;
    // End Process still re-checks the live list before signalling.
    private(set) var endProcessRefusal: OrbitProcessMonitor.EndProcessRefusal? = .notAnOrbitProcess

    private var baseline = OrbitProcessMonitor.Baseline.none
    private var timer: Timer?
    private var isSampling = false

    // Read fresh on every use: a web view's process can change between a refresh and a click.
    private let attributionProvider: @MainActor () -> WebKitProcessAttribution

    init(attributionProvider: @escaping @MainActor () -> WebKitProcessAttribution = TaskManagerModel.liveAttribution) {
        self.attributionProvider = attributionProvider
    }

    static func liveAttribution() -> WebKitProcessAttribution {
        guard let engine = AppEnvironment.shared.engine as? WebKitEngine else { return .none }
        return WebKitProcessAttribution.gather(
            from: engine.openTabs.map(\.webView),
            extensionViews: engine.extensionWebViews
        )
    }

    var selectedProcess: OrbitProcessInfo? {
        guard let selectedProcessID else { return nil }
        return processes.first { $0.processID == selectedProcessID }
    }

    var canEndSelectedProcess: Bool { selectedProcess != nil && endProcessRefusal == nil }

    func start() {
        isSampling = true
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSampling else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        isSampling = false
        timer?.invalidate()
        timer = nil
    }

    // The window controller lives until quit. Called once the window is offscreen, so closing
    // does not paint an empty table, and the next open measures a new interval instead of the
    // whole time the window was closed.
    func releaseRetainedSample() {
        processes = []
        baseline = .none
        hasMeasuredCPU = false
        endProcessRefusal = .notAnOrbitProcess
    }

    func refresh() {
        let hadBaseline = !baseline.isEmpty
        let sample = OrbitProcessMonitor.sample(against: baseline, attribution: attributionProvider())
        baseline = sample.baseline
        if processes != sample.processes {
            processes = sample.processes
        }
        if hadBaseline { hasMeasuredCPU = true }

        if let selectedProcessID, !processes.contains(where: { $0.processID == selectedProcessID }) {
            self.selectedProcessID = nil
        }
        updateEndProcessRefusal()
    }

    private func updateEndProcessRefusal() {
        guard let selectedProcess else {
            endProcessRefusal = .notAnOrbitProcess
            return
        }
        endProcessRefusal = selectedProcess.processID == getpid() ? .isBrowserProcess : nil
    }

    @discardableResult
    func endSelectedProcess() -> OrbitProcessMonitor.EndProcessRefusal? {
        guard let selectedProcess else { return .notAnOrbitProcess }
        let refusal = OrbitProcessMonitor.endProcess(selectedProcess.processID, attribution: attributionProvider())
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

    func windowDidClose(_ notification: Notification) {
        model.releaseRetainedSample()
    }
}
