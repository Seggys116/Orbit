import XCTest
import SwiftUI
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class CommandBarLiveTypingTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var spaceID: SpaceID!
    private var profileID: ProfileID!
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        profileID = env.createDefaultProfileIfNeeded()
        spaceID = env.createSpace(
            name: "Live",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(style: .solid, colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.12)], grain: 0),
            profileID: profileID
        )
        env.state.activeSpaceID = spaceID
        env.state.tabs = [:]
        for index in env.state.spaces.indices {
            env.state.spaces[index].favorites = []
        }
    }

    override func tearDown() {
        CommandBarView.testResultsObserver = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private var observed: [(query: String, rows: [String])] = []

    private func observeResults() {
        observed = []
        CommandBarView.testResultsObserver = { [weak self] query, results in
            self?.observed.append((query: query, rows: results.map { "\($0.id)/\($0.title)" }))
        }
    }

    // MARK: - Harness

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @discardableResult
    private func recordVisit(url: URL, title: String, timeout: TimeInterval = 5) -> Bool {
        env.recordVisit(url: url, title: title, profileID: profileID, spaceID: spaceID, wasTyped: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if env.localHistoryCache.contains(where: { $0.url == url }) { return true }
            pump(seconds: 0.02)
        }
        XCTFail("History never recorded \(title); the scenario would be vacuous.")
        return false
    }

    private func mountCommandBar() -> NSWindow {
        env.commandBarMode = .newTab
        env.isCommandBarPresented = true

        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: OrbitMetrics.commandBarWidth, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let hosting = NSHostingView(rootView: AnyView(CommandBarView().environment(env)))
        // Left at []: default sizing options collapse the window to the panel's minimum height.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.setContentSize(NSSize(width: OrbitMetrics.commandBarWidth, height: 520))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump(seconds: 0.4)
        return window
    }

    private func type(_ text: String, into window: NSWindow) -> Bool {
        guard let editor = fieldEditor(in: window) else {
            XCTFail("""
            The Command Bar's field never became first responder, so nothing below typed anything.
            first responder: \(String(describing: window.firstResponder))
            view tree: \(describeTree(window.contentView))
            """)
            return false
        }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            pump(seconds: 0.03)
        }
        return true
    }

    private func fieldEditor(in window: NSWindow) -> NSTextView? {
        if let editor = window.firstResponder as? NSTextView { return editor }
        if let editor = firstDescendant(of: window.contentView, ofType: NSTextView.self) { return editor }
        if let field = firstDescendant(of: window.contentView, ofType: NSTextField.self) {
            window.makeFirstResponder(field)
            pump(seconds: 0.2)
            if let editor = window.firstResponder as? NSTextView { return editor }
            return firstDescendant(of: window.contentView, ofType: NSTextView.self)
        }
        return nil
    }

    private func firstDescendant<T: NSView>(of view: NSView?, ofType type: T.Type) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    private func describeTree(_ view: NSView?, depth: Int = 0) -> String {
        guard let view else { return "" }
        let line = String(repeating: "  ", count: depth) + String(describing: Swift.type(of: view))
        return ([line] + view.subviews.map { describeTree($0, depth: depth + 1) }).joined(separator: "\n")
    }

    private func firstRowIconChroma(of window: NSWindow) -> Double? {
        guard let bitmap = captureBitmap(of: window) else { return nil }
        let scale = Double(bitmap.pixelsWide) / Double(window.frame.width)
        let iconOriginX = (6.0 + 10.0) * scale
        let iconOriginY = (52.0 + 1.0 + 6.0 + 14.0) * scale
        let iconExtent = 16.0 * scale
        var maxChroma = 0.0
        var samples = 0
        var y = iconOriginY
        while y < iconOriginY + iconExtent {
            var x = iconOriginX
            while x < iconOriginX + iconExtent {
                if let colour = bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) {
                    let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                    maxChroma = max(maxChroma, (channels.max() ?? 0) - (channels.min() ?? 0))
                    samples += 1
                }
                x += 1
            }
            y += 1
        }
        return samples > 0 ? maxChroma : nil
    }

    private func captureBitmap(of window: NSWindow) -> NSBitmapImageRep? {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    @discardableResult
    private func captureWindow(_ window: NSWindow, to path: String) -> Bool {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return false }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        return true
    }

    private func pressReturn(in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Could not synthesise a Return key event.")
            return
        }
        window.sendEvent(event)
        pump(seconds: 0.4)
    }

    private var openedURLs: [URL] {
        env.state.tabs.values.map(\.url)
    }

    // MARK: - The reported scenario

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_typingATermThatMatchesNothingAndPressingReturnSearchesForIt

    func test_typingATermThatMatchesNothingAndPressingReturnSearchesForIt() {
        guard recordVisit(url: URL(string: "https://www.figma.com/file/abc123/Q4-Roadmap")!, title: "Q4 Roadmap — Figma") else { return }
        guard recordVisit(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Gmail") else { return }
        guard recordVisit(url: URL(string: "https://linear.app/orbit/cycle/42")!, title: "2024-Q4 cycle — Linear") else { return }

        let window = mountCommandBar()
        guard type("wikipedia ", into: window) else { return }
        pump(seconds: 1.2)

        pressReturn(in: window)

        guard let opened = openedURLs.first(where: { $0.absoluteString.contains("wikipedia") || $0.host()?.contains("figma") == true || $0.host()?.contains("google") == true || $0.host()?.contains("linear") == true }) else {
            return XCTFail("Return opened nothing at all. Tabs: \(openedURLs.map(\.absoluteString))")
        }

        XCTAssertFalse(
            opened.host()?.contains("figma") == true || opened.host()?.contains("linear") == true || opened.absoluteString.contains("mail.google.com"),
            "Return opened a page with no relationship to \"wikipedia\": \(opened.absoluteString)"
        )
        XCTAssertTrue(
            opened.absoluteString.lowercased().contains("wikipedia"),
            "Return must have committed the typed term, as a search or an address. Opened: \(opened.absoluteString)"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_fastTypingOverALargeHistoryStillCommitsWhatWasTyped

    func test_fastTypingOverALargeHistoryStillCommitsWhatWasTyped() {
        for index in 1...240 {
            env.recordVisit(
                url: URL(string: "https://www.example-\(index).com/page")!,
                title: "Recent page \(index)",
                profileID: profileID,
                spaceID: spaceID,
                wasTyped: true
            )
        }
        guard recordVisit(url: URL(string: "https://www.figma.com/file/abc123/Q4-Roadmap")!, title: "Q4 Roadmap — Figma") else { return }
        pump(seconds: 1.0)

        observeResults()
        let window = mountCommandBar()
        guard let editor = fieldEditor(in: window) else {
            return XCTFail("The Command Bar's field never became first responder.")
        }
        for character in "wikipedia " {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        pump(seconds: 2.5)
        for (index, entry) in observed.enumerated() {
            print("[live] publish #\(index) for \"\(entry.query)\": \(entry.rows.prefix(4).joined(separator: " | "))")
        }
        guard let published = observed.last else {
            return XCTFail("The view never published a result list.")
        }
        XCTAssertEqual(published.query, "wikipedia ", "The last list published was built for \"\(published.query)\".")
        XCTAssertEqual(
            published.rows.first?.hasPrefix("search-wikipedia"), true,
            "The top row of the published list must be the typed term. Got: \(published.rows.prefix(4))"
        )

        let capturePath = NSTemporaryDirectory() + "orbit-command-bar-live.png"
        captureWindow(window, to: capturePath)
        guard let chroma = firstRowIconChroma(of: window) else {
            return XCTFail("Could not read the window's pixels, so nothing below verifies what is on screen.")
        }
        print("[live] first row icon chroma: \(chroma) — capture: \(capturePath)")
        XCTAssertLessThan(
            chroma, 0.25,
            """
            The first row on screen is drawing a saturated favicon, so it is one of the user's own \
            pages — not the grey magnifier of the "search for what I typed" row. The list published \
            was \(published.rows.prefix(3)), so the rows on screen are stale. Capture: \(capturePath)
            """
        )
        pressReturn(in: window)

        let opened = openedURLs.filter { $0.absoluteString != "orbit://new-tab" }
        XCTAssertTrue(
            opened.contains { $0.absoluteString.lowercased().contains("wikipedia") },
            """
            Return did not commit what was typed. This is the reported failure: a stale, broad, \
            early result set landed after the correct one, so the top row was the most recently \
            visited page rather than the query. Opened: \(opened.map(\.absoluteString))
            """
        )
        XCTAssertFalse(
            opened.contains { $0.host()?.contains("figma") == true || $0.host()?.hasPrefix("www.example-") == true },
            "Return opened a page from the stale result set: \(opened.map(\.absoluteString))"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_typingATermThatMatchesHistoryAndPressingReturnOpensThatPage

    func test_typingATermThatMatchesHistoryAndPressingReturnOpensThatPage() {
        let wikipedia = URL(string: "https://en.wikipedia.org/wiki/Orbital_mechanics")!
        guard recordVisit(url: URL(string: "https://www.figma.com/file/abc123/Q4-Roadmap")!, title: "Q4 Roadmap — Figma") else { return }
        guard recordVisit(url: wikipedia, title: "Orbital mechanics — Wikipedia") else { return }

        let window = mountCommandBar()
        guard type("orbital mechanics", into: window) else { return }
        pump(seconds: 1.2)
        pressReturn(in: window)

        XCTAssertTrue(
            openedURLs.contains(wikipedia),
            "The page whose title is exactly what was typed was not what Return opened. Tabs: \(openedURLs.map(\.absoluteString))"
        )
    }

    // MARK: - Appearing

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_thePanelDoesNotGrowIntoPlaceWhileItAppears

    func test_thePanelDoesNotGrowIntoPlaceWhileItAppears() {
        guard recordVisit(url: URL(string: "https://www.figma.com/file/abc123/Q4-Roadmap")!, title: "Q4 Roadmap — Figma") else { return }
        guard recordVisit(url: URL(string: "https://en.wikipedia.org/wiki/Orbital_mechanics")!, title: "Orbital mechanics — Wikipedia") else { return }
        guard recordVisit(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News") else { return }

        env.commandBarMode = .newTab
        env.isCommandBarPresented = false

        let seed = CommandBarEngine.results(query: "", mode: .newTab, env: env, suggestions: [])
        XCTAssertFalse(seed.isEmpty, "The no-query list is empty, so the seeded panel would legitimately open at its bare input-row height.")

        var heights: [CGFloat] = []
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: AnyView(
                CommandBarPresentationProbe { height in
                    if height > 0 { heights.append(height) }
                }
                .environment(env)
            )
        )
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump(seconds: 0.4)

        env.isCommandBarPresented = true
        pump(seconds: 0.9)

        guard let first = heights.first, let tallest = heights.max() else {
            return XCTFail("The panel never reported a height, so there is nothing here to assert on.")
        }
        XCTAssertGreaterThan(tallest, 120, "The panel never grew past its bare input row, so it has no result list and this test is vacuous.")

        XCTAssertEqual(
            first, tallest, accuracy: 1,
            """
            The panel was first laid out at \(first)pt and ended at \(tallest)pt — it grew into place. \
            Every height it was laid out at, in order: \(heights).
            """
        )
        XCTAssertLessThanOrEqual(
            Set(heights.map { ($0 * 2).rounded() }).count, 2,
            """
            The panel was laid out at \(Set(heights).count) distinct heights while appearing: \(heights). \
            One is the ordinary case; two is the asynchronous history pass widening the list after it landed. \
            More than that is an animation running on the panel's own size.
            """
        )
    }
}

private struct CommandBarPresentationProbe: View {
    @Environment(AppEnvironment.self) private var env

    var onHeight: (CGFloat) -> Void

    private struct PanelHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if env.isCommandBarPresented {
                    CommandBarView(seededFrom: env)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .transition(.opacity)
                }
            }
            .animation(OrbitMotion.standard, value: env.isCommandBarPresented)
            .onPreferenceChange(PanelHeightKey.self) { height in
                Task { @MainActor in onHeight(height) }
            }
    }
}
