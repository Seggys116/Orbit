import Foundation
import Observation

@MainActor
@Observable
final class LibraryRouter {
    var isActive = false

    var searchQuery = ""

    var selection: LibrarySelection?

    var selectedSection: LibrarySection = .downloads {
        didSet {
            guard oldValue != selectedSection else { return }
            // Selection and search are section-scoped: a stale id must not resolve in another section.
            selection = nil
            searchQuery = ""
        }
    }

    @ObservationIgnored var didUnhideSidebar = false

    func select(_ newSelection: LibrarySelection) {
        selection = newSelection
    }

    func clearSelection() {
        selection = nil
    }

    init() {}
}
