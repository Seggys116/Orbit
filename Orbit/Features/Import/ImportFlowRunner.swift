import AppKit
import Observation

@MainActor
@Observable
final class ImportFlowRunner {

    static let shared = ImportFlowRunner()

    private(set) var isImporting = false

    private init() {}

    func availableBrowsers() -> [ImportableBrowser] {
        BrowserDataReader().availableBrowsers()
    }

    // A source carrying its own structure (e.g. Arc) takes the native route: BrowserImportCoordinator reduces its input to a bookmark tree, silently discarding Spaces, themes, Today, Archive, favourites, extensions and settings.
    func run(_ browser: ImportableBrowser, env: AppEnvironment = .processRoot) {
        guard let spaceID = env.activeSpace?.id ?? env.spaces.first?.id else {
            present(title: "Nothing to import into", message: "Orbit has no Space to put the imported bookmarks in yet.")
            return
        }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                if browser.importsNativeStructure {
                    let summary = try await ArcImportCoordinator.performImport(
                        env: env,
                        importCookies: confirmCookieImport(browser)
                    )
                    present(
                        title: "Imported from \(browser.displayName)",
                        message: Self.nativeSummaryMessage(summary)
                    )
                } else {
                    let summary = try await BrowserImportCoordinator.performImport(browser, into: spaceID, env: env)
                    present(
                        title: "Imported from \(summary.browser.displayName)",
                        message: "\(summary.bookmarksImported) bookmark\(summary.bookmarksImported == 1 ? "" : "s") in \(summary.foldersCreated) folder\(summary.foldersCreated == 1 ? "" : "s"), and \(summary.historyEntriesImported) history entr\(summary.historyEntriesImported == 1 ? "y" : "ies")."
                    )
                }
            } catch {
                present(
                    title: "Couldn't import from \(browser.displayName)",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    static func nativeSummaryMessage(_ summary: ArcImportSummary) -> String {
        let caveats = OnboardingView.arcCaveats(summary)
        guard !caveats.isEmpty else { return OnboardingView.arcSummaryLine(summary) }
        return OnboardingView.arcSummaryLine(summary) + "\n\n" + caveats.joined(separator: "\n")
    }

    private func confirmCookieImport(_ browser: ImportableBrowser) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Bring your logins across from \(browser.displayName)?"
        alert.informativeText = "Orbit can copy \(browser.displayName)'s login sessions so you stay signed in to the sites you use. "
            + "macOS will ask for permission to read \(browser.displayName)'s saved key. "
            + "Everything else imports either way."
        alert.addButton(withTitle: "Bring Logins Across")
        alert.addButton(withTitle: "Skip Logins")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
