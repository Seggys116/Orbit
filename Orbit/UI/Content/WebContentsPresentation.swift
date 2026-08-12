import AppKit
import SwiftUI

// Keyed by ObjectIdentifier, not Tab.id: a re-materialised WebContents is a different object.
@MainActor
@Observable
final class WebContentsPresentation {

    static let shared = WebContentsPresentation()

    private var ownerByContents: [ObjectIdentifier: UUID] = [:]

    private var frozenFrameByContents: [ObjectIdentifier: NSImage] = [:]

    // Oldest-first, so ownership falls back to a still-on-screen host.
    private var claimantsByContents: [ObjectIdentifier: [UUID]] = [:]

    private init() {}

    // MARK: - Ownership

    func isOwner(_ host: UUID, of contents: any WebContents) -> Bool {
        ownerByContents[ObjectIdentifier(contents)] == host
    }

    func register(_ host: UUID, for contents: any WebContents) {
        let key = ObjectIdentifier(contents)
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
        unregister(host, forContentsKey: ObjectIdentifier(contents))
    }

    // By key, for the one caller that has already lost the object itself.
    func unregister(_ host: UUID, forContentsKey key: ObjectIdentifier) {
        claimantsByContents[key]?.removeAll { $0 == host }
        if ownerByContents[key] == host {
            ownerByContents[key] = claimantsByContents[key]?.last
        }
        if claimantsByContents[key]?.isEmpty ?? true {
            claimantsByContents.removeValue(forKey: key)
            ownerByContents.removeValue(forKey: key)
            frozenFrameByContents.removeValue(forKey: key)
        }
    }

    func claim(_ host: UUID, of contents: any WebContents) {
        let key = ObjectIdentifier(contents)
        guard ownerByContents[key] != host else { return }
        register(host, for: contents)
        // Captured before handover so the freeze matches what was showing.
        let size = contents.view.bounds.size
        Task { @MainActor [weak contents] in
            guard let contents, !contents.isClosed, size.width > 0, size.height > 0 else { return }
            if let image = await contents.capturePreview(rect: nil, size: size) {
                self.frozenFrameByContents[ObjectIdentifier(contents)] = image
            }
        }
        ownerByContents[key] = host
    }

    func frozenFrame(for contents: any WebContents) -> NSImage? {
        frozenFrameByContents[ObjectIdentifier(contents)]
    }
}

struct FrozenWebContentsView: View {
    var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
            Rectangle()
                .fill(.black.opacity(0.35))
                .allowsHitTesting(false)
        }
        .clipped()
    }
}
