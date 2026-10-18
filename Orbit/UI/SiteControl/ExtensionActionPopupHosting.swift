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
    /// Each axis scrolls only when the document is larger than the frame on that axis.
    /// Turning both on for a tall page is what draws the horizontal bar.
    public private(set) var scrollsHorizontally = false
    public private(set) var scrollsVertically = false

    private let engine: any BrowserEngine
    private let session: any EngineSession
    private let url: URL
    private var observer: Observer?
    private var sizeCorrectionGeneration = 0

    public init(engine: any BrowserEngine, session: any EngineSession, url: URL) {
        self.engine = engine
        self.session = session
        self.url = url
    }

    public func start() {
        guard contents == nil, loadFailure == nil else { return }
        do {
            let contents: any WebContents
            if let engine = engine as? WebKitEngine {
                contents = try engine.makeWebContents(session: session, initialURL: nil, registersAsTab: false)
            } else {
                contents = try engine.makeWebContents(session: session, initialURL: nil)
            }
            let observer = Observer(model: self)
            contents.delegate = observer
            self.observer = observer
            self.contents = contents
            // Smaller than the page, on purpose. The web view is born at 800×600; measuring
            // there reports that viewport as the page height. The loading frame is the same
            // minimum, so embedding before the first report does not stretch it back.
            contents.view.frame = NSRect(origin: .zero, size: ExtensionActionPopupSupport.popupLoadingSize)
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
        sizeCorrectionGeneration += 1
        let held = contents
        // Drop the model's reference before close. A re-entrant view update must not observe a live popup, and this object must not keep the web view.
        contents = nil
        held?.delegate = nil
        observer = nil
        held?.close()
    }

    fileprivate func handleFailure(_ error: EngineError) {
        loadFailure = "\(error.headline). \(error.underlyingDescription)"
    }

    // Every distinct report is adopted, not just the first: a popup that grows after load (an async list rendering, a details disclosure opening) grows with it, which is what Chrome does too.
    fileprivate func applyPreferredSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let viewBounds = contents?.view.bounds.size ?? .zero
        // A report the size of the web view is the viewport, not the page. Adopting it leaves
        // the frame taller than the page, or shorter by less than a scrollbar.
        if ExtensionActionPopupSupport.isUnlaidOutViewportSize(size, viewBounds: viewBounds) {
            correctViewportSize(fallback: size)
            return
        }
        adopt(raw: size)
    }

    private func adopt(raw: CGSize) {
        sizeCorrectionGeneration += 1
        let screen = NSScreen.main?.visibleFrame.size ?? .zero
        let frame = ExtensionActionPopupSupport.popupFrame(fitting: raw, on: screen)
        let horizontal = raw.width > frame.width + 0.5
        let vertical = raw.height > frame.height + 0.5
        if scrollsHorizontally != horizontal { scrollsHorizontally = horizontal }
        if scrollsVertically != vertical { scrollsVertically = vertical }
        if contentSize != frame { contentSize = frame }
        if !hasReportedContentSize { hasReportedContentSize = true }
    }

    private func correctViewportSize(fallback: CGSize) {
        guard let contents else {
            adopt(raw: fallback)
            return
        }
        sizeCorrectionGeneration += 1
        let generation = sizeCorrectionGeneration
        Task { @MainActor [weak self] in
            let measured = await ExtensionActionPopupSupport.measuredContentSize(in: contents)
            guard let self, generation == self.sizeCorrectionGeneration, self.contents != nil, !contents.isClosed else { return }
            // The script's own answer is the document. It is discarded only when both
            // axes are still the host, which is the viewport echoing itself.
            if let measured, !ExtensionActionPopupSupport.isEntirelyTheViewport(measured, viewBounds: contents.view.bounds.size) {
                self.adopt(raw: measured)
            }
        }
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
            ExtensionPopupWebContentsHostView(
                contents: contents,
                scrollsHorizontally: model.scrollsHorizontally,
                scrollsVertically: model.scrollsVertically
            )
                .frame(width: model.contentSize.width, height: model.contentSize.height)
                .fixedSize()
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
    var scrollsHorizontally: Bool
    var scrollsVertically: Bool

    func makeNSView(context: Context) -> NSView {
        // Not embedded here: SwiftUI can build this NSView and discard it, and embedding would park the popup web view in a container that is never shown.
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        embed(in: nsView)
        configureScrollers(in: contents.view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }

    private func embed(in container: NSView) {
        if contents.isClosed {
            detachIfPresent(in: container)
            return
        }
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
        // After addSubview: `container` often has no window yet, so AppKit has just told the engine this popup is hidden. See WebKitPaneVisibilityLiveTests.
        contents.setVisible(true)
        configureScrollers(in: view)
        // The document often finished loading before this view had a window, so the
        // size report from document-start never reached a popover that could grow.
        (contents as? WebKitWebContents)?.contentSizing?.measure()
    }

    // Scroll indicators stay hidden while the page fits the frame. A page past the maximum
    // keeps them: that overflow is real, and hiding the bars would clip it.
    private func configureScrollers(in view: NSView) {
        func walk(_ candidate: NSView) {
            if let scrollView = candidate as? NSScrollView {
                scrollView.autohidesScrollers = true
                scrollView.hasHorizontalScroller = scrollsHorizontally
                scrollView.hasVerticalScroller = scrollsVertically
            }
            candidate.subviews.forEach(walk)
        }
        walk(view)
    }

    private func detachIfPresent(in container: NSView) {
        guard contents.view.superview === container else { return }
        contents.setVisible(false)
        contents.view.removeFromSuperview()
    }
}
