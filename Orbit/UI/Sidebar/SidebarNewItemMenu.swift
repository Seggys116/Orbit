import AppKit

enum SidebarNewItemOption: CaseIterable {
    case newTab, newSplitView, newFolder, newSpace, newNote, newEasel, newBoost

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newSplitView: "New Split View"
        case .newFolder: "New Folder"
        case .newSpace: "New Space"
        case .newNote: "New Note"
        case .newEasel: "New Easel"
        case .newBoost: "New Boost"
        }
    }

    @MainActor
    func perform(in env: AppEnvironment) {
        switch self {
        case .newTab:
            env.perform(.newTabCommandBar)
        case .newSplitView:
            env.perform(.addSplit)
        case .newFolder:
            if let spaceID = env.activeSpace?.id { env.createFolder(name: "New Folder", in: spaceID) }
        case .newSpace:
            NotificationCenter.default.post(name: .orbitPresentNewSpaceFlow, object: nil)
        case .newNote:
            env.perform(.newNote)
        case .newEasel:
            env.perform(.newEasel)
        case .newBoost:
            if let host = env.activeTab?.url.host() {
                NotificationCenter.default.post(name: .orbitPresentBoostsEditor, object: host)
            }
        }
    }
}
