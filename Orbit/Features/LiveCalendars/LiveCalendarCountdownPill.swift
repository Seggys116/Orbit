import SwiftUI

// Kept in its own file, taking only a String: FavoritesGridView is reused into the host-less
// OrbitTests target and only a file with a shallow dependency graph can be symlinked alongside it.
struct LiveCalendarCountdownPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.75))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.92)))
            .fixedSize()
            .accessibilityLabel("Next meeting \(text)")
    }
}
