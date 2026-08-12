import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtensionsSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var extensions: [LoadedExtension] = []
    @State private var showImporter = false
    @State private var actionError: String?
    @State private var installStatusMessage: String?
    @State private var installStatusKind: ExtensionInstallStatusKind = .success
    @State private var installFailure: ExtensionInstallFailurePresentation?
    @State private var installInput = ""
    @State private var installController = ExtensionInstallController()
    @State private var installTask: Task<Void, Never>?
    @State private var expandedExtensionIDs: Set<String> = []
    @State private var updateRowStates: [String: ExtensionUpdateRowState] = [:]
    // Attaching .focused(_:) to the outside of OrbitTextField does nothing; must use externalFocus:.
    @FocusState private var installFieldFocused: Bool
    @State private var router = SettingsRouter.shared
    @State private var extensionRuntime = ExtensionRuntime.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Extensions").font(.system(size: 20, weight: .bold))

            if !env.capabilitiesSupportExtensions {
                OrbitSettingsSection(title: nil) {
                    ExtensionsEngineStartingNotice()
                }
            } else {
                if env.extensionStore.hasPendingChanges {
                    OrbitSettingsSection(title: nil) {
                        ExtensionPendingChangesBanner(lastError: extensionRuntime.lastError) {
                            RelaunchController.relaunch(host: env)
                        }
                    }
                }

                installSection

                OrbitSettingsSection(title: "Installed") {
                    ExtensionsInstalledSectionView(
                        extensions: extensions,
                        expandedExtensionIDs: expandedExtensionIDs,
                        updateRowStates: updateRowStates,
                        isCheckingForUpdateDisabled: installController.isBusy,
                        rowDetail: rowDetail(for:),
                        onSetEnabled: setEnabled,
                        onRemove: remove,
                        onToggleExpanded: toggleExpanded,
                        onOpenOptionsPage: openOptionsPage,
                        onOpenWebStoreListing: openWebStoreListing,
                        onCheckForUpdate: beginUpdateCheck
                    )
                }

                if let actionError {
                    OrbitInlineNotice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: actionError)
                }

                OrbitSettingsActionRow {
                    Text("Load an extension from a local, unpacked folder.")
                        .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                        .foregroundStyle(.secondary)
                } trailing: {
                    OrbitButton(title: "Load Unpacked Extension…", kind: .primary, accentColor: SettingsPalette.accent) {
                        actionError = nil
                        showImporter = true
                    }
                }
            }
        }
        .task { refresh() }
        // Both hooks needed: onAppear catches a request made before this pane existed, onChange catches later ones.
        .onAppear { applyPendingInstallFieldFocus() }
        .onChange(of: router.focusRequest?.token) { _, _ in applyPendingInstallFieldFocus() }
        // ExtensionRuntime loads and unloads after the store change that triggered it, so the running/not-running column settles here rather than in the action that started it.
        .onChange(of: extensionRuntime.settleSerial) { _, _ in refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { await load(directory: url) }
            case .failure(let error):
                actionError = error.localizedDescription
            }
        }
        // The setter fires with nil for every non-button dismissal (Escape, click-outside); route it to consentSheetDismissedWithoutAnswer() so default is decline.
        .sheet(item: Binding(
            get: { installController.consentRequest },
            set: { newValue in
                if newValue == nil {
                    installController.consentSheetDismissedWithoutAnswer()
                }
            }
        )) { request in
            ExtensionConsentSheetView(pending: request.pending) { granted in
                installController.answerConsent(granted)
            }
        }
    }

    // MARK: - Install from the Chrome Web Store

    private var installSection: some View {
        OrbitSettingsSection(title: "Install from the Chrome Web Store") {
            VStack(alignment: .leading, spacing: 8) {
                OrbitSettingsActionRow {
                    Text("Browse the Chrome Web Store to find extensions.")
                        .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                        .foregroundStyle(.secondary)
                } trailing: {
                    OrbitButton(title: "Browse Chrome Web Store", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        openWebStoreHome()
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    OrbitTextField(
                        placeholder: "Paste a Chrome Web Store link or extension ID",
                        text: $installInput,
                        accentColor: SettingsPalette.accent,
                        externalFocus: $installFieldFocused
                    )
                    OrbitButton(title: "Install", kind: .primary, isCompact: true, accentColor: SettingsPalette.accent) {
                        beginInstall()
                    }
                    .disabled(installController.isBusy || installInputTrimmed.isEmpty)
                }

                if let installHint {
                    Text(installHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if installController.phase != .idle {
                    HStack(alignment: .top, spacing: 8) {
                        if let stage = installController.installStage {
                            ExtensionInstallStageRow(stage: stage)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(installPhaseDescription)
                                    .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        OrbitButton(title: "Cancel", kind: .ghost, isCompact: true) {
                            installTask?.cancel()
                        }
                    }
                }

                if let installFailure {
                    ExtensionInstallFailureRow(presentation: installFailure)
                }

                if let installStatusMessage {
                    OrbitInlineNotice(
                        systemImage: installStatusKind.systemImage,
                        tint: installStatusKind.tint,
                        text: installStatusMessage
                    )
                }
            }
        }
    }

    // Deferred a turn: on first-open this runs during the update that installs the focusable leaf, so an inline assignment is silently dropped.
    private func applyPendingInstallFieldFocus() {
        guard router.focusRequest?.target == .extensionInstallField else { return }
        router.consumeFocusRequest(.extensionInstallField)
        Task { @MainActor in
            installFieldFocused = true
        }
    }

    private var installInputTrimmed: String {
        installInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var installHint: String? {
        switch ExtensionInstallLogic.classifyInput(installInput) {
        case .empty:
            return nil
        case .webStoreLink:
            return "Looks like a Chrome Web Store link."
        case .extensionID:
            return "Looks like an extension id."
        case .unrecognized:
            return "That doesn't look like a Chrome Web Store link or extension id yet."
        }
    }

    private var installPhaseDescription: String {
        switch installController.phase {
        case .idle: return ""
        case .resolving: return "Resolving…"
        case .downloadingAndVerifying: return "Downloading and verifying…"
        case .awaitingConsent: return "Waiting for your decision…"
        case .finishingInstall: return "Installing…"
        case .checkingForUpdate: return "Checking for an update…"
        }
    }

    private func beginInstall() {
        actionError = nil
        installStatusMessage = nil
        installFailure = nil
        let raw = installInput
        installTask = Task {
            do {
                let result = try await installController.install(raw)
                switch result {
                case .installed(let installedExtension, let isUpdate, let previousVersion):
                    installInput = ""
                    installStatusKind = .success
                    if isUpdate {
                        installStatusMessage = previousVersion.map {
                            "Updated \"\(installedExtension.name)\" from \($0) to \(installedExtension.version)."
                        } ?? "Updated \"\(installedExtension.name)\" to \(installedExtension.version)."
                    } else {
                        installStatusMessage = "Installed \"\(installedExtension.name)\" \(installedExtension.version)."
                    }
                case .declined:
                    installStatusKind = .declined
                    installStatusMessage = "Installation declined."
                case .noUpdateAvailable:
                    break
                }
                refresh()
            } catch {
                installFailure = ExtensionInstallFailurePresentation.present(error)
            }
            installTask = nil
        }
    }

    // MARK: - Installed list row detail

    struct ExtensionRowDetail {
        let warnings: [ExtensionPermissionWarning]
        let requestsTabs: Bool
        let isPathDerived: Bool
        let optionsURL: URL?
    }

    private func rowDetail(for ext: LoadedExtension) -> ExtensionRowDetail? {
        guard let manifest = try? ChromeExtensionManifest.read(fromDirectory: ext.directory) else { return nil }
        return ExtensionRowDetail(
            warnings: ExtensionPermissionWarnings.warnings(for: manifest),
            requestsTabs: ExtensionInstallLogic.requestsTabsPermission(manifest),
            isPathDerived: ExtensionInstallLogic.isPathDerivedID(manifestKey: manifest.key),
            // The Site Control popover only reaches extensions with a toolbar action; one that declares nothing but options_page has this as its only way in.
            optionsURL: ExtensionActionPopupSupport.settingsOptionsPageURL(
                extensionID: ext.id,
                isEnabled: ext.isEnabled,
                isActivatedInRunningEngine: ext.isActivated,
                manifestKey: manifest.key,
                optionsPagePath: manifest.optionsPagePath,
                sessionIsPersistent: env.engine?.defaultSession.isPersistent ?? false
            )
        )
    }

    private func toggleExpanded(_ id: String) {
        if expandedExtensionIDs.contains(id) {
            expandedExtensionIDs.remove(id)
        } else {
            expandedExtensionIDs.insert(id)
        }
    }

    private func openWebStoreListing(for id: String) {
        guard let url = try? ChromeWebStoreLocator.detailURL(forExtensionID: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openOptionsPage(_ url: URL) {
        guard let spaceID = env.activeSpace?.id else { return }
        env.openTab(url: url, in: spaceID)
    }

    private func openWebStoreHome() {
        guard let spaceID = env.activeSpace?.id, let url = URL(string: "https://chromewebstore.google.com/") else { return }
        env.openTab(url: url, in: spaceID)
    }

    private func beginUpdateCheck(for id: String) {
        updateRowStates[id] = .checking
        Task {
            do {
                let result = try await installController.checkForUpdate(id: id)
                updateRowStates[id] = .outcome(ExtensionInstallLogic.updateOutcome(for: result))
                refresh()
            } catch {
                updateRowStates[id] = .failed(ExtensionInstallFailurePresentation.present(error))
            }
        }
    }

    // MARK: - Mutating actions

    // Union of both sources: the engine knows what's actually running (including an unpacked
    // folder never recorded); an entry only ExtensionStore knows about is installed but not running.
    private func refresh() {
        let recorded = env.extensionStore.installed()
        guard let engine = env.engine else {
            extensions = recorded.map { record -> LoadedExtension in
                var copy = record
                copy.isActivated = false
                return copy
            }
            return
        }
        let running = engine.loadedExtensions(session: engine.defaultSession)
        let runningIDs = Set(running.map(\.id))
        var merged = running.map { loaded -> LoadedExtension in
            guard let record = recorded.first(where: { $0.id == loaded.id }) else { return loaded }
            var copy = loaded
            copy.isEnabled = record.isEnabled
            return copy
        }
        for record in recorded where !runningIDs.contains(record.id) {
            var copy = record
            copy.isActivated = false
            merged.append(copy)
        }
        extensions = merged
    }

    private func load(directory: URL) async {
        guard let engine = env.engine else { return }
        do {
            _ = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // An extension loaded straight from a folder was never recorded, so it has
    // no store entry to remove — unload it from the running engine instead.
    private func remove(_ ext: LoadedExtension) {
        do {
            if env.extensionStore.installed().contains(where: { $0.id == ext.id }) {
                try env.extensionStore.remove(id: ext.id)
            } else if let engine = env.engine {
                engine.uninstallExtension(id: ext.id, session: engine.defaultSession)
            }
            actionError = nil
            expandedExtensionIDs.remove(ext.id)
            updateRowStates.removeValue(forKey: ext.id)
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, for ext: LoadedExtension) {
        do {
            try env.extensionStore.setEnabled(enabled, id: ext.id)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - No engine yet (pure — the only state behind capabilitiesSupportExtensions == false)

// Chromium always reports .extensions; this is reached only before start() has produced an engine, and is replaced by the real pane the moment env.engine exists.

struct ExtensionsEngineStartingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Chromium isn't running yet. Your extensions appear here as soon as it starts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Pending-changes / activation-error banner (pure — no ExtensionStore/ExtensionRuntime reads)

struct ExtensionPendingChangesBanner: View {
    var lastError: String?
    var onRestart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(lastError.map { "Chromium refused to load an extension: \($0)" }
                ?? "Some extensions are installed but not running yet.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            OrbitButton(title: "Restart Orbit", kind: .primary, isCompact: true, accentColor: SettingsPalette.accent, action: onRestart)
        }
    }
}

// MARK: - Installed list (pure — takes its extensions/state as plain values, never reads env.extensionStore or ExtensionRuntime.shared)

// DI seam the row states are tested through: a test can render any row combination without real installed extensions.
struct ExtensionsInstalledSectionView: View {
    var extensions: [LoadedExtension]
    var expandedExtensionIDs: Set<String>
    var updateRowStates: [String: ExtensionUpdateRowState]
    var isCheckingForUpdateDisabled: Bool
    var rowDetail: (LoadedExtension) -> ExtensionsSettingsPane.ExtensionRowDetail?
    var onSetEnabled: (Bool, LoadedExtension) -> Void
    var onRemove: (LoadedExtension) -> Void
    var onToggleExpanded: (String) -> Void
    var onOpenOptionsPage: (URL) -> Void
    var onOpenWebStoreListing: (String) -> Void
    var onCheckForUpdate: (String) -> Void

    var body: some View {
        if extensions.isEmpty {
            Text("No extensions installed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(extensions.enumerated()), id: \.element.id) { offset, ext in
                ExtensionRowView(
                    ext: ext,
                    isExpanded: expandedExtensionIDs.contains(ext.id),
                    detail: rowDetail(ext),
                    updateState: updateRowStates[ext.id],
                    isCheckingForUpdateDisabled: isCheckingForUpdateDisabled,
                    onSetEnabled: { onSetEnabled($0, ext) },
                    onRemove: { onRemove(ext) },
                    onToggleExpanded: { onToggleExpanded(ext.id) },
                    onOpenOptionsPage: onOpenOptionsPage,
                    onOpenWebStoreListing: { onOpenWebStoreListing(ext.id) },
                    onCheckForUpdate: { onCheckForUpdate(ext.id) }
                )
                if offset < extensions.count - 1 {
                    Divider()
                }
            }
        }
    }
}

// MARK: - One installed-extension row (pure — the extraction ExtensionConsentSheetView already models)

struct ExtensionRowView: View {
    var ext: LoadedExtension
    var isExpanded: Bool
    var detail: ExtensionsSettingsPane.ExtensionRowDetail?
    var updateState: ExtensionUpdateRowState?
    var isCheckingForUpdateDisabled: Bool
    var onSetEnabled: (Bool) -> Void
    var onRemove: () -> Void
    var onToggleExpanded: () -> Void
    var onOpenOptionsPage: (URL) -> Void
    var onOpenWebStoreListing: () -> Void
    var onCheckForUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                extensionIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ext.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(ext.manifestVersion >= 3 ? "MV3" : "MV2")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tertiary.opacity(0.3)))
                    }
                    Text("Version \(ext.version)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                OrbitToggle(
                    accessibilityLabel: "\(ext.name) enabled",
                    isOn: Binding(
                        get: { ext.isEnabled },
                        set: onSetEnabled
                    ),
                    accentColor: SettingsPalette.accent,
                    isCompact: true
                )

                OrbitButton(title: "Remove", kind: .destructive, isCompact: true, accentColor: SettingsPalette.accent, action: onRemove)
            }

            detailDisclosure
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var extensionIcon: some View {
        if let iconURL = ext.iconURL, let nsImage = NSImage(contentsOf: iconURL) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detailDisclosure: some View {
        OrbitButton(
            title: isExpanded ? "Hide Details" : "Show Details",
            systemImage: isExpanded ? "chevron.down" : "chevron.right",
            kind: .ghost,
            isCompact: true,
            action: onToggleExpanded
        )

        if isExpanded {
            expandedDetail
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ID: \(ext.id)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let detail {
                sourceRow(detail)

                if let optionsURL = detail.optionsURL {
                    OrbitButton(title: "Extension Options…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        onOpenOptionsPage(optionsURL)
                    }
                }

                if detail.requestsTabs {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("This extension asks to read your open tabs. Orbit's Chromium engine currently reports no open tabs to any extension, so tab-related features of this extension won't work.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !detail.warnings.isEmpty {
                    warningsDetail(detail.warnings)
                }
            } else {
                Text("This extension's manifest.json could not be read.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 38)
    }

    @ViewBuilder
    private func sourceRow(_ detail: ExtensionsSettingsPane.ExtensionRowDetail) -> some View {
        if detail.isPathDerived {
            Text("Loaded from a local, unpacked folder with no signing key, so its id is generated from that folder's path rather than assigned by the Chrome Web Store. There's no Web Store listing to link to and no update to check for.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("This extension's id matches how the Chrome Web Store identifies it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    OrbitButton(title: "View on Chrome Web Store…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent, action: onOpenWebStoreListing)
                    OrbitButton(title: "Check for Update", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent, action: onCheckForUpdate)
                        .disabled(isCheckingForUpdateDisabled)
                }
                if let updateState {
                    updateStateView(updateState)
                }
            }
        }
    }

    private func warningsDetail(_ warnings: [ExtensionPermissionWarning]) -> some View {
        let grouped = ExtensionInstallLogic.groupedWarnings(warnings)
        return VStack(alignment: .leading, spacing: 6) {
            if !grouped.granted.isEmpty {
                warningGroup(title: "Granted at install:", warnings: grouped.granted)
            }
            if !grouped.optional.isEmpty {
                warningGroup(title: "May be requested later:", warnings: grouped.optional)
            }
        }
    }

    private func warningGroup(title: String, warnings: [ExtensionPermissionWarning]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(severityColor(warning.severity))
                        .frame(width: 5, height: 5)
                        .padding(.top, 4)
                    Text(warning.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func severityColor(_ severity: ExtensionPermissionWarningSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .moderate: return .yellow
        case .low: return .secondary
        }
    }

    @ViewBuilder
    private func updateStateView(_ state: ExtensionUpdateRowState) -> some View {
        switch state {
        case .checking:
            Text("Checking for an update…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .outcome(let outcome):
            Text(Self.updateOutcomeText(outcome))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .failed(let presentation):
            ExtensionInstallFailureRow(presentation: presentation)
        }
    }

    static func updateOutcomeText(_ outcome: ExtensionUpdateOutcome) -> String {
        switch outcome {
        case .updated(let name, let newVersion, let previousVersion):
            return previousVersion.map { "Updated \(name) from \($0) to \(newVersion)." }
                ?? "Updated \(name) to \(newVersion)."
        case .alreadyCurrent(let version):
            return "Already up to date (version \(version))."
        case .declined:
            return "Update declined."
        }
    }
}

enum ExtensionUpdateRowState: Equatable {
    case checking
    case outcome(ExtensionUpdateOutcome)
    case failed(ExtensionInstallFailurePresentation)
}

extension AppEnvironment {
    var capabilitiesSupportExtensions: Bool {
        engine?.capabilities.contains(.extensions) ?? false
    }
}
