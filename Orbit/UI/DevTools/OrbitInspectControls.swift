// Clickable things use `InspectHitTarget` or an Orbit control: SwiftUI Button, Menu and Picker need a second click here because the first is spent on focus.

import AppKit
import SwiftUI

enum InspectChrome {
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let label = Font.system(size: 12)
    static let labelStrong = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)

    static let rowHeight: CGFloat = 22
    static let controlHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 28
    static let rowRadius: CGFloat = OrbitRadius.sm
    static let controlRadius: CGFloat = OrbitRadius.sm
    static let panelPadding: CGFloat = 10

    // Text
    static var ink: Color { OrbitNeutral.ink }
    static var ink2: Color { OrbitNeutral.ink2 }
    static var muted: Color { OrbitNeutral.muted }
    static var muted2: Color { OrbitNeutral.muted2 }
    static var accent: Color { OrbitNeutral.accent }

    // Surfaces
    static var background: Color { OrbitNeutral.bg }
    static var panel: Color { OrbitNeutral.card }
    static var selection: Color { OrbitNeutral.chipStrong }
    static var hover: Color { OrbitNeutral.chip }
    static var surface: Color { OrbitNeutral.sunk }
    static var hairline: Color { OrbitNeutral.line }

    // Code colours: AA on `card` and `bg` in both appearances.
    static let tagColor = Hex.tag.color
    static let attributeNameColor = Hex.attributeName.color
    static let attributeValueColor = Hex.attributeValue.color
    static let stringColor = Hex.string.color
    static let numberColor = Hex.attributeValue.color
    static let keywordColor = Hex.keyword.color

    /// A light/dark colour pair, usable from SwiftUI and from AppKit text attributes.
    struct HexPair {
        var light: UInt32
        var dark: UInt32

        var color: Color { OrbitNeutral.adaptive(light: light, dark: dark) }

        /// A dynamic `NSColor` that re-resolves when the appearance changes.
        var nsColor: NSColor {
            let light = light, dark = dark
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            }
        }
    }

    enum Hex {
        static let tag = HexPair(light: 0x7B2FA8, dark: 0xD2A8FF)
        static let attributeName = HexPair(light: 0x9A4A00, dark: 0xFFB86B)
        static let attributeValue = HexPair(light: 0x0B5CAD, dark: 0x7FB8FF)
        static let string = HexPair(light: 0xB02A37, dark: 0xFF9A93)
        static let keyword = HexPair(light: 0xA8266B, dark: 0xFF8FC4)
        static let ink = HexPair(light: 0x0B0B12, dark: 0xF4F4F8)
        static let muted = HexPair(light: 0x5B5B6B, dark: 0xA3A3B5)
    }
    static var goodColor: Color { OrbitNeutral.good }
    static var warnColor: Color { OrbitNeutral.warn }
    static var badColor: Color { OrbitNeutral.bad }

    static func scoreColor(_ score: Int) -> Color {
        if score >= 90 { return goodColor }
        if score >= 50 { return warnColor }
        return badColor
    }

    static func auditColor(_ score: Double?) -> Color {
        guard let score else { return muted }
        if score >= 0.9 { return goodColor }
        if score >= 0.5 { return warnColor }
        return badColor
    }
}

/// A one-pixel divider in the inspector's hairline colour.
struct InspectDivider: View {
    var body: some View {
        Rectangle().fill(InspectChrome.hairline).frame(height: 1)
    }
}

/// A one-pixel vertical divider between table columns, in the inspector's hairline colour.
struct InspectVerticalDivider: View {
    var height: CGFloat = InspectChrome.rowHeight

    var body: some View {
        Rectangle().fill(InspectChrome.hairline).frame(width: 1, height: height)
    }
}

/// What a draggable click target puts on the pasteboard and when it starts and stops.
struct InspectDragSource {
    var payload: String
    var onBegan: () -> Void = {}
    var onEnded: () -> Void = {}
}

struct InspectHitTarget: NSViewRepresentable {
    var action: () -> Void
    var doubleAction: (() -> Void)?
    var focusable: Bool
    var drag: InspectDragSource?
    var located: ((CGPoint, Int) -> Void)?

    /// `focusable` joins the Tab key loop and fires on Space or Return; use it for buttons, not rows, which would add hundreds of stops.
    init(focusable: Bool = false, drag: InspectDragSource? = nil, doubleAction: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.doubleAction = doubleAction
        self.focusable = focusable
        self.drag = drag
        self.located = nil
    }

    /// Reports the click point and count; tree rows need it because a double-click means different things on different parts.
    init(drag: InspectDragSource? = nil, located: @escaping (CGPoint, Int) -> Void) {
        self.action = {}
        self.doubleAction = nil
        self.focusable = false
        self.drag = drag
        self.located = located
    }

    func makeNSView(context: Context) -> InspectHitView {
        let view = InspectHitView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InspectHitView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InspectHitView) {
        view.action = action
        view.doubleAction = doubleAction
        view.isFocusable = focusable
        view.drag = drag
        view.located = located
    }
}

