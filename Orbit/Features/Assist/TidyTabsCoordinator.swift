//  AppEnvironment.tidyTodayTabsByHost is a separate, host-based grouping path used when this feature is off — never a fallback for a failed model call.

import Foundation

@MainActor
@Observable
final class TidyTabsCoordinator {

    static let shared = TidyTabsCoordinator()

    init() {}

    enum Phase: Equatable {
        case idle
        case tidying
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var phaseSpaceID: SpaceID?

    func dismissError() {
        guard case .failed = phase else { return }
        phase = .idle
        phaseSpaceID = nil
    }

    func reset() {
        phase = .idle
        phaseSpaceID = nil
    }

    func phase(for spaceID: SpaceID) -> Phase {
        phaseSpaceID == spaceID ? phase : .idle
    }

    // MARK: - Decisions (pure, no provider, no environment)

    static func shouldUseModel(todayTabCount: Int) -> Bool {
        AssistSettings.isTidyTabsEnabled
            && AssistSettings.isProviderConfigured
            && todayTabCount > AssistRuntime.tidyTabsMinimumTabs
    }

    static func candidates(from tabs: [Tab]) -> [AssistRuntime.TidyTabCandidate] {
        tabs.map { tab in
            AssistRuntime.TidyTabCandidate(
                id: tab.id,
                title: tab.displayTitle,
                url: tab.url
            )
        }
    }

    // MARK: - The core, sink-taking path

    @discardableResult
    func tidy(
        spaceID: SpaceID,
        candidates: [AssistRuntime.TidyTabCandidate],
        sink: AssistSink,
        runtime: AssistRuntime = AssistRuntime.shared,
        apply: ([AssistRuntime.TidyTabGroup]) -> Void
    ) async -> Result<[AssistRuntime.TidyTabGroup], AssistError> {
        phase = .tidying
        phaseSpaceID = spaceID
        do {
            let groups = try await runtime.tidiedTabGroups(candidates: candidates, sink: sink)
            apply(groups)
            phase = .idle
            phaseSpaceID = nil
            return .success(groups)
        } catch let error as AssistError {
            phase = .failed(error.localizedDescription)
            phaseSpaceID = spaceID
            return .failure(error)
        } catch {
            let wrapped = AssistError.transport(error.localizedDescription)
            phase = .failed(wrapped.localizedDescription)
            phaseSpaceID = spaceID
            return .failure(wrapped)
        }
    }

    // MARK: - Production entry point

    /// Checks every tab's live session, not just the active one — this feature sends a whole list, so one private tab in it is one too many.
    func tidy(spaceID: SpaceID, env: AppEnvironment) {
        guard AssistSettings.isTidyTabsEnabled else {
            fail(.featureDisabled("Tidy Tabs"), spaceID: spaceID)
            return
        }
        if let space = env.space(spaceID), env.isIncognito(space) {
            fail(.incognito, spaceID: spaceID)
            return
        }
        let tabs = env.todayTabs(in: spaceID)
        for tab in tabs where env.webContents[tab.id]?.session.isPersistent == false {
            fail(.incognito, spaceID: spaceID)
            return
        }
        guard tabs.count > AssistRuntime.tidyTabsMinimumTabs else {
            fail(.featureDisabled("Tidy Tabs"), spaceID: spaceID)
            return
        }
        guard let sink = AssistRuntime.providerOnlySink() else {
            fail(.notConfigured, spaceID: spaceID)
            return
        }

        let payload = Self.candidates(from: tabs)
        Task { [weak env] in
            await tidy(spaceID: spaceID, candidates: payload, sink: sink) { groups in
                env?.applyTidyTabGroups(groups, in: spaceID)
            }
        }
    }

    private func fail(_ error: AssistError, spaceID: SpaceID) {
        phase = .failed(error.localizedDescription)
        phaseSpaceID = spaceID
    }
}
