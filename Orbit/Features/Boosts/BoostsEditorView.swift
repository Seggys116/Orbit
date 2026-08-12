import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BoostsEditorView: View {
    @Environment(AppEnvironment.self) private var env
    var host: String

    @State private var selectedBoostID: UUID?
    @State private var activeTab: EditorTab = .zap

    @State private var isZapModeActive = false
    @State private var pendingPick: ZapPick?
    @State private var zapLevel: Double = 0
    @State private var matchCount: Int = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?

    @State private var cssBuffer: String = ""
    @State private var jsBuffer: String = ""
    @State private var applyDebounceTask: Task<Void, Never>?

    @State private var shareErrorMessage: String?
    @State private var showImportPanel = false

    @State private var isAdvancedColorPresented = false
    @State private var visualDebounceTask: Task<Void, Never>?

    @FocusState private var isNameFieldFocused: Bool

    enum EditorTab: String, CaseIterable, Identifiable {
        case zap = "Zap"
        case css = "CSS"
        case js = "JavaScript"
        case appearance = "Appearance"
        var id: String { rawValue }
    }

    private var boostsForHost: [Boost] { env.boostStore.boosts(forHost: host) }
    private var selectedBoost: Boost? {
        guard let selectedBoostID else { return nil }
        return env.boostStore.boost(selectedBoostID)
    }
    private var contents: (any WebContents)? { env.activeWebContents }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            if let boost = selectedBoost {
                editor(for: boost)
            } else {
                emptyState
            }
        }
        .frame(width: 720, height: 520)
        .onAppear {
            if selectedBoostID == nil { selectedBoostID = boostsForHost.first?.id }
            loadBuffers()
        }
        .onChange(of: selectedBoostID) { _, _ in loadBuffers(); teardownZap() }
        .onDisappear { teardownZap() }
        .fileImporter(isPresented: $showImportPanel, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if let imported = BoostSharing.importPayload(from: url, into: env.boostStore, overrideHost: host) {
                selectedBoostID = imported.id
                BoostRuntime.shared.reapply(host: host, env: env)
            }
        }
        .alert("Can't Share This Boost", isPresented: Binding(get: { shareErrorMessage != nil }, set: { if !$0 { shareErrorMessage = nil } })) {
            Button("OK", role: .cancel) { shareErrorMessage = nil }
        } message: {
            Text(shareErrorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(host)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            List(selection: $selectedBoostID) {
                ForEach(boostsForHost) { boost in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(boost.isEnabled ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(boost.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(boost.isEnabled ? "Active" : "Disabled")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(boost.id)
                    .contextMenu {
                        Button(boost.isEnabled ? "Disable" : "Enable") {
                            env.boostStore.setEnabled(!boost.isEnabled, forBoost: boost.id)
                            BoostRuntime.shared.reapply(host: host, env: env)
                        }
                        Button("Delete", role: .destructive) {
                            env.boostStore.deleteBoost(boost.id)
                            if selectedBoostID == boost.id { selectedBoostID = boostsForHost.first?.id }
                            BoostRuntime.shared.reapply(host: host, env: env)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 8) {
                Button {
                    let boost = env.boostStore.createBoost(name: "New Boost", host: host)
                    selectedBoostID = boost.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)

                Button {
                    showImportPanel = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .orbitTooltip("Import a shared Boost file")
                Spacer()
            }
            .padding(8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.circle").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No Boosts for \(host) yet").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("New Boost") {
                let boost = env.boostStore.createBoost(name: "New Boost", host: host)
                selectedBoostID = boost.id
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    @ViewBuilder
    private func editor(for boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Boost name", text: Binding(
                    get: { boost.name },
                    set: { renameBoost(boost.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($isNameFieldFocused)
                .fixedSize(horizontal: true, vertical: false)

                OrbitNSMenuButton(menu: { boostNameMenu(for: boost) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .orbitTooltip("Rename, Shuffle, Reset all Edits, Delete")

                Spacer()

                Toggle("Enabled", isOn: Binding(
                    get: { boost.isEnabled },
                    set: { newValue in
                        env.boostStore.setEnabled(newValue, forBoost: boost.id)
                        BoostRuntime.shared.reapply(host: host, env: env)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

                Button {
                    shareBoost(boost)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .orbitTooltip(boost.customJavaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Share this Boost" : "This Boost contains JavaScript and can't be shared")
            }
            .padding(12)

            Picker("", selection: $activeTab) {
                ForEach(EditorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            switch activeTab {
            case .zap: zapPane(boost)
            case .css: cssPane(boost)
            case .js: jsPane(boost)
            case .appearance: appearancePane(boost)
            }
        }
    }

    private func renameBoost(_ id: UUID, to name: String) {
        env.boostStore.updateBoost(id) { $0.name = name }
    }

    // MARK: - The Boost-name dropdown (Arc's caret menu)

    private func boostNameMenu(for boost: Boost) -> NSMenu {
        let menu = NSMenu()
        let boostID = boost.id

        menu.addItem(ClosureMenuItem(title: "Rename this Boost…") {
            Task { @MainActor in isNameFieldFocused = true }
        })

        menu.addItem(ClosureMenuItem(title: "Shuffle") {
            Task { @MainActor in shuffle(boostID) }
        })

        menu.addItem(ClosureMenuItem(title: "Reset all Edits") {
            Task { @MainActor in resetAllEdits(boostID) }
        })

        menu.addItem(ClosureMenuItem(title: "Delete this Boost") {
            Task { @MainActor in
                env.boostStore.deleteBoost(boostID)
                if selectedBoostID == boostID { selectedBoostID = boostsForHost.first?.id }
                BoostRuntime.shared.reapply(host: host, env: env)
            }
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "All Boosts…") {
            Task { @MainActor in LibraryWindowController.show(section: .boosts) }
        })

        return menu
    }

    private func shuffle(_ boostID: UUID) {
        guard let boost = env.boostStore.boost(boostID) else { return }
        let shuffled = BoostShuffle.shuffled(boost, fontCandidates: Self.installedFontFamilies)
        applyVisualChange(boostID) { target in
            target.backgroundColor = shuffled.backgroundColor
            target.textColor = shuffled.textColor
            target.accentColor = shuffled.accentColor
            target.fontFamily = shuffled.fontFamily
        }
        activeTab = .appearance
    }

    private func resetAllEdits(_ boostID: UUID) {
        applyVisualChange(boostID) { boost in
            boost.resetToOriginalColors()
            boost.fontFamily = nil
            boost.pageSizeScale = 1.0
            boost.textCase = .original
            boost.zappedSelectors = []
            boost.customCSS = ""
            boost.customJavaScript = ""
        }
        loadBuffers()
        // Injected "display: none" rules can't be un-injected; reload for the reset to take visible effect.
        contents?.reload(ignoringCache: false)
    }

    // MARK: - Zap pane

    @ViewBuilder
    private func zapPane(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    isZapModeActive.toggle()
                    if isZapModeActive { activateZapMode() } else { teardownZap() }
                } label: {
                    Label(isZapModeActive ? "Zap Mode: On" : "Turn On Zap Mode", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(isZapModeActive ? .orange : .accentColor)

                if isZapModeActive {
                    Text("Hover an element on the page, then click it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let pick = pendingPick {
                pickCard(pick, boost: boost)
            }

            Divider()

            Text("ZAPPED ELEMENTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)

            if boost.zappedSelectors.isEmpty {
                Text("Nothing zapped on this site yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(boost.zappedSelectors, id: \.self) { selector in
                            HStack {
                                Text(selector)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    restoreSelector(selector, boost: boost)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.plain)
                                .orbitTooltip("Restore this element")
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pickCard(_ pick: ZapPick, boost: Boost) -> some View {
        let clampedLevel = min(Int(zapLevel), max(pick.ladder.count - 1, 0))
        let selectedSelector = pick.ladder.indices.contains(clampedLevel) ? pick.ladder[clampedLevel] : pick.ladder.first ?? pick.tag

        return VStack(alignment: .leading, spacing: 10) {
            Text("Picked: <\(pick.tag)>").font(.system(size: 12, weight: .semibold))

            HStack {
                Text("Narrow").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $zapLevel, in: 0...Double(max(pick.ladder.count - 1, 0)), step: 1)
                    .onChange(of: zapLevel) { _, _ in schedulePreview(for: pick) }
                Text("Widen").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Text(matchCount < 0 ? "Invalid selector" : "\(matchCount) element\(matchCount == 1 ? "" : "s") match")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(selectedSelector)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button("Zap This") {
                    addSelector(pick.ladder.first ?? pick.tag, boost: boost)
                }
                Button("Zap All Related Elements") {
                    addSelector(selectedSelector, boost: boost)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { clearPick() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
        .task(id: pick) { schedulePreview(for: pick, immediate: true) }
    }

    // MARK: - Zap mode lifecycle

    private func activateZapMode() {
        guard let contents else { return }
        pendingPick = nil
        zapLevel = 0
        pollTask?.cancel()
        pollTask = Task { [contents] in
            _ = try? await contents.evaluateJavaScript(ZapEngine.activateScript)
            while !Task.isCancelled {
                if let raw = try? await contents.evaluateJavaScript(ZapEngine.pollScript), let pick = ZapEngine.decodePick(raw) {
                    await MainActor.run {
                        pendingPick = pick
                        zapLevel = 0
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func teardownZap() {
        isZapModeActive = false
        pollTask?.cancel()
        pollTask = nil
        previewTask?.cancel()
        previewTask = nil
        pendingPick = nil
        if let contents {
            Task { _ = try? await contents.evaluateJavaScript(ZapEngine.deactivateScript) }
        }
    }

    private func clearPick() {
        pendingPick = nil
        if let contents {
            Task { _ = try? await contents.evaluateJavaScript(ZapEngine.clearPreviewScript) }
        }
    }

    private func schedulePreview(for pick: ZapPick, immediate: Bool = false) {
        previewTask?.cancel()
        let level = min(Int(zapLevel), max(pick.ladder.count - 1, 0))
        guard pick.ladder.indices.contains(level), let contents else { return }
        let selector = pick.ladder[level]
        previewTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 80_000_000) }
            guard !Task.isCancelled else { return }
            if let result = try? await contents.evaluateJavaScript(ZapEngine.previewScript(selector: selector)) {
                await MainActor.run { matchCount = (result as? Int) ?? (result as? NSNumber)?.intValue ?? 0 }
            }
        }
    }

    private func addSelector(_ selector: String, boost: Boost) {
        env.boostStore.updateBoost(boost.id) { b in
            if !b.zappedSelectors.contains(selector) {
                b.zappedSelectors.append(selector)
            }
        }
        BoostRuntime.shared.reapply(host: host, env: env)
        clearPick()
    }

    private func restoreSelector(_ selector: String, boost: Boost) {
        env.boostStore.updateBoost(boost.id) { b in
            b.zappedSelectors.removeAll { $0 == selector }
        }
        BoostRuntime.shared.reapply(host: host, env: env)
        // Injected "display: none" rules can't be un-injected; reload so registration re-runs without the selector.
        contents?.reload(ignoringCache: false)
    }

    // MARK: - CSS pane

    private func cssPane(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies live to \(host) as you type.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            CodeEditorView(text: $cssBuffer, language: .css) { newValue in
                commitCSS(newValue, boostID: boost.id)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func commitCSS(_ value: String, boostID: UUID) {
        applyDebounceTask?.cancel()
        applyDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            env.boostStore.updateBoost(boostID) { $0.customCSS = value }
            BoostRuntime.shared.reapply(host: host, env: env)
        }
    }

    // MARK: - JS pane

    private func jsPane(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JavaScript Boosts can't be shared — see the share button's tooltip.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    env.boostStore.updateBoost(boost.id) { $0.customJavaScript = jsBuffer }
                    BoostRuntime.shared.reapply(host: host, env: env)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            CodeEditorView(text: $jsBuffer, language: .javaScript, onChange: nil)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Appearance pane

    @ViewBuilder
    private func appearancePane(_ boost: Boost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                colorSection(boost)
                Divider()
                fontSection(boost)
                Divider()
                sizeAndCaseSection(boost)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Colour

    @ViewBuilder
    private func colorSection(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("COLOR")

            ColorPicker("Background", selection: colorBinding(\.backgroundColor, boostID: boost.id), supportsOpacity: true)
            ColorPicker("Text", selection: colorBinding(\.textColor, boostID: boost.id), supportsOpacity: true)
            ColorPicker("Accent", selection: colorBinding(\.accentColor, boostID: boost.id), supportsOpacity: true)

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { boost.invertLightness },
                    set: { newValue in
                        applyVisualChange(boost.id) { $0.invertLightness = newValue }
                    }
                )) {
                    Label("Invert Lightness", systemImage: "lightbulb")
                }
                .toggleStyle(.button)
                .orbitTooltip("Invert lightness — a dark mode for sites that don't have one")

                Button {
                    isAdvancedColorPresented.toggle()
                } label: {
                    Label("Advanced Color Controls", systemImage: "slider.horizontal.3")
                }
                .orbitTooltip("Contrast, Brightness and Original Saturation")
                .popover(isPresented: $isAdvancedColorPresented, arrowEdge: .bottom) {
                    advancedColorControls(boost.id)
                }

                Button {
                    applyVisualChange(boost.id) { $0.resetToOriginalColors() }
                } label: {
                    Label("Reset to Original Colors", systemImage: "nosign")
                }
                .disabled(boost.hasDefaultVisualAdjustments)
                .orbitTooltip("Reset to original colors")

                Spacer()
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
        }
    }

    private func advancedColorControls(_ boostID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            adjustmentSlider("Contrast", keyPath: \.contrast, boostID: boostID)
            adjustmentSlider("Brightness", keyPath: \.brightness, boostID: boostID)
            adjustmentSlider("Original Saturation", keyPath: \.saturation, boostID: boostID)
        }
        .padding(14)
        .frame(width: 240)
    }

    private func adjustmentSlider(
        _ title: String,
        keyPath: WritableKeyPath<Boost, Double>,
        boostID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(percentLabel(env.boostStore.boost(boostID)?[keyPath: keyPath] ?? 1.0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { env.boostStore.boost(boostID)?[keyPath: keyPath] ?? 1.0 },
                    set: { newValue in applyVisualChange(boostID) { $0[keyPath: keyPath] = newValue } }
                ),
                in: Boost.colorAdjustmentRange
            )
        }
    }

    private func percentLabel(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    // MARK: Font

    @ViewBuilder
    private func fontSection(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("FONT")

            Picker("Family", selection: Binding(
                get: { boost.fontFamily ?? "" },
                set: { newValue in
                    applyVisualChange(boost.id) { $0.fontFamily = newValue.isEmpty ? nil : newValue }
                }
            )) {
                Text("Site Default").tag("")
                Divider()
                ForEach(Self.installedFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            TextField("Custom font stack", text: Binding(
                get: { boost.fontFamily ?? "" },
                set: { newValue in
                    applyVisualChange(boost.id) { $0.fontFamily = newValue.isEmpty ? nil : newValue }
                }
            ))
            .orbitTooltip("Any CSS font-family value, e.g. \"Iowan Old Style\", Georgia, serif")
        }
    }

    private static let installedFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    // MARK: Size and Case

    @ViewBuilder
    private func sizeAndCaseSection(_ boost: Boost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("SIZE & CASE")

            HStack(spacing: 8) {
                Button(boost.pageSizeButtonLabel) {
                    let next = boost.nextPageSizeScale
                    applyVisualChange(boost.id) { $0.pageSizeScale = next }
                }
                .buttonStyle(.borderedProminent)
                .tint(boost.pageSizeScale == 1.0 ? Color.secondary.opacity(0.25) : Color.accentColor)
                .orbitTooltip("Overall page size, 90% to 150%")

                Button(boost.textCase.buttonLabel) {
                    let next = boost.textCase.next
                    applyVisualChange(boost.id) { $0.textCase = next }
                }
                .buttonStyle(.borderedProminent)
                .tint(boost.textCase == .original ? Color.secondary.opacity(0.25) : Color.accentColor)
                .orbitTooltip("Text case: UPPERCASE, lowercase, or Capitalize Each Word")

                Spacer()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Applying

    private func applyVisualChange(_ boostID: UUID, _ transform: @escaping (inout Boost) -> Void) {
        env.boostStore.updateBoost(boostID, transform)
        visualDebounceTask?.cancel()
        visualDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            BoostRuntime.shared.reapply(host: host, env: env)
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Boost, ThemeColor?>, boostID: UUID) -> Binding<Color> {
        Binding(
            get: {
                guard let boost = env.boostStore.boost(boostID), let theme = boost[keyPath: keyPath] else { return .clear }
                return Color(theme.nsColor)
            },
            set: { newColor in
                let themeColor = ThemeColor(NSColor(newColor))
                applyVisualChange(boostID) { $0[keyPath: keyPath] = themeColor }
            }
        )
    }

    // MARK: - Buffers

    private func loadBuffers() {
        guard let boost = selectedBoost else { cssBuffer = ""; jsBuffer = ""; return }
        cssBuffer = boost.customCSS
        jsBuffer = boost.customJavaScript
    }

    // MARK: - Sharing

    private func shareBoost(_ boost: Boost) {
        guard let contents else { return }
        if let error = BoostSharing.presentShareSheet(for: boost, from: contents.view) {
            shareErrorMessage = error.errorDescription
        }
    }
}
