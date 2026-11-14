import Foundation
import WebKit

final class AppCookieObserver: NSObject, WKHTTPCookieStoreObserver {
    var onChange: (() -> Void)?

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        let handler = onChange
        Task { @MainActor in
            handler?()
        }
    }
}
