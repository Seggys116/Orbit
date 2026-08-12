//  The shape Orbit fills, strokes and shadows for every floating menu, plus the shared
//  arrow-key/pointer selection state. Nothing here touches NSMenu, NSPopover or vibrancy.

import SwiftUI

/// A rounded rectangle with an optional beak, emitted as one continuous
/// subpath so `strokeBorder` never draws a seam where the beak meets the body.
nonisolated struct OrbitMenuSurfaceShape: InsettableShape {
    var cornerRadius: CGFloat = OrbitMetrics.contextMenuCornerRadius
    var arrow: OrbitMenuArrow?
    var arrowWidth: CGFloat = OrbitMetrics.contextMenuArrowWidth
    var arrowHeight: CGFloat = OrbitMetrics.contextMenuArrowHeight
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> OrbitMenuSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let full = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard full.width > 0, full.height > 0 else { return Path() }

        guard let arrow else {
            return Path(roundedRect: full, cornerRadius: min(cornerRadius, min(full.width, full.height) / 2), style: .continuous)
        }

        let beakHeight = max(0, arrowHeight - insetAmount)
        let body: CGRect
        switch arrow.edge {
        case .top:
            body = CGRect(x: full.minX, y: full.minY + beakHeight, width: full.width, height: full.height - beakHeight)
        case .bottom:
            body = CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - beakHeight)
        }
        guard body.width > 0, body.height > 0 else { return Path() }

        let radius = min(cornerRadius, min(body.width, body.height) / 2)
        let halfBeak = arrowWidth / 2
        // The fillet spreads the beak past its own half-width at the base, so
        // the clamp has to keep that spread clear of the corner arcs too.
        let clearance = radius + halfBeak + OrbitMetrics.contextMenuArrowFillet
        let tipX = min(max(arrow.offset, body.minX + clearance), body.maxX - clearance)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        if arrow.edge == .top {
            path.addBeak(tipX: tipX, base: body.minY, height: -beakHeight, halfWidth: halfBeak, sweepingRight: true)
        }
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY + radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY),
            radius: radius
        )
        if arrow.edge == .bottom {
            path.addBeak(tipX: tipX, base: body.maxY, height: beakHeight, halfWidth: halfBeak, sweepingRight: false)
        }
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY - radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.minX + radius, y: body.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}

private extension Path {
    /// Grows the beak from the current subpath with a concave fillet at each flank (blunted
    /// tip, no seam). `height` is signed along the beak axis; `sweepingRight` is pen direction.
    mutating func addBeak(tipX: CGFloat, base: CGFloat, height: CGFloat, halfWidth: CGFloat, sweepingRight: Bool) {
        let direction: CGFloat = sweepingRight ? 1 : -1
        let fillet = min(OrbitMetrics.contextMenuArrowFillet, halfWidth)
        let tipRadius = min(OrbitMetrics.contextMenuArrowTipRadius, halfWidth / 2)
        let tipY = base + height
        let shelfY = tipY - height * (tipRadius / max(abs(height), 0.001))
        // A quadratic only reaches halfway to its control point, so the tip's
        // control is thrown past the tip by exactly that shortfall.
        let tipControlY = tipY + (tipY - shelfY)

        // Only the two base corners are filleted; each fillet's control sits on the base
        // corner with its end on the flank, so the curve is tangent at both ends (no seam).
        let flankFraction: CGFloat = 0.24
        let flankX = halfWidth + (tipRadius - halfWidth) * flankFraction
        let flankY = base + height * flankFraction

        addLine(to: CGPoint(x: tipX - direction * (halfWidth + fillet), y: base))
        addQuadCurve(
            to: CGPoint(x: tipX - direction * flankX, y: flankY),
            control: CGPoint(x: tipX - direction * halfWidth, y: base)
        )
        addLine(to: CGPoint(x: tipX - direction * tipRadius, y: shelfY))
        addQuadCurve(
            to: CGPoint(x: tipX + direction * tipRadius, y: shelfY),
            control: CGPoint(x: tipX, y: tipControlY)
        )
        addLine(to: CGPoint(x: tipX + direction * flankX, y: flankY))
        addQuadCurve(
            to: CGPoint(x: tipX + direction * (halfWidth + fillet), y: base),
            control: CGPoint(x: tipX + direction * halfWidth, y: base)
        )
    }
}

// MARK: - Selection

/// Shared by the hosted SwiftUI menu and the panel controller driving it, so
/// arrow keys and the pointer move the same one highlight.
@Observable
final class OrbitMenuSelectionModel {
    var selectedItemID: UUID?

    private(set) var navigableItems: [OrbitContextMenuItem] = []

    init(entries: [OrbitContextMenuEntry] = []) {
        navigableItems = entries.navigableItems
    }

    func setEntries(_ entries: [OrbitContextMenuEntry]) {
        navigableItems = entries.navigableItems
        if let selectedItemID, !navigableItems.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
        }
    }

    var selectedItem: OrbitContextMenuItem? {
        guard let selectedItemID else { return nil }
        return navigableItems.first { $0.id == selectedItemID }
    }

    func move(by delta: Int) {
        guard !navigableItems.isEmpty, delta != 0 else { return }
        guard let selectedItemID, let index = navigableItems.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = delta > 0 ? navigableItems.first?.id : navigableItems.last?.id
            return
        }
        let count = navigableItems.count
        let next = ((index + delta) % count + count) % count
        self.selectedItemID = navigableItems[next].id
    }
}

extension [OrbitContextMenuEntry] {
    /// Everything the arrow keys can land on: enabled items in visual order,
    /// flattened through sections but never into a submenu -- a submenu's own
    /// items belong to that submenu's panel, not this one.
    var navigableItems: [OrbitContextMenuItem] {
        flatMap { entry -> [OrbitContextMenuItem] in
            switch entry {
            case .item(let item):
                return item.isEnabled ? [item] : []
            case .divider:
                return []
            case .section(_, _, let entries):
                return entries.navigableItems
            }
        }
    }
}

// MARK: - Keyboard

nonisolated enum OrbitMenuKeyAction: Equatable {
    case moveUp
    case moveDown
    case moveToFirst
    case moveToLast
    case activate
    case openSubmenu
    case closeSubmenu
    case dismiss

    /// `nil` for anything the menu must let through untouched.
    static func from(keyCode: UInt16) -> OrbitMenuKeyAction? {
        switch keyCode {
        case 126: return .moveUp        // kVK_UpArrow
        case 125: return .moveDown      // kVK_DownArrow
        case 124: return .openSubmenu   // kVK_RightArrow
        case 123: return .closeSubmenu  // kVK_LeftArrow
        case 115: return .moveToFirst   // kVK_Home
        case 119: return .moveToLast    // kVK_End
        case 36, 76: return .activate   // kVK_Return, kVK_ANSI_KeypadEnter
        case 53: return .dismiss        // kVK_Escape
        default: return nil
        }
    }
}
