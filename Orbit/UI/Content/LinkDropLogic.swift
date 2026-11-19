import AppKit
import UniformTypeIdentifiers

enum LinkDropZone: Equatable {
    case center
    case left
    case right
    case top
    case bottom

    var splitEdge: SplitEdge? {
        switch self {
        case .center: nil
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    var title: String { self == .center ? "Open in New Tab" : "Open in Split View" }

    var symbolName: String {
        switch self {
        case .center: "plus.rectangle.on.rectangle"
        case .left, .right: "rectangle.split.2x1"
        case .top, .bottom: "rectangle.split.1x2"
        }
    }
}

struct LinkDropPayload: Equatable {
    var url: URL
    var isExplicitLink: Bool
}

@MainActor
enum LinkDropLogic {
    static let minimumEdgeBand: CGFloat = 72
    static let edgeBandFraction: CGFloat = 0.22
    static let highlightInset: CGFloat = 8

    static let linkFileExtensions: Set<String> = ["webloc", "inetloc", "url"]
    static let openableSchemes: Set<String> = ["http", "https"]

    static func edgeBand(forLength length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        return min(max(length * edgeBandFraction, minimumEdgeBand), length * 0.4)
    }

    /// `point` has a top-left origin. A vertical split group takes its panes from the top and bottom, so a side drop there would flip the whole group's axis.
    static func zone(
        at point: CGPoint,
        in size: CGSize,
        splitAxis: SplitGroup.Axis?,
        splitAllowed: Bool
    ) -> LinkDropZone {
        guard splitAllowed, size.width > 0, size.height > 0 else { return .center }
        if splitAxis == .vertical {
            let band = edgeBand(forLength: size.height)
            if point.y <= band { return .top }
            if point.y >= size.height - band { return .bottom }
            return .center
        }
        let band = edgeBand(forLength: size.width)
        if point.x <= band { return .left }
        if point.x >= size.width - band { return .right }
        return .center
    }

    static func splitAllowed(paneCountInGroup: Int?) -> Bool {
        guard let paneCountInGroup else { return true }
        return paneCountInGroup < SplitGroup.maximumPanes
    }

    /// Top-left origin, matching `zone(at:in:splitAxis:splitAllowed:)`.
    static func highlightRect(for zone: LinkDropZone, in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        let half: CGRect
        switch zone {
        case .center: half = full
        case .left: half = CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: half = CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: half = CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: half = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
        return half.insetBy(dx: highlightInset, dy: highlightInset)
    }

    /// A drag that began inside this page and carries only text (a selected URL, say) belongs to the page: dropping it on a field or editor must keep working.
    static func accepts(_ payload: LinkDropPayload?, dragBeganInThisPage: Bool) -> Bool {
        guard let payload else { return false }
        return !dragBeganInThisPage || payload.isExplicitLink
    }

    /// The window asks for the drag destination with a hit test, so this is the point where an external link drag wins over the web view. A click, scroll or key event is never a drag, and a drag pasteboard left over from an earlier drag must not capture a later text selection.
    static func claimsHit(
        eventType: NSEvent.EventType?,
        primaryButtonDown: Bool,
        dragPasteboardChanged: Bool,
        sidebarDragInFlight: Bool,
        payload: LinkDropPayload?,
        dragBeganInThisPage: Bool
    ) -> Bool {
        guard primaryButtonDown, dragPasteboardChanged, !sidebarDragInFlight else { return false }
        guard SplitPaneDropCatcherView.claimsHit(duringEvent: eventType, dragInFlight: true) else { return false }
        return accepts(payload, dragBeganInThisPage: dragBeganInThisPage)
    }

    static func dragOperation(for mask: NSDragOperation) -> NSDragOperation {
        for candidate: NSDragOperation in [.copy, .link, .generic] where mask.contains(candidate) {
            return candidate
        }
        return []
    }

    // MARK: - Pasteboard

    static func payload(from pasteboard: NSPasteboard) -> LinkDropPayload? {
        let urlType = NSPasteboard.PasteboardType(UTType.url.identifier)
        let fileType = NSPasteboard.PasteboardType(UTType.fileURL.identifier)
        let urls: [URL] = (pasteboard.pasteboardItems ?? []).flatMap { item -> [URL] in
            [urlType, fileType].compactMap { type in
                item.string(forType: type).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }

        for item in urls where !item.isFileURL && isOpenable(item) {
            return LinkDropPayload(url: item, isExplicitLink: true)
        }
        for file in urls where file.isFileURL && linkFileExtensions.contains(file.pathExtension.lowercased()) {
            if let target = linkTarget(inFileAt: file) {
                return LinkDropPayload(url: target, isExplicitLink: true)
            }
        }
        if urls.contains(where: \.isFileURL) { return nil }

        if let text = pasteboard.string(forType: .string), let target = linkTarget(inText: text) {
            return LinkDropPayload(url: target, isExplicitLink: false)
        }
        return nil
    }

    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return false }
        return !(url.host() ?? "").isEmpty
    }

    static func linkTarget(inText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
        guard let url = URL(string: candidate), isOpenable(url) else { return nil }
        return url
    }

    static func linkTarget(inFileAt fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), data.count < 1_000_000 else { return nil }
        if fileURL.pathExtension.lowercased() == "url" {
            return linkTarget(inInternetShortcut: String(decoding: data, as: UTF8.self))
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist["URL"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              isOpenable(url) else { return nil }
        return url
    }

    static func linkTarget(inInternetShortcut contents: String) -> URL? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("url=") else { continue }
            let raw = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: raw), isOpenable(url) { return url }
        }
        return nil
    }
}
