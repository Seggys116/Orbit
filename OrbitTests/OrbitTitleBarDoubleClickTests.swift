import XCTest
import AppKit

@MainActor
final class OrbitTitleBarDoubleClickTests: XCTestCase {

    private struct MockPreferences: OrbitPreferenceReading {
        var values: [String: String] = [:]
        func string(forKey defaultName: String) -> String? { values[defaultName] }
    }

    // MARK: - Reading the system preference

    func test_resolveAction_maximizePreference_readsAsZoom() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "Maximize"])
        XCTAssertEqual(OrbitTitleBarDoubleClick.resolveAction(defaults: d), .zoom)
    }

    func test_resolveAction_minimizePreference_readsAsMinimize() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "Minimize"])
        XCTAssertEqual(OrbitTitleBarDoubleClick.resolveAction(defaults: d), .minimize)
    }

    func test_resolveAction_nonePreference_readsAsNone() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "None"])
        XCTAssertEqual(OrbitTitleBarDoubleClick.resolveAction(defaults: d), .none)
    }

    func test_resolveAction_unsetPreference_defaultsToZoom() {
        let d = MockPreferences(values: [:])
        XCTAssertNil(d.string(forKey: OrbitTitleBarDoubleClick.preferenceKey), "test precondition: key genuinely absent")
        XCTAssertEqual(OrbitTitleBarDoubleClick.resolveAction(defaults: d), .zoom)
    }

    func test_resolveAction_unrecognisedValue_fallsBackToZoom() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "SomeFutureMacOSValueThisCodeDoesNotKnowAbout"])
        XCTAssertEqual(OrbitTitleBarDoubleClick.resolveAction(defaults: d), .zoom)
    }

    // MARK: - Dispatching to the real NSWindow selector

    func test_handle_zoomPreference_callsPerformZoom() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "Maximize"])
        let window = RecordingWindow()

        OrbitTitleBarDoubleClick.handle(on: window, defaults: d)

        XCTAssertEqual(window.calls, [.zoom])
    }

    func test_handle_minimizePreference_callsPerformMiniaturize() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "Minimize"])
        let window = RecordingWindow()

        OrbitTitleBarDoubleClick.handle(on: window, defaults: d)

        XCTAssertEqual(window.calls, [.miniaturize])
    }

    func test_handle_nonePreference_callsNeitherSelector() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "None"])
        let window = RecordingWindow()

        OrbitTitleBarDoubleClick.handle(on: window, defaults: d)

        XCTAssertTrue(window.calls.isEmpty, "\"None\" must not zoom or minimize — the user explicitly turned this off.")
    }

    func test_handle_nilWindow_doesNotCrash() {
        let d = MockPreferences(values: [OrbitTitleBarDoubleClick.preferenceKey: "Maximize"])
        OrbitTitleBarDoubleClick.handle(on: nil, defaults: d)
    }
}

private final class RecordingWindow: NSWindow {
    enum Call: Equatable { case miniaturize, zoom }
    private(set) var calls: [Call] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override func performMiniaturize(_ sender: Any?) { calls.append(.miniaturize) }
    override func performZoom(_ sender: Any?) { calls.append(.zoom) }
}
