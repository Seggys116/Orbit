import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, profileSetup, importBrowser, searchEngine, defaultBrowser
}

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    var onFinished: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var spaceDrafts: [OnboardingSpaceDraft] = OnboardingSpaceDraft.defaults
    @State private var selectedSearchEngine: SearchEngine = .fallback
    @State private var selectedImportSource: ImportableBrowser?
    @State private var importLoginSessions = false
    @State private var importState: ImportState = .idle
    @State private var availableImportSources: [ImportableBrowser] = []
    @State private var committedProfileID: ProfileID?

    @State private var offersDefaultBrowserButton = true
    @State private var didRequestDefaultBrowser = false

    enum ImportState: Equatable {
        case idle
        case importing(ImportableBrowser)
        case finishedArc(ArcImportSummary)
        case finished(BrowserImportSummary)
        case failed(String)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                stepContent
                Spacer()
                navigationRow
            }
            .padding(48)
            .frame(width: 420)

            OnboardingStageArt(step: step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 880, height: 560)
        .task {
            let reader = BrowserDataReader()
            availableImportSources = await Task.detached(priority: .userInitiated) {
                reader.availableBrowsers()
            }.value
            offersDefaultBrowserButton = DefaultBrowser.shouldOfferToBecomeDefault
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Orbit").font(.system(size: 30, weight: .bold))
                Text("A calmer way to browse. Let's get you set up.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        case .profileSetup:
            VStack(alignment: .leading, spacing: 10) {
                Text("Set Up Your Spaces").font(.system(size: 24, weight: .bold))
                Text("Orbit keeps everything local — no account required. Spaces are separate sets of tabs and favourites you switch between. Start with these, or make them your own.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                spacesSetupEditor
            }
        case .importBrowser:
            importStepContent
        case .searchEngine:
            VStack(alignment: .leading, spacing: 10) {
                Text("Default Search Engine").font(.system(size: 24, weight: .bold))
                Text("Used for anything you type in the Command Bar that isn't an address. You can change it any time in Settings › Profiles.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                // OrbitPopupButton, not a stock Picker: a menu-style Picker does not present reliably inside this app's NSHostingView.
                OrbitPopupButton(
                    options: SearchEngine.allCases,
                    label: { $0.displayName },
                    selection: $selectedSearchEngine,
                    accessibilityLabel: "Default search engine"
                )
                .frame(width: 220)
            }
        case .defaultBrowser:
            VStack(alignment: .leading, spacing: 10) {
                Text("Make Orbit Your Default").font(.system(size: 24, weight: .bold))
                if offersDefaultBrowserButton {
                    Text("Open links from anywhere in Orbit. macOS asks you to confirm — you can say no, and nothing in Orbit will raise it again by itself.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set as Default Browser") {
                        didRequestDefaultBrowser = true
                        DefaultBrowser.requestBecomingDefault { _ in
                            Task { @MainActor in
                                offersDefaultBrowserButton = DefaultBrowser.shouldOfferToBecomeDefault
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Orbit already opens links from other apps. Nothing to do here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Spaces setup step

    private var spacesSetupEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($spaceDrafts) { $draft in
                spaceDraftRow(draft: $draft)
            }
            if spaceDrafts.isEmpty {
                Text("Continuing without adding any Space starts you with a single default Space instead.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                spaceDrafts.append(OnboardingSpaceDraft(name: "", emoji: ""))
            } label: {
                Label("Add Space", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
        }
        .frame(width: 300, alignment: .leading)
    }

    private func spaceDraftRow(draft: Binding<OnboardingSpaceDraft>) -> some View {
        HStack(spacing: 8) {
            TextField("—", text: draft.emoji)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 36)
                .onChange(of: draft.wrappedValue.emoji) { _, newValue in
                    guard newValue.count > 1 else { return }
                    draft.wrappedValue.emoji = String(newValue.suffix(1))
                }
                .accessibilityLabel("Emoji for \(draft.wrappedValue.name.isEmpty ? "this Space" : draft.wrappedValue.name), optional")
            TextField("Space name", text: draft.name)
                .textFieldStyle(.roundedBorder)
            Button {
                spaceDrafts.removeAll { $0.id == draft.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(draft.wrappedValue.name.isEmpty ? "this Space" : draft.wrappedValue.name)")
        }
    }

    // MARK: - Import step

    @ViewBuilder
    private var importStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import From Your Old Browser").font(.system(size: 24, weight: .bold))

            if availableImportSources.isEmpty {
                Text("Orbit couldn't find data from \(Self.supportedBrowserList) on this Mac. You can import later from Archive › Import from Another Browser.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(importDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    ForEach(availableImportSources) { browser in
                        importSourceRow(browser)
                    }
                }
                .frame(width: 300, alignment: .leading)

                loginSessionToggle
            }

            importStatusLine
        }
    }

    @ViewBuilder
    private var loginSessionToggle: some View {
        if selectedImportSource?.importsLoginSessions == true {
            Toggle(isOn: $importLoginSessions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stay signed in to your sites")
                        .font(.system(size: 12, weight: .medium))
                    Text("Copies your login sessions. macOS will ask for permission to read \(selectedImportSource?.displayName ?? "the browser")'s saved key.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .frame(width: 300, alignment: .leading)
            .disabled(isImporting)
        }
    }

    static var supportedBrowserList: String {
        let names = ImportableBrowser.allCases.map(\.displayName)
        guard let last = names.last else { return "any other browser" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    private var importDescription: String {
        guard let source = selectedImportSource else {
            return "Pick a browser to bring your bookmarks and browsing history across. Passwords are never imported."
        }
        guard source.importsNativeStructure else {
            return "Orbit can import your bookmarks and browsing history from \(source.displayName). Passwords are not imported."
        }
        return "Orbit can import your Arc Spaces whole: their names, icons and themes, your pinned tabs and folders, Today tabs, favourites, archived tabs, browsing history, extensions, keyboard shortcuts, per-site zoom and your link-routing rules. Passwords are not imported."
    }

    private func importSourceRow(_ browser: ImportableBrowser) -> some View {
        let isSelected = selectedImportSource == browser
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.filled.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(browser.displayName)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedImportSource = (selectedImportSource == browser) ? nil : browser
            importState = .idle
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(browser.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var importStatusLine: some View {
        switch importState {
        case .idle:
            EmptyView()
        case .importing(let browser):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Importing from \(browser.displayName)…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .finished(let summary):
            Text("Imported \(summary.bookmarksImported) bookmark\(summary.bookmarksImported == 1 ? "" : "s") into \(summary.foldersCreated) folder\(summary.foldersCreated == 1 ? "" : "s") and \(summary.historyEntriesImported) history entr\(summary.historyEntriesImported == 1 ? "y" : "ies") from \(summary.browser.displayName).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .finishedArc(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.arcSummaryLine(summary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.arcCaveats(summary), id: \.self) { caveat in
                    Text(caveat)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isImporting: Bool {
        if case .importing = importState { return true }
        return false
    }

    private func runImportThenAdvance(_ browser: ImportableBrowser) {
        guard let spaceID = env.activeSpace?.id ?? env.spaces.first?.id else {
            importState = .failed("Orbit has no Space to import into yet.")
            return
        }
        importState = .importing(browser)
        Task { @MainActor in
            do {
                if browser.importsNativeStructure {
                    let summary = try await ArcImportCoordinator.performImport(
                        env: env,
                        importCookies: importLoginSessions && browser.importsLoginSessions
                    )
                    importState = .finishedArc(summary)
                } else {
                    let summary = try await BrowserImportCoordinator.performImport(browser, into: spaceID, env: env)
                    importState = .finished(summary)
                }
                move(1)
            } catch {
                importState = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    static func arcSummaryLine(_ summary: ArcImportSummary) -> String {
        var parts: [String] = []
        parts.append("\(summary.spacesCreated) Space\(summary.spacesCreated == 1 ? "" : "s")")
        parts.append("\(summary.totalTabsImported) tab\(summary.totalTabsImported == 1 ? "" : "s")")
        if summary.foldersCreated > 0 {
            parts.append("\(summary.foldersCreated) folder\(summary.foldersCreated == 1 ? "" : "s")")
        }
        if summary.favoritesImported > 0 {
            parts.append("\(summary.favoritesImported) favourite\(summary.favoritesImported == 1 ? "" : "s")")
        }
        if summary.historyEntriesImported > 0 {
            parts.append("\(summary.historyEntriesImported) history entr\(summary.historyEntriesImported == 1 ? "y" : "ies")")
        }
        if summary.keyBindingsImported > 0 {
            parts.append("\(summary.keyBindingsImported) keyboard shortcut\(summary.keyBindingsImported == 1 ? "" : "s")")
        }
        if case .imported(let count) = summary.cookies, count > 0 {
            parts.append("\(count) login session\(count == 1 ? "" : "s")")
        }
        return "Imported " + parts.joined(separator: ", ") + " from Arc."
    }

    static func arcCaveats(_ summary: ArcImportSummary) -> [String] {
        var caveats: [String] = []
        if summary.extensionsInstalled > 0, summary.extensionsNeedRestart {
            caveats.append("\(summary.extensionsInstalled) extension\(summary.extensionsInstalled == 1 ? "" : "s") installed from Arc. Restart Orbit to load \(summary.extensionsInstalled == 1 ? "it" : "them").")
        }
        if summary.extensionsAlreadyInstalled > 0 {
            caveats.append("\(summary.extensionsAlreadyInstalled) extension\(summary.extensionsAlreadyInstalled == 1 ? "" : "s") from Arc \(summary.extensionsAlreadyInstalled == 1 ? "was" : "were") already installed in Orbit.")
        }
        if !summary.extensionsNeedingManualInstall.isEmpty {
            caveats.append("Couldn't install \(summary.extensionsNeedingManualInstall.joined(separator: ", ")) from Arc — reinstall from the Chrome Web Store.")
        }
        if !summary.keyBindingsNeedingManualRebind.isEmpty {
            let actions = summary.keyBindingsNeedingManualRebind.joined(separator: ", ")
            caveats.append("Couldn't bring these Arc shortcuts across: \(actions). Set them again in Settings › Shortcuts.")
        }
        switch summary.cookies {
        case .notAttempted, .imported:
            break
        case .partiallyImported(let stored, let decrypted):
            let missed = decrypted - stored
            caveats.append("\(stored) login session\(stored == 1 ? "" : "s") came across from Arc. \(missed) had already expired or couldn't be re-stored, so you may need to sign in again on some sites.")
        case .decryptedButEngineCannotInstall(let count):
            caveats.append("\(count) login session\(count == 1 ? "" : "s") could be read from Arc but there was no browsing session to put \(count == 1 ? "it" : "them") in, so you will need to sign in again.")
        case .keychainDenied:
            caveats.append("Orbit was not allowed to read Arc's saved logins, so you will need to sign in again.")
        case .failed(let reason):
            caveats.append("Arc's login sessions could not be read: \(reason)")
        }
        return caveats
    }

    // MARK: - Navigation

    private var navigationRow: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isImporting)
            }
            stageIndicator
            Spacer()
            if step == .importBrowser, selectedImportSource != nil {
                Button("Maybe Later") {
                    selectedImportSource = nil
                    importState = .idle
                    move(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isImporting)
            }
            Button(continueButtonTitle) {
                if step == .profileSetup { commitSpacesSetup() }
                if step == .searchEngine { commitSearchEngine() }
                if step == .importBrowser, let browser = selectedImportSource {
                    runImportThenAdvance(browser)
                    return
                }
                if step == .defaultBrowser {
                    commitSearchEngine()
                    Self.commitDefaultBrowserDecision(
                        wasOffered: offersDefaultBrowserButton,
                        didRequest: didRequestDefaultBrowser
                    )
                    onFinished()
                } else {
                    move(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isImporting)
        }
    }

    private var stageIndicator: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { each in
                Capsule()
                    .fill(each == step ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: each == step ? 16 : 6, height: 6)
            }
        }
        .padding(.leading, step == .welcome ? 0 : 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private var continueButtonTitle: String {
        if step == .defaultBrowser { return "Finish" }
        if step == .importBrowser, let browser = selectedImportSource {
            return "Import From \(browser.displayName)"
        }
        return "Continue"
    }

    private func move(_ delta: Int) {
        guard let newStep = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        withAnimation(OrbitMotion.standard) { step = newStep }
    }

    static func commitDefaultBrowserDecision(wasOffered: Bool, didRequest: Bool) {
        guard wasOffered, !didRequest else { return }
        DefaultBrowser.recordDeclined()
    }

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
}
