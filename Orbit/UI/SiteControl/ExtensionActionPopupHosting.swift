// Model is pre-started, not built in .onAppear: a popover's teardown timing relative to .onDisappear isn't guaranteed, so SiteControlPopoverView's state transition drives it instead.
// Sizing is the renderer's: enableContentSizing puts the WebContents into auto-resize mode, so it reports its own preferred size rather than being laid out at a fixed host size.

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class ExtensionActionPopupModel {
    public private(set) var contents: (any WebContents)?
    public private(set) var loadFailure: String?
    public private(set) var contentSize: CGSize = ExtensionActionPopupSupport.popupLoadingSize
    public private(set) var hasReportedContentSize = false

    private let engine: any BrowserEngine
    private let session: any EngineSession
    private let url: URL
    private var observer: Observer?

    public init(engine: any BrowserEngine, session: any EngineSession, url: URL) {
        self.engine = engine
        self.session = session
        self.url = url
    }

    public func start() {
        guard contents == nil, loadFailure == nil else { return }
        do {
            let contents = try engine.makeWebContents(session: session, initialURL: nil)
            let observer = Observer(model: self)
            contents.delegate = observer
            self.observer = observer
            self.contents = contents
            // Before load, so the very first layout is already the self-sizing one.
            contents.enableContentSizing(
                minimum: ExtensionActionPopupSupport.popupMinimumSize,
                maximum: ExtensionActionPopupSupport.popupMaximumSize
            )
            contents.load(url)
        } catch {
            loadFailure = "This extension's popup could not be opened: \(error.localizedDescription)"
        }
    }

    // Safe to call more than once: SiteControlPopoverView calls this from more than one dismissal path, uncoordinated about which runs first.
    public func teardown() {
        contents?.close()
        contents = nil
        observer = nil
    }

    fileprivate func handleFailure(_ error: EngineError) {
        loadFailure = "\(error.headline). \(error.underlyingDescription)"
    }

    // Every report is adopted, not just the first: a popup that grows after load (an async list rendering, a details disclosure opening) grows with it, which is what Chrome does too.
    fileprivate func applyPreferredSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        hasReportedContentSize = true
        contentSize = ExtensionActionPopupSupport.clampedPopupSize(size)
    }

    private final class Observer: WebContentsDelegate {
        private weak var model: ExtensionActionPopupModel?

        init(model: ExtensionActionPopupModel) {
            self.model = model
        }

        func webContents(_ contents: WebContents, didFailLoading error: EngineError) {
            model?.handleFailure(error)
        }

        func webContents(_ contents: WebContents, didChangePreferredSize size: CGSize) {
            model?.applyPreferredSize(size)
        }
    }
}

public struct ExtensionActionPopupView: View {
    public var model: ExtensionActionPopupModel

    public init(model: ExtensionActionPopupModel) {
        self.model = model
    }

    public var body: some View {
        if let loadFailure = model.loadFailure {
            ExtensionPopupMessageView(
                symbol: "exclamationmark.triangle",
                symbolColor: .secondary,
                message: loadFailure
            )
        } else if let contents = model.contents {
            ExtensionPopupWebContentsHostView(contents: contents)
                .frame(width: model.contentSize.width, height: model.contentSize.height)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(
                    width: ExtensionActionPopupSupport.popupLoadingSize.width,
                    height: ExtensionActionPopupSupport.popupLoadingSize.height
                )
        }
    }
}

// The one layout every non-web state of an extension popup uses, so a failure and a pending-activation notice are the same object at the same width rather than two differently-padded boxes.
struct ExtensionPopupMessageView<Accessory: View>: View {
    var symbol: String
    var symbolColor: Color
    var message: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(symbolColor)
            Text(message)
                .font(.system(size: OrbitMetrics.siteControlRowValueFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .padding(16)
        .frame(width: ExtensionActionPopupSupport.popupMessageWidth)
    }
}

extension ExtensionPopupMessageView where Accessory == EmptyView {
    init(symbol: String, symbolColor: Color, message: String) {
        self.init(symbol: symbol, symbolColor: symbolColor, message: message) { EmptyView() }
    }
}

// Shown instead of ExtensionActionPopupView for an extension the running engine has not loaded yet — its chrome-extension:// popup would answer ERR_BLOCKED_BY_CLIENT, so this never attempts that navigation at all.
public struct ExtensionPendingActivationView: View {
    public var extensionName: String

    public init(extensionName: String) {
        self.extensionName = extensionName
    }

    public var body: some View {
        ExtensionPopupMessageView(
            symbol: "arrow.triangle.2.circlepath",
            symbolColor: .orange,
            message: "\"\(extensionName)\" was just installed. Orbit needs to restart to finish enabling it."
        ) {
            OrbitButton(title: "Restart Orbit", kind: .primary, isCompact: true) {
                RelaunchController.relaunch()
            }
        }
    }
}

// Deliberately not WebContentsHostView: that type arbitrates a tab's view across panes and freezes/unfreezes it with key window status, which would risk this popup silently going inert.
private struct ExtensionPopupWebContentsHostView: NSViewRepresentable {
    var contents: any WebContents

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        embed(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        embed(in: nsView)
    }

    private func embed(in container: NSView) {
        guard contents.view.superview !== container else { return }
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        let view = contents.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // After addSubview: `container` has no window on the makeNSView path,
        // so AppKit has just told content:: this popup is hidden. See
        // ChromiumPaneVisibilityLiveTests.
        contents.setVisible(true)
    }
}
