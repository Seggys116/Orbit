import SwiftUI

struct OrbitConsolePane: View {
    var session: OrbitInspectSession
    private var model: OrbitConsoleModel { session.console }

    @State private var atBottom = true
    @State private var showJumpPill = false
    @State private var completions: [String] = []
    @State private var completionPrefix = ""
    @State private var selectedCompletion = 0

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            InspectDivider()
            logArea
            InspectDivider()
            inputArea
        }
        .background(InspectChrome.panel)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ConFilterLevel.allCases, id: \.self) { level in
                    let count = model.count(for: level)
                    InspectChip(
                        level.title,
                        selected: model.filterLevel == level,
                        count: level == .all ? nil : (count > 0 ? count : nil)
                    ) {
                        model.filterLevel = level
                    }
                }

                Rectangle().fill(InspectChrome.hairline).frame(width: 1, height: 18)

                InspectSearchField(placeholder: "Filter  (/regex/, -exclude, url:pattern)",
                                   text: Binding(get: { model.filterText },
                                                 set: { model.filterText = $0 }))
                    .frame(minWidth: 180, maxWidth: 300)

                Rectangle().fill(InspectChrome.hairline).frame(width: 1, height: 18)

                InspectChip("Group similar", selected: model.groupSimilar) {
                    model.groupSimilar.toggle()
                }
                InspectChip("Timestamps", selected: model.showTimestamps) {
                    model.showTimestamps.toggle()
                }

                Spacer(minLength: 0)

                InspectTextButton("Clear", systemImage: "trash") {
                    model.clear()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 36)
    }

    private var logArea: some View {
        logScroll
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.displayEntries.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.displayEntries) { entry in
                            VStack(spacing: 0) {
                                if model.showTimestamps && entry.level != .navigation {
                                    Text(formatTimestamp(entry.timestamp))
                                        .font(InspectChrome.monoSmall)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.horizontal, 4)
                                        .padding(.top, 1)
                                }
                                ConEntryRow(entry: entry, model: model, session: session)
                                Rectangle()
                                    .fill(InspectChrome.hairline.opacity(0.5))
                                    .frame(height: 1)
                            }
                        }

                        // Auto-scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("con_bottom")
                            .onScrollGeometryChange(for: Bool.self) { geo in
                                // True when bottom is visible (distance from visible bottom to content bottom < 80pt)
                                let dist = geo.contentSize.height
                                    - geo.contentOffset.y
                                    - geo.containerSize.height
                                return dist < 80
                            } action: { _, isNearBottom in
                                atBottom = isNearBottom
                                showJumpPill = !isNearBottom && !model.displayEntries.isEmpty
                            }
                    }
                }
                .onChange(of: model.displayEntries.count) { _, _ in
                    if atBottom {
                        proxy.scrollTo("con_bottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo("con_bottom", anchor: .bottom)
            }
            .onChange(of: model.inputFocusRequested) { _, requested in
                if requested { model.inputFocusRequested = false }
            }
            .overlay(alignment: .bottom) {
                if showJumpPill {
                    jumpPill {
                        proxy.scrollTo("con_bottom", anchor: .bottom)
                        atBottom = true
                        showJumpPill = false
                    }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .orbitAnimation(OrbitMotion.quick, value: showJumpPill)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.entries.isEmpty {
            InspectEmptyState(
                symbol: "terminal",
                title: "No console output",
                message: "Messages from console.log, errors, and warnings will appear here."
            )
        } else {
            InspectEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No results",
                message: "No messages match the current filter."
            )
        }
    }

    private func jumpPill(_ action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text("Jump to latest")
                .font(.system(size: 11.5, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(OrbitNeutral.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(InspectChrome.accent))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
        .contentShape(Capsule())
        .overlay(InspectHitTarget(focusable: true, action: action))
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to latest message")
        .accessibilityAddTraits(.isButton)
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            if !completions.isEmpty {
                completionPopup
                InspectDivider()
            }

            HStack(alignment: .bottom, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)
                    .padding(.bottom, 6)

                ConInputView(
                    text: Binding(get: { model.inputText }, set: { model.inputText = $0 }),
                    onSubmit: {
                        model.submitInput()
                        completions = []
                    },
                    onHistoryUp: {
                        return model.history.up()
                    },
                    onHistoryDown: {
                        return model.history.down()
                    },
                    focusRequested: model.inputFocusRequested
                )
                .frame(minHeight: 22, maxHeight: 120)

                InspectTextButton("Run", prominent: true,
                                  action: {
                    model.submitInput()
                    completions = []
                })
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onChange(of: model.inputText) { _, newText in
            refreshCompletions(for: newText)
        }
    }

    private var completionPopup: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Candidates are unique names, so the name itself is the identity.
                ForEach(Array(completions.prefix(12).enumerated()), id: \.element) { idx, item in
                    HStack {
                        Text(item)
                            .font(InspectChrome.mono)
                            .foregroundStyle(idx == selectedCompletion ? OrbitNeutral.onAccent : InspectChrome.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(idx == selectedCompletion ? InspectChrome.accent : Color.clear)
                    .contentShape(Rectangle())
                    .overlay(InspectHitTarget {
                        acceptCompletion(item)
                    })
                }
            }
        }
        .frame(maxHeight: 160)
        .background(InspectChrome.panel)
    }

    private func refreshCompletions(for text: String) {
        guard !text.isEmpty else { completions = []; return }
        let (path, prefix) = parseCompletionPath(text)
        completionPrefix = prefix
        Task {
            let results = await model.fetchCompletions(path: path, prefix: prefix)
            if model.inputText.hasSuffix(text.dropFirst(max(0, text.count - 1))) {
                completions = results
                selectedCompletion = 0
            }
        }
    }

    /// Split "document.body.sty" into path=["document","body"] prefix="sty"
    private func parseCompletionPath(_ text: String) -> (path: [String], prefix: String) {
        // Find the last identifier chain
        var chain = ""
        for ch in text.reversed() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" || ch == "." {
                chain.insert(ch, at: chain.startIndex)
            } else { break }
        }
        let parts = chain.components(separatedBy: ".")
        if parts.count <= 1 { return ([], parts.last ?? "") }
        return (Array(parts.dropLast()), parts.last ?? "")
    }

    private func acceptCompletion(_ completion: String) {
        let (path, _) = parseCompletionPath(model.inputText)
        let prefix = (path + [completion]).joined(separator: ".")
        // Replace the tail of inputText with the completion
        var newText = model.inputText
        if let lastDotOrEnd = newText.lastIndex(of: ".") {
            newText = String(newText[...lastDotOrEnd]) + completion
        } else {
            newText = prefix
        }
        model.inputText = newText + (completion.hasSuffix(")") ? "" : "")
        completions = []
    }

    private func formatTimestamp(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let secs = ms / 1000
        return String(format: "%.3f s", secs)
    }
}
