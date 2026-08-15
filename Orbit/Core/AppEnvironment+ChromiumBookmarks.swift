import Foundation

enum ChromiumBookmarksSetup {
    static let installOnce: Void = {
        OrbitChromiumBookmarksBridge.shared.install()
    }()
}
