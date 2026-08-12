import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private static var shared: LibraryWindowController?

    static func toggleVisible() {
        if let shared, let window = shared.window, window.isVisible, window.isKeyWindow {
            window.performClose(nil)
            return
        }
        show(section: LibraryRouter.shared.selectedSection)
    }

    @discardableResult
    static func show(section: LibrarySection) -> LibraryWindowController {
        LibraryRouter.shared.selectedSection = section
        if let shared {
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            return shared
        }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LibraryMetrics.windowDefaultWidth,
                height: LibraryMetrics.windowDefaultHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: LibraryMetrics.windowMinWidth, height: LibraryMetrics.windowMinHeight)
        window.backgroundColor = NSColor(LibraryPalette.contentBackground)
        window.center()
        window.contentView = NSHostingView(rootView: LibraryRootView().orbitEnvironment(AppEnvironment.processRoot))
        let controller = LibraryWindowController(window: window)
        shared = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }
}

@MainActor
@Observable
final class LibraryRouter {
    static let shared = LibraryRouter()

    var selection: LibrarySelection?

    var selectedSection: LibrarySection = .downloads {
        didSet {
            guard oldValue != selectedSection else { return }
            // Selection is section-scoped: clear it on section change so a stale id can't resolve in the wrong section.
            selection = nil
        }
    }

    func select(_ newSelection: LibrarySelection) {
        selection = (selection == newSelection) ? nil : newSelection
    }

    private init() {}
}

struct LibraryRootView: View {
    @State private var router = LibraryRouter.shared
    @State private var searchQuery = ""
    @Environment(AppEnvironment.self) private var env

    private var counts: [LibrarySection: Int] {
        [
            // Must match LibraryMediaView's own filter predicate or the badge and section contents disagree.
            .media: env.mediaStates.values.filter { $0.isMediaActive }.count,
            .downloads: env.downloads.count,
            .easelsAndNotes: env.noteStore.index.count + env.easelStore.index.count,
            .spaces: env.spaces.count,
            .boosts: env.boostStore.boosts.count,
            .archivedTabs: env.archivedTabs().count,
        ]
    }

    private var showsPreview: Bool { router.selectedSection.supportsPreview }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebarView(
                selection: Binding(
                    get: { router.selectedSection },
                    set: { router.selectedSection = $0 }
                ),
                counts: counts
            )

            Rectangle()
                .fill(LibraryPalette.divider)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                header

                if router.selectedSection.rendersItsOwnScrolling {
                    LibrarySectionDetailView(section: router.selectedSection, searchQuery: searchQuery)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LibrarySectionDetailView(section: router.selectedSection, searchQuery: searchQuery)
                            .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
                            .padding(.top, 4)
                            .padding(.bottom, 24)
                    }
                }
            }
            .frame(
                width: showsPreview ? LibraryMetrics.listColumnWidth : nil,
                alignment: .top
            )
            .frame(maxWidth: showsPreview ? nil : .infinity, maxHeight: .infinity, alignment: .top)
            .background(LibraryPalette.contentBackground)

            if showsPreview {
                LibraryPreviewPaneView(selection: router.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: LibraryMetrics.windowMinWidth, minHeight: LibraryMetrics.windowMinHeight)
        .background(LibraryPalette.contentBackground)
        .onChange(of: router.selectedSection) { _, _ in searchQuery = "" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(router.selectedSection.rawValue)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LibraryPalette.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            LibrarySearchField(text: $searchQuery, placeholder: "Search \(router.selectedSection.rawValue)")
                .frame(maxWidth: LibraryMetrics.searchFieldMaxWidth)
        }
        .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
        .padding(.top, LibraryMetrics.contentTopPadding)
        .padding(.bottom, 12)
    }
}

private struct LibrarySectionDetailView: View {
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

private struct LibraryBoostsFallbackView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var filtered: [Boost] {
        guard !searchQuery.isEmpty else { return env.boostStore.boosts }
        let query = searchQuery.lowercased()
        return env.boostStore.boosts.filter { $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query) }
    }

    var body: some View {
        if !filtered.isEmpty {
            VStack(spacing: LibraryMetrics.rowSpacing) {
                ForEach(filtered) { boost in
                    LibraryRowCard {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(LibraryPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(boost.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(LibraryPalette.textPrimary)
                                Text(boost.host).font(.system(size: 11)).foregroundStyle(LibraryPalette.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { boost.isEnabled },
                                set: { env.boostStore.setEnabled($0, forBoost: boost.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }
}