final class InspectHitView: NSView, NSDraggingSource {
    var action: () -> Void = {}
    var doubleAction: (() -> Void)?
    var drag: InspectDragSource?
    var located: ((CGPoint, Int) -> Void)?
    var isFocusable = false {
        didSet { if isFocusable != oldValue { focusRingType = isFocusable ? .exterior : .none } }
    }

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    override var acceptsFirstResponder: Bool { isFocusable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        if let located {
            let point = convert(event.locationInWindow, from: nil)
            located(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y), event.clickCount)
        } else if event.clickCount >= 2, let doubleAction {
            doubleAction()
        } else {
            action()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, !dragStarted, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        dragStarted = true
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(drag.payload, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: dragImage())
        drag.onBegan()
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func keyDown(with event: NSEvent) {
        guard isFocusable else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 49, 76: action()      // return, space, keypad enter
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: OrbitRadius.sm, yRadius: OrbitRadius.sm).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// A snapshot of whatever SwiftUI drew under this transparent target, so the drag shows the row.
    private func dragImage() -> NSImage {
        guard let host = superview, let rep = host.bitmapImageRepForCachingDisplay(in: frame) else {
            return NSImage(size: bounds.size)
        }
        host.cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        drag?.onEnded()
    }
}

struct InspectMenuItem {
    var title: String
    var checked = false
    var enabled = true
    var isSeparator = false
    var action: () -> Void = {}

    static var separator: InspectMenuItem { InspectMenuItem(title: "", isSeparator: true) }
}

private final class InspectMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// A click target that opens a native menu on the first click.
struct InspectMenuTarget: NSViewRepresentable {
    var items: () -> [InspectMenuItem]

    func makeNSView(context: Context) -> InspectMenuView {
        let view = InspectMenuView()
        view.items = items
        return view
    }

