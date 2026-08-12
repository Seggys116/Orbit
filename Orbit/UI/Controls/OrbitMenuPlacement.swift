//  Where a floating Orbit menu lands, as pure geometry in AppKit screen coordinates
//  (origin bottom-left, y up), testable without creating a window or screen.

import CoreGraphics
import Foundation

nonisolated enum OrbitMenuArrowEdge: Equatable {
    case top
    case bottom
}

nonisolated struct OrbitMenuArrow: Equatable {
    var edge: OrbitMenuArrowEdge
    /// Distance from the container's leading edge to the arrow's tip, in points.
    var offset: CGFloat
}

nonisolated enum OrbitMenuPlacementMode: Equatable {
    /// The right-click menu: the container's top-leading corner sits on the point.
    case pointCorner
    /// A button menu: centred on the anchor, optionally with a beak pointing at it.
    case anchored
    /// A submenu: beside its parent row, top edges aligned.
    case submenu
}

nonisolated enum OrbitMenuDirection: Equatable {
    case down
    case up
}

nonisolated struct OrbitMenuGeometry: Equatable {
    /// The drawn container, in screen coordinates. The panel hosting it is this
    /// outset by `OrbitMetrics.contextMenuShadowPadding`.
    var containerFrame: CGRect
    var arrow: OrbitMenuArrow?
    var direction: OrbitMenuDirection
}

nonisolated enum OrbitMenuPlacement {

    /// `contentSize` is the full drawn container size, already including
    /// `OrbitMetrics.contextMenuArrowHeight` when `showsArrow` is true.
    static func geometry(
        contentSize: CGSize,
        anchor: CGRect,
        mode: OrbitMenuPlacementMode,
        preferredDirection: OrbitMenuDirection,
        showsArrow: Bool,
        visibleFrame: CGRect,
        gap: CGFloat = OrbitMetrics.contextMenuAnchorGap,
        screenInset: CGFloat = OrbitMetrics.contextMenuScreenEdgeInset,
        cornerRadius: CGFloat = OrbitMetrics.contextMenuCornerRadius,
        arrowWidth: CGFloat = OrbitMetrics.contextMenuArrowWidth
    ) -> OrbitMenuGeometry {
        let bounds = visibleFrame.insetBy(dx: screenInset, dy: screenInset)

        if mode == .submenu {
            return submenuGeometry(contentSize: contentSize, anchor: anchor, bounds: bounds)
        }

        let wantsArrow = showsArrow && mode == .anchored
        let anchorGap = mode == .pointCorner ? 0 : (wantsArrow ? 0 : gap)

        let direction = resolvedDirection(
            preferred: preferredDirection, height: contentSize.height,
            anchor: anchor, bounds: bounds, gap: anchorGap
        )

        var originY: CGFloat
        switch direction {
        case .down:
            originY = anchor.minY - anchorGap - contentSize.height
        case .up:
            originY = anchor.maxY + anchorGap
        }
        originY = clamp(originY, lower: bounds.minY, upper: bounds.maxY - contentSize.height)

        var originX: CGFloat
        switch mode {
        case .pointCorner:
            originX = anchor.minX
        case .anchored, .submenu:
            originX = anchor.midX - contentSize.width / 2
        }
        originX = clamp(originX, lower: bounds.minX, upper: bounds.maxX - contentSize.width)

        let frame = CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height)

        var arrow: OrbitMenuArrow?
        if wantsArrow {
            // The beak sits on whichever edge faces the anchor, and its tip
            // tracks the anchor's centre even after the container was clamped
            // sideways -- clamped in turn so it never runs into a corner.
            let edge: OrbitMenuArrowEdge = direction == .down ? .top : .bottom
            let limit = cornerRadius + arrowWidth / 2 + OrbitMetrics.contextMenuArrowFillet
            let offset = clamp(anchor.midX - frame.minX, lower: limit, upper: max(limit, frame.width - limit))
            arrow = OrbitMenuArrow(edge: edge, offset: offset)
        }

        return OrbitMenuGeometry(containerFrame: frame, arrow: arrow, direction: direction)
    }

    // MARK: - Submenu

    private static func submenuGeometry(
        contentSize: CGSize, anchor: CGRect, bounds: CGRect
    ) -> OrbitMenuGeometry {
        let overlap = OrbitMetrics.contextMenuSubmenuOverlap
        var originX = anchor.maxX - overlap
        if originX + contentSize.width > bounds.maxX {
            let flipped = anchor.minX + overlap - contentSize.width
            originX = flipped >= bounds.minX ? flipped : bounds.maxX - contentSize.width
        }
        originX = clamp(originX, lower: bounds.minX, upper: max(bounds.minX, bounds.maxX - contentSize.width))

        // Top edges aligned: a submenu reads as an extension of its own row,
        // not of the bottom of the parent menu.
        var originY = anchor.maxY + OrbitMetrics.contextMenuVerticalPadding - contentSize.height
        originY = clamp(originY, lower: bounds.minY, upper: max(bounds.minY, bounds.maxY - contentSize.height))

        return OrbitMenuGeometry(
            containerFrame: CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height),
            arrow: nil,
            direction: .down
        )
    }

    // MARK: - Flipping

    private static func resolvedDirection(
        preferred: OrbitMenuDirection, height: CGFloat, anchor: CGRect, bounds: CGRect, gap: CGFloat
    ) -> OrbitMenuDirection {
        let roomDown = anchor.minY - gap - bounds.minY
        let roomUp = bounds.maxY - anchor.maxY - gap
        switch preferred {
        case .down:
            return (roomDown < height && roomUp >= height) ? .up : .down
        case .up:
            return (roomUp < height && roomDown >= height) ? .down : .up
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}
