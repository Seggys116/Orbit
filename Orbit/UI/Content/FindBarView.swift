import SwiftUI

struct FindBarView: View {
    @Environment(AppEnvironment.self) private var env
    @FocusState private var isFocused: Bool

    private var contents: (any WebContents)? { env.activeWebContents }
    private var result: FindResult { env.currentFindResult }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Find or Ask", text: findQueryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { commitFind(forward: true) }

            if !env.findQuery.isEmpty {
                Text(matchLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 16)

            Button { commitFind(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(result.matchCount == 0)

            Button { commitFind(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(result.matchCount == 0)

            if result.matchCount == 0, !env.findQuery.isEmpty, env.hasConfiguredAIProvider {
                Button("Ask") {
                    if let tabID = env.activeTabID {
                        env.extensionPoints.askOnPage?(tabID, env.findQuery)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        .onAppear { isFocused = true }
        .onExitCommand { dismiss() }
    }

    private var findQueryBinding: Binding<String> {
        Binding(
            get: { env.findQuery },
            set: { newValue in
                env.findQuery = newValue
                contents?.find(newValue, options: FindOptions(forward: true, findNext: false))
            }
        )
    }

    private var matchLabel: String {
        result.matchCount == 0 ? "No results" : "\(result.activeMatchOrdinal)/\(result.matchCount)"
    }

    private func commitFind(forward: Bool) {
        contents?.find(env.findQuery, options: FindOptions(forward: forward, findNext: true))
    }

    private func dismiss() {
        env.dismissFindBar()
    }
}
