import AppKit

enum OrbitScrollerMetrics {
    static let thickness: CGFloat = 9
    static let knobThickness: CGFloat = 5
    static let knobHoverThickness: CGFloat = 7
    static let minimumKnobLength: CGFloat = 24
    static let knobOpacity: CGFloat = 0.32
    static let knobHoverOpacity: CGFloat = 0.55
}

final class OrbitScroller: NSScroller {

    // Required or AppKit silently falls back to its own scroller class under overlay style.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        OrbitScrollerMetrics.thickness
    }

    private var isPointerOver = false

    private var hoverTrackingArea: NSTrackingArea?

    private var isHorizontal: Bool { bounds.width > bounds.height }

    // MARK: - Drawing

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard usableParts != .noScrollerParts else { return }

        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }

        let thickness = isPointerOver
            ? OrbitScrollerMetrics.knobHoverThickness
            : OrbitScrollerMetrics.knobThickness

        var frame: NSRect
        if isHorizontal {
            let width = min(max(knob.width, OrbitScrollerMetrics.minimumKnobLength), slot.width)
            let x = min(max(knob.minX, slot.minX), slot.maxX - width)
            frame = NSRect(x: x, y: bounds.midY - thickness / 2, width: width, height: thickness)
        } else {
            let height = min(max(knob.height, OrbitScrollerMetrics.minimumKnobLength), slot.height)
            let y = min(max(knob.minY, slot.minY), slot.maxY - height)
            frame = NSRect(x: bounds.midX - thickness / 2, y: y, width: thickness, height: height)
        }

        knobColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    private var knobColor: NSColor {
        let base: NSColor
        switch knobStyle {
        case .light:
            base = .white
        case .dark:
            base = .black
        default:
            base = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        }
        return base.withAlphaComponent(
            isPointerOver ? OrbitScrollerMetrics.knobHoverOpacity : OrbitScrollerMetrics.knobOpacity
        )
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only remove the one this type added; AppKit installs its own tracking areas too.
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerOver = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerOver = false
        needsDisplay = true
    }
}

@MainActor
enum OrbitScrollerInstaller {

    private static var isStarted = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard !isStarted else { return }
        isStarted = true

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: nil, queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    guard let scrollView = notification.object as? NSScrollView else { return }
                    apply(to: scrollView)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    guard let contentView = (notification.object as? NSWindow)?.contentView else { return }
                    sweep(contentView)
                }
            }
        )
    }

    // .scrollIndicators(.never) leaves hasVerticalScroller false; this must never add one back.
    @discardableResult
    static func apply(to scrollView: NSScrollView) -> Bool {
        var changed = false
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is OrbitScroller) {
            scrollView.verticalScroller = OrbitScroller()
            changed = true
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is OrbitScroller) {
            scrollView.horizontalScroller = OrbitScroller()
            changed = true
        }
        return changed
    }

    static func sweep(_ view: NSView) {
        if let scrollView = view as? NSScrollView { apply(to: scrollView) }
        for subview in view.subviews { sweep(subview) }
    }
}
