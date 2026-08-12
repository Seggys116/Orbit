//  Anchor position is an approximation: the engine reports only the hovered URL, never its on-page rect.

import SwiftUI

struct LinkPreviewOverlayView: View {
    var pointerInOverlay: () -> CGPoint = { .zero }

    @Environment(AppEnvironment.self) private var env
    @State private var controller = LinkPreviewController.shared
    @State private var hoverMonitor = LinkPreviewHoverMonitor.shared

    private let cardWidth: CGFloat = 320
    private let estimatedCardHeight: CGFloat = 260
    private let verticalOffsetFromPointer: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: .topLeading) {
                    LinkPreviewCardView(phase: controller.phase)
                        .frame(width: cardWidth)
                        .offset(clampedOffset(size: proxy.size))
                        .animation(OrbitMotion.quick, value: controller.phase)
                }
        }
        .allowsHitTesting(false)
        .onAppear { hoverMonitor.start() }
        .onDisappear {
            hoverMonitor.stop()
            controller.dismiss()
        }
        .onChange(of: env.hoveredLinkURL) { _, url in refresh(url: url) }
        .onChange(of: hoverMonitor.isShiftDown) { _, _ in refresh(url: env.hoveredLinkURL) }
        .onChange(of: env.activeTabID) { _, _ in refresh(url: env.hoveredLinkURL) }
    }

    private func refresh(url: URL?) {
        let contents = env.activeTabID.flatMap { env.webContents[$0] }
        let isSessionPersistent = contents?.session.isPersistent ?? false
        let isServiceLink = url.flatMap(RecentPagesService.matching) != nil

        controller.hoverChanged(
            url: url,
            shiftDown: hoverMonitor.isShiftDown,
            at: pointerAnchor(),
            isSessionPersistent: isSessionPersistent,
            fetch: { try await LinkPreviewFetcher.fetchPreviewData(for: $0) },
            sink: isSessionPersistent ? AssistRuntime.providerOnlySink() : nil,
            recentPages: (isSessionPersistent && isServiceLink) ? RecentPagesHistoryConnection.source() : .unavailable,
            recentPagesQuery: RecentPagesQuery(excludedSpaceIDs: incognitoSpaceIDs())
        )
    }

    /// Defense in depth: bulk importers can write incognito rows to `HistoryStore` directly, bypassing the usual recordVisit guard.
    private func incognitoSpaceIDs() -> Set<SpaceID> {
        Set(env.state.spaces.filter { env.isIncognito($0) }.map(\.id))
    }

    private func pointerAnchor() -> CGPoint { pointerInOverlay() }

    private func clampedOffset(size: CGSize) -> CGSize {
        let localX = controller.anchor.x
        let localY = controller.anchor.y + verticalOffsetFromPointer

        let maxX = max(0, size.width - cardWidth)
        let maxY = max(0, size.height - estimatedCardHeight)

        return CGSize(
            width: min(max(localX, 0), maxX),
            height: min(max(localY, 0), maxY)
        )
    }
}
