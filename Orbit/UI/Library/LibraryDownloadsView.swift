import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryDownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var filtered: [DownloadItem] {
        guard !searchQuery.isEmpty else { return env.libraryDownloads }
        let query = searchQuery.lowercased()
        return env.libraryDownloads.filter { item in
            item.suggestedFileName.lowercased().contains(query)
                || item.destinationURL.lastPathComponent.lowercased().contains(query)
                || (item.sourceURL.host()?.lowercased().contains(query) ?? false)
        }
    }

    private var groups: [LibraryDateGroup<DownloadItem>] {
        LibraryDateGrouping.group(filtered, date: \.startedAt)
    }

    var body: some View {
        content
            .background { Color.clear.onAppear { env.downloadStore.startWatchingFolder() } }
    }

    @ViewBuilder
    private var content: some View {
        if !groups.isEmpty {
            LazyVStack(alignment: .leading, spacing: LibraryModeMetrics.groupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: OrbitSpacing.xs) {
                        LibraryDateSectionHeader(title: group.title)
                        LazyVStack(spacing: LibraryModeMetrics.rowSpacing) {
                            ForEach(group.items) { item in
                                DownloadRow(item: item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DownloadRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.libraryStyle) private var style
    var item: DownloadItem

    private var router: LibraryRouter { env.libraryRouter }

    private var isSelected: Bool {
        router.selection == .download(item.id)
    }

    private var fileExists: Bool {
        env.downloadStore.fileStillExists(item.id)
    }

    private var displayName: String {
        fileExists ? item.destinationURL.lastPathComponent : item.suggestedFileName
    }

    private var sourceHost: String {
        item.sourceURL.host() ?? item.sourceURL.absoluteString
    }

    private var progress: DownloadProgress {
        DownloadProgress(receivedBytes: item.receivedBytes, totalBytes: item.totalBytes, state: item.state)
    }

    private var isInFlight: Bool {
        switch item.state {
        case .pending, .inProgress, .paused: return true
        case .completed, .cancelled, .interrupted: return false
        }
    }

    private var isOpenable: Bool { item.state == .completed && fileExists }

    private var detailText: String {
        switch item.state {
        case .completed:
            let sizeText = item.totalBytes > 0 ? LibraryByteFormat.string(item.totalBytes) : LibraryByteFormat.string(item.receivedBytes)
            return fileExists ? sizeText : "File no longer on disk"
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Failed"
        case .pending:
            return "Starting…"
        case .inProgress, .paused:
            let receivedText = LibraryByteFormat.string(item.receivedBytes)
            if item.totalBytes > 0 {
                return "\(receivedText) of \(LibraryByteFormat.string(item.totalBytes))"
            }
            return receivedText
        }
    }

    private var statusLine: String {
        item.sourceURL.isFileURL ? detailText : "\(sourceHost) · \(detailText)"
    }

    private var isFolderOnly: Bool {
        env.downloadStore.isFolderOnly(item.id)
    }

    private var folderOnlyActions: [LibraryRowAction] {
        guard fileExists else { return [] }
        return [
            LibraryRowAction(title: "Show in Finder", symbol: "folder") {
                env.downloadStore.revealInFinder(item.id)
            },
            LibraryRowAction(title: "Open", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.open(item.destinationURL)
            },
            LibraryRowAction(title: "Move to Trash", symbol: "trash", isDestructive: true) {
                env.downloadStore.moveToTrash(item.id)
            },
        ]
    }

    private var actions: [LibraryRowAction] {
        if isFolderOnly { return folderOnlyActions }
        switch item.state {
        case .pending, .inProgress, .paused:
            return [LibraryRowAction(title: "Cancel", symbol: "xmark", alwaysVisible: true) {
                env.cancelDownload(item.id)
            }]
        case .completed where fileExists:
            return [
                LibraryRowAction(title: "Show in Finder", symbol: "folder") {
                    env.downloadStore.revealInFinder(item.id)
                },
                LibraryRowAction(title: "Open", symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(item.destinationURL)
                },
                LibraryRowAction(title: "Remove from List", symbol: "xmark", isDestructive: true) {
                    env.downloadStore.remove(item.id)
                },
            ]
        case .completed, .cancelled, .interrupted:
            return [
                LibraryRowAction(title: "Download Again", symbol: "arrow.clockwise") { retry() },
                LibraryRowAction(title: "Remove from List", symbol: "xmark", isDestructive: true) {
                    env.downloadStore.remove(item.id)
                },
            ]
        }
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected, actions: actions) {
            Image(nsImage: DownloadFileIcon.icon(for: item, fileExists: fileExists))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                .opacity(item.state == .cancelled || item.state == .interrupted ? OrbitMetrics.spacePagerInactiveOpacity : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                Text(displayName)
                    .font(OrbitFont.sidebarRowActive)
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine)
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
                if isInFlight {
                    LibraryProgressBar(fraction: progress.fraction)
                        .padding(.top, OrbitSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .modifier(DownloadDragOutModifier(url: isOpenable ? item.destinationURL : nil))
        // Order matters: double-tap must be declared before single-tap.
        .onTapGesture(count: 2) {
            if isOpenable {
                NSWorkspace.shared.open(item.destinationURL)
            }
        }
        .onTapGesture {
            withOrbitAnimation(OrbitMotion.standard) { router.select(.download(item.id)) }
        }
    }

    private func retry() {
        guard let spaceID = env.activeSpace?.id else { return }
        env.downloadStore.remove(item.id)
        _ = env.openTab(url: item.sourceURL, in: spaceID, section: .today)
    }
}

/// Drags the downloaded file itself out of the row, into Finder or another app.
private struct DownloadDragOutModifier: ViewModifier {
    var url: URL?

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var isSuppressed: Bool {
        #if DEBUG
        screenshotModeDragDisabled
        #else
        false
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url, !isSuppressed {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}
