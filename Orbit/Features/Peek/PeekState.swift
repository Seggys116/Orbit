import SwiftUI

// Split out of PeekPanelView.swift: TabRowView reads this and is reused into the
// host-less OrbitTests bundle, which cannot also pull in AppEnvironment.
@MainActor
@Observable
final class PeekState {
    static let shared = PeekState()
    private init() {}

    struct ActivePreview: Identifiable, Equatable {
        var id: UUID { sourceTabID }
        var sourceTabID: TabID
        var url: URL
    }

    var activePreview: ActivePreview?

    // Also the ownership flag: clear before promoting, or teardown() closes the just-promoted tab.
    var previewTabID: TabID?

    func present(sourceTabID: TabID, url: URL) {
        activePreview = ActivePreview(sourceTabID: sourceTabID, url: url)
    }

    func dismiss() {
        activePreview = nil
    }
}
