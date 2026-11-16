import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Guards around plaintext

/// Showing, copying and exporting a password need the person at the Mac, so each goes through the device owner's authentication
/// (Touch ID, Apple Watch or the login password). If it cannot be performed, the answer is no.
@MainActor
enum PasswordAuthentication {
    private static let deviceOwner: (String) async -> Bool = { reason in
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    #if DEBUG
    /// Replaced by tests so no prompt is ever shown.
    static var evaluate: (String) async -> Bool = deviceOwner
    #else
    static let evaluate: (String) async -> Bool = deviceOwner
    #endif
}

@MainActor
enum PasswordClipboard {
    // nonisolated so it can be a default argument.
    nonisolated static let clearDelay: TimeInterval = 30
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies the password, marked concealed so clipboard managers skip it, and clears it after `delay` seconds unless something else was copied since.
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general, clearAfter delay: TimeInterval = clearDelay) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealedType)
        let recorded = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard shouldClear(changeCount: pasteboard.changeCount, recorded: recorded, current: pasteboard.string(forType: .string), copied: value) else { return }
                pasteboard.clearContents()
            }
        }
    }

    /// Only a pasteboard still holding exactly what was copied is cleared; anything the person copied since is theirs.
    nonisolated static func shouldClear(changeCount: Int, recorded: Int, current: String?, copied: String) -> Bool {
        changeCount == recorded && current == copied
    }
}

/// Dialogs the pane raises. A modal waits for a person, so under a test run each answers "no" for itself.
enum PasswordsPrompt {

