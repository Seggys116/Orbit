import Foundation

@MainActor
public final class ContentBlockingRuntime {

    public static let shared = ContentBlockingRuntime()

    public let controller: ContentBlockingController

    private struct WeakSessionBox {
        weak var session: (any EngineSession)?
    }
    private var boundSessions: [ObjectIdentifier: WeakSessionBox] = [:]
    private var didStartInitialLoad = false

    private init() {
        self.controller = ContentBlockingController()
    }

    #if DEBUG
    init(controller: ContentBlockingController) {
        self.controller = controller
    }
    #endif

    public func beginInitialCacheLoad() {
        controller.beginInitialCacheLoad()
    }

    @discardableResult
    public func prepareSession(_ session: any EngineSession, engine: any BrowserEngine) -> Task<Void, Never>? {
        boundSessions = boundSessions.filter { $0.value.session != nil }

        let key = ObjectIdentifier(session)
        let isNew = boundSessions[key] == nil
        boundSessions[key] = WeakSessionBox(session: session)

        guard engine.capabilities.contains(.contentBlocking) else { return nil }

        let cacheLoadTask = controller.beginInitialCacheLoad()

        var readiness: [Task<Void, Never>] = []

        if isNew {
            readiness.append(Task { @MainActor in
                await self.controller.attach(engine: engine, sessions: [session])
            })
        }

        // refresh() recompiles even when loadFromCache already installed a hit.
        // That recompile stays off this list: the returned task is the first
        // navigation's wait, and it must resume with the cached rules in place.
        let scheduleRefresh = !didStartInitialLoad
        if scheduleRefresh {
            didStartInitialLoad = true
            readiness.append(cacheLoadTask)
        } else if !controller.hasCompletedInitialCacheLoad {
            readiness.append(cacheLoadTask)
        }

        guard !readiness.isEmpty else { return nil }

        let readinessTask = Task { @MainActor in
            for task in readiness { await task.value }
        }

        if scheduleRefresh {
            Task { @MainActor in
                await readinessTask.value
                // The navigation waiter is queued behind this task. Yield so
                // its load runs before refresh() takes the main actor to recompile.
                await Task.yield()
                // Downloading and recompiling competes with the first page for the network and main actor.
                // Cached lists are already installed, so it waits for the first commit (or a cap) unless a list is missing.
                if !self.controller.hasMissingEnabledList {
                    await LaunchGate.shared.waitForFirstCommit(timeout: Self.refreshDeferral)
                }
                await self.controller.refresh()
            }
        }

        return readinessTask
    }

    static let refreshDeferral: Duration = .seconds(30)

    /// True while the first navigation still has cached rules worth a short wait: blocking is on and the cache load has not landed.
    var shouldHoldFirstNavigation: Bool {
        controller.isEnabled && !controller.hasCompletedInitialCacheLoad
    }

    /// Returns when `readiness` finishes or `timeout` passes, whichever is first; the readiness work itself is never cancelled.
    /// A cold compile can outlast the timeout, in which case the page loads without the rules and they apply as they land.
    func awaitReadiness(_ readiness: Task<Void, Never>, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                await readiness.value
                once.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume()
            }
        }
    }

    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    public func reset() {
        boundSessions.removeAll()
        didStartInitialLoad = false
    }
}

// Lives here rather than with the app delegate: the host-less test target compiles this file but not the delegate.
/// Lets launch work that the first page does not need wait for that page's first commit, with a cap so it still runs
/// if no page ever commits. `pageDidCommit()` is called from the first main-frame commit of any tab.
@MainActor
final class LaunchGate {

    static let shared = LaunchGate()

    private(set) var hasFirstPageCommitted = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func pageDidCommit() {
        guard !hasFirstPageCommitted else { return }
        hasFirstPageCommitted = true
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume() }
    }

    /// Returns at the first commit or when `timeout` passes, whichever is first. Returns at once if a page already committed.
    func waitForFirstCommit(timeout: Duration) async {
        if hasFirstPageCommitted { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }
}
