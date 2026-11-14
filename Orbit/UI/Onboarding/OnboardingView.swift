import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    var onFinished: () -> Void

    @State private var flow = OnboardingFlowState()
    @State private var spaceDrafts: [OnboardingSpaceDraft] = OnboardingView.initialDrafts()
    @State private var selectedDraftID: UUID?
    @State private var selectedSearchEngine: SearchEngine = .fallback
    @State private var selectedImportSource: ImportableBrowser?
    @State private var importLoginSessions = false
    @State private var importState: ImportState = .idle
    @State private var importProgress = ImportProgress()
    @State private var availableImportSources: [ImportableBrowser] = []
    @State private var hasLoadedImportSources = false
    @State private var committedProfileID: ProfileID?
    // Set when an import lands: the Spaces step then edits the Spaces that now exist instead of a blank draft list.
    @State private var needsSpaceReseed = false
    @State private var shortcutPrimer = OnboardingShortcutPrimer()

    @State private var offersDefaultBrowserButton = true
    @State private var didRequestDefaultBrowser = false

    enum ImportState: Equatable {
        case idle
        case importing(ImportableBrowser)
        case finishedArc(ArcImportSummary)
        case finished(BrowserImportSummary)
        case failed(String)
    }

    // Below this width the stage would leave the control column cramped, so the column takes the window.
    private static let stageMinimumWindowWidth: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            let showsStage = proxy.size.width >= Self.stageMinimumWindowWidth
            let columnWidth = showsStage ? min(460, max(380, proxy.size.width * 0.5)) : proxy.size.width
            HStack(spacing: 0) {
                controlColumn
                    .frame(width: columnWidth)
                if showsStage {
                    OnboardingStageArt(scene: planetScene)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // Fills its window rather than pinning 880x560: a hard frame centres and clips the control column when the window is narrower.
        .frame(minWidth: 420, idealWidth: 880, maxWidth: .infinity, minHeight: 400, idealHeight: 560, maxHeight: .infinity)
        .background(OrbitNeutral.bg)
        .task {
            let reader = BrowserDataReader()
            availableImportSources = await Task.detached(priority: .userInitiated) {
                reader.availableBrowsers()
            }.value
            hasLoadedImportSources = true
            offersDefaultBrowserButton = DefaultBrowser.shouldOfferToBecomeDefault
        }
    }

    // MARK: - Column

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingStepRail(state: flow) { target in
                flow.go(to: target)
            }
            .padding(.bottom, 22)

            ZStack(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .scrollClipDisabled()
                .id(flow.step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .orbitAnimation(OrbitMotion.dramatic, value: flow.step)

            navigationRow
                .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 22)
        .frame(maxHeight: .infinity)
        .background(OrbitNeutral.card)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome:
            OnboardingWelcomeStep()
        case .importBrowser:
            OnboardingImportStep(
                sources: availableImportSources,
                hasLoadedSources: hasLoadedImportSources,
                selection: $selectedImportSource,
                importLoginSessions: $importLoginSessions,
                state: importState,
                progress: importProgress,
                onSelectionChanged: {
                    importState = .idle
                    importProgress = ImportProgress()
                }
            )
            .orbitAnimation(OrbitMotion.dramatic, value: importState)
        case .spaces:
            OnboardingSpacesStep(drafts: $spaceDrafts, selectedDraftID: $selectedDraftID)
        case .shortcuts:
            OnboardingShortcutsStep(primer: $shortcutPrimer)
        case .finish:
            OnboardingFinishStep(
                searchEngine: $selectedSearchEngine,
                offersDefaultBrowser: offersDefaultBrowserButton,
                onSetDefaultBrowser: requestDefaultBrowser
            )
        }
    }

    // MARK: - Stage

    private var planetScene: OnboardingPlanetScene {
        let selectedTheme = spaceDrafts.first { $0.id == selectedDraftID }?.theme ?? spaceDrafts.first?.theme
        return OnboardingPlanetScene.scene(
            step: flow.step,
            importPhase: importPhase,
            hasImportSource: selectedImportSource != nil,
            importFraction: importProgress.overallFraction,
            spaceTint: selectedTheme?.primary.planetColor,
            shortcutsTried: shortcutPrimer.triedCount
        )
    }

    // MARK: - Navigation

    private var importPhase: OnboardingImportPhase { Self.phase(of: importState) }

    private var primaryTitle: String {
        flow.primaryTitle(importSourceName: selectedImportSource?.displayName, importPhase: importPhase)
    }

    private var navigationRow: some View {
        let hasSource = selectedImportSource != nil
        let offersMaybeLater = flow.offersMaybeLater(hasImportSource: hasSource, importPhase: importPhase)
        let back = Button("Back") { flow.back() }
            .buttonStyle(OnboardingButtonStyle(variant: .plain))
            .disabled(!flow.canGoBack)
            .opacity(flow.isFirst ? 0 : 1)
            .accessibilityHidden(flow.isFirst)
        let maybeLater = Button("Maybe later") { skipImport() }
            .buttonStyle(OnboardingButtonStyle(variant: .plain))
            .disabled(flow.isBusy)
        let primary = Button(primaryTitle) { performPrimaryAction() }
            .buttonStyle(OnboardingButtonStyle(variant: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(flow.isBusy)

        // The long form needs all three controls on one line; a narrow column gives the primary action its own line so nothing clips.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                back
                Spacer(minLength: 8)
                if offersMaybeLater { maybeLater }
                primary
            }
            VStack(alignment: .trailing, spacing: 8) {
                primary
                HStack(spacing: 8) {
                    back
                    Spacer(minLength: 8)
                    if offersMaybeLater { maybeLater }
                }
            }
        }
    }

    private func performPrimaryAction() {
        let action = flow.primaryAction(hasImportSource: selectedImportSource != nil, importPhase: importPhase)
        switch action {
        case .startImport:
            if let browser = selectedImportSource { runImport(browser) }
        case .next:
            advance()
        case .finish:
            finish()
        }
    }

    private func advance() {
        if flow.step == .spaces { commitSpacesSetup() }
        if flow.step == .importBrowser { prepareSpacesStep() }
        flow.advance()
    }

    private func skipImport() {
        selectedImportSource = nil
        importState = .idle
        importProgress = ImportProgress()
        advance()
    }

    private func finish() {
        commitSearchEngine()
        Self.commitDefaultBrowserDecision(
            wasOffered: offersDefaultBrowserButton,
            didRequest: didRequestDefaultBrowser
        )
        onFinished()
    }

    private func requestDefaultBrowser() {
        didRequestDefaultBrowser = true
        DefaultBrowser.requestBecomingDefault { _ in
            Task { @MainActor in
                offersDefaultBrowserButton = DefaultBrowser.shouldOfferToBecomeDefault
            }
        }
    }

    // MARK: - Import

    // Never advances the step itself: the caller decides when to move on.
    private func runImport(_ browser: ImportableBrowser) {
        guard let spaceID = env.activeSpace?.id ?? env.spaces.first?.id else {
            importState = .failed("Orbit has no Space to import into yet.")
            return
        }
        importProgress = ImportProgress()
        importState = .importing(browser)
        flow.isBusy = true
        let wantsLoginSessions = importLoginSessions
        Task { @MainActor in
            let report: ImportProgressHandler = { event in importProgress.apply(event) }
            let result: ImportState
            if browser.importsNativeStructure {
                result = await OnboardingImportRunner.runArcImport(
                    env: env,
                    importLoginSessions: wantsLoginSessions,
                    progress: report
                )
            } else {
                result = await OnboardingImportRunner.runStandardImport(
                    browser,
                    into: spaceID,
                    env: env,
                    progress: report
                )
            }
            if Self.isImportComplete(result) {
                importProgress.finishAll()
                needsSpaceReseed = true
            }
            importState = result
            flow.isBusy = false
        }
    }

    private func prepareSpacesStep() {
        guard needsSpaceReseed else { return }
        needsSpaceReseed = false
        spaceDrafts = OnboardingSpaceDraft.drafts(from: env.spaces)
        selectedDraftID = spaceDrafts.first?.id
    }

    // MARK: - Commit

    private func commitSpacesSetup() {
        guard let firstProfile = env.state.profiles.first else { return }
        OnboardingCommit.applySpacesSetup(spaceDrafts, profileID: firstProfile.id, in: &env.state)
        committedProfileID = firstProfile.id
    }

    private func commitSearchEngine() {
        OnboardingCommit.applySearchEngine(
            selectedSearchEngine,
            toProfile: committedProfileID,
            in: &env.state
        )
    }

    // MARK: - Statics

    // Every draft starts with an explicit theme so the preview and the committed Space always agree.
    static func initialDrafts() -> [OnboardingSpaceDraft] {
        var drafts = OnboardingSpaceDraft.defaults
        let themes = OnboardingCommit.resolvedThemes(for: drafts)
        for index in drafts.indices { drafts[index].theme = themes[index] }
        return drafts
    }

    static var supportedBrowserList: String {
        let names = ImportableBrowser.allCases.map(\.displayName)
        guard let last = names.last else { return "any other browser" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    static func phase(of state: ImportState) -> OnboardingImportPhase {
        switch state {
        case .idle: .idle
        case .importing: .running
        case .finished, .finishedArc: .done
        case .failed: .failed
        }
    }

    static func isImportComplete(_ state: ImportState) -> Bool {
        phase(of: state) == .done
    }

    static func continueButtonTitle(
        step: OnboardingStep,
        selectedImportSource: ImportableBrowser?,
        importState: ImportState
    ) -> String {
        OnboardingFlowState(step: step).primaryTitle(
            importSourceName: selectedImportSource?.displayName,
            importPhase: phase(of: importState)
        )
    }

    static func commitDefaultBrowserDecision(wasOffered: Bool, didRequest: Bool) {
        guard wasOffered, !didRequest else { return }
        DefaultBrowser.recordDeclined()
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    private struct Point: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    private let points = [
        Point(symbol: "arrow.down.circle", text: "Bring your tabs, bookmarks and history over"),
        Point(symbol: "square.stack", text: "Sort your browsing into themed Spaces"),
        Point(symbol: "keyboard", text: "Learn the few keys that matter"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeading(
                title: "Welcome to Orbit.",
                subtitle: "A calmer way to browse. It takes about a minute to get set up."
            )
            VStack(alignment: .leading, spacing: 10) {
                ForEach(points) { point in
                    HStack(spacing: 10) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(OrbitNeutral.ink2)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
                                    .fill(OrbitNeutral.chip)
                            )
                        Text(point.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OrbitNeutral.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
