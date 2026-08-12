import AppKit
import Quartz
import SwiftUI

// MARK: - Pane

struct LibraryPreviewPaneView: View {
    @Environment(AppEnvironment.self) private var env
    var selection: LibrarySelection?

    @State private var session: LibraryLiveWebSession?

    private var content: LibraryPreviewContent {
        LibraryPreviewContent.resolve(selection, env: env)
    }

    var body: some View {
        body(for: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: LibraryMetrics.previewLeadingCornerRadius,
                    bottomLeadingRadius: LibraryMetrics.previewLeadingCornerRadius,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
            )
            .onAppear {
                let created = session ?? LibraryLiveWebSession(
                    open: { env.makeDetachedTab(url: $0) },
                    close: { env.closeDetachedTab($0) }
                )
                session = created
                created.show(content.liveWebURL)
            }
            .onDisappear {
                session?.teardown()
            }
            .onChange(of: content) { _, newContent in
                session?.show(newContent.liveWebURL)
            }
    }

    @ViewBuilder
    private func body(for content: LibraryPreviewContent) -> some View {
        switch content {
        case .none:
            Color.clear

        case .file(let url):
            LibraryQuickLookPreviewView(url: url)

        case .liveWeb:
            liveWeb

        case .note(let noteBody):
            LibraryNotePreviewView(noteBody: noteBody)

        case .easel(let items):
            if case .easel(let easelID) = selection {
                LibraryEaselPreviewView(easelID: easelID, items: items)
            }

        case .media(let tabID, let state):
            LibraryMediaPreviewView(tabID: tabID, state: state)
        }
    }

    @ViewBuilder
    private var liveWeb: some View {
        if let tabID = session?.tabID, let contents = env.webContents[tabID] {
            WebContentsHostView(contents: contents, environment: env)
        } else {
            Color.clear
        }
    }
}

// MARK: - Downloads: the real file, via QuickLook

struct LibraryQuickLookPreviewView: NSViewRepresentable {
    var url: URL

    // QLPreviewView.init imports as failable; force-unwrapping it would crash
    // when QuickLook fails to start, so this coordinator lets the nil case draw nothing.
    final class Coordinator {
        var preview: QLPreviewView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return container }
        preview.autostarts = true
        preview.previewItem = url as NSURL
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.preview = preview
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let preview = context.coordinator.preview else { return }
        guard preview.previewItem?.previewItemURL != url else { return }
        preview.previewItem = url as NSURL
        preview.refreshPreviewItem()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.preview?.close()
        coordinator.preview = nil
    }
}

// MARK: - Notes: the real decoded body

struct LibraryNotePreviewView: View {
    var noteBody: NSAttributedString

    var body: some View {
        ScrollView {
            Text(AttributedString(noteBody))
                .textSelection(.enabled)
                .foregroundStyle(LibraryPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LibraryMetrics.previewContentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LibraryPalette.previewBackground)
    }
}

// MARK: - Easels: the real items, read-only

struct LibraryEaselPreviewView: View {
    @Environment(AppEnvironment.self) private var env
    var easelID: UUID
    var items: [EaselItem]

    @State private var model: EaselCanvasModel?

    private var contentBounds: CGRect {
        items.dropFirst().reduce(items.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = contentBounds
            let available = CGSize(
                width: max(1, proxy.size.width - LibraryMetrics.previewContentPadding * 2),
                height: max(1, proxy.size.height - LibraryMetrics.previewContentPadding * 2)
            )
            let scale = min(1, min(
                available.width / max(1, bounds.width),
                available.height / max(1, bounds.height)
            ))

            ZStack {
                if let model {
                    ForEach(items.sorted { $0.zIndex < $1.zIndex }) { item in
                        EaselItemContentView(
                            model: model,
                            item: item,
                            env: env,
                            isEditingText: .constant(false),
                            textDraft: .constant("")
                        )
                        .frame(width: item.frame.width, height: item.frame.height)
                        .rotationEffect(.degrees(item.rotation))
                        .position(
                            x: item.frame.midX - bounds.minX,
                            y: item.frame.midY - bounds.minY
                        )
                    }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .center)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
        .background(LibraryPalette.previewBackground)
        .onAppear { rebuildModelIfNeeded() }
        .onChange(of: easelID) { _, _ in rebuildModelIfNeeded() }
    }

    private func rebuildModelIfNeeded() {
        guard model?.easelID != easelID else { return }
        model = EaselCanvasModel(easelID: easelID, store: env.easelStore)
    }
}

// MARK: - Media: a live frame plus the real now-playing metadata

struct LibraryMediaPreviewView: View {
    @Environment(AppEnvironment.self) private var env
    var tabID: TabID
    var state: MediaState

    @State private var frame: NSImage?
    @State private var artwork: NSImage?

    private var tab: Tab? { env.tab(tabID) }

    private var title: String? {
        state.nowPlayingTitle ?? tab?.displayTitle
    }

    private var subtitle: String? {
        state.nowPlayingArtist ?? tab?.url.host()
    }

    var body: some View {
        ZStack {
            LibraryPalette.previewBackground

            if let frame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                metadataStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tabID) { await loadFrame() }
        .task(id: state.nowPlayingArtworkURL) { await loadArtwork() }
    }

    @ViewBuilder
    private var metadataStack: some View {
        VStack(spacing: 16) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: LibraryMetrics.previewArtworkMaxSize, maxHeight: LibraryMetrics.previewArtworkMaxSize)
                    .clipShape(RoundedRectangle(cornerRadius: LibraryMetrics.previewArtworkCornerRadius))
            }
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LibraryPalette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(LibraryMetrics.previewContentPadding)
    }

    private func loadFrame() async {
        guard let contents = env.webContents[tabID] else {
            frame = nil
            return
        }
        frame = await contents.capturePreview(rect: nil, size: LibraryMetrics.previewCaptureSize)
    }

    private func loadArtwork() async {
        guard let url = state.nowPlayingArtworkURL else {
            artwork = nil
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            artwork = nil
            return
        }
        artwork = NSImage(data: data)
    }
}
