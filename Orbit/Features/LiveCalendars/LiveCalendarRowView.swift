import AppKit
import Combine
import SwiftUI

// MARK: - The Join row

struct LiveCalendarJoinRow: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    @State private var store = LiveCalendarStore.shared
    @State private var now = Date()
    @State private var didJoin = false

    private let tick = Timer.publish(every: LiveCalendarCountdown.refreshInterval, on: .main, in: .common)
        .autoconnect()

    private var hasCalendarFavourite: Bool {
        env.favorites(for: spaceID).contains { CalendarSiteMatcher.isCalendar($0.url) }
    }

    private var joinableEvent: LiveCalendarEvent? {
        guard LiveCalendarSettings.isEnabled, LiveCalendarSettings.showsJoinRow, hasCalendarFavourite else { return nil }
        guard let event = store.nextEvent else { return nil }
        return event.shouldOfferJoin(at: now, leadTime: LiveCalendarSettings.leadTime) ? event : nil
    }

    var body: some View {
        Group {
            if let event = joinableEvent {
                row(event)
            } else if shouldOfferConnect {
                connectRow
            } else if shouldExplainDenial {
                deniedRow
            }
        }
        .onReceive(tick) { now = $0 }
        .onAppear { if LiveCalendarSettings.isEnabled { store.startRefreshing() } }
        .onChange(of: store.nextEvent?.id) { _, _ in didJoin = false }
    }

    // MARK: The meeting row

    private func row(_ event: LiveCalendarEvent) -> some View {
        HStack(spacing: 0) {
            Text(EventEmoji.leading(in: event.title) ?? "🗓")
                .font(.system(size: 12))
                .frame(width: OrbitMetrics.faviconSize, alignment: .center)

            Text(EventEmoji.stripLeading(from: event.title))
                .font(.system(size: OrbitMetrics.sidebarRowFontSize))
                .foregroundStyle(theme.readableForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, OrbitMetrics.liveCalendarRowInnerSpacing)

            Spacer(minLength: OrbitMetrics.liveCalendarRowInnerSpacing)

            Button(action: { join(event) }) {
                Group {
                    if didJoin {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    } else {
                        Text("Join").font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 34)
                .padding(.horizontal, OrbitMetrics.liveCalendarJoinButtonHorizontalPadding)
                .padding(.vertical, OrbitMetrics.liveCalendarJoinButtonVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(joinFill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join \(event.title)")
        }
        .frame(height: OrbitMetrics.sidebarRowHeight)
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
    }

    private var joinFill: Color {
        Color(theme.primary.nsColor).blended(with: .black, fraction: 0.28)
    }

    private func join(_ event: LiveCalendarEvent) {
        guard let url = event.joinURL else { return }
        didJoin = true
        _ = env.openTab(url: url, in: spaceID)
    }

    // MARK: Connect / denied

    private var shouldOfferConnect: Bool {
        LiveCalendarSettings.isEnabled && hasCalendarFavourite && store.authorization == .notDetermined
    }

    private var shouldExplainDenial: Bool {
        LiveCalendarSettings.isEnabled && hasCalendarFavourite && store.authorization == .denied
    }

    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("See upcoming meetings and join video calls instantly with the Calendar Preview.")
                .font(.system(size: 10))
                .foregroundStyle(theme.readableSecondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await store.connect() } } label: {
                Text("Connect Calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(joinFill))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .modifier(LiveCalendarRowChrome(theme: theme))
    }

    private var deniedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Orbit cannot read your calendar.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.readableForeground)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Privacy Settings")
                    .font(.system(size: 10))
                    .underline()
                    .foregroundStyle(theme.readableSecondaryForeground)
            }
            .buttonStyle(.plain)
        }
        .modifier(LiveCalendarRowChrome(theme: theme))
    }
}

private struct LiveCalendarRowChrome: ViewModifier {
    var theme: SpaceTheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, OrbitMetrics.liveCalendarCardHorizontalPadding)
            .padding(.vertical, OrbitMetrics.liveCalendarCardVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
                    .fill(theme.readableForeground.opacity(0.10))
            )
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
            .padding(.bottom, OrbitMetrics.favoriteGridVerticalPadding)
    }
}
