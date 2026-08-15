import Foundation

enum ChromiumDownloadsSetup {
    static let installOnce: Void = {
        OrbitChromiumDownloadsBridge.shared.install()
    }()
}
