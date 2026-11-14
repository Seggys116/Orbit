import Foundation

// Onboarding imports run before any window exists, so without a live engine session ArcImportCoordinator reports .decryptedButEngineCannotInstall for cookies; Settings never hits this.
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
        performImport: (@MainActor (AppEnvironment, Bool) async throws -> ArcImportSummary)? = nil,
        progress: ImportProgressHandler? = nil
    ) async -> OnboardingView.ImportState {
        let importCookies = resolvedImportCookies(toggleOn: importLoginSessions, browser: .arc)
        ensureEngineReady(env: env, starter: engineStarter)
        do {
            let summary: ArcImportSummary
            if let performImport {
                summary = try await performImport(env, importCookies)
            } else {
                summary = try await ArcImportCoordinator.performImport(
                    env: env,
                    importCookies: importCookies,
                    progress: progress
                )
            }
            return .finishedArc(summary)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func runStandardImport(
        _ browser: ImportableBrowser,
        into spaceID: SpaceID,
        env: AppEnvironment,
        progress: ImportProgressHandler? = nil
    ) async -> OnboardingView.ImportState {
        do {
            let summary = try await BrowserImportCoordinator.performImport(
                browser,
                into: spaceID,
                env: env,
                progress: progress
            )
            return .finished(summary)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
