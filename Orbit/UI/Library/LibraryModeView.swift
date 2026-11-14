import AppKit
import SwiftUI
import WebKit

extension AnyTransition {
    /// Opacity plus a short horizontal slide; Reduce Motion keeps only the fade.
    static func librarySlide(offset: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: offset))
    }
}

/// The Library as the sidebar shows it; selecting a row pushes a detail view into the same column.
struct LibraryModeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryStyle) private var style
    @Bindable var router: LibraryRouter

    @State private var escapeMonitor: Any?

    private var isShowingDetail: Bool {
        router.selection != nil && router.selectedSection.supportsPreview
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                LibraryRailView(
                    selection: Binding(
                        get: { router.selectedSection },
                        set: { newSection in
                            withOrbitAnimation(OrbitMotion.standard) { router.selectedSection = newSection }
                        }
                    )
                )

                Rectangle()
                    .fill(style.divider)
                    .frame(width: OrbitMetrics.cardBorderWidth)
                    .padding(.vertical, OrbitSpacing.xs)

                contentColumn
            }
        }
        .onAppear { installEscapeMonitor() }
        .onDisappear { removeEscapeMonitor() }
    }


    private var header: some View {
        HStack(spacing: OrbitSpacing.sm) {
            Button {
                env.closeLibrary()
            } label: {
                HStack(spacing: OrbitSpacing.sm) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .semibold))
                        .frame(width: LibraryModeMetrics.backButtonSize, height: LibraryModeMetrics.backButtonSize)
                    Text("Library")
                        .font(OrbitFont.spaceTitle)
                        .lineLimit(1)
                }
                .foregroundStyle(style.foreground)
                .padding(.trailing, OrbitSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .orbitTooltip("Back to tabs")
            .accessibilityLabel("Back to tabs")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LibraryModeMetrics.headerHorizontalPadding)
        .frame(height: LibraryModeMetrics.headerHeight)
    }


    private var contentColumn: some View {
        ZStack(alignment: .topLeading) {
            if let selection = router.selection, isShowingDetail {
                LibraryDetailView(selection: selection, router: router)
                    .transition(.librarySlide(offset: LibraryModeMetrics.slideDistance, reduceMotion: reduceMotion))
            } else {
                listColumn
                    .transition(.librarySlide(offset: -LibraryModeMetrics.slideDistance, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .orbitAnimation(OrbitMotion.standard, value: isShowingDetail)
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            if router.selectedSection.rendersItsOwnScrolling {
                LibrarySectionDetailView(section: router.selectedSection, searchQuery: router.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LibrarySectionDetailView(section: router.selectedSection, searchQuery: router.searchQuery)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LibraryModeMetrics.contentPadding)
                        .padding(.bottom, OrbitSpacing.xxl)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: LibraryModeMetrics.sectionHeaderSpacing) {
            Text(router.selectedSection.rawValue)
                .font(OrbitFont.spaceTitle)
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            LibrarySearchField(
                text: $router.searchQuery,
                placeholder: "Search \(router.selectedSection.rawValue)",
                onExit: { env.handleLibraryEscape() }
            )
        }
        .padding(.horizontal, LibraryModeMetrics.contentPadding)
        .padding(.top, OrbitSpacing.xs)
        .padding(.bottom, OrbitSpacing.md)
    }

    // MARK: Escape

    // A window-level monitor, not a focus-bound key handler: focus is usually in the page, not here.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        // Captured by value: an @Environment read from a stored closure is outside the view graph.
        let env = env
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // kVK_Escape
            let responder = event.window?.firstResponder
            let ownsEscape = Self.firstResponderOwnsEscape(responder)
            let overlayPresented = env.isCommandBarPresented
                || event.window?.attachedSheet != nil
                || NSApp.windows.contains { $0 is OrbitMenuPanel && $0.isVisible }
            let isForeground = AppEnvironment.frontmost === env && event.window?.isKeyWindow == true
            return env.handleLibraryEscape(isForegroundWindow: isForeground, isOverlayPresented: overlayPresented, firstResponderOwnsEscape: ownsEscape) ? nil : event
        }
    }

    // Text views (field editors, marked-text composition) and web content keep their own Escape.
    private static func firstResponderOwnsEscape(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView { return true }
        if let client = responder as? NSTextInputClient, client.hasMarkedText() { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }
}

// MARK: - Detail (pushed into the column)

private struct LibraryDetailView: View {
    var selection: LibrarySelection
    @Bindable var router: LibraryRouter

    @Environment(\.libraryStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitSpacing.md) {
            Button {
                withOrbitAnimation(OrbitMotion.standard) { router.clearSelection() }
            } label: {
                HStack(spacing: OrbitSpacing.sm) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .semibold))
                    Text(router.selectedSection.rawValue)
                        .font(OrbitFont.spaceTitle)
                        .lineLimit(1)
                }
                .foregroundStyle(style.foreground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(router.selectedSection.rawValue)")
            .padding(.horizontal, LibraryModeMetrics.contentPadding)
            .padding(.top, OrbitSpacing.xs)

            LibraryPreviewPaneView(selection: selection)
                .clipShape(RoundedRectangle(cornerRadius: LibraryModeMetrics.detailCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LibraryModeMetrics.detailCornerRadius, style: .continuous)
                        .strokeBorder(style.border, lineWidth: OrbitMetrics.cardBorderWidth)
                )
                .padding(.horizontal, LibraryModeMetrics.contentPadding)
                .padding(.bottom, LibraryModeMetrics.contentPadding)
        }
    }
}

