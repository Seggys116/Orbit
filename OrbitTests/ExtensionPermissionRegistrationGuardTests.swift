// The WebKit wrapper acts on a permission only when the extension declared it (or the user granted
// it as optional). WebKit drops manifest permissions it does not recognise, so the wrapper is the
// only thing that makes bookmarks, history, management and the rest exist, and a permission it
// forgets turns its whole namespace into undefined. Host-less: runs the generated wrapper.

import WebKit
import XCTest

final class ExtensionPermissionRegistrationGuardTests: XCTestCase {

    private typealias Runtime = ChromeWrapperRuntime
    private typealias Inventory = ChromeAPISurfaceInventory

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func text(at url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(
            text.count, 500,
            "Walked \(text.count) characters of \(url.path). That is far too few -- the path resolution is wrong and every check below would pass vacuously."
        )
        return text
    }

    /// The grant list the generated wrapper carries into the extension.
    private func grantedList(in script: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"var GRANTED = \[([^\]]*)\];"#)
        let range = NSRange(script.startIndex..., in: script)
        let match = try XCTUnwrap(expression.firstMatch(in: script, range: range), "the generated wrapper carries no grant list")
        let body = (script as NSString).substring(with: match.range(at: 1))
        return body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }
    }

    // MARK: - What the wrapper acts on

    func test_theWebKitNativePermissionListIsWebKitsOwn() {
        let sdk = Set([
            WKWebExtension.Permission.activeTab, .alarms, .clipboardWrite, .contextMenus, .cookies,
            .declarativeNetRequest, .declarativeNetRequestFeedback, .declarativeNetRequestWithHostAccess,
            .menus, .nativeMessaging, .scripting, .storage, .tabs, .unlimitedStorage, .webNavigation, .webRequest,
        ].map(\.rawValue))
        XCTAssertEqual(
            Inventory.webKitNativePermissions, sdk,
            "the inventory's list of permissions WebKit recognises is not the SDK's. A permission missing from it is reported as having no provider; an extra one hides a permission nothing implements."
        )
    }

    func test_everyPermissionTheWrapperActsOnIsDisjointFromWebKitsAndNamesANamespaceOrAFlag() {
        let wrapped = Inventory.wrappedPermissions
        XCTAssertEqual(
            wrapped.intersection(Inventory.webKitNativePermissions).sorted(), [],
            "a permission cannot be both the wrapper's and WebKit's: WebKit's grant would be shadowed or doubled"
        )
        let names = Set(Inventory.namespaces.map(\.name))
        XCTAssertEqual(
            wrapped.subtracting(names).sorted(), Inventory.additionalWrappedPermissions.sorted(),
            "a wrapped permission that is neither a namespace nor a declared flag is one nothing reads"
        )
    }

    func test_eachWrappedPermissionDeclaredOnItsOwnIsGrantedAndCreatesItsNamespace() throws {
        let namespaceNames = Set(Inventory.namespaces.map(\.name))
        for permission in Inventory.wrappedPermissions.sorted() {
            let generated = try Runtime.generate(manifestPermissions: [permission])
            XCTAssertEqual(
                try grantedList(in: generated.script), [permission],
                "declaring \(permission) alone must grant exactly \(permission)"
            )
            let session = try Runtime.start(manifestPermissions: [permission])
            XCTAssertEqual(session.failures, [])
            let created = namespaceNames.union(["privacy"]).filter { session.exists($0) }
            let ungated = Set(Inventory.namespaces.filter { !$0.ungatedMethods.isEmpty }.map(\.name))
            let expected: Set<String> = namespaceNames.contains(permission) || permission == "privacy"
                ? Set([permission]).union(ungated) : ungated
            XCTAssertEqual(
                created, expected,
                "declaring \(permission) alone created the wrong namespaces; one that exists without its permission is a permission check that never denies, one that is missing is an API an extension asked for and cannot reach"
            )
        }
    }

    func test_permissionsTheWrapperDoesNotActOnAreNeverGranted() throws {
        let unrelated = ["tabs", "storage", "scripting", "alarms", "webNavigation", "cookies", "nativeMessaging", "clipboardRead", "notifications"]
        let generated = try Runtime.generate(manifestPermissions: unrelated)
        XCTAssertEqual(
            try grantedList(in: generated.script), [],
            "the wrapper granted a permission it neither owns nor needs; nativeMessaging in particular is WebKit's transport and must never be a wrapper grant"
        )
    }

    func test_theWrapperLeavesTheManifestsPermissionsAsDeclared() throws {
        let permissions = ["bookmarks", "history", "storage", "tabs"]
        let optional = ["management", "downloads"]
        let generated = try Runtime.generate(manifestPermissions: permissions, optionalPermissions: optional)
        XCTAssertEqual(generated.manifest["permissions"] as? [String], permissions)
        XCTAssertEqual(
            generated.manifest["optional_permissions"] as? [String], optional,
            "the wrapper rewrote optional_permissions, so an extension would see a different consent prompt than the one it declared"
        )
        XCTAssertFalse(
            (generated.manifest["permissions"] as? [String] ?? []).contains("nativeMessaging"),
            "the wrapper added nativeMessaging to the manifest; its transport is granted on the context and never written to the manifest"
        )
        XCTAssertFalse(
            ((generated.manifest["description"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            "WebKit refuses a manifest with a blank description, and Chrome does not"
        )
    }

    // MARK: - Optional permissions

    func test_anOptionalPermissionIsGrantedOnlyOnceTheUserGrantedIt() throws {
        let generated = try Runtime.generate(
            manifestPermissions: [], optionalPermissions: ["history", "bookmarks"], grantedOptional: ["history"]
        )
        XCTAssertEqual(try grantedList(in: generated.script), ["history"])

        let session = try Runtime.start(
            manifestPermissions: [], optionalPermissions: ["history", "bookmarks"], grantedOptional: ["history"]
        )
        XCTAssertTrue(session.exists("history"), "a granted optional permission must exist from the first line")
        XCTAssertFalse(session.exists("bookmarks"), "an optional permission the user never granted created its namespace")

        let ungranted = try Runtime.start(manifestPermissions: [], optionalPermissions: ["history", "bookmarks"])
        XCTAssertFalse(ungranted.exists("history"))
        XCTAssertFalse(ungranted.exists("bookmarks"))
    }

    func test_aGrantDeliveredAtRuntimeCreatesTheNamespaceAndARevokeTakesItAway() throws {
        let session = try Runtime.start(manifestPermissions: [], optionalPermissions: ["history"])
        XCTAssertFalse(session.exists("history"))

        session.deliverGrants(["history"])
        XCTAssertEqual(session.failures, [])
        let granted = try XCTUnwrap(session.members(of: "history"), "a grant pushed by Orbit did not create chrome.history")
        XCTAssertEqual(granted.functions, Set(try XCTUnwrap(Inventory.namespaces.first { $0.name == "history" }).methods))
        XCTAssertEqual(granted.events, Set(["onVisited", "onVisitRemoved"]))

        session.deliverGrants([])
        XCTAssertFalse(session.exists("history"), "revoking the permission left chrome.history behind")
    }

    // MARK: - chrome.management keeps its ungated members

    func test_managementIsDefinedWithoutItsPermissionButKeepsOnlyTheUngatedMembers() throws {
        let management = try XCTUnwrap(Inventory.namespaces.first { $0.name == "management" })
        XCTAssertEqual(Set(management.ungatedMethods), ["getSelf", "uninstallSelf", "getPermissionWarningsByManifest"])

        let without = try XCTUnwrap(
            try Runtime.start(manifestPermissions: []).members(of: "management"),
            "chrome.management is undefined without the permission; upstream keeps its dependency-free members for every extension, so getSelf() would break for anything that calls it"
        )
        XCTAssertEqual(without.functions, Set(management.ungatedMethods))
        XCTAssertEqual(without.events, [], "management events exist for an extension that never asked for management")

        let with = try XCTUnwrap(try Runtime.start(manifestPermissions: ["management"]).members(of: "management"))
        XCTAssertEqual(with.functions, Set(management.methods))
        XCTAssertEqual(with.events, Set(management.events))

        let revoked = try Runtime.start(manifestPermissions: [], optionalPermissions: ["management"], grantedOptional: ["management"])
        revoked.deliverGrants([])
        let afterRevoke = try XCTUnwrap(revoked.members(of: "management"))
        XCTAssertEqual(afterRevoke.functions, Set(management.ungatedMethods), "revoking management must fall back to the ungated members")
        XCTAssertEqual(afterRevoke.events, [])
    }

    // MARK: - chrome.scripting is WebKit's

    func test_scriptingIsWebKitsAndTheWrapperOnlyCompletesIt() throws {
        XCTAssertTrue(Inventory.webKitNativePermissions.contains("scripting"))
        XCTAssertFalse(
            Inventory.wrappedPermissions.contains("scripting"),
            "scripting is provided by WebKit; wrapping it too would shadow WebKit's real executeScript"
        )
        let session = try Runtime.start(manifestPermissions: ["scripting"])
        XCTAssertEqual(session.value(of: "chrome.scripting.ExecutionWorld.MAIN") as? String, "MAIN")
        XCTAssertEqual(session.value(of: "chrome.scripting.ExecutionWorld.ISOLATED") as? String, "ISOLATED")
        XCTAssertEqual(
            session.members(of: "scripting")?.functions, Set<String>(),
            "the wrapper must not define scripting functions of its own over WebKit's"
        )
    }

    // MARK: - Blocking authentication needs its own permission

    func test_aBlockingOnAuthRequiredListenerNeedsTheWebRequestAuthProviderPermission() throws {
        let attempt = """
        (function () {
          try {
            chrome.webRequest.onAuthRequired.addListener(function () {}, { urls: ["<all_urls>"] }, ["blocking"]);
            return "accepted";
          } catch (error) { return String(error.message); }
        })()
        """
        let denied = try Runtime.start(manifestPermissions: ["webRequest"])
        let refusal = try XCTUnwrap(denied.value(of: attempt) as? String)
        XCTAssertTrue(
            refusal.contains("webRequestAuthProvider"),
            "a blocking auth listener was not refused for lack of the permission: \(refusal)"
        )

        let allowed = try Runtime.start(manifestPermissions: ["webRequest", "webRequestAuthProvider"])
        XCTAssertEqual(allowed.value(of: attempt) as? String, "accepted")
    }

    // MARK: - Source invariants (security)

    /// Source invariants on purpose: nothing observable at runtime tells a blanket grant from a
    /// requested one until an extension abuses it.
    func test_theEngineGrantsOnlyWhatTheExtensionRequested() throws {
        let engine = try text(at: repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"))
        XCTAssertTrue(engine.contains("for permission in webExtension.requestedPermissions"))
        XCTAssertTrue(engine.contains("setPermissionStatus(.grantedExplicitly, for: permission)"))
        XCTAssertFalse(
            engine.contains("Permission(\"nativeMessaging\")") || engine.contains("for: .nativeMessaging"),
            "the engine grants nativeMessaging itself; only the declared-permission gate in WebKitExtensionServices may open that transport"
        )
        XCTAssertFalse(
            engine.contains("Permission(\"<all_urls>\")"),
            "the engine grants every origin to every extension instead of what each one declared"
        )
    }

    func test_theTransportGrantIsMadeOnTheContextAndGatedOnTheDeclaration() throws {
        let services = try text(at: repositoryFile("Orbit/Engine/WebKit/WebKitExtensionServices.swift"))
        XCTAssertTrue(services.contains("context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)"))
        XCTAssertTrue(
            services.contains("if name == WKWebExtension.Permission.nativeMessaging.rawValue { return entry.declaresNativeMessaging }"),
            "chrome.permissions must never report nativeMessaging for an extension that did not declare it: the reserved transport grant is Orbit's, not the extension's"
        )
    }
}
