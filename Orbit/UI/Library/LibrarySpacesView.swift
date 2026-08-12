import SwiftUI

struct LibrarySpacesView: View {
    var searchQuery: String

    var body: some View {
        // ScrollView must stay here, not inside ManageSpacesColumnsView: ImageRenderer cannot rasterise a ScrollView.
        ScrollView(.horizontal) {
            ManageSpacesColumnsView(
                searchQuery: searchQuery,
                onAddSpace: { ManageSpacesAddSpaceAction.perform() }
            )
            .padding(.horizontal, LibraryMetrics.contentHorizontalPadding)
            .padding(.bottom, LibraryMetrics.contentHorizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
