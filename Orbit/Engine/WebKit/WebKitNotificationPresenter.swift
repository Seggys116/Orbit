import AppKit
import OSLog
import UserNotifications
import WebKit

/// Posts a page's web notifications through the system notification center and activates the page's tab when one is clicked.
@MainActor
final class WebKitNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebKitNotificationPresenter()

    struct Content {
        var identifier: String
        var title: String
        var body: String
        var origin: String

        /// Reads WebKit's private notification data; every key is checked first so a changed object degrades to blanks.
        init(notification: AnyObject) {
            func value(_ keys: [String]) -> String? {
                guard let object = notification as? NSObject else { return nil }
                for key in keys where object.responds(to: NSSelectorFromString(key)) {
                    switch object.value(forKey: key) {
                    case let text as String where !text.isEmpty: return text
                    case let url as URL: return url.absoluteString
                    case let uuid as UUID: return uuid.uuidString
                    default: continue
                    }
                }
                return nil
            }
            identifier = value(["identifier", "notificationID", "uuid", "tag"]) ?? UUID().uuidString
            title = value(["title"]) ?? ""
            body = value(["body"]) ?? ""
            origin = value(["originString", "origin"]) ?? ""
        }
    }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitNotificationPresenter")

    private var activations: [String: () -> Void] = [:]
    private var delegateInstalled = false
    private let dataStoreDelegates = NSMapTable<WKWebsiteDataStore, WebKitNotificationDataStoreDelegate>.weakToStrongObjects()

    /// Page notifications are only delivered to the data store's private delegate. `activate` is handed the
    /// notification's origin when the user clicks it.
    func install(on dataStore: WKWebsiteDataStore, activate: @escaping (String) -> Void) {
        guard dataStoreDelegates.object(forKey: dataStore) == nil else { return }
        let selector = NSSelectorFromString("_setDelegate:")
        guard dataStore.responds(to: selector) else { return }
        let delegate = WebKitNotificationDataStoreDelegate(presenter: self, activate: activate)
        dataStoreDelegates.setObject(delegate, forKey: dataStore)
        dataStore.perform(selector, with: delegate)
    }

    /// A bare test host has no bundle for the notification center to attach to.
    private var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func present(_ content: Content, onActivate: @escaping () -> Void) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            center.delegate = self
            delegateInstalled = true
        }
        activations[content.identifier] = onActivate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
            guard granted else { return }
            let payload = UNMutableNotificationContent()
            payload.title = content.title
            payload.body = content.body
            if !content.origin.isEmpty { payload.subtitle = URL(string: content.origin)?.host() ?? content.origin }
            payload.sound = .default
            let request = UNNotificationRequest(identifier: content.identifier, content: payload, trigger: nil)
            center.add(request) { error in
                if let error { Self.logger.error("Notification could not be posted: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isDefaultAction {
                NSApp.activate()
                self.activations[identifier]?()
            }
            self.activations[identifier] = nil
        }
        completionHandler()
    }
}

/// Answers WebKit's `_WKWebsiteDataStoreDelegate` request to show a page's notification.
@MainActor
final class WebKitNotificationDataStoreDelegate: NSObject {
    private weak var presenter: WebKitNotificationPresenter?
    private let activate: (String) -> Void

    init(presenter: WebKitNotificationPresenter, activate: @escaping (String) -> Void) {
        self.presenter = presenter
        self.activate = activate
    }

    @objc(websiteDataStore:showNotification:)
    func websiteDataStore(_ dataStore: WKWebsiteDataStore, showNotification notification: AnyObject) {
        let content = WebKitNotificationPresenter.Content(notification: notification)
        let activate = activate
        presenter?.present(content) { activate(content.origin) }
    }
}