    @MainActor
    static func confirmExport() -> Bool {
        guard !DebugFlags.isRunningUnderTests else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export all saved passwords?"
        alert.informativeText = "The file will hold every saved password in plain text, readable by anyone who can open it. Delete it as soon as you have used it."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func confirmDeleteImportedFile(named name: String) -> Bool {
        guard !DebugFlags.isRunningUnderTests else { return false }
        let alert = NSAlert()
        alert.messageText = "Delete \(name)?"
        alert.informativeText = "The file you imported holds your passwords in plain text. Deleting it removes it for good; the passwords stay saved in Orbit."
        let delete = alert.addButton(withTitle: "Delete File")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let keep = alert.addButton(withTitle: "Keep File")
        keep.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Model

struct PasswordEditorDraft: Identifiable, Equatable {
    /// Identifies the sheet, not the login.
    let id = UUID()
    /// The login being edited; nil when adding.
    var loginID: UUID?
    var website = ""
    var username = ""
    /// For an edit, empty keeps the saved password. Changing the website as well needs the device owner's authentication first.
    var password = ""

    var isNew: Bool { loginID == nil }
}

@MainActor
@Observable
final class PasswordsSettingsModel {

    var query = ""
    private(set) var logins: [SavedLogin] = []
    private(set) var neverSaveSites: [String] = []
    private(set) var selectedID: UUID?
    /// The selected login's password, only after authentication and only until the selection changes.
    private(set) var revealedPassword: String?
    private(set) var statusMessage: String?

    let vault: any PasswordVault
    var authenticate: (String) async -> Bool = { await PasswordAuthentication.evaluate($0) }
    var confirmExport: () -> Bool = { PasswordsPrompt.confirmExport() }
    var confirmDelete: () -> Bool = {
        MenuPrompt.confirmDestructive(
            title: "Delete this saved password?",
            message: "Orbit will no longer fill it in. This cannot be undone.",
            acceptTitle: "Delete"
        )
    }

    init(vault: any PasswordVault = PasswordVaults.shared) {
        self.vault = vault
        reload()
    }

    var filtered: [SavedLogin] { PasswordAutofillPolicy.filter(logins, query: query) }

    var selected: SavedLogin? {
        guard let selectedID else { return nil }
        return logins.first { $0.id == selectedID }
    }

    func reload() {
        logins = vault.allLogins()
        neverSaveSites = vault.neverSaveSiteKeys().sorted()
        if let selectedID, !logins.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            revealedPassword = nil
        }
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        revealedPassword = nil
    }

    // MARK: Plaintext, behind authentication

    func revealPassword() async {
        guard let login = selected else { return }
        guard await authenticate("Show the saved password for \(Self.host(of: login))") else { return }
        // Read again: the entry may have changed while the prompt was up.
        guard selectedID == login.id, let current = vault.login(id: login.id) else { return }
        revealedPassword = current.password
    }

    func hidePassword() {
        revealedPassword = nil
    }

    func copyPassword() async {
        guard let login = selected else { return }
        guard await authenticate("Copy the saved password for \(Self.host(of: login))") else { return }
        guard let current = vault.login(id: login.id) else { return }
        PasswordClipboard.copy(current.password)
        statusMessage = "Password copied. It is cleared from the clipboard after \(Int(PasswordClipboard.clearDelay)) seconds."
    }

    /// The CSV of every saved login, or nil when the person did not authenticate or did not confirm the plaintext warning.
    func exportText() async -> String? {
        guard await authenticate("Export your saved passwords") else {
            statusMessage = "Export cancelled: Orbit could not confirm it is you."
            return nil
        }
        guard confirmExport() else { return nil }
        return PasswordCSV.export(vault.allLogins())
    }

    // MARK: Editing

    func newDraft() -> PasswordEditorDraft { PasswordEditorDraft() }

    /// A draft for the selected login. It never holds the saved password, and opening it needs no authentication; `save` asks for it when the website is changed.
    func draftForSelection() -> PasswordEditorDraft? {
        guard let login = selected else { return nil }
        var draft = PasswordEditorDraft()
        draft.loginID = login.id
        draft.website = login.origin
        draft.username = login.username
        return draft
    }

    /// An error message to show in the editor, or nil once saved.
    /// Pointing a saved login at another website would let the person reveal its password by filling it into a page they control, so changing
    /// the website needs the device owner's authentication, and fails closed. Only after that does a blank password keep the saved one.
    func save(_ draft: PasswordEditorDraft) async -> String? {
        guard let origin = PasswordAutofillPolicy.parseWebsite(draft.website) else {
            return "Enter a website such as example.com."
        }
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return "Enter a username." }
        if let loginID = draft.loginID, let saved = vault.login(id: loginID) {
            if saved.origin != origin.origin {
                guard await authenticate("Change the website of the saved password for \(Self.host(of: saved))") else {
                    return "The website was not changed: Orbit could not confirm it is you."
                }
            }
            // Read again: the entry may have changed while the prompt was up, and the approval was for changing this origin.
            guard var existing = vault.login(id: loginID), existing.origin == saved.origin else {
                return "That login changed while you were editing it. Close the editor and try again."
            }
            existing.origin = origin.origin
            existing.siteKey = origin.siteKey
            existing.username = username
            if !draft.password.isEmpty { existing.password = draft.password }
            existing.updatedAt = Date()
            guard vault.update(existing) else { return "That login could not be saved." }
            selectedID = existing.id
        } else {
            guard !draft.password.isEmpty else { return "Enter a password." }
            guard let url = URL(string: origin.origin),
                  let outcome = vault.save(origin: url, username: username, password: draft.password)
            else { return "That login could not be saved." }
            switch outcome {
            case .added(let login), .updated(let login), .unchanged(let login): selectedID = login.id
            }
        }
        revealedPassword = nil
        reload()
        return nil
    }

    func deleteSelected() {
        guard let login = selected, confirmDelete() else { return }
        vault.delete(id: login.id)
        selectedID = nil
        revealedPassword = nil
        reload()
    }

    func removeNeverSave(_ siteKey: String) {
        vault.setNeverSave(false, forSiteKey: siteKey)
        reload()
    }

    // MARK: Import

    static func summaryText(for summary: PasswordCSV.MergeSummary) -> String {
        let total = summary.added + summary.updated + summary.unchanged
        let noun = total == 1 ? "password" : "passwords"
        return "Imported \(total) \(noun): \(summary.added) added, \(summary.updated) updated, \(summary.unchanged) unchanged. \(summary.skipped) skipped."
    }

    /// Reads and merges one file; true when it was a password CSV.
    func importFile(at url: URL) -> Bool {
        do {
            let parsed = try PasswordCSV.parse(data: try Data(contentsOf: url))
            statusMessage = Self.summaryText(for: PasswordCSV.merge(parsed, into: vault))
            reload()
            return true
        } catch let error as PasswordCSV.ImportError {
            switch error {
            case .empty: statusMessage = "That file is empty."
            case .notText: statusMessage = "That file is not a text file, so it cannot be a password CSV."
            case .unrecognizedFormat: statusMessage = "That file has no website and password columns, so Orbit cannot import it."
            }
            return false
        } catch {
            statusMessage = "That file could not be read."
            return false
        }
    }

    func runImport() async {
        guard let url = await Self.pickFileToImport() else { return }
        guard importFile(at: url) else { return }
        // The file holds every password in plain text; leaving it behind is the person's call, but they are asked.
        guard PasswordsPrompt.confirmDeleteImportedFile(named: url.lastPathComponent) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            statusMessage = (statusMessage ?? "") + " The file was deleted."
        } catch {
            statusMessage = (statusMessage ?? "") + " The file could not be deleted."
        }
    }

