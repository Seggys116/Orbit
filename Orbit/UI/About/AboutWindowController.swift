import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    private static var shared: AboutWindowController?

    @discardableResult
    static func show() -> AboutWindowController {
        if let shared {
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            #if ORBIT_SPARKLE
            Self.hookUpdaterFocus(to: shared.window)
            #endif
            return shared
        }
        let size = AboutView.windowSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: AboutView())
        let controller = AboutWindowController(window: window)
        shared = controller
        #if ORBIT_SPARKLE
        Self.hookUpdaterFocus(to: window)
        #endif
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    #if ORBIT_SPARKLE
    private static func hookUpdaterFocus(to window: NSWindow?) {
        UpdaterController.shared.onRequestFocus = { [weak window] in
            window?.makeKeyAndOrderFront(nil)
        }
    }
    #endif
}

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var windowSize: NSSize {
        #if ORBIT_SPARKLE
        NSSize(width: 380, height: 520)
        #else
        NSSize(width: 340, height: 320)
        #endif
    }

    #if ORBIT_SPARKLE
    @Bindable private var updater = UpdaterController.shared
    #endif

    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text("Orbit").font(.system(size: 20, weight: .bold))
            Text("Version \(appVersion) (\(buildNumber))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            VStack(spacing: 4) {
                Text(ChromiumBuild.engineDescription).font(.system(size: 12, weight: .medium))
                Text("Chromium \(ChromiumBuild.version) · \(ChromiumBuild.channel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("Pinned \(ChromiumBuild.pinnedAt)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            #if ORBIT_SPARKLE
            Divider().padding(.vertical, 4)
            updatesSection
            #endif

            Spacer(minLength: 0)

            Text("© \(Calendar.current.component(.year, from: Date())) Orbit")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    #if ORBIT_SPARKLE
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Updates")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                UpdaterStatusView(
                    status: updater.status,
                    canCheckForUpdates: updater.canCheckForUpdates,
                    onCheckForUpdates: { updater.checkForUpdates() },
                    onInstallNow: { updater.installUpdateNow() },
                    onRemindLater: { updater.remindMeLater() },
                    onSkipVersion: { updater.skipThisVersion() },
                    onCancelCheck: { updater.cancelCheck() },
                    onCancelDownload: { updater.cancelDownload() }
                )
                .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
    }
    #endif
}