// MARK: - Section routing

struct LibrarySectionDetailView: View {
    @Environment(AppEnvironment.self) private var env
    var section: LibrarySection
    var searchQuery: String

    var body: some View {
        // flatMap, not `?(section)`: the hook is optional AND returns an optional; chaining would bind a nested AnyView?.
        if let override = env.extensionPoints.librarySection.flatMap({ $0(section) }) {
            override
        } else {
            switch section {
            case .media: LibraryMediaView(searchQuery: searchQuery)
            case .downloads: LibraryDownloadsView(searchQuery: searchQuery)
            case .easelsAndNotes: LibraryEaselsNotesView(searchQuery: searchQuery)
            case .spaces: LibrarySpacesView(searchQuery: searchQuery)
            case .boosts: LibraryBoostsFallbackView(searchQuery: searchQuery)
            case .archivedTabs: LibraryArchivedTabsView(searchQuery: searchQuery)
            }
        }
    }
}

// internal, not private: the screenshot composition renders this directly.
struct LibraryBoostsFallbackView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.libraryStyle) private var style
    var searchQuery: String

    private var filtered: [Boost] {
        guard !searchQuery.isEmpty else { return env.boostStore.boosts }
        let query = searchQuery.lowercased()
        return env.boostStore.boosts.filter { $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query) }
    }

    var body: some View {
        if !filtered.isEmpty {
            LazyVStack(spacing: LibraryModeMetrics.rowSpacing) {
                ForEach(filtered) { boost in
                    LibraryRowCard {
                        Image(systemName: "bolt.circle")
                            .font(.system(size: OrbitMetrics.iconChrome - 4))
                            .foregroundStyle(style.foreground)
                            .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                        VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                            Text(boost.name)
                                .font(OrbitFont.sidebarRowActive)
                                .foregroundStyle(style.foreground)
                                .lineLimit(1)
                            Text(boost.host)
                                .font(OrbitFont.commandBarRowSubtitle)
                                .foregroundStyle(style.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: OrbitSpacing.sm)
                        Toggle("", isOn: Binding(
                            get: { boost.isEnabled },
                            set: { env.boostStore.setEnabled($0, forBoost: boost.id) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable \(boost.name)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
