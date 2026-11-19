import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens a link dropped on the tab list as a new tab. It validates only when the drag pasteboard holds a link, so it never competes with the sidebar's own row drags.
@MainActor
struct SidebarLinkDropDelegate: DropDelegate {
    var environment: AppEnvironment
    var spaceID: SpaceID

    private var payload: LinkDropPayload? {
        guard !SidebarDragSession.hasInFlightDrag else { return nil }
        return LinkDropLogic.payload(from: NSPasteboard(name: .drag))
    }

    func validateDrop(info: DropInfo) -> Bool { payload != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: payload == nil ? .cancel : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload else { return false }
        LinkDropAction.openInNewTab(payload.url, in: spaceID, environment: environment)
        return true
    }
}

extension View {
    func sidebarLinkDropDestination(environment: AppEnvironment, spaceID: SpaceID) -> some View {
        modifier(SidebarLinkDropDestination(environment: environment, spaceID: spaceID))
    }
}

private struct SidebarLinkDropDestination: ViewModifier {
    var environment: AppEnvironment
    var spaceID: SpaceID

    #if DEBUG
    // ImageRenderer paints a drop destination as an artifact over the section, so render tests switch it off, as they do for the sidebar's own drag and drop.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            content
        } else {
            destination(content)
        }
        #else
        destination(content)
        #endif
    }

    private func destination(_ content: Content) -> some View {
        content.onDrop(
            of: [.url, .fileURL, .plainText],
            delegate: SidebarLinkDropDelegate(environment: environment, spaceID: spaceID)
        )
    }
}
