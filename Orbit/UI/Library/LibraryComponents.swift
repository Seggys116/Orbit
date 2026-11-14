import SwiftUI


struct LibrarySearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    /// Escape while the field is being edited; the field editor consumes it before any window-level handler.
    var onExit: (() -> Void)?

    @Environment(\.libraryStyle) private var style
    @FocusState private var isFocused: Bool

    private static let cornerRadius = OrbitRadius.md

    var body: some View {
        HStack(spacing: OrbitSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1, weight: .medium))
                .foregroundStyle(style.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(OrbitFont.commandBarRowSubtitle)
                .foregroundStyle(style.foreground)
                .focused($isFocused)
                .onExitCommand { onExit?() }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1))
                        .foregroundStyle(style.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, OrbitSpacing.md)
        .frame(height: LibraryModeMetrics.searchFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(style.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(isFocused ? style.focusRing : style.border, lineWidth: OrbitMetrics.cardBorderWidth)
        )
        .orbitAnimation(OrbitMotion.quick, value: isFocused)
        .orbitAnimation(OrbitMotion.quick, value: text.isEmpty)
    }
}


/// One action on a Library row: hover button, context menu entry and accessibility action, so no path depends on the pointer alone.
struct LibraryRowAction: Identifiable {
    var title: String
    var symbol: String
    var isDestructive = false
    /// Stays on screen when the row is idle (a running download's Cancel).
    var alwaysVisible = false
    var action: () -> Void

    var id: String { title }
}


struct LibraryRowCard<Content: View>: View {
    var isSelected: Bool = false
    var actions: [LibraryRowAction] = []
    /// Replaces the menu derived from `actions` when a row needs entries beyond them.
    var menu: (() -> [OrbitContextMenuEntry])?
    @ViewBuilder var content: Content

    @Environment(\.libraryStyle) private var style
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return style.selectedFill }
        return isHovering ? style.hoverFill : .clear
    }

    private var visibleActions: [LibraryRowAction] {
        (isHovering || isSelected) ? actions : actions.filter(\.alwaysVisible)
    }

    private var contextEntries: [OrbitContextMenuEntry] {
        if let menu { return menu() }
        return actions.map { action in
            .item(OrbitContextMenuItem(
                title: action.title,
                systemImage: action.symbol,
                isDestructive: action.isDestructive,
                action: action.action
            ))
        }
    }

    var body: some View {
        HStack(spacing: LibraryModeMetrics.rowContentSpacing) {
            content
            if !visibleActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(visibleActions) { action in
                        LibraryActionButton(symbol: action.symbol, help: action.title, action: action.action)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, LibraryModeMetrics.rowHorizontalPadding)
        .padding(.vertical, LibraryModeMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                .fill(fill)
        )
        .contentShape(RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
        .onHover { isHovering = $0 }
        .orbitAnimation(OrbitMotion.quick, value: isHovering)
        .orbitAnimation(OrbitMotion.quick, value: isSelected)
        .modifier(LibraryRowMenuModifier(isEnabled: menu != nil || !actions.isEmpty, entries: { contextEntries }))
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.action)
            }
        }
    }
}

private struct LibraryRowMenuModifier: ViewModifier {
    var isEnabled: Bool
    var entries: () -> [OrbitContextMenuEntry]

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.orbitRightClickMenu(entries)
        } else {
            content
        }
    }
}


struct LibraryDateSectionHeader: View {
    var title: String

    @Environment(\.libraryStyle) private var style

    var body: some View {
        Text(title)
            .font(OrbitFont.sidebarSectionHeader)
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .padding(.horizontal, LibraryModeMetrics.rowHorizontalPadding)
            .accessibilityAddTraits(.isHeader)
    }
}


struct LibraryActionButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    @Environment(\.libraryStyle) private var style
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1, weight: .medium))
                .foregroundStyle(style.foreground)
                .frame(width: LibraryModeMetrics.actionButtonSize, height: LibraryModeMetrics.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
                        .fill(isHovering ? style.selectedFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .orbitTooltip(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
        .orbitAnimation(OrbitMotion.quick, value: isHovering)
    }
}


struct LibraryProgressBar: View {
    var fraction: Double?

    @Environment(\.libraryStyle) private var style

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(style.progressTrack)
                if let fraction {
                    Capsule()
                        .fill(style.foreground)
                        .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
                } else {
                    Capsule()
                        .fill(style.foreground.opacity(OrbitMetrics.extensionInstallProgressIndeterminateOpacity))
                        .frame(width: proxy.size.width * 0.28)
                }
            }
        }
        .frame(height: 3)
    }
}


struct LibraryDateGroup<Item>: Identifiable {
    var id: String { title }
    var title: String
    var items: [Item]
}

enum LibraryDateGrouping {
    // Reused, not allocated per call: a fresh DateFormatter() pays ICU setup each time, ~120ms of a ~150ms grouping pass over a few thousand archived tabs.
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    // Uses day-count from `now`, not Calendar.isDateInToday, which ignores `now`.
    static func title(for date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let daysBack = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

        if daysBack == 0 { return "Today" }
        if daysBack == 1 { return "Yesterday" }
        if daysBack > 0 && daysBack < 7 {
            return weekdayFormatter.string(from: date)
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = sameYear ? monthDayFormatter : monthDayYearFormatter
        return formatter.string(from: date)
    }

    // Buckets by startOfDay, not by title string: same grouping, but title(for:) runs once per bucket instead of per item (~90ms vs ~3ms for 3,000 archived tabs).
    static func group<Item>(_ items: [Item], now: Date = Date(), date: (Item) -> Date) -> [LibraryDateGroup<Item>] {
        let calendar = Calendar.current
        let sorted = items.sorted { date($0) > date($1) }

        var order: [Date] = []
        var buckets: [Date: [Item]] = [:]
        for item in sorted {
            let day = calendar.startOfDay(for: date(item))
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(item)
        }
        return order.map { day in
            LibraryDateGroup(title: title(for: day, calendar: calendar, now: now), items: buckets[day] ?? [])
        }
    }
}


enum LibraryByteFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
