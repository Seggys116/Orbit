import Foundation

/// What the chrome wrapper provides on top of WebKit, as data. Conformance tests read this rather
/// than the wrapper's source, and run the generated wrapper to prove it still matches.
enum ChromeAPISurfaceInventory {

    /// A namespace WebKit lacks, created by the wrapper and gated by the permission of the same name.
    struct Namespace {
        let name: String
        let methods: [String]
        let events: [String]
        /// Members upstream gives every extension, with or without the namespace's permission.
        let ungatedMethods: [String]
        /// Constants and enum objects the wrapper attaches to the namespace.
        let constants: [String]

        init(
            _ name: String, methods: [String], events: [String] = [],
            ungatedMethods: [String] = [], constants: [String] = []
        ) {
            self.name = name
            self.methods = methods
            self.events = events
            self.ungatedMethods = ungatedMethods
            self.constants = constants
        }
    }

    /// Members the wrapper adds to a namespace WebKit provides itself, because WebKit leaves them out.
    struct Augmentation {
        let namespace: String
        let functions: [String]
        let events: [String]
        let properties: [String]

        init(_ namespace: String, functions: [String] = [], events: [String] = [], properties: [String] = []) {
            self.namespace = namespace
            self.functions = functions
            self.events = events
            self.properties = properties
        }
    }

    static let namespaces: [Namespace] = [
        Namespace(
            "bookmarks",
            methods: ["getTree", "get", "getChildren", "getSubTree", "search", "create", "move", "update", "remove", "removeTree"],
            events: ["onCreated", "onRemoved", "onChanged", "onMoved"]
        ),
        Namespace(
            "downloads",
            methods: ["search", "download", "pause", "resume", "cancel", "erase", "open", "show", "removeFile", "showDefaultFolder"],
            events: ["onCreated", "onChanged", "onErased"]
        ),
        Namespace(
            "history",
            methods: ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
            events: ["onVisited", "onVisitRemoved"]
        ),
        Namespace(
            "sessions",
            methods: ["getRecentlyClosed", "getDevices", "restore"],
            events: ["onChanged"],
            constants: ["MAX_SESSION_RESULTS"]
        ),
        Namespace("search", methods: ["query"]),
        Namespace(
            "management",
            methods: ["getAll", "get", "getSelf", "getPermissionWarningsById", "getPermissionWarningsByManifest", "setEnabled", "uninstall", "uninstallSelf"],
            events: ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"],
            ungatedMethods: ["getSelf", "uninstallSelf", "getPermissionWarningsByManifest"],
            constants: ["ExtensionDisabledReason", "ExtensionInstallType", "ExtensionType", "LaunchType"]
        ),
        Namespace(
            "idle",
            methods: ["queryState", "setDetectionInterval"],
            events: ["onStateChanged"],
            constants: ["IdleState"]
        ),
        Namespace("power", methods: ["requestKeepAwake", "releaseKeepAwake"], constants: ["Level"]),
        Namespace(
            "offscreen",
            methods: ["createDocument", "closeDocument", "hasDocument"],
            constants: ["Reason"]
        ),
        Namespace("system.cpu", methods: ["getInfo"]),
        Namespace("system.memory", methods: ["getInfo"]),
        Namespace("system.display", methods: ["getInfo", "getDisplayLayout"], events: ["onDisplayChanged"]),
        Namespace(
            "system.storage",
            methods: ["getInfo", "ejectDevice", "getAvailableCapacity"],
            events: ["onAttached", "onDetached"],
            constants: ["EjectDeviceResultCode", "StorageUnitType"]
        ),
    ]

    /// Permissions the wrapper reads from the manifest, beyond the one each namespace is named after.
    static let additionalWrappedPermissions = ["privacy", "downloads.open", "webRequestAuthProvider"]

    /// Every permission the wrapper acts on; a manifest naming none of them gets no wrapper namespace.
    static let wrappedPermissions: Set<String> = Set(namespaces.map(\.name)).union(additionalWrappedPermissions)

