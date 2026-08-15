import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// Real NSWindow pixels: ImageRenderer cannot flatten an NSViewRepresentable, it paints an opaque placeholder.
@MainActor
final class NotesEditorTextContrastTests: XCTestCase {

    private var suiteName: String!
    private var writingStore: UserDefaults!
    private var originalShared: AppearanceSettings!
    private var previousProcessRoot: AppEnvironment!
    private var window: NSWindow?
    private var createdNoteIDs: [UUID] = []

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private static let bodyText = "The quick brown fox jumps over the lazy dog"

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-NotesContrast-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        originalShared = AppearanceSettings.shared
        AppearanceSettings.shared = AppearanceSettings(defaults: writingStore)
        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
    }

    override func tearDown() {
        for id in createdNoteIDs { env.noteStore.deleteNote(id) }
        createdNoteIDs = []
        NotesEditorView.controllerObserverForTests = nil
        window?.orderOut(nil)
        window = nil
        AppEnvironment.processRoot = previousProcessRoot
        previousProcessRoot = nil
        AppearanceSettings.shared = originalShared
        writingStore?.removePersistentDomain(forName: suiteName)
        writingStore = nil
        super.tearDown()
    }

    // MARK: - Capture

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// dlsym, not a direct call: obsoleted in the macOS 15 SDK but the symbol is still live.
    private func captureBitmap(of window: NSWindow) -> NSBitmapImageRep? {
        typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(bitPattern: Int32(window.windowNumber)), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private struct Sample {
        var background: Double
        var ink: Double
        var inkPixels: Int

        var contrast: Double {
            let lighter = max(background, ink) + 0.05
            let darker = min(background, ink) + 0.05
            return lighter / darker
        }
    }

    /// The dominant luma in the body area is the paper; the ink is the luma furthest from it.
    private func sampleBodyArea(_ bitmap: NSBitmapImageRep, size: CGSize) -> Sample? {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let area = NSRect(x: 20, y: 130, width: size.width - 40, height: 120)
        var counts: [Int: (luma: Double, count: Int)] = [:]
        for y in Int(area.minY * scale)..<min(Int(area.maxY * scale), bitmap.pixelsHigh) {
            for x in Int(area.minX * scale)..<min(Int(area.maxX * scale), bitmap.pixelsWide) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luma = 0.299 * colour.redComponent + 0.587 * colour.greenComponent + 0.114 * colour.blueComponent
                counts[Int((luma * 100).rounded()), default: (luma, 0)].count += 1
            }
        }
        let ranked = counts.values.sorted { $0.count > $1.count }
        guard let paper = ranked.first else { return nil }
        var ink = paper
        for entry in ranked where entry.count > 3 && abs(entry.luma - paper.luma) > abs(ink.luma - paper.luma) {
            ink = entry
        }
        return Sample(background: paper.luma, ink: ink.luma, inkPixels: ink.count)
    }

    private func renderNote(_ noteID: UUID, appearance: NSAppearance.Name, afterFirstLayout: ((RichTextController) -> Void)? = nil) -> Sample? {
        let size = CGSize(width: 620, height: 420)
        var seenController: RichTextController?
        NotesEditorView.controllerObserverForTests = { seenController = $0 }
        defer { NotesEditorView.controllerObserverForTests = nil }

        let hostView = NSHostingView(rootView: NotesEditorView(noteID: noteID).orbitEnvironment(env))
        hostView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        self.window = window
        pump(seconds: 0.6)

        if let afterFirstLayout {
            guard let seenController else {
                XCTFail("NotesEditorView never published its RichTextController — the test cannot reach the live NSTextView.")
                return nil
            }
            afterFirstLayout(seenController)
            pump(seconds: 0.6)
        }

        window.displayIfNeeded()
        pump(seconds: 0.3)
        guard let bitmap = captureBitmap(of: window) else { return nil }
        return sampleBodyArea(bitmap, size: size)
    }

    // MARK: - Fixtures

    private func makeNote(body: NSAttributedString) -> UUID {
        let note = env.noteStore.createNote(title: "Contrast", bodyData: NotesEditorView.encode(body) ?? Data())
        createdNoteIDs.append(note.id)
        return note.id
    }

    /// What a paste from any other app leaves behind: a resolved sRGB colour with no appearance to follow.
    private func bakedColourBody(_ colour: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: Self.bodyText,
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: colour]
        )
    }

    private func pasteRichText(_ colour: NSColor, into controller: RichTextController) {
        guard let textView = controller.textView else {
            XCTFail("The RichTextController has no NSTextView, so nothing can be pasted into it.")
            return
        }
        let source = bakedColourBody(colour)
        guard let rtf = source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]) else {
            XCTFail("Could not build RTF for the paste fixture.")
            return
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotesEditorTextContrastTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        textView.readSelection(from: pasteboard, type: .rtf)
    }

    private func assertReadable(_ sample: Sample?, appearance: String, source: String) {
        guard let sample else {
            XCTFail("Could not capture this process's own window pixels for the \(appearance) \(source) case.")
            return
        }
        XCTAssertGreaterThan(
            sample.inkPixels, 200,
            "No glyphs were rendered at all in the \(appearance) \(source) case — the fixture is broken, not the contrast."
        )
        XCTAssertGreaterThan(
            sample.contrast, 4.5,
            "Note body text in \(appearance) (\(source)) is unreadable: measured glyph luma \(String(format: "%.3f", sample.ink)) "
                + "on background luma \(String(format: "%.3f", sample.background)), a contrast ratio of "
                + "\(String(format: "%.2f", sample.contrast)):1. The body colour is baked to one appearance instead of following it."
        )
    }

    // MARK: - 1. A note already saved with a baked colour

    func test_savedNoteWithBakedBlackBodyIsReadableInDarkMode() throws {
        let id = makeNote(body: bakedColourBody(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        assertReadable(renderNote(id, appearance: .darkAqua), appearance: "dark mode", source: "saved baked-black body")
    }

    func test_savedNoteWithBakedWhiteBodyIsReadableInLightMode() throws {
        let id = makeNote(body: bakedColourBody(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        assertReadable(renderNote(id, appearance: .aqua), appearance: "light mode", source: "saved baked-white body")
    }

    // MARK: - 2. Live paste, the route the colour arrives by

    func test_pastedBlackRichTextIsReadableInDarkMode() throws {
        let id = makeNote(body: NSAttributedString(string: ""))
        let sample = renderNote(id, appearance: .darkAqua) { controller in
            self.pasteRichText(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), into: controller)
        }
        assertReadable(sample, appearance: "dark mode", source: "pasted black rich text")
    }

    // MARK: - 3. The fix must not be a hardcoded white

    func test_plainTypedNoteStaysDarkInkOnLightPaper() throws {
        let id = makeNote(body: bakedColourBody(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        guard let sample = renderNote(id, appearance: .aqua) else {
            throw XCTSkip("Could not capture this process's own window pixels on this machine.")
        }
        XCTAssertGreaterThan(
            sample.background, sample.ink,
            "In light mode the note's paper must stay lighter than its ink — measured paper luma "
                + "\(String(format: "%.3f", sample.background)) against ink luma \(String(format: "%.3f", sample.ink)), "
                + "which means the body colour was forced light instead of made to follow the appearance."
        )
        assertReadable(sample, appearance: "light mode", source: "saved baked-black body")
    }

    // MARK: - 4. A deliberate colour is not flattened

    func test_deliberatelyColouredPasteKeepsItsHue() throws {
        let red = NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        guard let decoded = NotesEditorView.decode(NotesEditorView.encode(bakedColourBody(red)) ?? Data()) else {
            XCTFail("The red fixture did not survive the archive round trip.")
            return
        }
        let stored = decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(
            stored?.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.85, accuracy: 0.02,
            "A deliberately coloured run must survive the dark-mode repair — flattening every colour to the default text colour would silently delete the user's formatting."
        )
    }
}
