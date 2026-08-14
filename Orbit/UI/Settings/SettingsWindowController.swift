import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, data, profiles, assist, links, shortcuts, extensions, adBlocker, icloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .data: return "Data"
        case .profiles: return "Profiles"
        case .assist: return "Assist"
        case .links: return "Links"
        // Display title only; case stays `shortcuts` — deep links depend on that spelling.
        case .shortcuts: return "Keybinds"
        case .extensions: return "Extensions"
        case .adBlocker: return "Ad Blocker"
        case .icloud: return "iCloud"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .data: return "internaldrive"
        case .profiles: return "person.crop.circle"
        case .assist: return "sparkles"
        case .links: return "arrow.triangle.branch"
        case .shortcuts: return "keyboard"
        case .extensions: return "puzzlepiece.extension"
        case .adBlocker: return "shield.lefthalf.filled"
        case .icloud: return "icloud"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    @discardableResult
    static func show(
        pane: SettingsPane = .general,
        focusing focusTarget: SettingsFocusTarget? = nil
    ) -> SettingsWindowController {
        if let focusTarget {
            SettingsRouter.shared.requestFocus(focusTarget)
        }
        if let shared {
            SettingsRouter.shared.selectedPane = pane
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            #if ORBIT_SPARKLE
            Self.hookUpdaterFocus(to: shared.window)
            #endif
            return shared
        }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: SettingsMetrics.windowDefaultWidth,
                height: SettingsMetrics.windowDefaultHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: SettingsMetrics.windowMinWidth, height: SettingsMetrics.windowMinHeight)
        window.backgroundColor = NSColor(SettingsPalette.contentBackground)
        window.center()
        SettingsRouter.shared.selectedPane = pane
        window.contentView = NSHostingView(rootView: SettingsRootView().orbitEnvironment(AppEnvironment.processRoot))
        let controller = SettingsWindowController(window: window)
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
            SettingsRouter.shared.selectedPane = .general
            window?.makeKeyAndOrderFront(nil)
        }
    }
    #endif
}

enum SettingsFocusTarget: Equatable, Sendable {
    case extensionInstallField
}

/// Claims Cmd-, only, hands off to the one window above, never builds `SettingsRootView`:
/// a scene body evaluates before `AppEnvironment.processRoot` is set, which once gave Demo a broken Extensions pane.
struct SettingsSceneRedirectView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                dismiss()
                SettingsWindowController.show()
            }
    }
}

@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selectedPane: SettingsPane = .general

    private(set) var focusRequest: (target: SettingsFocusTarget, token: UUID)?

    private init() {}

    func requestFocus(_ target: SettingsFocusTarget) {
        // Fresh token so a repeat request for the same target still changes the value and fires onChange.
        focusRequest = (target, UUID())
    }

    func consumeFocusRequest(_ target: SettingsFocusTarget) {
        guard focusRequest?.target == target else { return }
        focusRequest = nil
    }
}

struct SettingsRootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = SettingsRouter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SettingsSidebarView(
                selection: Binding(
                    get: { router.selectedPane },
                    set: { router.selectedPane = $0 }
                )
            )

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(width: 1)

            ScrollView {
                paneView
                    .padding(SettingsMetrics.contentHorizontalPadding)
                    .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsPalette.contentBackground)
        }
        .frame(minWidth: SettingsMetrics.windowMinWidth, minHeight: SettingsMetrics.windowMinHeight)
        .background(SettingsPalette.contentBackground)
    }

    @ViewBuilder
    private var paneView: some View {
        switch router.selectedPane {
        case .general: GeneralSettingsPane()
        case .data: DataSettingsPane()
        case .profiles: ProfilesSettingsPane()
        case .assist: AssistSettingsPane()
        case .links: LinksSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .extensions: ExtensionsSettingsPane()
        case .adBlocker: AdBlockerSettingsPane()
        case .icloud: SyncSettingsPane()
        }
    }
}
