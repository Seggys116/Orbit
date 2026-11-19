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
        onDrop(
            of: [.url, .fileURL, .plainText],
            delegate: SidebarLinkDropDelegate(environment: environment, spaceID: spaceID)
        )
    }
}
