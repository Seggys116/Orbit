import SwiftUI

struct SplitPaneCloseControl: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab
    var foreground: Color

    static func isApplicable(to tab: Tab, in env: AppEnvironment) -> Bool {
        env.splitGroup(for: tab.id) != nil
    }

    var body: some View {
        if Self.isApplicable(to: tab, in: env) {
            // OrbitNSActionButton: only mechanism proven to receive clicks inside the window's titlebar band.
            OrbitNSActionButton(action: { env.closeSplitPane(tab.id) }) {
                ToolbarTrailingGlyph.splitClose
                    .foregroundStyle(foreground)
            }
            .orbitTooltip("Close This Pane")
        }
    }
}
