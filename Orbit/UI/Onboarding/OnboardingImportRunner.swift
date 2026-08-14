import Foundation

// Onboarding's import step runs before any browser window exists, so
// AppEnvironment.engine is nil at that point unless something starts it —
// without a live engine session, ArcImportCoordinator has nowhere to store
// decrypted cookies and reports .decryptedButEngineCannotInstall even when
// the user asked to bring logins across. The menu-driven import in Settings
// never hits this because the app is already running with an engine by then.
@MainActor
enum OnboardingImportRunner {

    static func resolvedImportCookies(toggleOn: Bool, browser: ImportableBrowser) -> Bool {
        toggleOn && browser.importsLoginSessions
    }

    static func ensureEngineReady(
        env: AppEnvironment,
        starter: @MainActor (AppEnvironment) -> Void = { $0.startEngineIfNeeded() }
    ) {
        guard env.engine == nil else { return }
        starter(env)
    }

    static func runArcImport(
        env: AppEnvironment,
        importLoginSessions: Bool,
        engineStarter: @MainActor (AppEnvironment) -> Void = { $0.startEngineIfNeeded() },
        performImport: @MainActor (AppEnvironment, Bool) async throws -> ArcImportSummary = { env, importCookies in
            try await ArcImportCoordinator.performImport(env: env, importCookies: importCookies)
        }
    ) async -> OnboardingView.ImportState {
        let importCookies = resolvedImportCookies(toggleOn: importLoginSessions, browser: .arc)
        ensureEngineReady(env: env, starter: engineStarter)
        do {
            let summary = try await performImport(env, importCookies)
            return .finishedArc(summary)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
