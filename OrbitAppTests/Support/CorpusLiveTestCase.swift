//  Every corpus suite shares one engine process, so an extension left loaded leaks
//  into the next suite's page; tearDown fails the suite that broke it, not the one after.

import Foundation
import XCTest
@testable import Orbit

@MainActor
class CorpusLiveTestCase: LiveEnvironmentTestCase {

    private var extensionsAtStart: Set<String> = []

    override func setUp() {
        super.setUp()
        extensionsAtStart = Self.loadedExtensionIDs()
    }

    override func tearDown() {
        super.tearDown()
        unloadWhatThisSuiteLeftBehind()
    }

    /// Empty before the first live test in the process starts an engine; a
    /// suite that skips on the live-engine gate never reaches one at all.
    static func loadedExtensionIDs() -> Set<String> {
        guard let engine = LiveChromiumEngineHost.startedEngine else { return [] }
        return Set(engine.loadedExtensions(session: engine.defaultSession).map(\.id))
    }

    private func unloadWhatThisSuiteLeftBehind() {
        guard let engine = LiveChromiumEngineHost.startedEngine else { return }
        let leaked = Self.loadedExtensionIDs().subtracting(extensionsAtStart).sorted()
        guard !leaked.isEmpty else { return }
        for id in leaked {
            engine.unloadExtension(id: id, session: engine.defaultSession)
        }
        XCTFail(
            """
            this suite left \(leaked.joined(separator: ", ")) loaded in the shared engine. Every \
            corpus suite must unload what it loads -- `defer { engine.unloadExtension(id:session:) }` \
            immediately after the load -- because the next suite's page is filtered by whatever is \
            still there, and the failure lands on that suite instead of this one.
            """
        )
    }
}
