import Foundation
import OSLog

/// Which directory the engine's profile lives in; resolved to a real path
/// by EngineStorageDirectory and handed to the engine before it starts.
public enum EngineStorage {
    /// The real user's profile at ~/Library/Application Support/Orbit.
    case persistent
    /// No extensions, every session in-memory, private directory.
    case ephemeral
    /// Extensions and persistent sessions, in a private per-process directory.
    case isolated
}

/// The one place Orbit picks a `BrowserEngine` implementation. A second
/// implementation adds its own `#elseif` branch and start helper here;
/// nothing else in the app should need to know which engine is compiled in.
@MainActor
enum EngineFactory {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "EngineFactory")

    /// Traps on failure; does not throw or return an optional.
    static func makeEngine(storage: EngineStorage = .persistent) -> BrowserEngine {
        let engine = ChromiumEngine(storage: storage)
        do {
            try engine.start()
        } catch {
            logger.fault("ChromiumEngine.start() failed: \(String(describing: error), privacy: .public)")
            fatalError("ChromiumEngine.start() failed: \(error)")
        }
        installBuiltInUserScripts(on: engine)
        // Not under XCTest: a hosted test run must not load the real user's
        // installed extensions into its engine.
        if storage != .ephemeral, !DebugFlags.isRunningUnderTests {
            ExtensionRuntime.shared.bind(to: engine)
        }
        return engine
    }

    // Every one of these is load-bearing for chrome UI (media session, pane
    // header colour, link hover). BoostRuntime installs user scripts separately.
    private static func installBuiltInUserScripts(on engine: BrowserEngine) {
        let session = engine.defaultSession
        for script in [
            MediaSessionObserverScript.chromiumUserScript,
            PageColorObserverScript.chromiumUserScript,
            LinkHoverObserverScript.chromiumUserScript,
            MediaTransportScript.userScript,
            PageScrollbarStyleScript.userScript,
        ] {
            engine.addUserScript(script, session: session)
        }
    }
}
