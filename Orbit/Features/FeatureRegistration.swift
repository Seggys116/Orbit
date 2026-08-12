import SwiftUI
import AppKit

@MainActor
enum FeatureRegistration {

    static func installAll(into env: AppEnvironment) {
        installBoosts(env)
        installEasel(env)
        installNotes(env)
        installPeek(env)
        installLibrary(env)
        installMedia(env)
        installCapture(env)
        installAssist(env)
    }

    // MARK: - Boosts (spec §6.1)

    private static func installBoosts(_ env: AppEnvironment) {
        env.extensionPoints.boostsEditor = { host in
            AnyView(BoostsEditorView(host: host))
        }
        BoostsEditorWindowController.startObservingPresentationRequests()
    }

    // MARK: - Easel (spec §6.2)

    private static func installEasel(_ env: AppEnvironment) {
        env.extensionPoints.easelCanvas = { easelID in
            AnyView(EaselCanvasView(easelID: easelID))
        }
    }

    // MARK: - Notes (spec §6.3)

    private static func installNotes(_ env: AppEnvironment) {
        env.extensionPoints.notesEditor = { noteID in
            AnyView(NotesEditorView(noteID: noteID))
        }
    }

    // MARK: - Peek (spec §6.4)

    private static func installPeek(_ env: AppEnvironment) {
        env.extensionPoints.peekPanel = { sourceTabID, url in
            AnyView(PeekPanelView(sourceTabID: sourceTabID, url: url))
        }
    }

    // MARK: - Library (spec §6.14)

    private static func installLibrary(_ env: AppEnvironment) {
        env.extensionPoints.librarySection = { section in
            switch section {
            case .boosts:
                return AnyView(LibraryBoostsSectionView())
            case .media, .downloads, .easelsAndNotes, .spaces, .archivedTabs:
                return nil
            }
        }
    }

    // MARK: - Picture-in-Picture (spec §6.5)

    private static func installMedia(_ env: AppEnvironment) {
        env.extensionPoints.requestPictureInPicture = { tabID in
            PiPController.shared.requestPiP(for: tabID, env: env)
        }
        env.extensionPoints.dismissPictureInPicture = { tabID in
            PiPController.shared.dismissPiP(for: tabID, env: env)
        }
        PiPController.shared.start(env: env)
    }

    // MARK: - Capture tool (spec §6.9)

    private static func installCapture(_ env: AppEnvironment) {
        env.extensionPoints.presentCaptureTool = { tabID, fullPage in
            CaptureController.shared.present(tabID: tabID, fullPage: fullPage, env: env)
        }
    }

    // MARK: - Assist (spec §6.7)

    private static func installAssist(_ env: AppEnvironment) {
        env.hasConfiguredAIProvider = AssistSettings.isAnyFeatureLive

        env.extensionPoints.askOnPage = { [weak env] tabID, query in
            guard let env else { return }
            let controller = AskOnPageController.shared
            controller.present(tabID: tabID)
            let incognito = env.tab(tabID)
                .flatMap { env.space($0.spaceID) }
                .map { env.isIncognito($0) } ?? false
            let sink = incognito ? nil : AssistRuntime.productionSink(for: env.webContents[tabID])
            Task { await controller.ask(question: query, sink: sink, incognito: incognito) }
        }

        TidyTabTitlesCoordinator.shared.start(env: env)
        TidyDownloadsCoordinator.shared.start(env: env)
    }
}
