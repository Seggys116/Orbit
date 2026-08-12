import SwiftUI

// MARK: - Presenter

@MainActor
final class GitHubLiveFolderToastPresenter: SidebarToastPresenter {

    static let shared = GitHubLiveFolderToastPresenter()

    typealias Dismissal = SidebarToastPresenter.Dismissal

    func announceLiveFolderCreated() {
        present(title: GitHubLiveFolderCopy.toastTitle, body: GitHubLiveFolderCopy.toastBody)
    }
}

// MARK: - The overlay

@MainActor
struct GitHubLiveFolderToastView: View {
    var theme: SpaceTheme
    var presenter: GitHubLiveFolderToastPresenter = .shared

    var body: some View {
        SidebarToastView(theme: theme, presenter: presenter)
    }
}

// MARK: - Activation watching

private struct GitHubLiveFolderActivation: Equatable {
    var spaceID: SpaceID
    var isEnabled: Bool
}

extension View {
    // presenter has no default: a default argument is evaluated outside the callee's isolation, so `= .shared` on this main-actor singleton would be a concurrency error under Swift 6.
    @MainActor
    func gitHubLiveFolderToast(
        for space: Space,
        theme: SpaceTheme,
        presenter: GitHubLiveFolderToastPresenter
    ) -> some View {
        let activation = GitHubLiveFolderActivation(
            spaceID: space.id,
            isEnabled: space.githubLiveFolder?.isEnabled ?? false
        )
        return self
            .overlay(alignment: .bottom) {
                GitHubLiveFolderToastView(theme: theme, presenter: presenter)
            }
            .onChange(of: activation) { previous, current in
                guard previous.spaceID == current.spaceID else { return }
                guard !previous.isEnabled, current.isEnabled else { return }
                withAnimation(OrbitMotion.quick) {
                    presenter.announceLiveFolderCreated()
                }
            }
    }
}
