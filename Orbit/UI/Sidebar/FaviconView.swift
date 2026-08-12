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

    @Environment(\.faviconCache) private var faviconCache

    @State private var image: NSImage?

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
                image = cached
                return
            }
            image = await faviconCache.image(for: url, host: host)
        }
    }
}

private struct FaviconRequestKey: Equatable {
    var url: URL?
    var host: String
}
