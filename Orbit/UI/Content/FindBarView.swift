import AppKit
import SwiftUI

struct FindBarView: View {
    @Environment(AppEnvironment.self) private var env
    @FocusState private var isFocused: Bool

    private var contents: (any WebContents)? { env.activeWebContents }
    private var result: FindResult { env.currentFindResult }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14)

            TextField("Find or Ask", text: findQueryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { commitFind(forward: true) }
                .background(FindFieldFocusAnchor(request: env.findBarFocusRequest))

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
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 34)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OrbitRadius.row))
        .overlay(RoundedRectangle(cornerRadius: OrbitRadius.row).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        .onAppear { isFocused = true }
        .onChange(of: env.findBarFocusRequest) { isFocused = true }
        .onExitCommand { dismiss() }
    }

    private var findQueryBinding: Binding<String> {
        Binding(
            get: { env.findQuery },
            set: { newValue in
                guard newValue != env.findQuery else { return }
                env.findQuery = newValue
                // Typing starts a fresh search; Return and the chevrons step with findNext: true.
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

/// Pulls the keyboard out of the web view and into the find field, selecting any previous query, on every Cmd-F.
private struct FindFieldFocusAnchor: NSViewRepresentable {
    let request: UUID

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.handledRequest != request else { return }
        context.coordinator.handledRequest = request
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.makeKey()
            guard let field = Self.textField(near: view) else { return }
            if window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
            field.currentEditor()?.selectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var handledRequest: UUID?
    }

    private static func textField(near anchor: NSView) -> NSTextField? {
        var container = anchor.superview
        while let current = container {
            if let field = firstTextField(in: current) { return field }
            container = current.superview
        }
        return nil
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}
