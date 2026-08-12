import AppKit
import Foundation

// Incognito and torn-off sessions are window-scoped AppEnvironments over an ephemeral
// Space/Profile they own; a standard session wraps the shared one and owns nothing.
@MainActor
final class WindowSession {

    enum Kind {
        case standard
        case incognito
        case tornOff
    }

    let kind: Kind

    let environment: AppEnvironment

    // Always AppEnvironment.shared in the running app; dispose() removes this
    // session's entities from here.
    private let root: AppEnvironment

    // nil for a standard session, which owns nothing and must never delete anything.
    private let ownedSpaceID: SpaceID?
    private let ownedProfileID: ProfileID?

    private(set) var isDisposed = false

    var isIncognito: Bool { kind == .incognito }
    var isTornOff: Bool { kind == .tornOff }

    private init(
        kind: Kind,
        environment: AppEnvironment,
        root: AppEnvironment,
        ownedSpaceID: SpaceID?,
        ownedProfileID: ProfileID?
    ) {
        self.kind = kind
        self.environment = environment
        self.root = root
        self.ownedSpaceID = ownedSpaceID
        self.ownedProfileID = ownedProfileID
    }

    // MARK: - Standard

    static func standard(on host: AppEnvironment = .processRoot) -> WindowSession {
        let root = host.rootEnvironment
        return WindowSession(
            kind: .standard,
            environment: root,
            root: root,
            ownedSpaceID: nil,
            ownedProfileID: nil
        )
    }

    // MARK: - Incognito

    static var incognitoTheme: SpaceTheme {
        SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.13)],
            grain: 0.4,
            prefersDarkContent: true
        )
    }

    // Must pass activate: false (default would yank every open window onto this Space) and root on host.rootEnvironment (not a window that might close first).
    static func incognito(on host: AppEnvironment) -> WindowSession {
        let root = host.rootEnvironment

        let profile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        root.state.profiles.append(profile)

        let spaceID = root.store.createSpace(
            name: "Incognito",
            icon: "eyeglasses",
            iconIsEmoji: false,
            theme: WindowSession.incognitoTheme,
            profileID: profile.id,
            activate: false
        )

        let environment = AppEnvironment.makeWindowScoped(sharing: root, activeSpaceID: spaceID)
        // Pushed here, not from OrbitWindowController.configure(): a window-scoped environment
        // is 1:1 with this window for its whole life, with no construction-order dependency on it.
        OrbitChromiumTabsBridge.shared.windowCreated(owner: environment, focused: false)
        // extensionPoints is per-environment; without this an Incognito window would
        // silently lose Peek, Capture, Boosts, Easels, Notes, Library and Media.
        FeatureRegistration.installAll(into: environment)

        return WindowSession(
            kind: .incognito,
            environment: environment,
            root: root,
            ownedSpaceID: spaceID,
            ownedProfileID: profile.id
        )
    }

    // MARK: - Torn off

    // Reuses the origin tab's own Profile (unlike incognito(on:), which mints one) so a
    // tab torn off stays logged in — only the Space is new and ephemeral.
    static func tornOff(on host: AppEnvironment, adopting tabID: TabID) -> WindowSession? {
        let root = host.rootEnvironment
        guard let tab = root.store.tab(tabID), let originSpace = root.store.space(tab.spaceID) else { return nil }

        let originProfile = root.store.profile(originSpace.profileID)
        let isOriginPrivate = originProfile.map { OrbitState.isEphemeral($0) } ?? originSpace.isEphemeral

        let resolvedProfileID: ProfileID
        let ownedProfileID: ProfileID?
        if isOriginPrivate {
            // Must own a fresh Profile here, or the origin window closing deletes the shared one and silently de-privatises this window.
            let privateProfile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
            root.state.profiles.append(privateProfile)
            resolvedProfileID = privateProfile.id
            ownedProfileID = privateProfile.id
        } else {
            resolvedProfileID = originSpace.profileID
            ownedProfileID = nil
        }

        let spaceID = root.store.createSpace(
            name: tab.displayTitle,
            iconOverride: originSpace.resolvedIcon,
            theme: originSpace.theme,
            profileID: resolvedProfileID,
            activate: false
        )
        // createSpace derives Space.ephemeral from whether the resolved Profile is
        // persistent, which is backwards for the reused-Profile branch; force it on.
        root.store.mutateSpace(spaceID) { $0.ephemeral = true }

        let isPinnedTab = tab.section == .pinned
        let environment: AppEnvironment
        if isPinnedTab {
            // Must leave the pinned row in place, not moveTab it, or the bookmark is permanently removed from the origin Space's Pinned tree.
            host.closeTabKeepingBookmark(tabID)
            environment = AppEnvironment.makeWindowScoped(sharing: root, activeSpaceID: spaceID, isTornOff: true)
            // See incognito(on:)'s own comment -- pushed before the tab open
            // below, whose materialization otherwise needs a window already registered.
            OrbitChromiumTabsBridge.shared.windowCreated(owner: environment, focused: false)
            FeatureRegistration.installAll(into: environment)
            environment.openTab(url: tab.pinnedURL ?? tab.url, in: spaceID)
        } else {
            environment = AppEnvironment.makeWindowScoped(sharing: root, activeSpaceID: spaceID, isTornOff: true)
            OrbitChromiumTabsBridge.shared.windowCreated(owner: environment, focused: false)
            FeatureRegistration.installAll(into: environment)

            root.store.moveTab(tabID, toSpace: spaceID, section: .today)

            // host, not root: the origin tab's live renderer lives in whichever environment's
            // own webContents map actually holds it, which for a tab dragged out of an
            // Incognito or another torn-off window is that window's own private map.
            environment.adoptWebContents(for: tabID, from: host)
            environment.activateTab(tabID)
        }

        return WindowSession(
            kind: .tornOff,
            environment: environment,
            root: root,
            ownedSpaceID: spaceID,
            ownedProfileID: ownedProfileID
        )
    }

    // MARK: - Disposal

    // disposeWindowSession() must run first, while the tabs are still in the document, before deleteSpace/deleteProfile remove what this session created.
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        guard kind == .incognito || kind == .tornOff else { return }

        // Tabs first (disposeWindowSession releases every WebContents), window second: mirrors
        // real teardown order, so OrbitTabRegistry never sees a tab referencing a dead window id.
        environment.disposeWindowSession()
        OrbitChromiumTabsBridge.shared.windowRemoved(owner: environment)

        guard let ownedSpaceID else { return }
        root.store.deleteSpace(ownedSpaceID)
        if let ownedProfileID {
            _ = root.store.deleteProfile(ownedProfileID)
        }
    }
}
