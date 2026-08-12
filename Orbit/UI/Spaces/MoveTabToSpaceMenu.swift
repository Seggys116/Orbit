import SwiftUI

struct MoveTabToSpaceMenu: View {
    @Environment(AppEnvironment.self) private var env
    var tabID: TabID
    var currentSection: TabSection

    var body: some View {
        Menu("Move to Space") {
            ForEach(env.spaces) { space in
                if space.id != env.tab(tabID)?.spaceID {
                    Menu(space.name) {
                        Button("Pinned") { env.moveTab(tabID, toSpace: space.id, section: .pinned) }
                        Button("Today") { env.moveTab(tabID, toSpace: space.id, section: .today) }
                    }
                }
            }
        }
    }
}
