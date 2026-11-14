import AppKit
import SwiftUI

// MARK: - Browser identity

extension ImportableBrowser {
    /// Used to find the installed app so its real icon can stand in for the browser.
    var applicationBundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .opera: "com.operasoftware.Opera"
        case .firefox: "org.mozilla.firefox"
        case .arc: "company.thebrowser.Browser"
        }
    }

    /// What the importer brings across, in one short line for the picker row.
    var importSummaryLine: String {
        importsNativeStructure ? "Spaces, tabs, folders and history" : "Bookmarks and history"
    }
}

@MainActor
enum OnboardingBrowserIcons {
    private static var cache: [ImportableBrowser: NSImage?] = [:]

    /// The installed app's icon, or nil when the app is not installed (its data can outlive it).
    static func icon(for browser: ImportableBrowser) -> NSImage? {
        if let cached = cache[browser] { return cached }
        let workspace = NSWorkspace.shared
        let image = workspace
            .urlForApplication(withBundleIdentifier: browser.applicationBundleIdentifier)
            .map { workspace.icon(forFile: $0.path) }
        cache[browser] = .some(image)
        return image
    }
}

// MARK: - Step

struct OnboardingImportStep: View {
    let sources: [ImportableBrowser]
    let hasLoadedSources: Bool
    @Binding var selection: ImportableBrowser?
    @Binding var importLoginSessions: Bool
    let state: OnboardingView.ImportState
    let progress: ImportProgress
    let onSelectionChanged: () -> Void

    private var isImporting: Bool {
        if case .importing = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeading(title: "Bring everything with you.", subtitle: description)

            if hasLoadedSources && sources.isEmpty {
                Text("No data found from \(OnboardingView.supportedBrowserList). You can import later from Archive › Import from Another Browser.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(sources) { browser in
                        OnboardingBrowserRow(
                            browser: browser,
                            isSelected: selection == browser,
                            isDisabled: isImporting
                        ) {
                            selection = (selection == browser) ? nil : browser
                            onSelectionChanged()
                        }
                    }
                }
                signInToggle
            }

            progressSection
        }
    }

    private var description: String {
        guard let source = selection else {
            return "Pick a browser to import bookmarks and history. Passwords are never imported."
        }
        guard source.importsNativeStructure else {
            return "Imports bookmarks and history from \(source.displayName). Passwords are not imported."
        }
        return "Imports your Arc Spaces, tabs, folders, history, extensions and shortcuts. Passwords are not imported."
    }

    @ViewBuilder
    private var signInToggle: some View {
        if selection?.importsLoginSessions == true {
            Toggle(isOn: $importLoginSessions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stay signed in to your sites")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OrbitNeutral.ink)
                    Text("Copies your login sessions. macOS asks permission to read \(selection?.displayName ?? "the browser")'s saved key.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OrbitNeutral.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isImporting)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        switch state {
        case .idle:
            EmptyView()
        case .importing(let browser):
            VStack(alignment: .leading, spacing: 10) {
                if progress.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(browser.displayName)…")
                            .font(.system(size: 12))
                            .foregroundStyle(OrbitNeutral.muted)
                    }
                } else {
                    OnboardingImportProgressList(progress: progress)
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
        case .finished(let summary):
            VStack(alignment: .leading, spacing: 8) {
                OnboardingImportProgressList(progress: progress)
                Text(Self.standardSummaryLine(summary))
                    .font(.system(size: 12))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
        case .finishedArc(let summary):
            VStack(alignment: .leading, spacing: 8) {
                OnboardingImportProgressList(progress: progress)
                Text(OnboardingView.arcSummaryLine(summary))
                    .font(.system(size: 12))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(OnboardingView.arcCaveats(summary), id: \.self) { caveat in
                    Text(caveat)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OrbitNeutral.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(OrbitNeutral.warn)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    static func standardSummaryLine(_ summary: BrowserImportSummary) -> String {
        let bookmarks = summary.bookmarksImported
        let folders = summary.foldersCreated
        let history = summary.historyEntriesImported
        return "Imported \(bookmarks) bookmark\(bookmarks == 1 ? "" : "s") into \(folders) folder\(folders == 1 ? "" : "s") and \(history) history entr\(history == 1 ? "y" : "ies") from \(summary.browser.displayName)."
    }
}

// MARK: - Browser row

private struct OnboardingBrowserRow: View {
    let browser: ImportableBrowser
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    private let outerRadius = OrbitRadius.lg
    private let inset: CGFloat = 7

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrbitNeutral.ink)
                    Text(browser.importSummaryLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OrbitNeutral.muted2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(OrbitNeutral.accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(inset)
            .background(
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(isHovering && !isSelected ? OrbitNeutral.chipStrong : OrbitNeutral.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .strokeBorder(isSelected ? OrbitNeutral.accent : OrbitNeutral.line, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isSelected ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: isHovering)
        .orbitAnimation(OrbitMotion.quick, value: isSelected)
        .accessibilityLabel(browser.displayName)
        .accessibilityHint(browser.importSummaryLine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var tile: some View {
        let radius = OrbitRadius.concentric(outer: outerRadius, inset: inset)
        if let icon = OnboardingBrowserIcons.icon(for: browser) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(OrbitNeutral.chipStrong)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(OrbitNeutral.muted)
                )
        }
    }
}

// MARK: - Live progress

struct OnboardingImportProgressList: View {
    let progress: ImportProgress

    var body: some View {
        VStack(spacing: 8) {
            ForEach(progress.items) { item in
                OnboardingImportProgressRow(item: item)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .orbitAnimation(OrbitMotion.dramatic, value: progress.items.map(\.kind))
    }
}

private struct OnboardingImportProgressRow: View {
    let item: ImportProgressItem

    var body: some View {
        HStack(spacing: 8) {
            Text(item.kind.title)
                .font(.system(size: 12))
                .foregroundStyle(OrbitNeutral.muted)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            bar
            Text(countText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(OrbitNeutral.ink)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.kind.title)
        .accessibilityValue(accessibilityText)
    }

    private var bar: some View {
        let track = Capsule()
        return track
            .fill(OrbitNeutral.chipStrong)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(OrbitNeutral.ink)
                    .scaleEffect(x: max(item.fraction, 0.0001), y: 1, anchor: .leading)
                    .orbitAnimation(OrbitMotion.standard, value: item.fraction)
            }
            .clipShape(track)
    }

    private var countText: String {
        if item.isFinished || item.total != nil { return item.completed.formatted() }
        return "Working"
    }

    private var accessibilityText: String {
        if item.isFinished { return "\(item.completed.formatted()) imported" }
        if let total = item.total { return "\(item.completed.formatted()) of \(total.formatted())" }
        return "In progress"
    }
}
