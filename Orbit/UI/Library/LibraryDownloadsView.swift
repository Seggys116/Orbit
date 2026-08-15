import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryDownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var filtered: [DownloadItem] {
        guard !searchQuery.isEmpty else { return env.downloads }
        let query = searchQuery.lowercased()
        return env.downloads.filter { item in
            item.suggestedFileName.lowercased().contains(query)
                || item.destinationURL.lastPathComponent.lowercased().contains(query)
                || (item.sourceURL.host()?.lowercased().contains(query) ?? false)
        }
    }

    private var groups: [LibraryDateGroup<DownloadItem>] {
        LibraryDateGrouping.group(filtered, date: \.startedAt)
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: LibraryMetrics.dateGroupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryDateSectionHeader(title: group.title)
                        VStack(spacing: LibraryMetrics.rowSpacing) {
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
    @State private var router = LibraryRouter.shared
    var item: DownloadItem

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

    private var detailText: String {
        switch item.state {
        case .completed:
            let sizeText = item.totalBytes > 0 ? LibraryByteFormat.string(item.totalBytes) : LibraryByteFormat.string(item.receivedBytes)
            return fileExists ? sizeText : "file no longer on disk"
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

    private var statusLine: String { "\(sourceHost) · \(detailText)" }

    private var startedTimeText: String {
        item.startedAt.formatted(date: .omitted, time: .shortened)
    }

    // Only worth spreading into columns once the list isn't squeezed down to make room for the
    // preview pane (see LibraryRootView.showsPreview).
    private var isWide: Bool { router.selection == nil }

    var body: some View {
        LibraryRowCard(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(nsImage: DownloadFileIcon.icon(for: item, fileExists: fileExists))
                        .resizable()
                        .frame(width: LibraryMetrics.rowIconSize, height: LibraryMetrics.rowIconSize)
                        .opacity(item.state == .cancelled || item.state == .interrupted ? 0.55 : 1)

                    if isWide {
                        Text(displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LibraryPalette.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LibraryColumnText(text: sourceHost, width: LibraryMetrics.rowMetaColumnWidth)
                        LibraryColumnText(text: detailText, width: LibraryMetrics.rowSecondaryColumnWidth)
                        LibraryColumnText(text: startedTimeText, width: LibraryMetrics.rowDateColumnWidth, alignment: .trailing, color: LibraryPalette.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LibraryPalette.textPrimary)
                                .lineLimit(1)
                            Text(statusLine)
                                .font(.system(size: 11))
                                .foregroundStyle(LibraryPalette.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    actions
                }

                if isInFlight {
                    LibraryProgressBar(fraction: progress.fraction)
                        .frame(maxWidth: isWide ? .infinity : 220)
                        .padding(.leading, LibraryMetrics.rowIconSize + 10)
                }
            }
        }
        .contentShape(Rectangle())
        // Order matters: double-tap must be declared before single-tap.
        .onTapGesture(count: 2) {
            if item.state == .completed && fileExists {
                NSWorkspace.shared.open(item.destinationURL)
            }
        }
        .onTapGesture { router.select(.download(item.id)) }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .pending, .inProgress, .paused:
            LibraryActionButton(symbol: "xmark", help: "Cancel") {
                env.cancelDownload(item.id)
            }
        case .completed where fileExists:
            LibraryActionButton(symbol: "folder", help: "Reveal in Finder") {
                env.downloadStore.revealInFinder(item.id)
            }
            LibraryActionButton(symbol: "arrow.up.forward.app", help: "Open") {
                NSWorkspace.shared.open(item.destinationURL)
            }
            LibraryActionButton(symbol: "xmark", help: "Remove from List") {
                env.downloadStore.remove(item.id)
            }
        case .completed, .cancelled, .interrupted:
            LibraryActionButton(symbol: "arrow.clockwise", help: "Download Again") {
                retry()
            }
            LibraryActionButton(symbol: "xmark", tint: LibraryPalette.destructive, help: "Remove from List") {
                env.downloadStore.remove(item.id)
            }
        }
    }

    private func retry() {
        guard let spaceID = env.activeSpace?.id else { return }
        env.downloadStore.remove(item.id)
        _ = env.openTab(url: item.sourceURL, in: spaceID, section: .today)
    }
}
