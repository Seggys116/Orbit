import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: OnboardingWindowController?

    #if DEBUG
    static var openBrowserWindow: () -> Void = { OrbitWindowController.openNewWindow(on: .processRoot) }
    #else
    static let openBrowserWindow: () -> Void = { OrbitWindowController.openNewWindow(on: .processRoot) }
    #endif

    // Set true while quitting, so windowWillClose does not write hasCompletedOnboarding or open a browser window.
    static var isApplicationTerminating = false

    // Without this, Finish opening a browser window re-triggers showIfNeeded() from that window's onAppear.
    static var didForceShowThisLaunch = false

    static func consumeForceShowAllowance(flagEnabled: Bool) -> Bool {
        guard flagEnabled, !didForceShowThisLaunch else { return false }
        didForceShowThisLaunch = true
        return true
    }

    // The isDemo gate belongs to the launch path only: the Demo app must not open onboarding
    // every launch, but Restart Onboarding is an explicit request and must work in both apps.
    @discardableResult
    static func showIfNeeded(on host: AppEnvironment = .processRoot) -> OnboardingWindowController? {
        guard !host.isDemo else { return nil }
        return present(on: host)
    }

    @discardableResult
    static func present(on host: AppEnvironment = .processRoot) -> OnboardingWindowController? {
        guard !host.hasCompletedOnboarding else { return nil }
        if let shared { return shared }
        let window = makeWindow()
        installContentView(
            window: window,
            rootView: OnboardingRootView(onFinished: {
                host.hasCompletedOnboarding = true
                shared?.close()
                openBrowserWindow()
            }, environment: host)
        )
        let controller = OnboardingWindowController(window: window)
        shared = controller
        window.delegate = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    // The delegate is dropped before closing any window still up, or
    // windowWillClose would run the "user skipped onboarding" path and write
    // hasCompletedOnboarding back to true underneath the restart.
    @MainActor
    static func restart(on host: AppEnvironment = .processRoot) {
        if let existing = shared {
            existing.window?.delegate = nil
            existing.close()
            shared = nil
        }
        host.hasCompletedOnboarding = false
        guard let controller = present(on: host) else {
            host.hasCompletedOnboarding = true
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    static var presentedWindowForTests: NSWindow? { shared?.window }

    static func closeForTests() {
        shared?.window?.delegate = nil
        shared?.close()
        shared = nil
    }
    #endif

    // MARK: - Window

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        return window
    }

    // sizingOptions = [], safeAreaRegions = [], and the wrapper NSView are all required together;
    // dropping any one reintroduces a titlebar-height inset or unbounded window growth.
    @discardableResult
    static func installContentView<Content: View>(
        window: NSWindow,
        rootView: Content
    ) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
        return hosting
    }

    @discardableResult
    static func skipRemainingSteps(in env: AppEnvironment) -> Bool {
        guard !env.hasCompletedOnboarding else { return false }
        env.hasCompletedOnboarding = true
        return true
    }

    @discardableResult
    static func handleWindowClosed(env: AppEnvironment, isTerminating: Bool) -> Bool {
        shared = nil
        guard !isTerminating else { return false }
        guard skipRemainingSteps(in: env) else { return false }
        openBrowserWindow()
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Self.handleWindowClosed(env: AppEnvironment.processRoot, isTerminating: Self.isApplicationTerminating)
    }
}

struct OnboardingRootView: View {
    var onFinished: () -> Void
    let environment: AppEnvironment

    var body: some View {
        OnboardingView(onFinished: onFinished).environment(environment)
    }
}