    func runExport() async {
        guard let text = await exportText() else { return }
        guard let url = await Self.pickFileToExport() else { return }
        do {
            try PasswordExportFile.write(Data(text.utf8), to: url)
            statusMessage = "Exported to \(url.lastPathComponent). The file holds every password in plain text; delete it when you are done."
        } catch {
            statusMessage = "The passwords could not be written to that file: \(error.localizedDescription)"
        }
    }

    static func host(of login: SavedLogin) -> String {
        PasswordAutofillPolicy.displayHost(ofOrigin: login.origin)
    }

    private static func pickFileToImport() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText, .plainText]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a CSV file of passwords to import."
            panel.prompt = "Import"
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func pickFileToExport() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Orbit Passwords.csv"
            panel.message = "This file will hold your passwords in plain text."
            panel.prompt = "Export"
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

// MARK: - Pane

struct PasswordsSettingsPane: View {
    @State private var model = PasswordsSettingsModel()
    @State private var offersToSave = PasswordSettings.offersToSave
    @State private var offersToAutofill = PasswordSettings.offersToAutofill
    @State private var draft: PasswordEditorDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Passwords").font(.system(size: 20, weight: .bold))

            paragraph("Orbit keeps the passwords you save in the macOS Keychain and fills them into sign-in forms.")

            switchesSection
            savedSection
            if let login = model.selected {
                detailSection(login)
            }
            neverSavedSection
            importExportSection

