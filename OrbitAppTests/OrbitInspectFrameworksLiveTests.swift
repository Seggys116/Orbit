// Drives the Frameworks panel against real WebKit pages that look the way production builds look: no DevTools hook, no
// development globals, only what the frameworks leave on the DOM. Fibres and vnodes are written onto the elements by
// the page's own script, in the shapes React 18 and Vue 3 use, so nothing here depends on a framework being downloaded.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class OrbitInspectFrameworksLiveTests: XCTestCase {

    private func page(styles: String = "", body: String, script: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><title>Frameworks fixture</title>
        <meta property="og:title" content="Open Graph Title"><meta name="description" content="A described page">
        <link rel="canonical" href="https://example.com/canonical">
        <style>\(styles)</style></head>
        <body>\(body)<script>\(script)</script></body></html>
        """
    }

    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(10), _ predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func withPage(_ html: String, _ body: @escaping (OrbitFrameworksModel) async throws -> Void) throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: ["/": .init(contentType: "text/html; charset=utf-8", body: html)])
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer {
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            OrbitDevToolsStore.shared.open(contents, panel: .frameworks, inspectAt: nil, armPicker: false)
            session.select(panel: .frameworks)
            session.frameworks.refresh()
            try await body(session.frameworks)
        }
    }

    // A React 18 production tree: roots and fibres on the DOM, no hook, no React global.
    private let reactScript = """
    var root = document.getElementById('root');
    function App() {}
    function Child() {}
    function Provider() {}
    var rootFiber = { tag: 3, return: null, sibling: null, child: null, stateNode: null, memoizedProps: null };
    rootFiber.stateNode = { current: rootFiber };
    var app = { tag: 0, type: App, key: null, return: rootFiber, sibling: null, memoizedProps: { title: 'Hello' }, memoizedState: null, stateNode: null };
    var provider = { tag: 10, type: { $$typeof: 'react.provider', _context: {} }, return: app, sibling: null, memoizedProps: { value: { getState: function() { return { todos: ['buy milk'] }; }, dispatch: function() {} } }, memoizedState: null, stateNode: null };
    var child = { tag: 0, type: Child, key: 'k1', return: provider, sibling: null, memoizedProps: { count: 3 }, memoizedState: null, stateNode: null };
    var host = { tag: 5, type: 'div', return: child, sibling: null, child: null, stateNode: document.getElementById('inner'), memoizedProps: {}, memoizedState: null };
    rootFiber.child = app; app.child = provider; provider.child = child; child.child = host;
    root['__reactContainer$prod'] = rootFiber;
    document.getElementById('inner')['__reactFiber$prod'] = host;
    """

    func testAProductionReactTreeIsFoundWithNoHookAndNoGlobals() throws {
        try withPage(page(body: "<div id=\"root\"><div id=\"inner\">content</div></div>", script: reactScript)) { model in
            try await self.waitUntil("the component tree") { !model.componentNodes.isEmpty }

            XCTAssertEqual(model.componentFramework, "react")
            XCTAssertEqual(model.componentNodes.map(\.name), ["App", "Context.Provider", "Child"])
            XCTAssertEqual(model.componentRoots.count, 1)
            let child = try XCTUnwrap(model.componentNodes.first { $0.name == "Child" })
            XCTAssertEqual(child.key, "k1")
            XCTAssertEqual(child.framework, "react")
            XCTAssertNotNil(child.domNodeID, "A component must point at the element it rendered into.")
            XCTAssertTrue(child.props.keys.contains("count"))
        }
    }

    func testReactIsDetectedFromTheFibresAlone() throws {
        try withPage(page(body: "<div id=\"root\"><div id=\"inner\"></div></div>", script: reactScript)) { model in
            try await self.waitUntil("detections") { !model.detections.isEmpty }
            let react = try XCTUnwrap(model.detections.first { $0.name == "React" })
            XCTAssertEqual(react.confidence, .certain)
        }
    }

    func testALiveReduxStoreIsReadFromTheReactTree() throws {
        try withPage(page(body: "<div id=\"root\"><div id=\"inner\"></div></div>", script: reactScript)) { model in
            try await self.waitUntil("data items") { model.dataItems.contains { $0.label.hasPrefix("Redux Store") } }
            let store = try XCTUnwrap(model.dataItems.first { $0.label.hasPrefix("Redux Store") })
            XCTAssertTrue(store.rawJSON?.contains("buy milk") == true, "The store's current state must be shown: \(store.rawJSON ?? "nil")")
        }
    }

    // A Vue 3 production tree: the root container's vnode, no __vue_app__ global.
    func testAProductionVueTreeIsFoundFromTheRootContainer() throws {
        let script = """
        var container = document.getElementById('app');
        var childInstance = { type: { __name: 'Child' }, props: { label: 'hi' }, setupState: { n: 2 }, vnode: { el: document.getElementById('child-el') }, subTree: { children: [] } };
        var rootInstance = {
          type: { name: 'App' }, props: { msg: 'x' }, setupState: { count: 1 }, vnode: { el: container }, parent: null,
          subTree: { children: [ { component: childInstance }, { children: [ { children: [] } ] } ] },
          appContext: { config: { globalProperties: { $pinia: { state: { value: { counter: { n: 7 } } } } } } }
        };
        container._vnode = { shapeFlag: 4, component: rootInstance };
        container.setAttribute('data-v-app', '');
        """
        try withPage(page(body: "<div id=\"app\"><div id=\"child-el\"></div></div>", script: script)) { model in
            try await self.waitUntil("the component tree") { !model.componentNodes.isEmpty }

            XCTAssertEqual(model.componentFramework, "vue")
            XCTAssertEqual(model.componentNodes.map(\.name), ["App", "Child"])
            XCTAssertEqual(model.componentNodes.first { $0.name == "Child" }?.framework, "vue", "A Vue node must not be labelled React.")
            XCTAssertTrue(model.componentNodes.first { $0.name == "App" }?.hooks.contains { $0.value.contains("count") } == true, "setup state should be listed")

            try await self.waitUntil("pinia data") { model.dataItems.contains { $0.label == "Pinia Stores" } }
            XCTAssertTrue(model.dataItems.first { $0.label == "Pinia Stores" }?.rawJSON?.contains("\"n\": 7") == true)
            XCTAssertNotNil(model.detections.first { $0.name == "Vue" })
        }
    }

    func testCustomElementsAreTheTreeWhenNothingElseIsMounted() throws {
        let body = "<my-card id=\"card\" title=\"Hello\"><my-badge></my-badge></my-card><p>plain</p>"
        try withPage(page(body: body, script: "")) { model in
            try await self.waitUntil("the component tree") { !model.componentNodes.isEmpty }

            XCTAssertEqual(model.componentFramework, "webcomponents")
            XCTAssertEqual(model.componentNodes.map(\.name), ["<my-card>", "<my-badge>"])
            XCTAssertEqual(model.componentRoots.count, 1)
            XCTAssertEqual(model.componentNodes.first?.childIDs.count, 1, "The badge sits inside the card.")
        }
    }

    func testAPageWithNoFrameworkSaysWhyThereIsNoTree() throws {
        try withPage(page(body: "<p>plain</p>", script: "")) { model in
            try await self.waitUntil("a note") { model.treeNote != nil }

            XCTAssertTrue(model.componentNodes.isEmpty)
            XCTAssertTrue(model.treeNote?.contains("found none mounted") == true, "got \(model.treeNote ?? "nil")")
        }
    }

    func testTailwindIsDetectedFromClassesAndStylesheetVariables() throws {
        let styles = "*, ::before, ::after { --tw-ring-offset-width: 0px; --tw-shadow: 0 0 #0000; } .flex { display: flex }"
        let body = """
        <div class="flex items-center justify-between px-4 py-2 md:flex hover:bg-gray-100 text-sm text-gray-700 rounded-lg shadow-md w-1/2 mt-4 gap-2">
        <span class="font-semibold dark:bg-gray-900 lg:grid-cols-3">hello</span></div>
        """
        try withPage(page(styles: styles, body: body, script: "")) { model in
            try await self.waitUntil("a Tailwind detection") { model.detections.contains { $0.name == "Tailwind CSS" } }

            let tailwind = try XCTUnwrap(model.detections.first { $0.name == "Tailwind CSS" })
            XCTAssertEqual(tailwind.confidence, .certain, "The --tw-* stylesheet variables settle it.")
            XCTAssertEqual(tailwind.category, .styling)
            XCTAssertTrue(tailwind.evidence.contains { $0.contains("--tw-") })
            XCTAssertTrue(tailwind.evidence.contains { $0.contains("utility classes") })
        }
    }

    func testPageMetadataAndEmbeddedStateAreOfferedAsData() throws {
        let script = """
        var state = { user: { id: 1 }, list: [1, 2, 3] }; state.self = state;
        window.APP_STORE = state;
        window.__INITIAL_DATA__ = { greeting: 'hello' };
        window.dataLayer = [{ event: 'gtm.js' }];
        """
        try withPage(page(body: "<p>x</p>", script: script)) { model in
            try await self.waitUntil("page metadata") { model.dataItems.contains { $0.id == "page-metadata" } }

            let metadata = try XCTUnwrap(model.dataItems.first { $0.id == "page-metadata" }?.rawJSON)
            XCTAssertTrue(metadata.contains("Open Graph Title"))
            XCTAssertTrue(metadata.contains("https://example.com/canonical"))
            XCTAssertTrue(metadata.contains("A described page"))

            let embedded = try XCTUnwrap(model.dataItems.first { $0.id == "embedded-APP_STORE" }?.rawJSON, "a global named like state should be offered")
            XCTAssertTrue(embedded.contains("[Circular]"), "A cyclic object must serialise, not vanish: \(embedded)")
            XCTAssertTrue(model.dataItems.first { $0.id == "embedded-__INITIAL_DATA__" }?.rawJSON?.contains("hello") == true)
            XCTAssertTrue(model.dataItems.first { $0.label == "Tag Manager dataLayer" }?.rawJSON?.contains("gtm.js") == true)
        }
    }
}
