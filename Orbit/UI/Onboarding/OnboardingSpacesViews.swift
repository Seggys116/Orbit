import SwiftUI

extension ThemeColor {
    /// The same colour as a planet colour, for retinting the stage to a Space's theme.
    var planetColor: PlanetColor {
        PlanetColor(red: red, green: green, blue: blue)
    }
}

struct OnboardingSpacesStep: View {
    @Binding var drafts: [OnboardingSpaceDraft]
    @Binding var selectedDraftID: UUID?

    @FocusState private var focusedDraftID: UUID?

    private var selectedIndex: Int? {
        drafts.firstIndex { $0.id == selectedDraftID } ?? drafts.indices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeading(
                title: "Make it yours.",
                subtitle: "Spaces are separate sets of tabs and favourites, each with its own theme. No account needed."
            )

            VStack(spacing: 6) {
                ForEach($drafts) { $draft in
                    draftRow(draft: $draft)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .orbitAnimation(OrbitMotion.dramatic, value: drafts.map(\.id))

            if drafts.isEmpty {
                Text("With no Space added, you start with one default Space.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                addDraft()
            } label: {
                Label("Add Space", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(OnboardingButtonStyle(variant: .plain))

            if let index = selectedIndex {
                themeSection(for: index)
            }
        }
        .onChange(of: focusedDraftID) { _, newValue in
            if let newValue { selectedDraftID = newValue }
        }
    }

    // MARK: Rows

    private func draftRow(draft: Binding<OnboardingSpaceDraft>) -> some View {
        let value = draft.wrappedValue
        let isSelected = value.id == (selectedIndex.map { drafts[$0].id })
        let outer = OrbitRadius.lg
        let inset: CGFloat = 5
        let fieldRadius = OrbitRadius.concentric(outer: outer, inset: inset)
        let displayName = value.name.isEmpty ? "this Space" : value.name

        return HStack(spacing: 6) {
            TextField("·", text: draft.emoji)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).fill(OrbitNeutral.chip))
                .focused($focusedDraftID, equals: value.id)
                .onChange(of: value.emoji) { _, newValue in
                    guard newValue.count > 1 else { return }
                    draft.wrappedValue.emoji = String(newValue.suffix(1))
                }
                .accessibilityLabel("Emoji for \(displayName), optional")
            TextField("Space name", text: draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(OrbitNeutral.ink)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).fill(OrbitNeutral.chip))
                .focused($focusedDraftID, equals: value.id)
            if value.existingSpaceID == nil {
                Button {
                    removeDraft(value.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(OrbitNeutral.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(displayName)")
            }
        }
        .padding(inset)
        .background(RoundedRectangle(cornerRadius: outer, style: .continuous).fill(OrbitNeutral.chip.opacity(isSelected ? 1 : 0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: outer, style: .continuous)
                .strokeBorder(isSelected ? OrbitNeutral.accent : OrbitNeutral.line, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: outer, style: .continuous))
        .onTapGesture { selectedDraftID = value.id }
        .orbitAnimation(OrbitMotion.quick, value: isSelected)
    }

    private func addDraft() {
        let used = drafts.compactMap(\.theme)
        let theme = SpaceThemePalette.nextDefaultTheme(avoiding: used)
        let draft = OnboardingSpaceDraft(name: "", emoji: "", theme: theme)
        withOrbitAnimation(OrbitMotion.dramatic) {
            drafts.append(draft)
            selectedDraftID = draft.id
        }
        focusedDraftID = draft.id
    }

    private func removeDraft(_ id: UUID) {
        withOrbitAnimation(OrbitMotion.dramatic) {
            drafts.removeAll { $0.id == id }
            if selectedDraftID == id { selectedDraftID = drafts.first?.id }
        }
    }

    // MARK: Theme

    private func themeSection(for index: Int) -> some View {
        let draft = drafts[index]
        let selectedTheme = draft.theme ?? SpaceTheme()
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme for \(draft.name.isEmpty ? "this Space" : draft.name)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OrbitNeutral.ink)
                    .lineLimit(2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 8)], alignment: .leading, spacing: 8) {
                    // The preset list is a fixed constant, so its position is a stable identity.
                    ForEach(0..<SpaceThemePalette.presets.count, id: \.self) { position in
                        let theme = SpaceThemePalette.presets[position]
                        OnboardingThemeSwatch(
                            theme: theme,
                            isSelected: theme.colors == selectedTheme.colors,
                            label: "Theme \(position + 1)"
                        ) {
                            drafts[index].theme = theme
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OnboardingSidebarMock(theme: selectedTheme, name: draft.name, emoji: draft.emoji)
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

// MARK: - Swatch

private struct OnboardingThemeSwatch: View {
    let theme: SpaceTheme
    let isSelected: Bool
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Space themes are deliberately dark; the swatch shows the colour the planet takes from the theme, so a pick matches the stage.
        let tint = GlyphPlanetPalette.tinted(by: theme.primary.planetColor).lit
        Button(action: action) {
            Circle()
                .fill(Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue, opacity: 1))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(OrbitNeutral.line, lineWidth: 1))
                .padding(2)
                .overlay(
                    Circle()
                        .strokeBorder(OrbitNeutral.ink, lineWidth: 1.5)
                        .opacity(isSelected ? 1 : (isHovering ? 0.35 : 0))
                )
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .orbitAnimation(OrbitMotion.quick, value: isSelected)
        .orbitAnimation(OrbitMotion.fade, value: isHovering)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Mini sidebar

/// A small stand-in for the real sidebar, painted with the Space's actual theme.
struct OnboardingSidebarMock: View {
    let theme: SpaceTheme
    let name: String
    let emoji: String

    @Environment(\.colorScheme) private var colorScheme

    private static let rowWidths: [CGFloat] = [78, 62, 70, 52]

    var body: some View {
        let onDark = theme.isDarkSurface(for: colorScheme)
        let text: Color = onDark ? .white : Color.black.opacity(0.85)
        let skeleton: Color = onDark ? .white : .black
        let shape = RoundedRectangle(cornerRadius: OrbitRadius.lg, style: .continuous)
        ZStack(alignment: .topLeading) {
            ThemeBackgroundView(theme: theme)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if emoji.isEmpty {
                        Image(systemName: "circle.grid.2x2")
                            .font(.system(size: 10))
                    } else {
                        Text(emoji).font(.system(size: 11))
                    }
                    Text(name.isEmpty ? "Space name" : name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(text)
                .padding(.bottom, 2)
                ForEach(0..<Self.rowWidths.count, id: \.self) { row in
                    RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                        .fill(skeleton.opacity(row == 0 ? 0.22 : 0.10))
                        .frame(width: Self.rowWidths[row], height: 14)
                }
            }
            .padding(10)
        }
        .frame(width: 104, height: 128)
        .clipShape(shape)
        .overlay(shape.strokeBorder(OrbitNeutral.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sidebar preview for \(name.isEmpty ? "this Space" : name)")
    }
}
