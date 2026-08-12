import AppKit
import SwiftUI

@MainActor
@Observable
final class DataSettingsModel {

    var selection: Set<DataResetCategory> = []
    private(set) var isRunning = false

    var canRemoveSelected: Bool { !selection.isEmpty && !isRunning }
    var canResetEverything: Bool { !isRunning }

    func isSelected(_ category: DataResetCategory) -> Bool { selection.contains(category) }

    func setSelected(_ category: DataResetCategory, _ isOn: Bool) {
        if isOn {
            selection.insert(category)
        } else {
            selection.remove(category)
        }
    }

    func removeSelected(on env: AppEnvironment) {
        let categories = selection
        guard !categories.isEmpty, !isRunning else { return }
        guard MenuPrompt.confirmDestructive(
            title: Self.selectionConfirmationTitle(categories),
            message: Self.selectionConfirmationMessage(categories),
            acceptTitle: "Remove Selected Data"
        ) else { return }
        isRunning = true
        Task { @MainActor in
            let outcome = await env.resetData(categories)
            isRunning = false
            selection.subtract(outcome.clearedCategories)
            Self.presentOutcome(outcome)
        }
    }

    func resetEverything(on env: AppEnvironment) {
        guard !isRunning else { return }
        guard MenuPrompt.confirmDestructive(
            title: Self.everythingConfirmationTitle,
            message: Self.everythingConfirmationMessage,
            acceptTitle: "Reset Orbit"
        ) else { return }
        isRunning = true
        Task { @MainActor in
            let outcome = await env.resetEverything()
            isRunning = false
            selection.removeAll()
            Self.presentOutcome(outcome)
        }
    }

    // MARK: - Wording

    static func orderedTitles(_ categories: Set<DataResetCategory>) -> [String] {
        DataResetCategory.allCases.filter { categories.contains($0) }.map(\.title)
    }

    static func sentenceList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func selectionConfirmationTitle(_ categories: Set<DataResetCategory>) -> String {
        categories.count == 1 ? "Remove this data?" : "Remove these \(categories.count) kinds of data?"
    }

    static func selectionConfirmationMessage(_ categories: Set<DataResetCategory>) -> String {
        var message = "This permanently removes \(sentenceList(orderedTitles(categories))). It cannot be undone."
        if categories.contains(where: \.requiresRelaunch) {
            message += " Orbit has to restart to finish."
        }
        return message
    }

    static let everythingConfirmationTitle = "Reset Orbit to a fresh install?"

    static var everythingConfirmationMessage: String {
        "This permanently removes everything Orbit has stored on this Mac — "
            + sentenceList(orderedTitles(Set(DataResetCategory.allCases)))
            + " — and leaves Orbit exactly as it was before you first opened it. "
            + "It cannot be undone, and Orbit has to restart to finish."
    }

    static func outcomeTitle(_ outcome: DataResetOutcome) -> String {
        if outcome.failedCategories.isEmpty {
            return outcome.clearedCategories.isEmpty ? "Nothing was removed" : "Data removed"
        }
        return outcome.clearedCategories.isEmpty ? "Nothing could be removed" : "Some data could not be removed"
    }

    static func outcomeMessage(_ outcome: DataResetOutcome) -> String {
        var parts: [String] = []
        if !outcome.clearedCategories.isEmpty {
            parts.append("Removed \(sentenceList(orderedTitles(outcome.clearedCategories))).")
        }
        if !outcome.failedCategories.isEmpty {
            parts.append("Could not remove \(sentenceList(orderedTitles(outcome.failedCategories))) — that data is still on this Mac.")
        }
        if parts.isEmpty {
            parts.append("Nothing matched what you selected, so nothing changed.")
        }
        return parts.joined(separator: " ")
    }

    static let relaunchTitle = "Restart Orbit now?"
    static let relaunchMessage = "Orbit has to restart before the data it has already loaded is gone from this session too."

    private static func presentOutcome(_ outcome: DataResetOutcome) {
        DataResetPrompt.report(title: outcomeTitle(outcome), message: outcomeMessage(outcome))
        guard outcome.needsRelaunch else { return }
        guard DataResetPrompt.confirmRelaunch(title: relaunchTitle, message: relaunchMessage) else { return }
        RelaunchController.relaunch()
    }
}

// runModal blocks until a button is pressed and an unattended run presses nothing, so both of these must settle themselves under XCTest.
enum DataResetPrompt {

    @MainActor
    static func report(title: String, message: String) {
        guard !DebugFlags.isRunningUnderTests else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    static func confirmRelaunch(title: String, message: String) -> Bool {
        guard !DebugFlags.isRunningUnderTests else { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Restart Orbit")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct DataSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = DataSettingsModel()
    @State private var importer = ImportFlowRunner.shared
    @State private var importableBrowsers: [ImportableBrowser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Data").font(.system(size: 20, weight: .bold))

            resetByCategorySection
            resetEverythingSection
            onboardingSection
            importSection
        }
        .onAppear { importableBrowsers = importer.availableBrowsers() }
    }

    private var resetByCategorySection: some View {
        OrbitSettingsSection(title: "Reset by category") {
            ForEach(DataResetCategory.allCases) { category in
                OrbitSettingsRow(title: category.title, description: category.detail) {
                    OrbitToggle(
                        accessibilityLabel: "Select \(category.title) for removal",
                        isOn: Binding(
                            get: { model.isSelected(category) },
                            set: { model.setSelected(category, $0) }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }
            }
            OrbitSettingsActionRow {
                Text(selectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                OrbitButton(title: "Remove Selected Data", kind: .destructive, isCompact: true, accentColor: SettingsPalette.accent) {
                    model.removeSelected(on: env)
                }
                .disabled(!model.canRemoveSelected)
            }
        }
    }

    private var selectionSummary: String {
        if model.isRunning { return "Removing data…" }
        guard !model.selection.isEmpty else { return "Pick what to remove. Nothing is removed until you confirm." }
        return "Removes \(DataSettingsModel.sentenceList(DataSettingsModel.orderedTitles(model.selection)))."
    }

    private var everythingSummary: String {
        if model.isRunning { return "Resetting Orbit…" }
        return "Removes every category above at once — "
            + DataSettingsModel.sentenceList(DataSettingsModel.orderedTitles(Set(DataResetCategory.allCases)))
            + " — and returns Orbit to a fresh install. It cannot be undone."
    }

    private var resetEverythingSection: some View {
        OrbitSettingsSection(title: "Reset everything") {
            OrbitSettingsActionRow {
                Text(everythingSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                OrbitButton(title: "Reset Orbit", kind: .destructive, isCompact: true, accentColor: SettingsPalette.accent) {
                    model.resetEverything(on: env)
                }
                .disabled(!model.canResetEverything)
            }
        }
    }

    private var onboardingSection: some View {
        OrbitSettingsSection(title: "Onboarding") {
            OrbitSettingsActionRow {
                Text("Reopens the welcome flow you saw the first time you launched Orbit. Nothing is removed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                OrbitButton(title: "Restart Onboarding", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    OnboardingWindowController.restart()
                }
            }
        }
    }

    private var importSection: some View {
        OrbitSettingsSection(title: "Import") {
            if importableBrowsers.isEmpty {
                OrbitSettingsActionRow {
                    Text("No other browser's data found on this Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(importableBrowsers) { browser in
                    OrbitSettingsActionRow {
                        Text(browser.displayName)
                            .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .medium))
                    } trailing: {
                        OrbitButton(title: "Import", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                            importer.run(browser, env: env)
                        }
                        .disabled(importer.isImporting)
                    }
                }
            }
        }
    }
}
