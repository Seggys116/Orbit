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

        if !didStartInitialLoad {
            didStartInitialLoad = true
            readiness.append(cacheLoadTask)
            Task { @MainActor in
                await cacheLoadTask.value
                await self.controller.refresh()
            }
        } else if !controller.hasCompletedInitialCacheLoad {
            readiness.append(cacheLoadTask)
        }

        guard !readiness.isEmpty else { return nil }
        return Task { @MainActor in
            for task in readiness { await task.value }
        }
    }

    public func reset() {
        boundSessions.removeAll()
        didStartInitialLoad = false
    }
}
