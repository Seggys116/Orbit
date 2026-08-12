import SwiftUI

struct RootView: View {
    var body: some View {
        BrowserWindowView()
    }
}

extension View {
    // Every hosting root uses this rather than a bare .environment(_:), so a
    // FaviconView anywhere under it reads the same cache the environment's own
    // navigation callbacks write into.
    func orbitEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment)
            .environment(\.faviconCache, environment.faviconCache)
    }
}
