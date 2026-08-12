import SwiftUI

struct AskOnPagePanelView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = AskOnPageController.shared
    @FocusState private var isFieldFocused: Bool

    private let panelWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controller.exchanges) { exchange in
                exchangeView(exchange)
            }

            switch controller.phase {
            case .thinking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the page…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            askField
        }
        .padding(12)
        .frame(width: panelWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        .onAppear { isFieldFocused = true }
        .onExitCommand { controller.dismiss() }
    }

    // MARK: Question + answer

    @ViewBuilder
    private func exchangeView(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exchange.question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(askButtonTint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if exchange.id == controller.exchanges.first?.id {
                    Button { controller.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close Ask on Page")
                }
            }

            if let notice = exchange.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let quote = exchange.quote {
                Text("According to the article:")
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(quote)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { findOnPage(quote) } label: {
                        HStack(spacing: 3) {
                            Text("Find on Page")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Find this passage on the page")
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)
                }
            }

            Text(exchange.answer)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func findOnPage(_ quote: String) {
        guard let contents = controller.tabID.flatMap({ env.webContents[$0] }) else { return }
        env.findQuery = quote
        env.isFindBarPresented = true
        contents.find(quote, options: FindOptions(forward: true, findNext: false))
    }

    private typealias Exchange = AskOnPageController.Exchange

    // MARK: The "Ask a question..." row

    private var askField: some View {
        HStack(spacing: 6) {
            TextField("Ask a question...", text: draftBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isFieldFocused)
                .onSubmit(submit)

            Button(action: submit) {
                Text("Ask")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(askButtonTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(controller.draft.trimmingCharacters(in: .whitespaces).isEmpty || controller.phase == .thinking)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        )
    }

    private var draftBinding: Binding<String> {
        Binding(get: { controller.draft }, set: { controller.draft = $0 })
    }

    private var askButtonTint: Color {
        guard let theme = env.activeSpace?.theme else { return .accentColor }
        return Color(theme.primary.nsColor)
    }

    private func submit() {
        let question = controller.draft
        let contents = controller.tabID.flatMap { env.webContents[$0] }
        let incognito = controller.tabID
            .flatMap { env.tab($0) }
            .flatMap { env.space($0.spaceID) }
            .map { env.isIncognito($0) } ?? false
        let sink = incognito ? nil : AssistRuntime.productionSink(for: contents)
        Task { await controller.ask(question: question, sink: sink, incognito: incognito) }
    }
}
