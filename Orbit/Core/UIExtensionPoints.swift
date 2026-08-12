import SwiftUI

@MainActor
@Observable
final class UIExtensionPoints {

    // MARK: Boosts

    var boostsEditor: ((_ host: String) -> AnyView)?

    // MARK: Easel

    var easelCanvas: ((_ easelID: UUID) -> AnyView)?

    // MARK: Notes

    var notesEditor: ((_ noteID: UUID) -> AnyView)?

    // MARK: Peek

    var peekPanel: ((_ sourceTabID: TabID, _ url: URL) -> AnyView)?

    // MARK: Little Orbit

    /// nil renders a plain web-content card.
    var littleOrbitBody: ((_ tabID: TabID) -> AnyView)?

    // MARK: Library

    /// nil per section falls back to the Library's own built-in pane.
    var librarySection: ((_ section: LibrarySection) -> AnyView?)?

    // MARK: Picture-in-Picture

    var requestPictureInPicture: ((_ tabID: TabID) -> Bool)?

    var dismissPictureInPicture: ((_ tabID: TabID) -> Void)?

    // MARK: Capture tool

    var presentCaptureTool: ((_ tabID: TabID, _ fullPage: Bool) -> Void)?

    // MARK: Ask on Page

    var askOnPage: ((_ tabID: TabID, _ query: String) -> Void)?

    init() {}
}

enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case media = "Media"
    case downloads = "Downloads"
    case easelsAndNotes = "Easels & Notes"
    case spaces = "Spaces"
    case boosts = "Boosts"
    case archivedTabs = "Archived Tabs"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .media: return "play.circle"
        case .downloads: return "arrow.down.circle"
        case .easelsAndNotes: return "note.text"
        case .spaces: return "square.grid.2x2"
        case .boosts: return "bolt.circle"
        case .archivedTabs: return "archivebox"
        }
    }
}
