import Foundation

// Also used by Settings' import alert (ImportFlowRunner.nativeSummaryMessage), so these stay static and view-free.
extension OnboardingView {

    static func arcSummaryLine(_ summary: ArcImportSummary) -> String {
        var parts: [String] = []
        parts.append("\(summary.spacesCreated) Space\(summary.spacesCreated == 1 ? "" : "s")")
        parts.append("\(summary.totalTabsImported) tab\(summary.totalTabsImported == 1 ? "" : "s")")
        if summary.foldersCreated > 0 {
            parts.append("\(summary.foldersCreated) folder\(summary.foldersCreated == 1 ? "" : "s")")
        }
        if summary.favoritesImported > 0 {
            parts.append("\(summary.favoritesImported) favourite\(summary.favoritesImported == 1 ? "" : "s")")
        }
        if summary.historyEntriesImported > 0 {
            parts.append("\(summary.historyEntriesImported) history entr\(summary.historyEntriesImported == 1 ? "y" : "ies")")
        }
        if summary.faviconsImported > 0 {
            parts.append("\(summary.faviconsImported) site icon\(summary.faviconsImported == 1 ? "" : "s")")
        }
        if summary.keyBindingsImported > 0 {
            parts.append("\(summary.keyBindingsImported) keyboard shortcut\(summary.keyBindingsImported == 1 ? "" : "s")")
        }
        if case .imported(let count) = summary.cookies, count > 0 {
            parts.append("\(count) login session\(count == 1 ? "" : "s")")
        }
        let sites = summary.siteData.stagedSiteCount
        if sites > 0 {
            parts.append("saved site data from \(sites) site\(sites == 1 ? "" : "s")")
        }
        return "Imported " + parts.joined(separator: ", ") + " from Arc."
    }

    static func arcCaveats(_ summary: ArcImportSummary) -> [String] {
        var caveats: [String] = []
        if summary.extensionsInstalled > 0, summary.extensionsNeedRestart {
            caveats.append("\(summary.extensionsInstalled) extension\(summary.extensionsInstalled == 1 ? "" : "s") installed from Arc. Restart Orbit to load \(summary.extensionsInstalled == 1 ? "it" : "them").")
        }
        if summary.extensionsAlreadyInstalled > 0 {
            caveats.append("\(summary.extensionsAlreadyInstalled) extension\(summary.extensionsAlreadyInstalled == 1 ? "" : "s") from Arc \(summary.extensionsAlreadyInstalled == 1 ? "was" : "were") already installed in Orbit.")
        }
        if !summary.extensionsNeedingManualInstall.isEmpty {
            caveats.append("Couldn't install \(summary.extensionsNeedingManualInstall.joined(separator: ", ")) from Arc. Reinstall from the Chrome Web Store.")
        }
        if !summary.keyBindingsNeedingManualRebind.isEmpty {
            let actions = summary.keyBindingsNeedingManualRebind.joined(separator: ", ")
            caveats.append("Couldn't bring these Arc shortcuts across: \(actions). Set them again in Settings › Shortcuts.")
        }
        switch summary.cookies {
        case .notAttempted, .imported:
            break
        case .partiallyImported(let stored, let decrypted):
            let missed = decrypted - stored
            caveats.append("\(stored) login session\(stored == 1 ? "" : "s") came across from Arc. \(missed) had already expired or couldn't be re-stored, so you may need to sign in again on some sites.")
        case .decryptedButEngineCannotInstall(let count):
            caveats.append("\(count) login session\(count == 1 ? "" : "s") could be read from Arc but there was no browsing session to put \(count == 1 ? "it" : "them") in, so you will need to sign in again.")
        case .keychainDenied:
            caveats.append("Orbit was not allowed to read Arc's saved logins, so you will need to sign in again.")
        case .failed(let reason):
            caveats.append("Arc's login sessions could not be read: \(reason)")
        }
        switch summary.siteData {
        case .notAttempted, .nothingToImport:
            break
        case .staged(let sites, let indexedDBSites, _):
            let count = max(sites, indexedDBSites)
            caveats.append("Saved site data came across for \(count) site\(count == 1 ? "" : "s"). Restart Orbit to apply it. Sites Orbit already holds data for keep Orbit's.")
        case .failed(let reason):
            caveats.append("Arc's saved site data could not be read: \(reason)")
        }
        return caveats
    }
}
