import SwiftUI

// Profile picker deliberately absent: SpaceProfileNoDropdownTests fails the build if one reappears.
enum NewSpaceFlowRow: String, CaseIterable, Identifiable {
    case nameAndIcon
    case chooseTheme

    var id: String { rawValue }
}

@MainActor
enum NewSpaceFlowAction {
    static func canCreate(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Calls env.createSpace, not env.store.createSpace, so scopingActiveSpaceToThisWindow still applies.
    @discardableResult
    static func create(
        name: String,
        icon: String,
        iconIsEmoji: Bool,
        iconOverride: SpaceIcon? = nil,
        theme: SpaceTheme,
        in env: AppEnvironment
    ) -> SpaceID? {
        guard canCreate(name: name) else { return nil }
        let id = env.createSpace(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            iconIsEmoji: iconIsEmoji,
            theme: theme,
            profileID: NewSpaceProfileDefault.resolve(in: env)
        )
        if let iconOverride {
            env.store.setIcon(iconOverride, forSpace: id)
        }
        return id
    }
}

struct NewSpaceFlowView: View {
    @Environment(AppEnvironment.self) private var env

    var onDismiss: () -> Void = {}

    @State private var name = ""
    // nil means the icon chooser hasn't been opened yet.
    @State private var iconSelection: SpaceIcon?
    @State private var theme = SpaceTheme()
    @State private var showIconChooser = false
    @State private var showThemeEditor = false
    @FocusState private var nameFieldFocused: Bool

    private static let startingIcon = "plus.viewfinder"

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopRow(theme: theme)

            VStack(spacing: 0) {
                illustration
                    .padding(.top, OrbitMetrics.sidebarSectionSpacing * 2)

                Text("Create a Space")
                    .font(.system(size: OrbitMetrics.sidebarSpaceNameFontSize + 3, weight: .bold))
                    .foregroundStyle(theme.readableForeground)
                    .padding(.top, OrbitMetrics.sidebarInterSectionGap)

                Text("Separate your tabs for life, work, projects, and more.")
                    .font(.system(size: OrbitMetrics.sidebarRowFontSize - 1))
                    .foregroundStyle(theme.readableSecondaryForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, OrbitMetrics.sidebarInterSectionGap / 2)
                    .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)

                VStack(spacing: OrbitMetrics.sidebarInterSectionGap / 2) {
                    ForEach(NewSpaceFlowRow.allCases) { row($0) }
                }
                .padding(.top, OrbitMetrics.sidebarSectionSpacing * 2)

                Spacer(minLength: OrbitMetrics.sidebarSectionSpacing)

