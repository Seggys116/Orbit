import AppKit
import SwiftUI

// Keyed by WebContents.id, not ObjectIdentifier or Tab.id: a re-materialised WebContents is a different object, and an
// ObjectIdentifier is only an address. A page reopened after a close can be allocated where the closed one lived and
// would inherit its owner and frozen frame, leaving the pane dimmed grey with nothing a reload could change.
@MainActor
@Observable
final class WebContentsPresentation {

    static let shared = WebContentsPresentation()

    private var ownerByContents: [UUID: UUID] = [:]

    private var frozenFrameByContents: [UUID: NSImage] = [:]

    // Oldest-first, so ownership falls back to a still-on-screen host.
    private var claimantsByContents: [UUID: [UUID]] = [:]

    // Bumped when the user asks for the page (reload, reopen, selecting its tab); the host in the key window takes it.
    private var presentationRequests: [UUID: Int] = [:]

    private init() {}

    // MARK: - Ownership

    func isOwner(_ host: UUID, of contents: any WebContents) -> Bool {
        ownerByContents[contents.id] == host
    }

    /// No host holds the page yet. The first host to draw it shows it live instead of a dimmed frozen frame
    /// for the moment between building the view and its onAppear claim.
    func isUnclaimed(_ contents: any WebContents) -> Bool {
        ownerByContents[contents.id] == nil
    }

    func register(_ host: UUID, for contents: any WebContents) {
        let key = contents.id
        var claimants = claimantsByContents[key] ?? []
        if !claimants.contains(host) {
            claimants.append(host)
            claimantsByContents[key] = claimants
        }
        if ownerByContents[key] == nil {
            ownerByContents[key] = host
        }
    }

    func unregister(_ host: UUID, for contents: any WebContents) {
        unregister(host, forContentsKey: contents.id)
    }

    // By key, for the one caller that has already lost the object itself.
    func unregister(_ host: UUID, forContentsKey key: UUID) {
        claimantsByContents[key]?.removeAll { $0 == host }
        if ownerByContents[key] == host {
            ownerByContents[key] = claimantsByContents[key]?.last
        }
        if claimantsByContents[key]?.isEmpty ?? true {
            claimantsByContents.removeValue(forKey: key)
            ownerByContents.removeValue(forKey: key)
            frozenFrameByContents.removeValue(forKey: key)
            presentationRequests.removeValue(forKey: key)
        }
    }

    /// For a host whose view was destroyed without onDisappear (a panel or window torn down with it on screen).
    /// Left registered, it stays the owner, or becomes it again when the real owner leaves, and every pane
    /// showing the page is frozen grey until the user selects another tab and comes back.
    func unregisterEverywhere(_ host: UUID) {
        let keys = claimantsByContents.compactMap { $0.value.contains(host) ? $0.key : nil }
        for key in keys { unregister(host, forContentsKey: key) }
    }

    func claim(_ host: UUID, of contents: any WebContents) {
        let key = contents.id
        guard ownerByContents[key] != host else { return }
        let previousOwner = ownerByContents[key]
        register(host, for: contents)
        ownerByContents[key] = host
        // Only a host losing the page shows the freeze. A first claim has no such host, and a full-size snapshot
        // then would only compete with the page's first paint.
        guard previousOwner != nil else { return }
        // Captured before handover so the freeze matches what was showing.
        let size = contents.view.bounds.size
        Task { @MainActor [weak contents] in
            guard let contents, !contents.isClosed, size.width > 0, size.height > 0 else { return }
            if let image = await contents.capturePreview(rect: nil, size: size),
               self.claimantsByContents[contents.id] != nil {
                self.frozenFrameByContents[contents.id] = image
            }
        }
    }

    func frozenFrame(for contents: any WebContents) -> NSImage? {
        frozenFrameByContents[contents.id]
    }

    // MARK: - Explicit requests

    func requestPresentation(of contents: any WebContents) {
        // A page no host has drawn yet is claimed by the first one to appear; there is nothing to recover.
        guard claimantsByContents[contents.id] != nil else { return }
        presentationRequests[contents.id, default: 0] &+= 1
    }

    func presentationRequest(for contents: any WebContents) -> Int {
        presentationRequests[contents.id] ?? 0
    }
}

/// Lives in a host's @State so the host's registrations end with its storage, which SwiftUI releases even when
/// it skips onDisappear.
@MainActor
final class WebContentsPresentationHost {
    let id = UUID()

    deinit {
        let host = id
        if Thread.isMainThread {
            MainActor.assumeIsolated { WebContentsPresentation.shared.unregisterEverywhere(host) }
        } else {
            Task { @MainActor in WebContentsPresentation.shared.unregisterEverywhere(host) }
        }
    }
}

#if DEBUG
/// How many times a pane has been put under the dimmed freeze. A pane whose page is live must never need it.
@MainActor
enum FrozenFrameProbe {
    static var appearances = 0
}
#endif

struct FrozenWebContentsView: View {
    var image: NSImage?

    var body: some View {
        content
        #if DEBUG
            .onAppear { FrozenFrameProbe.appearances += 1 }
        #endif
    }

    private var content: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
                // Dims a picture of the page to say it is not the live one. With no picture yet, a dark wash over a blank pane reads as a grey screen with nothing behind it.
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .allowsHitTesting(false)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .clipped()
    }
}
