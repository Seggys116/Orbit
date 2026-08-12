import SwiftUI

// MARK: - Search field

struct LibrarySearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryPalette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(LibraryPalette.textPrimary)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: LibraryMetrics.searchFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: LibraryMetrics.searchFieldCornerRadius)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryMetrics.searchFieldCornerRadius)
                .strokeBorder(isFocused ? LibraryPalette.accent.opacity(0.6) : LibraryPalette.cardBorder, lineWidth: 1)
        )
        .animation(OrbitMotion.quick, value: isFocused)
    }
}

// MARK: - Row card container

struct LibraryRowCard<Content: View>: View {
    var isSelected: Bool = false
    @ViewBuilder var content: Content
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return LibraryPalette.selectedFill }
        return isHovering ? LibraryPalette.cardFillHover : LibraryPalette.cardFill
    }

    var body: some View {
        content
            .padding(.horizontal, LibraryMetrics.rowHorizontalPadding)
            .padding(.vertical, LibraryMetrics.rowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: LibraryMetrics.rowCornerRadius)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LibraryMetrics.rowCornerRadius)
                    .strokeBorder(
                        isSelected ? LibraryPalette.cardFillHover : LibraryPalette.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isSelected ? 0.22 : 0),
                radius: isSelected ? 6 : 0,
                y: isSelected ? 2 : 0
            )
            .onHover { isHovering = $0 }
            .animation(OrbitMotion.quick, value: isHovering)
            .animation(OrbitMotion.quick, value: isSelected)
    }
}

// MARK: - Date group header

struct LibraryDateSectionHeader: View {
    var title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: LibraryMetrics.dateHeaderFontSize, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(LibraryPalette.textTertiary)
            .padding(.horizontal, 2)
    }
}

// MARK: - Icon action button

struct LibraryActionButton: View {
    var symbol: String
    var tint: Color = LibraryPalette.textSecondary
    var help: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? LibraryPalette.textPrimary : tint)
                .frame(width: LibraryMetrics.actionButtonSize, height: LibraryMetrics.actionButtonSize)
                .background(
                    Circle().fill(isHovering ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .orbitTooltip(help)
        .onHover { isHovering = $0 }
        .animation(OrbitMotion.quick, value: isHovering)
    }
}

// MARK: - Progress bar

struct LibraryProgressBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LibraryPalette.progressTrack)
                if let fraction {
                    Capsule()
                        .fill(LibraryPalette.accent)
                        .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
                } else {
                    Capsule()
                        .fill(LibraryPalette.accent.opacity(0.6))
                        .frame(width: proxy.size.width * 0.28)
                }
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Date grouping

struct LibraryDateGroup<Item>: Identifiable {
    var id: String { title }
    var title: String
    var items: [Item]
}

enum LibraryDateGrouping {
    // Uses day-count from `now`, not Calendar.isDateInToday, which ignores `now`.
    static func title(for date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let daysBack = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

        if daysBack == 0 { return "Today" }
        if daysBack == 1 { return "Yesterday" }
        if daysBack > 0 && daysBack < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMMM d" : "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    static func group<Item>(_ items: [Item], now: Date = Date(), date: (Item) -> Date) -> [LibraryDateGroup<Item>] {
        let calendar = Calendar.current
        let sorted = items.sorted { date($0) > date($1) }

        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in sorted {
            let key = title(for: date(item), calendar: calendar, now: now)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }
        return order.map { LibraryDateGroup(title: $0, items: buckets[$0] ?? []) }
    }
}

// MARK: - Byte formatting

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
