import SwiftUI

// MARK: - Presenter

@MainActor
@Observable
class SidebarToastPresenter {

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var body: String
    }

    private(set) var message: Message?

    // nonisolated so it can be a default argument: a default argument expression is evaluated outside the callee's isolation, and a main-actor-isolated constant used as one is an error under Swift 6.
    nonisolated static let defaultDuration: TimeInterval = 6

    let duration: TimeInterval

    // Boxed: a bare @MainActor () -> Void parameter of a closure literal is non-escaping, so a test's schedule could not store it to run later.
    struct Dismissal {
        let run: @MainActor () -> Void
    }

    private let schedule: ((TimeInterval, Dismissal) -> Void)?

    private var generation = 0

    init(
        duration: TimeInterval = SidebarToastPresenter.defaultDuration,
        schedule: ((TimeInterval, Dismissal) -> Void)? = nil
    ) {
        self.duration = duration
        self.schedule = schedule
    }

    private func scheduleDismissal(_ work: @MainActor @escaping () -> Void) {
        if let schedule {
            schedule(duration, Dismissal(run: work))
            return
        }
        let delay = duration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            work()
        }
    }

    func present(title: String, body: String) {
        generation += 1
        let token = generation
        message = Message(title: title, body: body)
        scheduleDismissal { [weak self] in
            guard let self, self.generation == token else { return }
            self.message = nil
        }
    }

    func dismiss() {
        generation += 1
        message = nil
    }
}

// MARK: - The overlay

@MainActor
struct SidebarToastView: View {
    var theme: SpaceTheme
    var presenter: SidebarToastPresenter

    var body: some View {
        if let message = presenter.message {
            VStack(alignment: .leading, spacing: OrbitMetrics.sidebarPinnedSlashSpacing) {
                Text(message.title)
                    .font(OrbitFont.sidebarRowActive)
                    .foregroundStyle(theme.readableForeground)
                Text(message.body)
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize))
                    .foregroundStyle(theme.readableSecondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(OrbitMetrics.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(theme.primary.nsColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: OrbitMetrics.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                theme.readableForeground.opacity(OrbitMetrics.cardBorderOpacity),
                                lineWidth: OrbitMetrics.cardBorderWidth
                            )
                    )
            )
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.bottom, OrbitMetrics.sidebarInterSectionGap)
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.title). \(message.body)")
            .transition(.opacity)
        }
    }
}

// MARK: - Favorites toast

enum FavoritesToastCopy {
    static let alreadyFavoriteTitle = "Already in Favorites"
    static let alreadyFavoriteBody = "This page is already a favorite in this Space."
    static let atCapacityTitle = "Favorites Is Full"
    static let atCapacityBody = "Remove a favorite to add another — Favorites holds up to \(OrbitMetrics.favoritesMaximumCount) per Space."
}

// SidebarToastPresenter's stored properties are plain, not @Observable-tracked (only the superclass carries that macro), so a property added on a subclass would silently not participate in SwiftUI's observation.
@MainActor
final class FavoritesToastPresenter: SidebarToastPresenter {

    static let shared = FavoritesToastPresenter()

    func announceAlreadyFavorite() {
        present(title: FavoritesToastCopy.alreadyFavoriteTitle, body: FavoritesToastCopy.alreadyFavoriteBody)
    }

    func announceAtCapacity() {
        present(title: FavoritesToastCopy.atCapacityTitle, body: FavoritesToastCopy.atCapacityBody)
    }
}

// MARK: - Persistence toast

enum PersistenceToastCopy {
    static let saveFailedTitle = "Couldn't Save Changes"
    static let saveFailedBody = "Orbit couldn't write your latest changes to disk. They're still open in this window — check available disk space and try again."
}

@MainActor
final class PersistenceToastPresenter: SidebarToastPresenter {

    static let shared = PersistenceToastPresenter()

    func announceSaveFailed() {
        present(title: PersistenceToastCopy.saveFailedTitle, body: PersistenceToastCopy.saveFailedBody)
    }
}

extension View {
    @MainActor
    func persistenceFailureToast(theme: SpaceTheme) -> some View {
        overlay(alignment: .bottom) {
            SidebarToastView(theme: theme, presenter: PersistenceToastPresenter.shared)
        }
    }
}
