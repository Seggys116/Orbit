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
                await self.controller.refresh()
            }
        }

        return readinessTask
    }

    public func reset() {
        boundSessions.removeAll()
        didStartInitialLoad = false
    }
}
