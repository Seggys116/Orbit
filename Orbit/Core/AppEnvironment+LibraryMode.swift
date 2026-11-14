import AppKit
import SwiftUI

enum LibraryModeLayout {
    static let baseWidth: CGFloat = 340
    static let spacesWidth: CGFloat = OrbitMetrics.sidebarMaxWidth

    static func targetWidth(for section: LibrarySection) -> CGFloat {
        section == .spaces ? spacesWidth : baseWidth
    }

    /// Never narrower than the width the user chose, so entering Library mode cannot shrink the sidebar.
    static func width(for section: LibrarySection, userWidth: CGFloat) -> CGFloat {
        max(userWidth, targetWidth(for: section))
    }

    /// Outside Library mode this is exactly the user's width, so exit restores it with no stored copy.
    static func effectiveWidth(isLibraryMode: Bool, section: LibrarySection, userWidth: CGFloat) -> CGFloat {
        isLibraryMode ? width(for: section, userWidth: userWidth) : userWidth
    }
}

enum LibraryEscapeAction: Equatable {
    case ignore
    case clearSearch
    case closeDetail
    case exitLibrary

    /// An open menu, sheet or Command Bar owns Escape; otherwise it unwinds search, then detail, then the Library.
    static func resolve(
        isForegroundWindow: Bool,
        isOverlayPresented: Bool,
        hasSearchText: Bool,
        hasDetail: Bool,
        firstResponderOwnsEscape: Bool = false
    ) -> LibraryEscapeAction {
        guard isForegroundWindow, !isOverlayPresented, !firstResponderOwnsEscape else { return .ignore }
        if hasSearchText { return .clearSearch }
        if hasDetail { return .closeDetail }
        return .exitLibrary
    }
}

// Keyed weakly by the environment so a closed window's router goes with it.
@MainActor
private enum LibraryRouterRegistry {
    private static let routers = NSMapTable<AppEnvironment, LibraryRouter>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory
    )

    static func router(for env: AppEnvironment) -> LibraryRouter {
        if let existing = routers.object(forKey: env) { return existing }
        let created = LibraryRouter()
        routers.setObject(created, forKey: env)
        return created
    }
}

@MainActor
extension AppEnvironment {
    var libraryRouter: LibraryRouter { LibraryRouterRegistry.router(for: self) }

    var isLibraryMode: Bool { libraryRouter.isActive }

    var effectiveSidebarWidth: CGFloat {
        let router = libraryRouter
        return LibraryModeLayout.effectiveWidth(
            isLibraryMode: router.isActive,
            section: router.selectedSection,
            userWidth: sidebarWidth
        )
    }

    func openLibrary(section: LibrarySection? = nil) {
        let router = libraryRouter
        withOrbitAnimation(OrbitMotion.standard) {
            if let section { router.selectedSection = section }
            guard !router.isActive else { return }
            if !isSidebarVisible {
                router.didUnhideSidebar = true
                isSidebarVisible = true
            }
            router.isActive = true
        }
    }

    static func openLibraryInFrontmostWindow(section: LibrarySection? = nil) {
        _ = OrbitWindowController.activateBrowserWindow()
        frontmost.openLibrary(section: section)
    }

    func closeLibrary() {
        let router = libraryRouter
        guard router.isActive else { return }
        withOrbitAnimation(OrbitMotion.standard) {
            router.isActive = false
            router.selection = nil
            router.searchQuery = ""
            if router.didUnhideSidebar {
                router.didUnhideSidebar = false
                isSidebarVisible = false
            }
        }
    }

    func toggleLibrary(section: LibrarySection? = nil) {
        if isLibraryMode, section == nil || section == libraryRouter.selectedSection {
            closeLibrary()
        } else {
            openLibrary(section: section)
        }
    }

    /// Returns whether Escape was consumed so the key path can pass it on otherwise.
    @discardableResult
    func handleLibraryEscape(
        isForegroundWindow: Bool = true,
        isOverlayPresented: Bool = false,
        firstResponderOwnsEscape: Bool = false
    ) -> Bool {
        let router = libraryRouter
        guard router.isActive else { return false }
        switch LibraryEscapeAction.resolve(
            isForegroundWindow: isForegroundWindow,
            isOverlayPresented: isOverlayPresented,
            hasSearchText: !router.searchQuery.isEmpty,
            hasDetail: router.selection != nil,
            firstResponderOwnsEscape: firstResponderOwnsEscape
        ) {
        case .ignore:
            return false
        case .clearSearch:
            withOrbitAnimation(OrbitMotion.quick) { router.searchQuery = "" }
        case .closeDetail:
            withOrbitAnimation(OrbitMotion.standard) { router.selection = nil }
        case .exitLibrary:
            closeLibrary()
        }
        return true
    }

    func libraryModeSidebarWasHidden() {
        let router = libraryRouter
        guard router.isActive else { return }
        router.didUnhideSidebar = false
        router.isActive = false
        router.selection = nil
        router.searchQuery = ""
    }
}