    /// The permissions WKWebExtension itself recognises (WKWebExtensionPermission.h); everything else is the wrapper's or ignored.
    static let webKitNativePermissions: Set<String> = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
        "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging",
        "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest",
    ]

    /// chrome.privacy.services.searchSuggestEnabled is the only setting the wrapper backs.
    static let privacySettings = ["services.searchSuggestEnabled"]

    static let augmentations: [Augmentation] = [
        Augmentation("tabs", events: ["onCreated", "onUpdated", "onMoved", "onActivated", "onRemoved", "onReplaced"]),
        Augmentation(
            "runtime",
            events: ["onInstalled", "onStartup", "onSuspend", "onSuspendCanceled", "onUpdateAvailable", "onConnect"]
        ),
        Augmentation("commands", functions: ["getAll"], events: ["onCommand"]),
        Augmentation(
            "webNavigation",
            events: [
                "onBeforeNavigate", "onCommitted", "onDOMContentLoaded", "onCompleted", "onErrorOccurred",
                "onCreatedNavigationTarget", "onReferenceFragmentUpdated", "onTabReplaced", "onHistoryStateUpdated",
            ]
        ),
        Augmentation(
            "webRequest",
            events: [
                "onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired",
                "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred",
            ]
        ),
        Augmentation("cookies", events: ["onChanged"]),
        Augmentation("permissions", events: ["onAdded", "onRemoved"]),
        Augmentation("scripting", properties: ["ExecutionWorld"]),
        Augmentation(
            "storage",
            properties: ["managed", "sync.QUOTA_BYTES", "sync.QUOTA_BYTES_PER_ITEM", "sync.MAX_ITEMS",
                         "sync.MAX_WRITE_OPERATIONS_PER_HOUR", "sync.MAX_WRITE_OPERATIONS_PER_MINUTE"]
        ),
    ]

    /// Namespaces WebKit supplies itself. The runtime reflection suite proves each is reachable.
    static let webKitNativeNamespaces: [String] = [
        "action", "alarms", "commands", "contextMenus", "cookies", "declarativeNetRequest", "i18n",
        "permissions", "runtime", "scripting", "storage", "tabs", "webNavigation", "webRequest", "windows",
    ]

    /// Things no wrapper can supply because WebKit exposes no hook for them.
    static let impossibleOnWebKit: [String: String] = [
        "webRequest.blocking": "WebKit gives extensions no request interception: a blocking webRequest listener cannot cancel, redirect or rewrite a load. Blocking is only possible through declarativeNetRequest and Orbit's content rule lists, plus the wrapper's own onAuthRequired provider.",
        "debugger": "WebKit has no public remote debugging protocol an extension could drive.",
        "pageCapture": "WebKit can archive a page as .webarchive but has no MHTML writer.",
        "processes": "WebKit exposes no public per-renderer process information.",
    ]

    // MARK: - JavaScript tables

    /// The wrapper's `NAMESPACES` declaration, generated from `namespaces`.
    static let namespacesDeclaration: String = declaration(
        "NAMESPACES", entries: namespaces.map { ($0.name, $0.methods) }
    )

    /// The wrapper's `UNGATED` declaration.
    static let ungatedDeclaration: String = declaration(
        "UNGATED", entries: namespaces.filter { !$0.ungatedMethods.isEmpty }.map { ($0.name, $0.ungatedMethods) }
    )

    /// The wrapper's `EVENTS` declaration.
    static let eventsDeclaration: String = declaration(
        "EVENTS", entries: namespaces.filter { !$0.events.isEmpty }.map { ($0.name, $0.events) }
    )

    private static func declaration(_ name: String, entries: [(String, [String])]) -> String {
        let rows = entries.map { key, members -> String in
            let quotedKey = key.contains(".") ? JavaScriptLiteral.string(key) : key
            return "  \(quotedKey): [\(members.map { JavaScriptLiteral.string($0) }.joined(separator: ", "))]"
        }
        return "var \(name) = {\n\(rows.joined(separator: ",\n"))\n};"
    }
}
