import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DeveloperModeSettings {

    static let defaultsKey = "OrbitDeveloperModeEnabled"

    #if DEBUG
    static var defaults: UserDefaults = OrbitDefaults.standard {
        didSet {
            guard defaults !== oldValue else { return }
            shared.reload(from: defaults)
        }
    }
    #else
    static let defaults: UserDefaults = OrbitDefaults.standard
    #endif

    static let shared = DeveloperModeSettings()

    var isEnabled: Bool

    @ObservationIgnored private var backingStore: UserDefaults

    private init() {
        backingStore = Self.defaults
        isEnabled = Self.defaults.bool(forKey: Self.defaultsKey)
    }

    #if DEBUG
    // Not through isEnabled's setter: that would write the restored value straight back out.
    fileprivate func reload(from newStore: UserDefaults) {
        backingStore = newStore
        isEnabled = newStore.bool(forKey: Self.defaultsKey)
    }
    #endif

    fileprivate func setEnabled(_ newValue: Bool) {
        isEnabled = newValue
        backingStore.set(newValue, forKey: Self.defaultsKey)
    }

    @discardableResult
    fileprivate func toggleInstance() -> Bool {
        setEnabled(!isEnabled)
        return isEnabled
    }

    static var isEnabled: Bool {
        get { shared.isEnabled }
        set { shared.setEnabled(newValue) }
    }

    @discardableResult
    static func toggle() -> Bool {
        shared.toggleInstance()
    }
}

@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private init() {}

    private var overlayController: CaptureOverlayWindowController?

    func present(tabID: TabID, fullPage: Bool, env: AppEnvironment) {
        guard let contents = env.webContents[tabID] else { return }
        if fullPage {
            Task { await captureFullPage(contents: contents) }
        } else {
            presentRegionOverlay(contents: contents)
        }
    }

    // MARK: - Full page

    private func captureFullPage(contents: any WebContents) async {
        var size = CGSize(width: 1280, height: 2000)
        if let raw = try? await contents.evaluateJavaScript(
            "({w: Math.max(document.documentElement.scrollWidth, window.innerWidth), h: Math.max(document.documentElement.scrollHeight, window.innerHeight)})"
        ), let dict = raw as? [String: Any],
           let width = (dict["w"] as? NSNumber)?.doubleValue, let height = (dict["h"] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        }
        guard let image = await contents.capturePreview(rect: CGRect(origin: .zero, size: size), size: size) else { return }
        CaptureController.finish(image: image, suggestedName: "Full Page Capture")
    }

    // MARK: - Region

    private func presentRegionOverlay(contents: any WebContents) {
        overlayController = CaptureOverlayWindowController(contents: contents) { [weak self] in
            self?.overlayController = nil
        }
        overlayController?.show()
    }

    // MARK: - Output

    static func finish(image: NSImage, suggestedName: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).png"
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
