import SwiftUI

// Declared here, not in SiteSearchTint.swift: that resolver reaches for FaviconCache and AppKit, neither of which the host-less OrbitTests target can compile.
struct CommandRowTint: Equatable {
    var fill: Color
    var foreground: Color
}

struct CommandResultRow: View {
    @Environment(\.colorScheme) private var colorScheme

    var result: CommandResult
    var isSelected: Bool
    var siteTint: CommandRowTint? = nil

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(OrbitFont.commandBarRowTitle)
                    .fontWeight(activeSiteTint == nil ? nil : .bold)
                    .foregroundStyle(activeSiteTint?.foreground ?? .primary)
                    .lineLimit(1)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OrbitFont.commandBarRowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let switchHintLabel {
                Text(switchHintLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if result.instantOpenURL != nil {
                trailingHint(label: "Instant Open") {
                    Text("⇧↵")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                }
            } else if showsAskChatGPTHint {
                trailingHint(label: "Ask ChatGPT") {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: OrbitMetrics.commandBarRowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(selectionFill))
        .contentShape(Rectangle())
    }

    private var activeSiteTint: CommandRowTint? {
        isSelected ? siteTint : nil
    }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        if let siteTint { return siteTint.fill }
        return colorScheme == .dark ? OrbitColor.selectionFillDark : OrbitColor.selectionFillLight
    }

    private var switchHintLabel: String? {
        switch result.kind {
        case .openTab, .pinnedTab: return "Switch to Tab"
        case .tabInOtherSpace: return "Switch to Space"
        default: return nil
        }
    }

    private var showsAskChatGPTHint: Bool {
        if case .chatGPTAsk = result.kind { return true }
        return false
    }

    private func trailingHint<Glyph: View>(label: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            glyph()
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let host = result.faviconHost {
            FaviconView(url: result.faviconURL, host: host)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: result.symbolName)
                .frame(width: 16, height: 16)
                .foregroundStyle(activeSiteTint?.foreground ?? .secondary)
                .font(.system(size: 13))
        }
    }
}
