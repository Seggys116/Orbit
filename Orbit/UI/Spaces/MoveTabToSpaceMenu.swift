import Foundation

enum MoveTabToSpaceMenu {
    @MainActor
    static func entry(tabID: TabID, in env: AppEnvironment) -> OrbitContextMenuEntry {
        let currentSpaceID = env.tab(tabID)?.spaceID
        let targets = env.spaces.filter { $0.id != currentSpaceID }
        return .item(OrbitContextMenuItem(
            title: "Move to Space",
            systemImage: "arrow.right.square",
            isEnabled: !targets.isEmpty,
            submenu: targets.map { space -> OrbitContextMenuEntry in
                .item(OrbitContextMenuItem(title: space.name, submenu: [
                    .item(OrbitContextMenuItem(title: "Pinned", systemImage: "pin") {
                        env.moveTab(tabID, toSpace: space.id, section: .pinned)
                    }),
                    .item(OrbitContextMenuItem(title: "Today", systemImage: "sun.max") {
                        env.moveTab(tabID, toSpace: space.id, section: .today)
                    }),
                ]))
            }
        ))
    }
}
