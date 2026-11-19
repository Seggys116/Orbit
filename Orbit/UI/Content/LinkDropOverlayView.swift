import AppKit

private final class LinkDropSurface: NSView {
    private let fillColor: NSColor
    private let strokeColor: NSColor?

    init(fill: NSColor, stroke: NSColor?, cornerRadius: CGFloat) {
        fillColor = fill
        strokeColor = stroke
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = stroke == nil ? 0 : 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = strokeColor?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Purely visual: it never takes a hit, so the page and the drop catcher beneath it see every event.
final class LinkDropOverlayView: NSView {
    private let highlight = LinkDropSurface(
        fill: NSColor.controlAccentColor.withAlphaComponent(0.22),
        stroke: NSColor.controlAccentColor,
        cornerRadius: OrbitMetrics.cardCornerRadius
    )
    private let pill = LinkDropSurface(
        fill: NSColor.windowBackgroundColor.withAlphaComponent(0.94),
        stroke: nil,
        cornerRadius: 12
    )
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var presentedZone: LinkDropZone?
    private var generation = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        isHidden = true

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        pill.translatesAutoresizingMaskIntoConstraints = false
        highlight.addSubview(pill)
        addSubview(highlight)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -12),
            pill.centerXAnchor.constraint(equalTo: highlight.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: highlight.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if let presentedZone, !isHidden {
            highlight.frame = LinkDropLogic.highlightRect(for: presentedZone, in: bounds.size)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func present(_ zone: LinkDropZone) {
        guard zone != presentedZone || isHidden else { return }
        generation += 1
        let target = LinkDropLogic.highlightRect(for: zone, in: bounds.size)
        let wasVisible = presentedZone != nil && !isHidden
        presentedZone = zone

        icon.image = NSImage(systemSymbolName: zone.symbolName, accessibilityDescription: nil)
        label.stringValue = zone.title

        if !wasVisible {
            highlight.frame = target
            isHidden = false
        }
        let slide = wasVisible && !reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            if slide {
                highlight.animator().frame = target
            } else {
                highlight.frame = target
            }
        }
    }

    func dismiss() {
        guard presentedZone != nil || !isHidden else { return }
        presentedZone = nil
        generation += 1
        let expected = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == expected else { return }
            self.isHidden = true
        }
    }
}
