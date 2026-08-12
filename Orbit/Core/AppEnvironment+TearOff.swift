import AppKit
import Foundation

extension AppEnvironment {

    // MARK: - Tear-off: moving a live renderer between environments

    func adoptWebContents(for id: TabID, from source: AppEnvironment) {
        guard source !== self else { return }

        if let contents = source.detachWebContents(for: id) {
            // No cross-window "move" primitive exists, so this is remove-then-recreate. Must run
            // before installTransferredWebContents, while `source` can still resolve this tab as its own.
            if contents is ChromiumWebContents {
                OrbitChromiumTabsBridge.shared.tabRemoved(tabUUID: id, windowClosing: false)
            }
            installTransferredWebContents(contents, for: id)
        }

        // Must run before the mirror moves below — closes a race with source's stale deferred load.
        invalidateNavigationGeneration(for: id, in: source)

        moveMirrorEntry(id, from: source, keyPath: \.navigationStates)
        moveMirrorEntry(id, from: source, keyPath: \.themeColors)
        moveMirrorEntry(id, from: source, keyPath: \.documentColors)
        moveMirrorEntry(id, from: source, keyPath: \.mediaStates)
        moveMirrorEntry(id, from: source, keyPath: \.tabErrors)
        moveMirrorEntry(id, from: source, keyPath: \.certificateProblems)
        moveMirrorEntry(id, from: source, keyPath: \.findResultsByTab)
        // Moves the suspended continuation itself rather than resuming it —
        // whichever environment holds it is where the decision resolves.
        moveMirrorEntry(id, from: source, keyPath: \.pendingCertificateDecisions)
        moveMirrorEntry(id, from: source, keyPath: \.downloadIDByTab)
        moveMirrorMembership(id, from: source, keyPath: \.refusedCertificateTabIDs)
        moveMirrorMembership(id, from: source, keyPath: \.crashedTabs)
        moveMirrorMembership(id, from: source, keyPath: \.unresponsiveTabs)
        moveMirrorMembership(id, from: source, keyPath: \.dismissedMiniPlayerTabIDs)

        registerChromiumTab(id)
    }

    // Bumps rather than deletes: deleting would fall back to the
    // dictionary's default: 0, indistinguishable from an untouched counter.
    private func invalidateNavigationGeneration(for id: TabID, in source: AppEnvironment) {
        source.navigationGeneration[id, default: 0] += 1
    }

    private func moveMirrorEntry<Value>(
        _ id: TabID,
        from source: AppEnvironment,
        keyPath: ReferenceWritableKeyPath<AppEnvironment, [TabID: Value]>
    ) {
        guard let value = source[keyPath: keyPath].removeValue(forKey: id) else { return }
        self[keyPath: keyPath][id] = value
    }

    private func moveMirrorMembership(
        _ id: TabID,
        from source: AppEnvironment,
        keyPath: ReferenceWritableKeyPath<AppEnvironment, Set<TabID>>
    ) {
        guard source[keyPath: keyPath].remove(id) != nil else { return }
        self[keyPath: keyPath].insert(id)
    }

    // MARK: - The reverse: sending a torn-off tab back to the main window

    func moveTabToMainWindow(_ id: TabID, destinationSpaceID: SpaceID? = nil) {
        guard state.tabs[id] != nil else { return }
        let root = rootEnvironment
        guard let destination = destinationSpaceID ?? root.activeSpace?.id ?? root.spaces.first?.id else { return }
        let ownSpaceID = windowActiveSpaceID
        root.store.moveTab(id, toSpace: destination, section: .today)
        root.adoptWebContents(for: id, from: self)
        root.activateTab(id)

        OrbitWindowController.controller(for: root)?.window?.makeKeyAndOrderFront(nil)

        // state.tabs, not activeTabBySpace, which goes nil before it's known whether other tabs remain.
        if let ownSpaceID,
           !state.tabs.values.contains(where: { $0.spaceID == ownSpaceID && $0.section != .archived }) {
            OrbitWindowController.controller(for: self)?.window?.close()
        }
    }
}
