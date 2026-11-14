import SwiftUI

/// The last step: make Orbit the default browser and pick a search engine.
struct OnboardingFinishStep: View {
    @Binding var searchEngine: SearchEngine
    let offersDefaultBrowser: Bool
    let onSetDefaultBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeading(
                title: "You're set.",
                subtitle: offersDefaultBrowser ? "Make Orbit your default, and choose how it searches." : "Choose how Orbit searches."
            )

            section(title: "Default browser") {
                if offersDefaultBrowser {
                    Text("Open links from other apps in Orbit. macOS asks you to confirm.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(OrbitNeutral.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set as default browser", action: onSetDefaultBrowser)
                        .buttonStyle(OnboardingButtonStyle(variant: .raised))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(OrbitNeutral.good)
                        Text("Orbit already opens links from other apps. Nothing to do here.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(OrbitNeutral.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            section(title: "Search engine") {
                Text("Used for searches in the Command Bar. Change it later in Settings › Profiles.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // OrbitPopupButton, not a stock Picker: a menu-style Picker does not present reliably inside this app's NSHostingView.
                OrbitPopupButton(
                    options: SearchEngine.allCases,
                    label: { $0.displayName },
                    selection: $searchEngine,
                    accessibilityLabel: "Default search engine",
                    accentColor: OrbitNeutral.accent
                )
                .frame(width: 220)
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OrbitNeutral.ink)
            content()
        }
    }
}
