//  Profile UI lives only in this pane, never on a Space surface — guarded by a test.

import SwiftUI

struct ProfilesSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedProfileID: ProfileID?
    @State private var showNewProfileSheet = false
    @State private var renamingProfileID: ProfileID?
    @State private var draftName = ""
    @FocusState private var renameFieldFocused: Bool

    private var listedProfiles: [Profile] {
        env.state.profiles.filter(\.isPersistent)
    }

    private var selectedProfile: Profile? {
        (selectedProfileID.flatMap { id in listedProfiles.first { $0.id == id } }) ?? listedProfiles.first
    }

    // MARK: - Two-column layout arithmetic

    private static let profileListWidth: CGFloat = 160
    private static let columnSpacing: CGFloat = 24
    private static let paneInteriorWidth: CGFloat =
        SettingsMetrics.contentMaxWidth - SettingsMetrics.contentHorizontalPadding * 2
    private static let detailColumnWidth: CGFloat =
        paneInteriorWidth - profileListWidth - columnSpacing
    static let cardInteriorWidth: CGFloat =
        detailColumnWidth - OrbitControlMetrics.sectionPadding * 2

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            HStack {
                Text("Profiles").font(.system(size: 20, weight: .bold))
                Spacer()
                OrbitButton(title: "New Profile…", kind: .primary, accentColor: SettingsPalette.accent) { showNewProfileSheet = true }
            }

            Text("Profiles help keep your data separate across Spaces – like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces.")
                .font(.system(size: 11.5))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 24) {
                profileList
                Group {
                    if let profile = selectedProfile {
                        profileDetail(profile)
                    } else {
                        Text("No Profiles yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileSheet(onCreate: { selectedProfileID = $0 })
        }
    }

    // MARK: - Left: "Your Profiles" list

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Profiles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))

            VStack(spacing: 0) {
                ForEach(listedProfiles) { profile in
                    profileRow(profile)
                    if profile.id != listedProfiles.last?.id {
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous).fill(OrbitControlColor.fill(for: colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous).strokeBorder(OrbitControlColor.border(for: colorScheme)))
        }
        .frame(width: Self.profileListWidth)
    }

    private func profileRow(_ profile: Profile) -> some View {
        let isSelected = profile.id == selectedProfile?.id
        let spaceCount = env.spaces.filter { $0.profileID == profile.id }.count

        return HStack(spacing: 8) {
            if renamingProfileID == profile.id {
                // externalFocus, not .focused() on the container: FocusState does not propagate through it.
                OrbitTextField(
                    placeholder: "Profile name",
                    text: $draftName,
                    accentColor: SettingsPalette.accent,
                    accessibilityLabel: "Profile name",
                    externalFocus: $renameFieldFocused
                )
                .onSubmit { commitRename(profile.id) }
                .onExitCommand { renamingProfileID = nil }
            } else {
                Text(profile.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRename(profile) }
            }
            Spacer()
            Text("\(spaceCount) Space\(spaceCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: OrbitControlMetrics.textFieldHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? SettingsPalette.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedProfileID = profile.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(spaceCount) Space\(spaceCount == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Right: selected Profile's own settings

    private func profileDetail(_ profile: Profile) -> some View {
        let spacesForProfile = env.spaces.filter { $0.profileID == profile.id }

        return VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            OrbitSettingsSection(title: nil) {
                OrbitSettingsRow(title: "Search engine") {
                    OrbitPopupButton(
                        options: SearchEngine.allCases,
                        label: { $0.displayName },
                        selection: Binding(
                            get: { profile.searchEngine },
                            set: { newEngine in updateProfile(profile.id) { $0.searchEngine = newEngine } }
                        ),
                        accessibilityLabel: "Search engine",
                        accentColor: Color(profile.tint.nsColor)
                    )
                }

                OrbitSettingsRow(
                    title: "Include search engine suggestions",
                    description: "Sends what you type to \(profile.searchEngine.displayName) to fetch completions."
                ) {
                    OrbitToggle(
                        accessibilityLabel: "Include search engine suggestions",
                        isOn: Binding(
                            get: { profile.includesSearchSuggestions },
                            set: { newValue in
                                updateProfile(profile.id) { $0.includesSearchSuggestions = newValue }
                                // Same setting chrome.privacy.services.searchSuggestEnabled
                                // reads and writes -- keep the engine's user value in step.
                                env.pushSearchSuggestPreferenceToEngine()
                            }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }
                .frame(width: Self.cardInteriorWidth, alignment: .leading)
            }

            OrbitSettingsSection(title: nil) {
                OrbitSettingsRow(
                    title: "Archive tabs after",
                    description: "Applies to every Space on this Profile. The tab you are looking at, tabs in a Split View, and tabs playing media are never archived."
                ) {
                    archivePolicyPicker(profile)
                }
                .frame(width: Self.cardInteriorWidth, alignment: .leading)

                OrbitSettingsValueRow(title: "Storage location") {
                    Text(profile.sessionIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                }

                if !spacesForProfile.isEmpty {
                    spacesUsingProfile(spacesForProfile)
                }

                if !spacesNotOnThisProfile(profile).isEmpty {
                    addSpaceRow(profile)
                }
            }

            OrbitSettingsActionRow {
                Text(spacesForProfile.isEmpty
                     ? "Profile is not assigned to any Spaces."
                     : "Remove this Profile from every Space before deleting it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } trailing: {
                OrbitButton(title: "Delete Profile", kind: .destructive, isCompact: true, accentColor: SettingsPalette.accent) {
                    deleteProfile(profile)
                }
                .disabled(!spacesForProfile.isEmpty || listedProfiles.count <= 1)
            }
        }
    }

    private func spacesUsingProfile(_ spaces: [Space]) -> some View {
        HStack(spacing: 6) {
            Text("Spaces:").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(spaces) { space in
                Text(space.name)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.tertiary.opacity(0.3)))
            }
        }
    }

    private func spacesNotOnThisProfile(_ profile: Profile) -> [Space] {
        env.spaces.filter { $0.profileID != profile.id }
    }

    private func addSpaceRow(_ profile: Profile) -> some View {
        let candidates = spacesNotOnThisProfile(profile)

        return OrbitSettingsRow(
            title: "Add a Space",
            description: "Moves the Space onto this Profile. Its cookies, logins, history and extensions become this Profile's, effective immediately."
        ) {
            OrbitPopupButton(
                options: candidates.map { Optional($0.id) },
                label: { spaceID in
                    spaceID.flatMap { id in env.space(id)?.name } ?? "Choose a Space…"
                },
                selection: Binding<SpaceID?>(
                    get: { nil },
                    set: { newValue in
                        guard let spaceID = newValue else { return }
                        env.store.setProfile(profile.id, forSpace: spaceID)
                    }
                ),
                accessibilityLabel: "Add a Space to \(profile.name)",
                accentColor: Color(profile.tint.nsColor)
            )
        }
        .frame(width: Self.cardInteriorWidth, alignment: .leading)
    }

    private func archivePolicyPicker(_ profile: Profile) -> some View {
        OrbitPopupButton(
            options: ArchivePolicy.allCases,
            label: { $0.menuTitle },
            selection: Binding(
                get: { profile.archivePolicy },
                set: { newPolicy in env.store.setArchivePolicy(newPolicy, forProfile: profile.id) }
            ),
            accessibilityLabel: "Archive tabs after",
            accentColor: Color(profile.tint.nsColor)
        )
    }

    private func updateProfile(_ id: ProfileID, _ transform: (inout Profile) -> Void) {
        guard let index = env.state.profiles.firstIndex(where: { $0.id == id }) else { return }
        transform(&env.state.profiles[index])
    }

    // MARK: - Rename / delete

    private func beginRename(_ profile: Profile) {
        draftName = profile.name
        renamingProfileID = profile.id
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename(_ id: ProfileID) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { env.store.renameProfile(id, to: trimmed) }
        renamingProfileID = nil
    }

    private func deleteProfile(_ profile: Profile) {
        guard env.store.deleteProfile(profile.id) else { return }
        if selectedProfileID == profile.id {
            selectedProfileID = listedProfiles.first(where: { $0.id != profile.id })?.id
        }
    }
}

private struct NewProfileSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var onCreate: (ProfileID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Profile").font(.system(size: 15, weight: .semibold))
            OrbitTextField(placeholder: "Name", text: $name, accentColor: SettingsPalette.accent)
            Text("New Profiles start empty — no logins, cookies or history — and fill in as you browse.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                OrbitButton(title: "Cancel", kind: .secondary, accentColor: SettingsPalette.accent) { dismiss() }
                OrbitButton(title: "Create", kind: .primary, accentColor: SettingsPalette.accent, keyboardShortcut: .defaultAction) {
                    let id = env.store.createProfile(name: name.isEmpty ? "New Profile" : name)
                    onCreate(id)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
