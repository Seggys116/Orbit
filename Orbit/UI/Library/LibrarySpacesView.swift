import SwiftUI

struct LibrarySpacesView: View {
    @Environment(AppEnvironment.self) private var env

    var searchQuery: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ManageSpacesColumnsView(
                    searchQuery: searchQuery,
                    onAddSpace: { ManageSpacesAddSpaceAction.perform() }
                )
                .padding(.horizontal, LibraryModeMetrics.contentPadding)
                .padding(.bottom, LibraryModeMetrics.contentPadding)
            }
            // Opens centred on the Space being used, so it is never off-screen to one side of a long row of Spaces. Waits one turn so the columns have been laid out before it scrolls to one.
            .task {
                await Task.yield()
                centreActiveSpace(in: proxy)
            }
            .onChange(of: env.activeSpace?.id) { _, _ in centreActiveSpace(in: proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func centreActiveSpace(in proxy: ScrollViewProxy) {
        guard let activeID = env.activeSpace?.id else { return }
        withOrbitAnimation(OrbitMotion.standard) {
            proxy.scrollTo(activeID, anchor: .center)
        }
    }
}