            if let message = model.statusMessage {
                paragraph(message)
            }
        }
        .onAppear {
            offersToSave = PasswordSettings.offersToSave
            offersToAutofill = PasswordSettings.offersToAutofill
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitPasswordVaultDidChange)) { _ in
            model.reload()
        }
        .sheet(item: $draft) { current in
            PasswordEditorSheet(initial: current, save: { await model.save($0) })
        }
    }

    private var switchesSection: some View {
        OrbitSettingsSection(title: nil) {
            OrbitSettingsRow(title: "Offer to save passwords", description: "Asks after you sign in to a site. Never in a private window.") {
                OrbitToggle(
                    accessibilityLabel: "Offer to save passwords",
                    isOn: Binding(
                        get: { offersToSave },
                        set: { newValue in
                            offersToSave = newValue
                            PasswordSettings.offersToSave = newValue
                        }
                    ),
                    accentColor: SettingsPalette.accent
                )
            }
            OrbitSettingsRow(title: "Offer to AutoFill passwords", description: "Lists saved logins under a sign-in field and in its right-click menu.") {
                OrbitToggle(
                    accessibilityLabel: "Offer to AutoFill passwords",
                    isOn: Binding(
                        get: { offersToAutofill },
                        set: { newValue in
                            offersToAutofill = newValue
                            PasswordSettings.offersToAutofill = newValue
                        }
                    ),
                    accentColor: SettingsPalette.accent
                )
            }
        }
    }

    private var savedSection: some View {
        OrbitSettingsSection(title: "Saved passwords") {
            OrbitTextField(
                placeholder: "Search",
                text: Binding(get: { model.query }, set: { model.query = $0 }),
                systemImage: "magnifyingglass",
                accentColor: SettingsPalette.accent,
                accessibilityLabel: "Search saved passwords"
            )

            let rows = model.filtered
            if rows.isEmpty {
                Text(model.logins.isEmpty ? "No saved passwords yet." : "No saved password matches your search.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { login in
                            PasswordListRow(login: login, isSelected: login.id == model.selectedID) {
                                model.select(login.id)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 40 + 4, 200))
            }

            OrbitSettingsActionRow {
                Text("\(model.logins.count) saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } trailing: {
                OrbitButton(title: "Add Password…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    draft = model.newDraft()
                }
            }
        }
    }

    private func detailSection(_ login: SavedLogin) -> some View {
        OrbitSettingsSection(title: "Details") {
            OrbitSettingsValueRow(title: "Website") {
                Text(login.origin).font(.system(size: 12)).textSelection(.enabled)
            }
            OrbitSettingsValueRow(title: "Username") {
                Text(login.username).font(.system(size: 12)).textSelection(.enabled)
            }
            OrbitSettingsActionRow {
                Text("Password")
                    .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                    .foregroundStyle(.secondary)
                Text(model.revealedPassword ?? String(repeating: "\u{2022}", count: 10))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            } trailing: {
                HStack(spacing: 6) {
                    if model.revealedPassword == nil {
                        OrbitButton(title: "Show", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                            Task { await model.revealPassword() }
                        }
                    } else {
                        OrbitButton(title: "Hide", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                            model.hidePassword()
                        }
                    }
                    OrbitButton(title: "Copy", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        Task { await model.copyPassword() }
                    }
                }
            }
            OrbitSettingsActionRow {
                Text("Showing or copying a password asks you to authenticate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } trailing: {
                HStack(spacing: 6) {
                    OrbitButton(title: "Edit…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        draft = model.draftForSelection()
                    }
                    OrbitButton(title: "Delete", kind: .destructive, isCompact: true, accentColor: SettingsPalette.accent) {
                        model.deleteSelected()
                    }
                }
            }
        }
    }

    private var neverSavedSection: some View {
        OrbitSettingsSection(title: "Never saved") {
            if model.neverSaveSites.isEmpty {
                Text("Sites where you chose Never for This Site appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.neverSaveSites, id: \.self) { site in
                    OrbitSettingsActionRow {
                        Text(site).font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .medium))
                    } trailing: {
                        OrbitButton(title: "Remove", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                            model.removeNeverSave(site)
                        }
                    }
                }
            }
        }
    }

    private var importExportSection: some View {
        OrbitSettingsSection(title: "Import and export") {
            OrbitSettingsActionRow {
                Text("Bring passwords from a CSV file exported by another browser or password manager.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                OrbitButton(title: "Import Passwords…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    Task { await model.runImport() }
                }
            }
            OrbitSettingsActionRow {
                Text("Exporting writes every password to a file in plain text, after you authenticate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                OrbitButton(title: "Export Passwords…", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    Task { await model.runExport() }
                }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize + 1))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PasswordListRow: View {
    var login: SavedLogin
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(PasswordAutofillPolicy.displayHost(ofOrigin: login.origin))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.textPrimary)
                        .lineLimit(1)
                    Text(login.username)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? SettingsPalette.selectedFill : (isHovering ? SettingsPalette.hoverFill : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(PasswordAutofillPolicy.displayHost(ofOrigin: login.origin)), \(login.username)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PasswordEditorSheet: View {
    var initial: PasswordEditorDraft
    /// Returns an error message, or nil once the login is saved. Asynchronous because changing a login's website asks the person to authenticate.
    var save: @MainActor (PasswordEditorDraft) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PasswordEditorDraft
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(initial: PasswordEditorDraft, save: @escaping @MainActor (PasswordEditorDraft) async -> String?) {
        self.initial = initial
        self.save = save
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(initial.isNew ? "Add Password" : "Edit Password")
                .font(.system(size: 16, weight: .semibold))

            field("Website") {
                OrbitTextField(
                    placeholder: "example.com",
                    text: $draft.website,
                    accentColor: SettingsPalette.accent,
                    accessibilityLabel: "Website"
                )
            }
            field("Username") {
                OrbitTextField(
                    placeholder: "Username or email",
                    text: $draft.username,
                    accentColor: SettingsPalette.accent,
                    accessibilityLabel: "Username"
                )
            }
            field("Password") {
                OrbitSecureField(
                    placeholder: initial.isNew ? "Password" : "Leave blank to keep the saved password",
                    text: $draft.password,
                    accentColor: SettingsPalette.accent,
                    accessibilityLabel: "Password"
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OrbitButton(title: "Cancel", kind: .secondary, accentColor: SettingsPalette.accent) { dismiss() }
                OrbitButton(title: "Save", kind: .primary, accentColor: SettingsPalette.accent) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        let message = await save(draft)
                        isSaving = false
                        if let message {
                            errorMessage = message
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
