import Foundation

// Scripts must be registered before a session's first WebContents is created.
@MainActor
final class BoostRuntime {
    static let shared = BoostRuntime()

    init() {}

    // MARK: - The engine seam

    struct ScriptSink {
        let install: (UserScript, any EngineSession) -> Void
        let uninstall: (UUID, any EngineSession) -> Void

        init(
            install: @escaping (UserScript, any EngineSession) -> Void,
            uninstall: @escaping (UUID, any EngineSession) -> Void
        ) {
            self.install = install
            self.uninstall = uninstall
        }

        init(engine: any BrowserEngine) {
            self.install = { script, session in engine.addUserScript(script, session: session) }
            self.uninstall = { id, session in engine.removeUserScript(id: id, session: session) }
        }
    }

    // MARK: - What has been installed where

    // Compared by identity, not identifier: a session rebuilt under the same identifier has no scripts.
    private struct Installation {
        weak var session: (any EngineSession)?
        var scriptIDs: [UUID]
    }

    private var installations: [String: Installation] = [:]

    func hasInstalled(into session: any EngineSession) -> Bool {
        guard let existing = installations[session.identifier],
              let installedInto = existing.session else { return false }
        return installedInto === session
    }

    // MARK: - Installation

    @discardableResult
    func install(scripts: [UserScript], into session: any EngineSession, sink: ScriptSink) -> [UserScript] {
        for staleID in installations[session.identifier]?.scriptIDs ?? [] {
            sink.uninstall(staleID, session)
        }
        for script in scripts {
            sink.install(script, session)
        }
        installations[session.identifier] = Installation(session: session, scriptIDs: scripts.map(\.id))
        return scripts
    }

    @discardableResult
    func installAllBoosts(from store: BoostStore, into session: any EngineSession, sink: ScriptSink) -> [UserScript] {
        install(scripts: store.allCompiledScripts(), into: session, sink: sink)
    }

    @discardableResult
    func pageDidCommit(
        url: URL,
        in session: any EngineSession,
        contents: (any WebContents)?,
        store: BoostStore,
        sink: ScriptSink
    ) -> Bool {
        guard !hasInstalled(into: session) else { return false }

        installAllBoosts(from: store, into: session, sink: sink)

        if let contents, let host = url.host() {
            for script in store.compiledScripts(forHost: host) {
                contents.injectUserScript(script)
            }
        }
        return true
    }

    func reset() {
        installations.removeAll()
    }

    // MARK: - AppEnvironment-facing entry points

    func prepareSession(_ session: any EngineSession, env: AppEnvironment) {
        guard let sink = env.boostScriptSink, !hasInstalled(into: session) else { return }
        installAllBoosts(from: env.boostStore, into: session, sink: sink)
    }

    @discardableResult
    func pageDidCommit(url: URL, contents: any WebContents, env: AppEnvironment) -> Bool {
        guard let sink = env.boostScriptSink else { return false }
        return pageDidCommit(
            url: url,
            in: contents.session,
            contents: contents,
            store: env.boostStore,
            sink: sink
        )
    }

    func reapply(host: String, env: AppEnvironment) {
        guard env.boostScriptSink != nil else { return }
        reapplyAll(env: env)

        let scriptsForHost = env.boostStore.compiledScripts(forHost: host)
        for contents in env.webContents.values where hostMatches(contents, host: host) {
            for script in scriptsForHost {
                contents.injectUserScript(script)
            }
        }
    }

    // Installing an empty script set actively removes scripts already registered in live sessions.
    func reapplyAll(env: AppEnvironment) {
        guard let sink = env.boostScriptSink else { return }
        let all = env.boostStore.allCompiledScripts()

        var seenSessionIdentifiers: Set<String> = []
        for contents in env.webContents.values {
            let session = contents.session
            guard seenSessionIdentifiers.insert(session.identifier).inserted else { continue }
            install(scripts: all, into: session, sink: sink)
        }
    }

    private func hostMatches(_ contents: any WebContents, host: String) -> Bool {
        guard let contentsHost = contents.navigationState.url?.host()?.lowercased() else { return false }
        let lowered = host.lowercased()
        return contentsHost == lowered || contentsHost.hasSuffix(".\(lowered)")
    }
}
