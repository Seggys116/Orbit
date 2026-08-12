import SwiftUI

// Must be mounted as a real NSView above the engine's own — SwiftUI overlays draw beneath a hosted NSView.
@MainActor
@Observable
final class LinkHoverStatus {

    static let shared = LinkHoverStatus()

    init() {}

    private var urlByContents: [UUID: URL] = [:]

    func url(forContents contentsID: UUID) -> URL? { urlByContents[contentsID] }

    func report(_ url: URL?, forContents contentsID: UUID) {
        guard urlByContents[contentsID] != url else { return }
        if let url {
            urlByContents[contentsID] = url
        } else {
            urlByContents.removeValue(forKey: contentsID)
        }
    }

    func forget(contentsID: UUID) {
        urlByContents.removeValue(forKey: contentsID)
    }
}

struct LinkHoverStatusView: View {
    var contentsID: UUID

    @State private var status = LinkHoverStatus.shared

    private let maximumWidthFraction: CGFloat = 0.6

    var body: some View {
        GeometryReader { proxy in
            if let text = displayText {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: proxy.size.width * maximumWidthFraction, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(OrbitMotion.quick, value: displayText)
    }

    private var displayText: String? {
        LinkHoverStatusText.text(for: status.url(forContents: contentsID))
    }
}

enum LinkHoverStatusText {
    static func text(for url: URL?) -> String? {
        guard let url else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }
}
