import AppKit
import Foundation

// MARK: - Selection

enum LibrarySelection: Equatable, Hashable {
    case download(UUID)
    case archivedTab(TabID)
    case boostHost(String)
    case note(UUID)
    case easel(UUID)
    case media(TabID)

    var section: LibrarySection {
        switch self {
        case .download: return .downloads
        case .archivedTab: return .archivedTabs
        case .boostHost: return .boosts
        case .note, .easel: return .easelsAndNotes
        case .media: return .media
        }
    }
}

// MARK: - Which sections get a preview column at all

extension LibrarySection {
    // .spaces deliberately has no preview column (guarded by test).
    var supportsPreview: Bool {
        switch self {
        case .media, .downloads, .easelsAndNotes, .boosts, .archivedTabs:
            return true
        case .spaces:
            return false
        }
    }

    var rendersItsOwnScrolling: Bool {
        switch self {
        case .spaces:
            return true
        case .media, .downloads, .easelsAndNotes, .boosts, .archivedTabs:
            return false
        }
    }
}

// MARK: - Resolved preview content

enum LibraryPreviewContent: Equatable {
    case file(URL)
    case liveWeb(URL)
    case note(NSAttributedString)
    case easel([EaselItem])
    case media(TabID, MediaState)
    case none

    @MainActor
    static func resolve(_ selection: LibrarySelection?, env: AppEnvironment) -> LibraryPreviewContent {
        guard let selection else { return .none }

        switch selection {
        case .download(let id):
            guard let item = env.downloads.first(where: { $0.id == id }),
                  item.state == .completed,
                  env.downloadStore.fileStillExists(id)
            else { return .none }
            return .file(item.destinationURL)

        case .archivedTab(let id):
            guard let tab = env.tab(id), tab.section == .archived else { return .none }
            return .liveWeb(tab.url)

        case .boostHost(let host):
            guard env.boostStore.boosts.contains(where: { $0.host == host }),
                  let url = URL(string: "https://\(host)")
            else { return .none }
            return .liveWeb(url)

        case .note(let id):
            guard let note = env.noteStore.note(id),
                  let body = NotesEditorView.decode(note.bodyData),
                  !body.string.isEmpty
            else { return .none }
            return .note(body)

        case .easel(let id):
            guard let easel = env.easelStore.easel(id), !easel.items.isEmpty else { return .none }
            return .easel(easel.items)

        case .media(let tabID):
            guard let state = env.mediaStates[tabID], env.tab(tabID) != nil else { return .none }
            return .media(tabID, state)
        }
    }

    var liveWebURL: URL? {
        if case .liveWeb(let url) = self { return url }
        return nil
    }
}

// MARK: - Live web preview lifecycle

@MainActor
@Observable
final class LibraryLiveWebSession {
    private(set) var tabID: TabID?
    private(set) var currentURL: URL?

    private let open: (URL) -> TabID
    private let close: (TabID) -> Void

    init(open: @escaping (URL) -> TabID, close: @escaping (TabID) -> Void) {
        self.open = open
        self.close = close
    }

    func show(_ url: URL?) {
        if let url, url == currentURL, tabID != nil { return }

        if let existing = tabID {
            close(existing)
            tabID = nil
            currentURL = nil
        }

        guard let url else { return }
        tabID = open(url)
        currentURL = url
    }

    func teardown() {
        show(nil)
    }
}
