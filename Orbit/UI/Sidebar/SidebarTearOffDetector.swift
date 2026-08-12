//  No accessibility permission, so this samples NSEvent.pressedMouseButtons / mouseLocation (no CGEventTap/NSEvent.addGlobalMonitorForEvents) to detect a sidebar tab drag released outside every Orbit window.

import AppKit

// MARK: - Public contract

@MainActor
enum SidebarTearOff {
    // origin is the drag's own environment, not AppEnvironment.processRoot: the live WebContents this feature hands over lives wherever that environment's own webContents map holds it, which for an Incognito or torn-off window is not processRoot.
    static var handler: ((SidebarDragPayload, NSPoint, AppEnvironment) -> Void)?

    // Hook, not a direct OrbitWindowController reference: this file is a host-less-reused source in OrbitTests, which does not compile OrbitWindowController.swift at all.
    static var frontmostEnvironmentResolver: (() -> AppEnvironment?)?
}

// MARK: - Detector

@MainActor
enum SidebarTearOffDetector {

    // MARK: State

    private static var sessionToken: UInt64 = 0

    private static var timer: Timer?
    private static var payload: SidebarDragPayload?
    private static var changeCountAtStart: Int?
    // Weak: a window whose sidebar started this drag can close mid-drag, and this detector must not keep its environment alive past the window's own lifetime.
    private static weak var originEnvironment: AppEnvironment?
    private static var startedAt: Date?
    private static var consumed = false
    // The last NSEvent.mouseLocation sampled while the button was still confirmed down: the detecting tick can land up to one tick after the real mouse-up, by which a fast flick could carry mouseLocation somewhere the drag never reached.
    private static var lastKnownPressedLocation: NSPoint?

    private static let samplingInterval: TimeInterval = 1.0 / 60.0
    private static let safetyTimeoutInterval: TimeInterval = 300

    // MARK: Session lifecycle

    static func begin(_ payload: SidebarDragPayload) {
        timer?.invalidate()

        sessionToken &+= 1
        Self.payload = payload
        // Left nil, not captured eagerly: at this point in .onDrag's closure, AppKit's own dragging session hasn't started yet, so the drag pasteboard hasn't been written to. tick()'s own first call establishes the real baseline on a later run-loop turn guaranteed to fall after AppKit's write.
        changeCountAtStart = nil
        originEnvironment = SidebarTearOff.frontmostEnvironmentResolver?()
        startedAt = Date()
        consumed = false
        lastKnownPressedLocation = (NSEvent.pressedMouseButtons & 1 != 0) ? NSEvent.mouseLocation : nil

        // Timer(...) + explicit RunLoop.main.add(_:forMode: .common), not Timer.scheduledTimer: the convenience initializer schedules only into .default mode, which goes silent for the entire lifetime of AppKit's own modal drag-tracking loop.
        let sampler = Timer(timeInterval: samplingInterval, repeats: true) { _ in
            MainActor.assumeIsolated { SidebarTearOffDetector.tick() }
        }
        RunLoop.main.add(sampler, forMode: .common)
        timer = sampler
    }

    static func markConsumed() {
        guard payload != nil else { return }
        consumed = true
    }

    // MARK: Sampling

    private static func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private static func reset() {
        payload = nil
        changeCountAtStart = nil
        originEnvironment = nil
        startedAt = nil
        consumed = false
        lastKnownPressedLocation = nil
    }

    private static func tick() {
        guard let startedAt, Date().timeIntervalSince(startedAt) < safetyTimeoutInterval else {
            stopSampling()
            reset()
            return
        }
        if let changeCountAtStart {
            guard NSPasteboard(name: .drag).changeCount == changeCountAtStart else {
                stopSampling()
                reset()
                return
            }
        } else {
            // Lazily established here rather than in begin(_:): a Timer's first fire is always on a later run-loop turn than the synchronous drag-start sequence, so it is guaranteed to observe AppKit's pasteboard write; any earlier capture would not.
            Self.changeCountAtStart = NSPasteboard(name: .drag).changeCount
        }

        let leftButtonDown = NSEvent.pressedMouseButtons & 1 != 0
        if leftButtonDown {
            lastKnownPressedLocation = NSEvent.mouseLocation
            return
        }

        guard let payload else {
            stopSampling()
            reset()
            return
        }
        let releasePoint = lastKnownPressedLocation ?? NSEvent.mouseLocation
        let token = sessionToken
        stopSampling()

        // Deferred twice, not resolved on this tick: SidebarPayloadDropDelegate.performDrop(info:) consumes the same drag synchronously on AppKit's own mouse-up turn, and an in-app drop must always win over a stale tear-off decision.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                SidebarTearOffDetector.decide(token: token, payload: payload, releasedAt: releasePoint)
            }
        }
    }

    // MARK: Decision

    private static func decide(token: UInt64, payload: SidebarDragPayload, releasedAt point: NSPoint) {
        guard token == sessionToken else { return }
        defer { reset() }

        let wasConsumed = consumed
        if !wasConsumed {
            SidebarDragSession.discardStaleRecord()
        }

        let windowFrames = NSApp.windows
            .filter { $0.isVisible && !$0.isMiniaturized }
            .map(\.frame)
        guard shouldTearOff(payload: payload, releasedAt: point, windowFrames: windowFrames, wasConsumed: wasConsumed) else { return }
        guard !resolvesToFolder(payload) else { return }

        let origin = originEnvironment ?? .processRoot
        SidebarTearOff.handler?(payload, point, origin)
    }

    // NSEvent.mouseLocation and NSWindow.frame share the same bottom-left-origin screen space, so comparing point against windowFrames directly, with no flip, is correct.
    static func shouldTearOff(
        payload: SidebarDragPayload,
        releasedAt point: NSPoint,
        windowFrames: [NSRect],
        wasConsumed: Bool
    ) -> Bool {
        guard !wasConsumed else { return false }
        guard payload.kind == .pinnedNode || payload.kind == .todayTab else { return false }
        guard !windowFrames.contains(where: { $0.contains(point) }) else { return false }
        return true
    }

    // AppEnvironment.processRoot, not .shared: naming .shared directly would construct the real, non-scratch environment even when this detector runs in the OrbitDemo process.
    private static func resolvesToFolder(_ payload: SidebarDragPayload) -> Bool {
        guard payload.kind == .pinnedNode else { return false }
        guard let node = PinnedNodeTree.find(payload.nodeID, in: AppEnvironment.processRoot.pinnedNodes(in: payload.spaceID)) else {
            return false
        }
        if case .folder = node { return true }
        return false
    }
}