                createButton
                cancelButton
                    .padding(.top, OrbitMetrics.sidebarInterSectionGap / 2)
            }
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)

            SidebarBottomBar(theme: theme)
                .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ThemeBackgroundView(theme: theme) }
        .onAppear { nameFieldFocused = true }
    }

    // MARK: - Illustration

    private var illustration: some View {
        let cardHeight = OrbitMetrics.spaceBadgeSize
        let cardWidth = OrbitMetrics.spaceBadgeSize * 0.8
        return ZStack {
            card(width: cardWidth, height: cardHeight * 0.86)
                .rotationEffect(.degrees(-14))
                .offset(x: -cardWidth * 0.62)
            card(width: cardWidth, height: cardHeight * 0.86)
                .rotationEffect(.degrees(14))
                .offset(x: cardWidth * 0.62)
            card(width: cardWidth, height: cardHeight)
        }
        .frame(height: cardHeight)
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius)
            .fill(theme.readableForeground.opacity(OrbitMetrics.miniPlayerSurfaceOpacity * 1.6))
            .overlay(
                RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius)
                    .strokeBorder(theme.readableForeground.opacity(OrbitMetrics.sidebarDividerOpacity * 2), lineWidth: OrbitMetrics.cardBorderWidth)
            )
            .frame(width: width, height: height)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ row: NewSpaceFlowRow) -> some View {
        switch row {
        case .nameAndIcon: nameAndIconRow
        case .chooseTheme: chooseThemeRow
        }
    }

    private var nameAndIconRow: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            Button {
                showIconChooser = true
            } label: {
                iconPreview
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.readableForeground)
            .popover(isPresented: $showIconChooser, arrowEdge: .trailing) {
                SpaceIconChooserView { newIcon in
                    iconSelection = newIcon
                    showIconChooser = false
                }
            }

            TextField("Space name…", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: OrbitMetrics.sidebarRowFontSize))
                .foregroundStyle(theme.readableForeground)
                .focused($nameFieldFocused)
                .onSubmit(createSpace)
        }
        .modifier(NewSpaceFlowRowChrome(theme: theme, isActive: false))
    }

    private var chooseThemeRow: some View {
        Button {
            showThemeEditor = true
        } label: {
            HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
                Image(systemName: "paintbrush")
                    .font(.system(size: OrbitMetrics.iconChrome, weight: .medium))
                    .frame(width: OrbitMetrics.iconMedium)
                Text("Choose a Theme")
                    .font(.system(size: OrbitMetrics.sidebarRowFontSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.readableForeground)
            .modifier(NewSpaceFlowRowChrome(theme: theme, isActive: showThemeEditor))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showThemeEditor, arrowEdge: .trailing) {
            ThemeEditorView(theme: $theme, onDone: { showThemeEditor = false })
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        Group {
            if let iconSelection {
                SpaceIconView(icon: iconSelection, size: OrbitMetrics.iconChrome)
            } else {
                Image(systemName: NewSpaceFlowView.startingIcon)
                    .font(.system(size: OrbitMetrics.iconChrome, weight: .medium))
            }
        }
        .frame(width: OrbitMetrics.iconMedium, height: OrbitMetrics.iconMedium)
    }

    // MARK: - Footer

    private var createButton: some View {
        Button(action: createSpace) {
            Text("Create Space")
                .font(.system(size: OrbitMetrics.sidebarRowFontSize, weight: .semibold))
                .foregroundStyle(createButtonLabelColor)
                .frame(maxWidth: .infinity)
                .frame(height: OrbitMetrics.sidebarRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius)
                        .fill(createButtonFill)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!NewSpaceFlowAction.canCreate(name: name))
        .opacity(NewSpaceFlowAction.canCreate(name: name) ? 1 : 0.45)
    }

    private var createButtonFill: Color {
        Color(theme.primary.nsColor).blended(with: theme.readableForeground, fraction: 0.45)
    }

    private var createButtonLabelColor: Color {
        createButtonFill.approximateLuminance <= 0.55 ? Color.white.opacity(0.95) : Color.black.opacity(0.85)
    }

    private var cancelButton: some View {
        Button(action: onDismiss) {
            Text("Cancel")
                .font(.system(size: OrbitMetrics.sidebarRowFontSize))
                .foregroundStyle(theme.readableSecondaryForeground)
                .frame(maxWidth: .infinity)
                .frame(height: OrbitMetrics.sidebarRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private func createSpace() {
        // SpaceIcon.none written out in full: bare .none here resolves to nil.
        guard NewSpaceFlowAction.create(
            name: name,
            icon: NewSpaceFlowView.startingIcon,
            iconIsEmoji: false,
            iconOverride: iconSelection ?? SpaceIcon.none,
            theme: theme,
            in: env
        ) != nil else { return }
        onDismiss()
    }
}

private struct NewSpaceFlowRowChrome: ViewModifier {
    var theme: SpaceTheme
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .frame(height: OrbitMetrics.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius)
                    .fill(theme.readableForeground.opacity(OrbitMetrics.miniPlayerSurfaceOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius)
                    .strokeBorder(
                        theme.readableForeground.opacity(isActive ? OrbitMetrics.sidebarDividerOpacity * 3 : 0),
                        lineWidth: OrbitMetrics.cardBorderWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius))
    }
}

// Defers to BrowserStore.defaultProfile, never an Incognito session's ephemeral profile.
enum NewSpaceProfileDefault {
    static func resolve(in env: AppEnvironment) -> ProfileID {
        env.store.defaultProfile.map(\.id) ?? env.createDefaultProfileIfNeeded()
    }
}

extension AppEnvironment {
    func createDefaultProfileIfNeeded() -> ProfileID {
        if let existing = state.profiles.first { return existing.id }
        let profile = Profile(name: "default")
        state.profiles.append(profile)
        return profile.id
    }
}
