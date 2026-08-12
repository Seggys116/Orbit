import AppKit

private final class SidebarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }
}

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

    @MainActor
    static func buildNSMenu(in env: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in allCases {
            menu.addItem(SidebarMenuItem(title: option.title) { option.perform(in: env) })
        }
        return menu
    }
}
