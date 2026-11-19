import SwiftUI

#if DEBUG
/// Which rows the sidebar has actually put on screen, and which tabs each one holds. A split group must appear as one row holding both panes, and neither pane as a row of its own.
@MainActor
enum SidebarRowProbe {
    static var rows: [String: [TabID]] = [:]

    static func reset() { rows = [:] }

    /// Rows that hold more than one tab: the joined cells.
    static var joinedRows: [[TabID]] { rows.values.filter { $0.count > 1 } }

    /// Tabs that have a row of their own.
    static var tabsWithTheirOwnRow: Set<TabID> {
        Set(rows.values.filter { $0.count == 1 }.compactMap(\.first))
    }
}
#endif

extension View {
    /// Records the row in `SidebarRowProbe` while it is on screen. Does nothing in a release build.
    func sidebarRowProbe(id: String, tabs: [TabID]) -> some View {
        #if DEBUG
        return self
            .onAppear { SidebarRowProbe.rows[id] = tabs }
            .onChange(of: tabs) { _, current in SidebarRowProbe.rows[id] = current }
            .onDisappear { SidebarRowProbe.rows[id] = nil }
        #else
        return self
        #endif
    }
}
