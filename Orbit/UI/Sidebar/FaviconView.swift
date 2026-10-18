import SwiftUI

// The owning AppEnvironment's cache, injected at every hosting root. The
// default is the process-default cache rather than a real-profile singleton:
// this file is also compiled into OrbitTests, where no AppEnvironment exists.
private struct FaviconCacheKey: EnvironmentKey {
    @MainActor static var defaultValue: FaviconCache { .processDefault }
}

extension EnvironmentValues {
    var faviconCache: FaviconCache {
        get { self[FaviconCacheKey.self] }
        set { self[FaviconCacheKey.self] = newValue }
    }
}

struct FaviconView: View {
    var url: URL?
    var host: String

    var body: some View {
        ResolvedFaviconView(url: url, host: host)
            .equatable()
    }
}

private struct ResolvedFaviconView: View, Equatable {
    var url: URL?
    var host: String

    @Environment(\.faviconCache) private var faviconCache
    @State private var image: NSImage?

    static func == (lhs: ResolvedFaviconView, rhs: ResolvedFaviconView) -> Bool {
        lhs.url == rhs.url && lhs.host == rhs.host
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: FaviconRequestKey(url: url, host: host)) {
            if let cached = faviconCache.cachedImage(forHost: host) {
                assign(PreparedFavicon.prepare(cached))
                return
            }
            assign(PreparedFavicon.prepare(await faviconCache.image(for: url, host: host)))
        }
    }

    private func assign(_ resolved: NSImage) {
        if image !== resolved {
            image = resolved
        }
    }
}

// The default cache mode is allowed to drop a file-backed bitmap, so the next
// draw decodes the file again. Keep the decoded representation for the life of this image.
private enum PreparedFavicon {
    static func prepare(_ image: NSImage) -> NSImage {
        if image.cacheMode != .always {
            image.cacheMode = .always
        }
        return image
    }
}

private struct FaviconRequestKey: Equatable {
    var url: URL?
    var host: String
}
