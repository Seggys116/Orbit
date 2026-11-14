import SwiftUI

struct LibrarySpacesView: View {
    var searchQuery: String

    var body: some View {
        ScrollView(.horizontal) {
            ManageSpacesColumnsView(
                searchQuery: searchQuery,
                onAddSpace: { ManageSpacesAddSpaceAction.perform() }
            )
            .padding(.horizontal, LibraryModeMetrics.contentPadding)
            .padding(.bottom, LibraryModeMetrics.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
