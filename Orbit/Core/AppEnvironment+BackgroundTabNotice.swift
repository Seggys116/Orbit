import Foundation

/// A tab the user just opened in the background, offered back to them as a small notice.
struct BackgroundTabNotice: Identifiable, Equatable {
    let id = UUID()
    var tabID: TabID
}

extension AppEnvironment {

    /// How long the notice stays up before it dismisses itself.
    nonisolated static let backgroundTabNoticeDuration: TimeInterval = 5

    /// The notice to show now. It is hidden once its tab is closed or already on screen, so it never offers a tab the user is looking at.
    var visibleBackgroundTabNotice: BackgroundTabNotice? {
        guard let notice = backgroundTabNotice, isOpenForNotice(notice.tabID) else { return nil }
        guard !PiPController.isOnScreen(notice.tabID, env: self) else { return nil }
        return notice
    }

    /// Tells the user a link opened in a new background tab, with a way to go to it.
    func announceBackgroundTab(_ tabID: TabID) {
        backgroundTabNoticeGeneration += 1
        let token = backgroundTabNoticeGeneration
        backgroundTabNotice = BackgroundTabNotice(tabID: tabID)
        let delay = Self.backgroundTabNoticeDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, self.backgroundTabNoticeGeneration == token else { return }
            self.backgroundTabNotice = nil
        }
    }

    func dismissBackgroundTabNotice() {
        backgroundTabNoticeGeneration += 1
        backgroundTabNotice = nil
    }

    /// Takes the user to the tab the notice names, then removes the notice.
    func openBackgroundTabFromNotice() {
        guard let notice = backgroundTabNotice else { return }
        dismissBackgroundTabNotice()
        guard isOpenForNotice(notice.tabID) else { return }
        activateTab(notice.tabID)
    }

    /// Closing a tab archives it rather than deleting it, so existing is not enough.
    private func isOpenForNotice(_ tabID: TabID) -> Bool {
        tab(tabID).map { $0.archivedAt == nil } ?? false
    }
}
