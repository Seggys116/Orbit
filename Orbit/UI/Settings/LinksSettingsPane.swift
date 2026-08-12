import SwiftUI

struct LinksSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showAirTrafficControl = false

    @State private var opensOnModifierClick = LittleOrbitSettings.opensOnModifierClick
    @State private var archiveInterval = LittleOrbitSettings.archiveInterval
    @State private var shiftClickPeekEnabled = PeekSettings.isShiftClickPeekEnabled
    @State private var automaticPeekEnabled = PeekSettings.isAutomaticPeekEnabled
    @State private var linksFromOtherAppsOpenInLittleOrbit = LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Links").font(.system(size: 20, weight: .bold))

            paragraph("Little Orbit is a smaller, simpler Orbit window. It's perfect for quick lookups and reading funny tweets your friends send you.")

            OrbitSettingsSection(title: nil) {
                littleOrbitHotkeyRow

                OrbitSettingsRow(title: "Open Little Orbit when clicking on links with ⌥⌘ held") {
                    OrbitToggle(
                        accessibilityLabel: "Open Little Orbit when clicking on links with Option Command held",
                        isOn: Binding(
                            get: { opensOnModifierClick },
                            set: { newValue in
                                opensOnModifierClick = newValue
                                LinksSettingsActions.setOpensOnModifierClick(newValue)
                            }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }

                OrbitSettingsRow(
                    title: "Links from other apps open in Little Orbit",
                    description: "Sets Air Traffic Control's Default destination, used when no route matches."
                ) {
                    OrbitToggle(
                        accessibilityLabel: "Links from other apps open in Little Orbit",
                        isOn: Binding(
                            get: { linksFromOtherAppsOpenInLittleOrbit },
                            set: { newValue in
                                linksFromOtherAppsOpenInLittleOrbit = newValue
                                LinksSettingsActions.setLinksFromOtherAppsOpenInLittleOrbit(newValue)
                            }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }

                OrbitSettingsRow(title: "Archive Little Orbits after:") {
                    OrbitPopupButton(
                        options: LittleOrbitSettings.ArchiveInterval.allCases,
                        label: { $0.label },
                        selection: Binding(
                            get: { archiveInterval },
                            set: { newValue in
                                archiveInterval = newValue
                                LinksSettingsActions.setArchiveInterval(newValue)
                            }
                        ),
                        accessibilityLabel: "Archive Little Orbits after",
                        accentColor: SettingsPalette.accent
                    )
                }
            }

            paragraph("Peek is a way to preview a link without opening a new tab. It's perfect for quickly looking at a link from an email, news article, or tweet.")

            OrbitSettingsSection(title: nil) {
                OrbitSettingsRow(title: "Open a Peek window when clicking on links with Shift held") {
                    OrbitToggle(
                        accessibilityLabel: "Open a Peek window when clicking on links with Shift held",
                        isOn: Binding(
                            get: { shiftClickPeekEnabled },
                            set: { newValue in
                                shiftClickPeekEnabled = newValue
                                LinksSettingsActions.setShiftClickPeek(newValue)
                            }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }

                OrbitSettingsRow(
                    title: "Open a Peek window when clicking on links to other sites",
                    description: "Note: This only affects Favorites and Pinned tabs"
                ) {
                    OrbitToggle(
                        accessibilityLabel: "Open a Peek window when clicking on links to other sites",
                        isOn: Binding(
                            get: { automaticPeekEnabled },
                            set: { newValue in
                                automaticPeekEnabled = newValue
                                LinksSettingsActions.setAutomaticPeek(newValue)
                            }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                }
            }

            OrbitSettingsSection(title: nil) {
                OrbitSettingsActionRow {
                    Text("Choose where links open inside Orbit.")
                        .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize, weight: .medium))
                } trailing: {
                    OrbitButton(title: "Air Traffic Control…", kind: .secondary, accentColor: SettingsPalette.accent) {
                        showAirTrafficControl = true
                    }
                }
            }
        }
        .onAppear {
            opensOnModifierClick = LittleOrbitSettings.opensOnModifierClick
            archiveInterval = LittleOrbitSettings.archiveInterval
            shiftClickPeekEnabled = PeekSettings.isShiftClickPeekEnabled
            automaticPeekEnabled = PeekSettings.isAutomaticPeekEnabled
            linksFromOtherAppsOpenInLittleOrbit = LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit
        }
        .sheet(isPresented: $showAirTrafficControl) {
            AirTrafficControlSheet(
                onDefaultDestinationChanged: {
                    linksFromOtherAppsOpenInLittleOrbit = LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit
                }
            )
            .environment(env)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize + 1))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var littleOrbitHotkeyRow: some View {
        let binding = ShortcutRegistry.shared.binding(for: .newLittleOrbit)
        let keys = binding?.displayString ?? "no key"
        return OrbitSettingsRow(
            title: "Open Little Orbit when I press \(keys)",
            description: "Works while Orbit is frontmost. Orbit does not install a system-wide hotkey."
        ) {
            OrbitButton(title: binding == nil ? "Set in Keybinds…" : "Change in Keybinds…", kind: .secondary, accentColor: SettingsPalette.accent) {
                SettingsRouter.shared.selectedPane = .shortcuts
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - The write paths behind the pane's switches

enum LinksSettingsActions {

    static func setAutomaticPeek(_ enabled: Bool) {
        PeekSettings.isAutomaticPeekEnabled = enabled
    }

    static func setShiftClickPeek(_ enabled: Bool) {
        PeekSettings.isShiftClickPeekEnabled = enabled
    }

    static func setOpensOnModifierClick(_ enabled: Bool) {
        LittleOrbitSettings.opensOnModifierClick = enabled
    }

    static func setArchiveInterval(_ interval: LittleOrbitSettings.ArchiveInterval) {
        LittleOrbitSettings.archiveInterval = interval
    }

    static var linksFromOtherAppsOpenInLittleOrbit: Bool {
        RoutingDefaults.destination == .littleOrbit
    }

    static func setLinksFromOtherAppsOpenInLittleOrbit(_ enabled: Bool) {
        if enabled {
            RoutingDefaults.destination = .littleOrbit
        } else if RoutingDefaults.destination == .littleOrbit {
            RoutingDefaults.destination = .mostRecentSpace
        }
    }
}

// MARK: - Air Traffic Control

enum RouteMatchType: String, CaseIterable, Identifiable, Sendable {
    case contains = "Contains"
    case isEqualTo = "Is equal to"

    var id: String { rawValue }
}

struct AirTrafficControlEditor {
    var rules: Binding<[RoutingRule]>

    // MARK: Reads

    func rule(_ id: RoutingRule.ID) -> RoutingRule? {
        rules.wrappedValue.first { $0.id == id }
    }

    // MARK: Per-route bindings

    func matchType(for id: RoutingRule.ID) -> Binding<RouteMatchType> {
        Binding(
            get: { rule(id)?.pattern.hasPrefix("=") == true ? .isEqualTo : .contains },
            set: { newValue in
                update(id) { rule in
                    let body = Self.patternBody(rule.pattern)
                    rule.pattern = newValue == .isEqualTo ? "=\(body)" : body
                }
            }
        )
    }

    // Leading "=" on the stored pattern means "is equal to"; stripped here since it's storage, not user-facing content.
    func pattern(for id: RoutingRule.ID) -> Binding<String> {
        Binding(
            get: { Self.patternBody(rule(id)?.pattern ?? "") },
            set: { newValue in
                update(id) { rule in
                    let isExact = rule.pattern.hasPrefix("=")
                    rule.pattern = isExact ? "=\(newValue)" : newValue
                }
            }
        )
    }

    func destination(for id: RoutingRule.ID) -> Binding<RoutingRule.Destination> {
        Binding(
            get: { rule(id)?.destination ?? .mostRecentSpace },
            set: { newValue in update(id) { $0.destination = newValue } }
        )
    }

    // MARK: Structural edits

    @discardableResult
    func addRoute(defaultDestination: RoutingRule.Destination) -> RoutingRule.ID {
        let rule = RoutingRule(pattern: "", destination: defaultDestination)
        rules.wrappedValue.append(rule)
        return rule.id
    }

    func remove(_ id: RoutingRule.ID) {
        rules.wrappedValue.removeAll { $0.id == id }
    }

    // MARK: -

    static func patternBody(_ stored: String) -> String {
        stored.hasPrefix("=") ? String(stored.dropFirst()) : stored
    }

    private func update(_ id: RoutingRule.ID, _ transform: (inout RoutingRule) -> Void) {
        guard let index = rules.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
        var copy = rules.wrappedValue
        transform(&copy[index])
        rules.wrappedValue = copy
    }
}

private struct AirTrafficControlSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var onDefaultDestinationChanged: () -> Void

    @State private var defaultDestination = RoutingDefaults.destination

    private let labelColumnWidth: CGFloat = 86
    private let removeColumnWidth: CGFloat = OrbitControlMetrics.buttonCompactHeight

    private var editor: AirTrafficControlEditor {
        AirTrafficControlEditor(
            rules: Binding(
                get: { env.state.routingRules },
                set: { env.state.routingRules = $0 }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(env.state.routingRules) { rule in
                        routeBlock(rule)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            Divider()
            defaultRow
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Air Traffic Control").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 12)
            OrbitButton(title: "New Route", kind: .secondary, accentColor: SettingsPalette.accent) {
                editor.addRoute(defaultDestination: newRouteDestination)
            }
            OrbitButton(title: "Close", systemImage: "xmark", kind: .ghost, isIconOnly: true, accentColor: SettingsPalette.accent) {
                dismiss()
            }
        }
    }

    private var newRouteDestination: RoutingRule.Destination {
        env.spaces.first.map { .space($0.id) } ?? .mostRecentSpace
    }

    private func routeBlock(_ rule: RoutingRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                rowLabel("URL", systemImage: "link")

                OrbitPopupButton(
                    options: RouteMatchType.allCases,
                    label: { $0.rawValue },
                    selection: editor.matchType(for: rule.id),
                    accessibilityLabel: "Match type",
                    accentColor: SettingsPalette.accent
                )
                .frame(width: 132, alignment: .leading)

                OrbitTextField(
                    placeholder: "example.com",
                    text: editor.pattern(for: rule.id),
                    accentColor: SettingsPalette.accent,
                    accessibilityLabel: "URL to match"
                )
                .frame(maxWidth: .infinity)

                OrbitButton(
                    title: "Remove route",
                    systemImage: "minus",
                    kind: .secondary,
                    isIconOnly: true,
                    isCompact: true,
                    accentColor: SettingsPalette.accent
                ) {
                    editor.remove(rule.id)
                }
                .frame(width: removeColumnWidth)
            }

            HStack(spacing: 8) {
                rowLabel("Open in", systemImage: "arrow.turn.down.right")

                OrbitPopupButton(
                    options: destinationOptions(including: rule.destination),
                    label: destinationLabel,
                    selection: editor.destination(for: rule.id),
                    accessibilityLabel: "Open in",
                    accentColor: SettingsPalette.accent,
                    expands: true
                )

                Color.clear.frame(width: removeColumnWidth, height: 1)
            }
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
            Text(title)
                .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
        }
        .frame(width: labelColumnWidth, alignment: .trailing)
    }

    private var defaultRow: some View {
        HStack(spacing: 8) {
            Text("Default")
                .font(.system(size: OrbitControlMetrics.settingsRowTitleFontSize))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                .frame(width: labelColumnWidth, alignment: .trailing)

            OrbitPopupButton(
                options: destinationOptions(including: defaultDestination),
                label: destinationLabel,
                selection: Binding(
                    get: { defaultDestination },
                    set: { newValue in
                        defaultDestination = newValue
                        RoutingDefaults.destination = newValue
                        onDefaultDestinationChanged()
                    }
                ),
                accessibilityLabel: "Default routing destination",
                accentColor: SettingsPalette.accent,
                expands: true
            )

            Color.clear.frame(width: removeColumnWidth, height: 1)
        }
    }

    // current is folded in so a rule the list can't otherwise offer isn't silently rewritten to the first option.
    private func destinationOptions(including current: RoutingRule.Destination) -> [RoutingRule.Destination] {
        var options: [RoutingRule.Destination] = env.spaces.map { .space($0.id) }
        options.append(.mostRecentSpace)
        options.append(.littleOrbit)
        if !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private func destinationLabel(_ destination: RoutingRule.Destination) -> String {
        switch destination {
        case .space(let id): return env.space(id)?.name ?? "Deleted Space"
        case .profile(let id): return "Profile \(id.uuidString.prefix(6))"
        case .application(let bundleID): return bundleID
        case .littleOrbit: return "Little Orbit"
        case .mostRecentSpace: return "Most Recent Space"
        }
    }
}
