//  image is deliberately non-optional and this view has no empty state — TabRowView.shouldAttemptHoverPreview is the gate; do not make image optional again, it previously produced a spinner that could never resolve.

import SwiftUI

struct TabHoverPreviewView: View {
    var tab: Tab
    var image: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: OrbitMetrics.tabPreviewWidth, height: OrbitMetrics.tabPreviewHeight)
                .clipped()

            Divider()

            HStack(spacing: 6) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: OrbitMetrics.tabPreviewWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.popoverCornerRadius))
    }
}