    func updateNSView(_ nsView: InspectMenuView, context: Context) {
        nsView.items = items
    }
}

final class InspectMenuView: NSView {
    var items: () -> [InspectMenuItem] = { [] }
    private var retained: [InspectMenuAction] = []

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .exterior }
        set {}
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: OrbitRadius.sm, yRadius: OrbitRadius.sm).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76, 125: showMenu()   // return, space, keypad enter, down arrow
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        retained.removeAll()
        for entry in items() {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let target = InspectMenuAction(entry.action)
            retained.append(target)
            let item = NSMenuItem(title: entry.title, action: #selector(InspectMenuAction.run), keyEquivalent: "")
            item.target = target
            item.state = entry.checked ? .on : .off
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

struct InspectIconButton: View {
    var symbol: String
    var help: String
    var active = false
    var enabled = true
    var action: () -> Void

    init(symbol: String, help: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.enabled = enabled
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        icon(hovering: hovering)
            .overlay { if enabled { InspectHitTarget(focusable: true, action: action) } }
            .onHover { hovering = $0 }
            .orbitTooltip(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(enabled ? "" : "Unavailable")
    }

    func icon(hovering: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: InspectChrome.iconButtonSize, height: InspectChrome.iconButtonSize)
            .foregroundStyle(active ? InspectChrome.accent : InspectChrome.muted)
            .background(
                RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                    .fill(active ? InspectChrome.accent.opacity(0.14) : (hovering && enabled ? InspectChrome.hover : Color.clear))
            )
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .orbitAnimation(OrbitMotion.fade, value: hovering)
    }
}

struct InspectMenuButton: View {
    var symbol: String
    var help: String
    var items: () -> [InspectMenuItem]

    @State private var hovering = false

    var body: some View {
        InspectIconButton(symbol: symbol, help: help, active: false, action: {}).icon(hovering: hovering)
            .overlay(InspectMenuTarget(items: items))
            .onHover { hovering = $0 }
            .orbitTooltip(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

/// A small text button with a full-size click target, for "Clear", "Copy", "Run" and the like.
struct InspectTextButton: View {
    var title: String
    var systemImage: String?
    var enabled = true
    var prominent = false
    var action: () -> Void

    init(_ title: String, systemImage: String? = nil, enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.prominent = prominent
        self.action = action
    }

    @State private var hovering = false

    private var fill: Color {
        if prominent { return InspectChrome.accent }
        return hovering && enabled ? InspectChrome.selection : InspectChrome.hover
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(prominent ? OrbitNeutral.onAccent : InspectChrome.ink)
        .padding(.horizontal, 10)
        .frame(height: InspectChrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(fill)
                .brightness(prominent && hovering && enabled ? 0.06 : 0)
        )
        // Bevel: an inset top highlight and a hairline edge on the raised (prominent) button.
        .overlay(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .strokeBorder(prominent ? Color.black.opacity(0.18) : InspectChrome.hairline, lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            if prominent {
                RoundedRectangle(cornerRadius: max(0, InspectChrome.controlRadius - 0.5), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: 3) }
                    .padding(0.5)
            }
        }
        .shadow(color: .black.opacity(prominent ? 0.16 : 0), radius: 1, x: 0, y: 1)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .overlay { if enabled { InspectHitTarget(focusable: true, action: action) } }
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

/// A selectable chip, used for filters.
struct InspectChip: View {
    var title: String
    var selected: Bool
    var count: Int?
    var action: () -> Void

    init(_ title: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.count = count
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)").foregroundStyle(InspectChrome.muted)
            }
        }
        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? InspectChrome.ink : InspectChrome.muted)
        .padding(.horizontal, 9)
        .frame(height: InspectChrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(selected ? InspectChrome.selection : (hovering ? InspectChrome.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(focusable: true, action: action))
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { $0 > 0 ? "\(title), \($0)" : title } ?? title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Empty state and section header

struct InspectEmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(InspectChrome.muted2)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(InspectChrome.ink)
            Text(message)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// A section title in sentence case. Callers pass the title as it should read ("Box model", not "BOX MODEL").
struct InspectSectionHeader: View {
    var title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack {
            Text(title)
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(InspectChrome.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            }
        }
    }
}

// MARK: - Resizing

struct InspectResizeHandle: NSViewRepresentable {
    var vertical: Bool
    var sign: CGFloat
    var minBreadth: CGFloat
    var maxBreadth: CGFloat
    var current: () -> CGFloat
    var onChange: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> InspectResizeHandleView {
        let view = InspectResizeHandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InspectResizeHandleView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InspectResizeHandleView) {
        view.vertical = vertical
        view.sign = sign
        view.minBreadth = minBreadth
        view.maxBreadth = maxBreadth
        view.current = current
        view.onChange = onChange
        view.onEnd = onEnd
    }
}

final class InspectResizeHandleView: NSView {
    var vertical = false
    var sign: CGFloat = -1
    var minBreadth: CGFloat = 280
    var maxBreadth: CGFloat = 900
    var current: () -> CGFloat = { 440 }
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var startBreadth: CGFloat?
    private var startPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        startBreadth = current()
        startPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) { apply(event) }

    override func mouseUp(with event: NSEvent) {
        apply(event)
        startBreadth = nil
        startPoint = nil
        onEnd()
    }

    private func apply(_ event: NSEvent) {
        guard let startBreadth, let startPoint else { return }
        let delta = vertical
            ? (event.locationInWindow.y - startPoint.y) * sign
            : (event.locationInWindow.x - startPoint.x) * sign
        onChange(min(max(startBreadth + delta, minBreadth), max(minBreadth, maxBreadth)))
    }
}

/// Below `stackBelow` points of width the panes stack vertically so a docked inspector stays usable.
struct InspectSplit<First: View, Second: View>: View {
    var key: String
    var defaultFraction: CGFloat = 0.5
    var minFirst: CGFloat = 160
    var minSecond: CGFloat = 160
    var stackBelow: CGFloat = 0
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    @State private var fraction: CGFloat?

    private var storageKey: String { "orbit.inspect.split.\(key)" }

    var body: some View {
        GeometryReader { geo in
            let stacked = stackBelow > 0 && geo.size.width < stackBelow
            let total = max(1, stacked ? geo.size.height : geo.size.width)
            let stored = OrbitDefaults.standard.object(forKey: storageKey) as? Double
            let value = fraction ?? stored.map { CGFloat($0) } ?? defaultFraction
            let upper = max(minFirst, total - minSecond - 7)
            let firstSize = min(max(total * value, minFirst), upper)
            let handle = InspectResizeHandle(
                vertical: stacked,
                sign: stacked ? -1 : 1,
                minBreadth: minFirst,
                maxBreadth: upper,
                current: { firstSize },
                onChange: { fraction = $0 / total },
                onEnd: {
                    if let fraction { OrbitDefaults.standard.set(Double(fraction), forKey: storageKey) }
                }
            )
            .frame(width: stacked ? nil : 7, height: stacked ? 7 : nil)
            .background(InspectChrome.hairline.frame(width: stacked ? nil : 1, height: stacked ? 1 : nil))
            .accessibilityLabel("Resize panes")
            if stacked {
                VStack(spacing: 0) {
                    first().frame(height: firstSize).clipped()
                    handle
                    second().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            } else {
                HStack(spacing: 0) {
                    first().frame(width: firstSize).clipped()
                    handle
                    second().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
        }
    }
}

// MARK: - Text input

/// A search or filter field built on Orbit's own text field so it behaves like the rest of the app.
struct InspectSearchField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        OrbitTextField(
            placeholder: placeholder, text: $text, systemImage: "magnifyingglass",
            accentColor: OrbitNeutral.accent, accessibilityLabel: placeholder
        )
    }
}

/// A plain single-line text input with the same height, fill and focus ring as `InspectSearchField`.
struct InspectTextField: View {
    var placeholder: String
    @Binding var text: String
    var accessibilityLabel: String?

    init(_ placeholder: String, text: Binding<String>, accessibilityLabel: String? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        OrbitTextField(
            placeholder: placeholder, text: $text,
            accentColor: OrbitNeutral.accent, accessibilityLabel: accessibilityLabel ?? placeholder
        )
    }
}
