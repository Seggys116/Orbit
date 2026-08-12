import SwiftUI

struct ShortcutsSettingsPane: View {
    @State private var registry = ShortcutRegistry.shared
    @State private var searchText = ""
    @State private var selectedCategory: ShortcutCategory?
    @State private var recordingCommandID: ShortcutCommandID?
    @State private var recordingConflictNotice: String?

    private enum Group: String {
        case customized = "Customized Shortcuts"
        case defaults = "Default Shortcuts"
    }

    private static let categoryOptions: [ShortcutCategory?] = [nil] + ShortcutCategory.allCases

    private func isCustomized(_ command: ShortcutCommand) -> Bool {
        registry.binding(for: command.id) != command.defaultBinding
    }

    private func matchesSearch(_ command: ShortcutCommand) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        if command.title.lowercased().contains(query) { return true }
        if let binding = registry.binding(for: command.id), binding.displayString.lowercased().contains(query) { return true }
        return false
    }

    private func matchesFilters(_ command: ShortcutCommand) -> Bool {
        if let selectedCategory, command.category != selectedCategory { return false }
        return matchesSearch(command)
    }

    private var groupedCommands: [(Group, [ShortcutCommand])] {
        let matching = registry.commands.filter(matchesFilters)
        return [Group.customized, Group.defaults].compactMap { group in
            let commands = matching
                .filter { isCustomized($0) == (group == .customized) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    private var commandsByID: [ShortcutCommandID: ShortcutCommand] {
        Dictionary(uniqueKeysWithValues: registry.commands.map { ($0.id, $0) })
    }

    // Precomputed once per render; querying conflicts(for:) per row reintroduces an O(n²) hot path per keystroke.
    private var conflictingCommandsByID: [ShortcutCommandID: [ShortcutCommand]] {
        let groups = registry.conflictGroups()
        let byID = commandsByID
        var result: [ShortcutCommandID: [ShortcutCommand]] = [:]
        for ids in groups.values {
            let commandsInGroup = ids.compactMap { byID[$0] }
            for id in ids {
                result[id] = commandsInGroup.filter { $0.id != id }
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            HStack {
                Text("Keybinds").font(.system(size: 20, weight: .bold))
                Spacer()
                OrbitButton(title: "Reset All to Defaults", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    registry.resetToDefaults()
                    recordingCommandID = nil
                    recordingConflictNotice = nil
                }
            }

            HStack(spacing: 8) {
                OrbitTextField(
                    placeholder: "Type a feature name or shortcut (like \"Command E\")",
                    text: $searchText,
                    systemImage: "magnifyingglass",
                    accentColor: SettingsPalette.accent
                )
                .frame(maxWidth: .infinity)

                OrbitPopupButton(
                    options: Self.categoryOptions,
                    label: { $0?.rawValue ?? "All Categories" },
                    selection: $selectedCategory,
                    accessibilityLabel: "Filter by category",
                    accentColor: SettingsPalette.accent
                )
            }

            if let recordingConflictNotice {
                conflictBanner(recordingConflictNotice)
            }

            let conflictsByID = conflictingCommandsByID

            ForEach(groupedCommands, id: \.0) { group, commands in
                VStack(alignment: .leading, spacing: 8) {
                    OrbitSectionHeader(title: group.rawValue)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(commands) { command in
                            KeybindRow(
                                command: command,
                                recordingCommandID: $recordingCommandID,
                                recordingConflictNotice: $recordingConflictNotice,
                                accentColor: SettingsPalette.accent,
                                conflictingCommands: conflictsByID[command.id] ?? []
                            )
                        }
                    }
                }
            }

            if let emptyStateMessage {
                Text(emptyStateMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.textSecondary)
                    .padding(.top, 4)
            }
        }
    }

    private var emptyStateMessage: String? {
        guard groupedCommands.isEmpty else { return nil }
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedQuery.isEmpty, selectedCategory) {
        case (true, nil):
            return nil
        case (true, let category?):
            return "No shortcuts in \(category.rawValue)."
        case (false, nil):
            return "No shortcuts match \u{201c}\(trimmedQuery)\u{201d}."
        case (false, let category?):
            return "No shortcuts in \(category.rawValue) match \u{201c}\(trimmedQuery)\u{201d}."
        }
    }

    private func conflictBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LibraryPalette.destructive)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SettingsPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            OrbitButton(title: "Dismiss", systemImage: "xmark", kind: .ghost, isIconOnly: true, accentColor: SettingsPalette.accent) {
                recordingConflictNotice = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous)
                .fill(LibraryPalette.destructive.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.sectionCornerRadius, style: .continuous)
                .strokeBorder(LibraryPalette.destructive.opacity(0.4))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct KeybindRow: View {
    var command: ShortcutCommand
    @Binding var recordingCommandID: ShortcutCommandID?
    @Binding var recordingConflictNotice: String?
    var accentColor: Color
    var conflictingCommands: [ShortcutCommand]

    @State private var registry = ShortcutRegistry.shared
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    #if DEBUG
    // ImageRenderer cannot flatten an NSViewRepresentable; without this gate the row rasterises as a solid block.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeRepresentableDisabled
    #endif

    private var isRecording: Bool { recordingCommandID == command.id }
    private var binding: KeyBinding? { registry.binding(for: command.id) }
    private var isCustomized: Bool { registry.binding(for: command.id) != command.defaultBinding }

    private static let rowHorizontalPadding: CGFloat = 10
    private static let rowCornerRadius: CGFloat = LibraryMetrics.rowCornerRadius

    var body: some View {
        let hasConflict = !conflictingCommands.isEmpty
        let conflictNote: String? = hasConflict
            ? "Also used by \(conflictingCommands.map(\.title).joined(separator: ", "))"
            : nil

        return HStack(spacing: OrbitControlMetrics.settingsRowContentSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                    .foregroundStyle(SettingsPalette.textPrimary)
                if let conflictNote {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(conflictNote)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(LibraryPalette.destructive)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: OrbitControlMetrics.settingsRowContentSpacing)
            keyCell(hasConflict: hasConflict)
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, OrbitControlMetrics.settingsRowVerticalPadding)
        .frame(minHeight: OrbitControlMetrics.settingsRowMinHeight)
        .background(cardFill(hasConflict: hasConflict))
        .overlay(cardBorder(hasConflict: hasConflict))
        .contentShape(RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(OrbitMotion.quick, value: isHovering)
        .onTapGesture {
            recordingCommandID = command.id
            recordingConflictNotice = nil
        }
        .background(recorder())
        .contextMenu {
            Button("Remove Shortcut") {
                registry.setBinding(nil, for: command.id)
                recordingCommandID = nil
                recordingConflictNotice = nil
            }
            .disabled(binding == nil)
            Button("Reset Shortcut to Default") {
                registry.setBinding(command.defaultBinding, for: command.id)
                recordingCommandID = nil
                recordingConflictNotice = nil
            }
            .disabled(!isCustomized)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityValue(accessibilityValue(conflictNote: conflictNote))
    }

    private func accessibilityValue(conflictNote: String?) -> String {
        let base = binding?.displayString ?? "No shortcut"
        guard let conflictNote else { return base }
        return "\(base). \(conflictNote)."
    }

    private func cardFill(hasConflict: Bool) -> some View {
        RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
            .fill(
                isRecording ? accentColor.opacity(0.16)
                    : hasConflict ? LibraryPalette.destructive.opacity(0.08)
                    : (isHovering ? LibraryPalette.cardFillHover : LibraryPalette.cardFill)
            )
    }

    private func cardBorder(hasConflict: Bool) -> some View {
        RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
            .strokeBorder(
                isRecording ? accentColor
                    : hasConflict ? LibraryPalette.destructive.opacity(0.55)
                    : LibraryPalette.cardBorder,
                lineWidth: isRecording ? OrbitControlMetrics.textFieldFocusRingWidth : 1
            )
    }

    @ViewBuilder
    private func recorder() -> some View {
        let capture = ShortcutRecorderCapture(isActive: isRecording) { newBinding in
            guard let newBinding else {
                recordingCommandID = nil
                return
            }
            registry.setBinding(newBinding, for: command.id)
            let collisions = registry.conflicts(for: command.id).compactMap(registry.command(for:))
            if collisions.isEmpty {
                recordingConflictNotice = nil
            } else {
                let names = collisions.map(\.title).joined(separator: ", ")
                recordingConflictNotice = "\(newBinding.displayString) is also used by \(names) — both will resolve to whichever is listed first until one is changed."
            }
            recordingCommandID = nil
        }
        #if DEBUG
        if !screenshotModeRepresentableDisabled { capture }
        #else
        capture
        #endif
    }

    private func keyCell(hasConflict: Bool) -> some View {
        Text(binding?.displayString ?? "- - -")
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(SettingsPalette.textPrimary)
            .padding(.horizontal, 10)
            .frame(minWidth: 62, minHeight: OrbitControlMetrics.buttonCompactHeight)
            .background(
                RoundedRectangle(cornerRadius: OrbitControlMetrics.segmentedCornerRadius, style: .continuous)
                    .fill(hasConflict && !isRecording ? LibraryPalette.destructive.opacity(0.12) : OrbitControlColor.fill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitControlMetrics.segmentedCornerRadius, style: .continuous)
                    .strokeBorder(
                        isRecording ? accentColor : (hasConflict ? LibraryPalette.destructive : OrbitControlColor.border(for: colorScheme)),
                        lineWidth: isRecording ? OrbitControlMetrics.textFieldFocusRingWidth : 1
                    )
            )
    }
}

struct ShortcutRecorderCapture: NSViewRepresentable {
    var isActive: Bool
    var onCapture: (KeyBinding?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        if isActive, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((KeyBinding?) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // escape cancels
                onCapture?(nil)
                return
            }
            // Must use KeyBinding(recording:), not charactersIgnoringModifiers directly.
            guard let binding = KeyBinding(recording: event) else { return }
            onCapture?(binding)
        }
    }
}
