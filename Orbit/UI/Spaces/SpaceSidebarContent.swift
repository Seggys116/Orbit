import SwiftUI

struct SpaceSidebarContent: View {
    var space: Space

    var body: some View {
        SidebarView(paintsOwnBackground: false, space: space)
    }
}
