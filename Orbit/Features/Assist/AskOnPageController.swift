import Foundation

@MainActor
@Observable
final class AskOnPageController {

    static let shared = AskOnPageController()

    /// Not `private` — a test gets a clean controller instead of shared state.
    init() {}

    struct Exchange: Identifiable, Equatable {
        var id = UUID()
        var question: String
        var notice: String?
        var quote: String?
        var answer: String
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case failed(String)
    }

    private(set) var isPresented = false
    private(set) var tabID: TabID?
    private(set) var exchanges: [Exchange] = []
    private(set) var phase: Phase = .idle

    var draft: String = ""

    // MARK: - Presentation

    func present(tabID: TabID) {
        if self.tabID != tabID {
            exchanges = []
            phase = .idle
            draft = ""
        }
        self.tabID = tabID
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        phase = .idle
        draft = ""
    }

    func tabDidChange(to newTabID: TabID?) {
        guard isPresented, newTabID != tabID else { return }
        isPresented = false
        exchanges = []
        phase = .idle
        draft = ""
        tabID = nil
    }

    // MARK: - Asking

    func ask(
        question: String,
        sink: AssistSink?,
        runtime: AssistRuntime = AssistRuntime.shared,
        incognito: Bool = false
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if incognito {
            phase = .failed(AssistError.incognito.localizedDescription)
            return
        }
        guard let sink else {
            phase = .failed(AssistError.notConfigured.localizedDescription)
            return
        }

        draft = ""
        phase = .thinking
        do {
            let answer = try await runtime.askOnPage(question: trimmed, sink: sink)
            exchanges.append(
                Exchange(
                    question: answer.question,
                    notice: answer.truncationNotice,
                    quote: answer.quote,
                    answer: answer.text
                )
            )
            phase = .idle
        } catch let error as AssistError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
