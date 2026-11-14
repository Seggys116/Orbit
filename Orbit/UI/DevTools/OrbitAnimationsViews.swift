import SwiftUI

// MARK: - Animation badge

struct AnimTypeBadge: View {
    var type: AnimType
    var body: some View {
        Text(type.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(type.badgeColor))
    }
}

// MARK: - Time ruler

struct AnimTimeRuler: View {
    var ticks: [AnimRulerTick]
    var totalDuration: Double
    var scrubTime: Double?

    var body: some View {
        Canvas { ctx, size in
            drawRuler(ctx: ctx, size: size)
        }
        .frame(height: 22)
        .background(InspectChrome.surface)
    }

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        guard totalDuration > 0, w > 0 else { return }
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(InspectChrome.ink.opacity(0.03)))
        for tick in ticks {
            let x = CGFloat(tick.ms / totalDuration) * w
            guard x >= 0, x <= w + 1 else { continue }
            let tickH: CGFloat = tick.isMajor ? 10 : 5
            let tickColor = InspectChrome.ink.opacity(tick.isMajor ? 0.3 : 0.15)
            ctx.stroke(
                Path { p in p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x, y: size.height - tickH)) },
                with: .color(tickColor),
                lineWidth: 1
            )
            if tick.isMajor && !tick.label.isEmpty {
                ctx.draw(
                    Text(tick.label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(InspectChrome.muted),
                    at: CGPoint(x: x + 3, y: size.height - 13),
                    anchor: .leading
                )
            }
        }
        // Scrubber line
        if let st = scrubTime {
            let sx = CGFloat(st / totalDuration) * w
            ctx.stroke(
                Path { p in p.move(to: CGPoint(x: sx, y: 0)); p.addLine(to: CGPoint(x: sx, y: size.height)) },
                with: .color(InspectChrome.accent.opacity(0.9)),
                lineWidth: 1.5
            )
        }
    }
}

// MARK: - Animation row bar

struct AnimRowBar: View {
    var record: AnimRecord
    var totalDuration: Double
    var scrubTime: Double?
    var isSelected: Bool

    var body: some View {
        Canvas { ctx, size in
            drawBar(ctx: ctx, size: size)
        }
        .frame(height: InspectChrome.rowHeight)
    }

    private func drawBar(ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        guard totalDuration > 0, w > 0 else { return }
        let ad = OrbitAnimationsLogic.activeDuration(duration: record.duration, iterations: record.iterations)
        let adCapped = ad.isInfinite ? max(0, totalDuration - record.delay) : ad

        let delayX   = CGFloat(record.delay / totalDuration) * w
        let activeW  = CGFloat(adCapped / totalDuration) * w
        let endX     = delayX + activeW
        let endDelayW = CGFloat(record.endDelay / totalDuration) * w

        let barY: CGFloat = 6
        let barH: CGFloat = h - 12

        if record.delay > 0 {
            let delayRect = CGRect(x: 0, y: barY, width: delayX, height: barH)
            ctx.fill(Path(roundedRect: delayRect, cornerRadius: 2),
                     with: .color(InspectChrome.ink.opacity(0.06)))
            var i: CGFloat = 0
            while i < delayX + barH {
                let lineStart = CGPoint(x: max(0, i - barH), y: barY + (i < barH ? barH - i : 0))
                let lineEnd   = CGPoint(x: min(delayX, i), y: barY + max(0, barH - i))
                ctx.stroke(Path { p in p.move(to: lineStart); p.addLine(to: lineEnd) },
                           with: .color(InspectChrome.ink.opacity(0.12)), lineWidth: 1)
                i += 5
            }
        }

        if activeW > 0 {
            let barColor = record.isGone ? InspectChrome.muted.opacity(0.3) : record.type.barColor
            let activeRect = CGRect(x: delayX, y: barY, width: activeW, height: barH)
            ctx.fill(Path(roundedRect: activeRect, cornerRadius: 3), with: .color(barColor))

            let sepXs = OrbitAnimationsLogic.iterationSeparators(
                delay: record.delay, duration: record.duration,
                iterations: record.iterations, totalDuration: totalDuration)
            for sepFrac in sepXs {
                let sx = CGFloat(sepFrac) * w
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: sx, y: barY)); p.addLine(to: CGPoint(x: sx, y: barY + barH)) },
                    with: .color(.white.opacity(0.4)), lineWidth: 1)
            }

            let kfFracs = OrbitAnimationsLogic.keyframeDots(
                delay: record.delay, duration: record.duration, iterations: record.iterations,
                keyframes: record.keyframes, totalDuration: totalDuration)
            for kfFrac in kfFracs {
                let kx = CGFloat(kfFrac) * w
                let dotRect = CGRect(x: kx - 3, y: barY + barH * 0.5 - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.85)))
            }

            if ad.isInfinite {
                let arrowX = endX - 12
                let midY = barY + barH * 0.5
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: arrowX, y: midY - 4))
                        p.addLine(to: CGPoint(x: arrowX + 7, y: midY))
                        p.addLine(to: CGPoint(x: arrowX, y: midY + 4))
                    },
                    with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }
        }

        if record.endDelay > 0, endDelayW > 0 {
            let edRect = CGRect(x: endX, y: barY, width: endDelayW, height: barH)
            ctx.fill(Path(roundedRect: edRect, cornerRadius: 2),
                     with: .color(InspectChrome.ink.opacity(0.05)))
        }

        if let ct = record.currentTime, ct >= 0, !record.isGone {
            let px = CGFloat(ct / totalDuration) * w
            if px >= delayX, px <= endX {
                let pdot = CGRect(x: px - 4, y: barY + barH * 0.5 - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: pdot), with: .color(InspectChrome.accent))
                ctx.stroke(Path(ellipseIn: pdot.insetBy(dx: -1, dy: -1)),
                           with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
        }

        // Scrubber line
        if let st = scrubTime {
            let sx = CGFloat(st / totalDuration) * w
            ctx.stroke(
                Path { p in p.move(to: CGPoint(x: sx, y: 0)); p.addLine(to: CGPoint(x: sx, y: h)) },
                with: .color(InspectChrome.accent.opacity(0.6)), lineWidth: 1)
        }

        // Non-compositable warning stripe at top
        let hasWarning = record.properties.contains { p in
            !OrbitAnimationsLogic.isCompositableProperty(p) && OrbitAnimationsLogic.compositabilityHint(p) != nil
        }
        if hasWarning {
            let warnRect = CGRect(x: delayX, y: barY, width: min(activeW, 4), height: barH)
            ctx.fill(Path(roundedRect: warnRect, cornerRadius: 1),
                     with: .color(InspectChrome.warnColor.opacity(0.8)))
        }
    }
}

// MARK: - Single animation row

struct AnimRowView: View {
    var record: AnimRecord
    var totalDuration: Double
    var scrubTime: Double?
    var isSelected: Bool
    var onSelect: () -> Void
    var onHover: (Bool) -> Void
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            labelArea
                .frame(width: AnimMetrics.labelWidth)
            AnimRowBar(
                record: record,
                totalDuration: totalDuration,
                scrubTime: scrubTime,
                isSelected: isSelected
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(doubleAction: onReveal, action: onSelect))
        .onHover { hovering in onHover(hovering) }
        .contextMenu {
            Button("Reveal in Elements") { onReveal() }
            Button("Copy Selector") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.selector, forType: .string)
            }
        }
    }

    private var labelArea: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(record.playState.statusColor)
                .frame(width: 6, height: 6)
            Text(record.name.isEmpty ? record.id : record.name)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(record.isGone ? InspectChrome.muted : InspectChrome.ink)
            AnimTypeBadge(type: record.type)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                    .fill(InspectChrome.selection)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Group header

struct AnimGroupHeader: View {
    var label: String
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "curlybraces")
                .font(.system(size: 9))
                .foregroundStyle(InspectChrome.muted)
            Text(label)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.ink)
            Text("\(count)")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(InspectChrome.surface)
    }
}

// MARK: - Timing detail row

struct AnimTimingDetailRow: View {
    var label: String
    var value: String
    var muted: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(InspectChrome.mono)
                .foregroundStyle(muted ? InspectChrome.muted : InspectChrome.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: InspectChrome.rowHeight)
    }
}

// MARK: - Keyframe table row

struct AnimKeyframeRow: View {
    var keyframe: AnimKeyframe
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(keyframe.offset.map { String(format: "%.3f", $0) } ?? "auto")
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 60, alignment: .trailing)
                .padding(.trailing, 10)
            Text(keyframe.easing)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(keyframe.properties.sorted(by: { $0.key < $1.key })), id: \.key) { kv in
                    HStack(spacing: 4) {
                        Text(kv.key)
                            .foregroundStyle(InspectChrome.attributeNameColor)
                        Text(kv.value)
                            .foregroundStyle(InspectChrome.attributeValueColor)
                    }
                    .font(InspectChrome.mono)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(isSelected ? InspectChrome.selection : Color.clear)
    }
}

// MARK: - Easing curve canvas

struct AnimEasingCurveView: View {
    var easing: ParsedEasing
    var progress: Double?

    private let pad: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            drawCurve(ctx: ctx, size: size)
        }
        .frame(width: 120, height: 120)
        .background(InspectChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous))
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        let rect = CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad)

        // Grid
        for frac: CGFloat in [0.25, 0.5, 0.75] {
            let gx = rect.minX + frac * rect.width
            let gy = rect.minY + frac * rect.height
            ctx.stroke(Path { p in p.move(to: CGPoint(x: gx, y: rect.minY)); p.addLine(to: CGPoint(x: gx, y: rect.maxY)) },
                       with: .color(InspectChrome.ink.opacity(0.08)), lineWidth: 1)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: rect.minX, y: gy)); p.addLine(to: CGPoint(x: rect.maxX, y: gy)) },
                       with: .color(InspectChrome.ink.opacity(0.08)), lineWidth: 1)
        }

        // Boundary
        ctx.stroke(Path(rect), with: .color(InspectChrome.ink.opacity(0.15)), lineWidth: 1)

        // Curve
        let curvePath = AnimEasingPath.path(for: easing, in: rect)
        ctx.stroke(curvePath, with: .color(InspectChrome.accent), lineWidth: 2)

        // For cubic-bezier, show control point arms
        if case .cubicBezier(let p1x, let p1y, let p2x, let p2y) = easing {
            let (arm1, arm2) = AnimEasingPath.handleArmPaths(p1x: p1x, p1y: p1y, p2x: p2x, p2y: p2y, in: rect)
            ctx.stroke(arm1, with: .color(InspectChrome.muted.opacity(0.5)), lineWidth: 1)
            ctx.stroke(arm2, with: .color(InspectChrome.muted.opacity(0.5)), lineWidth: 1)
            let cp1 = AnimEasingPath.point(p1x, p1y, in: rect)
            let cp2 = AnimEasingPath.point(p2x, p2y, in: rect)
            ctx.fill(Path(ellipseIn: CGRect(x: cp1.x - 4, y: cp1.y - 4, width: 8, height: 8)),
                     with: .color(InspectChrome.accent))
            ctx.fill(Path(ellipseIn: CGRect(x: cp2.x - 4, y: cp2.y - 4, width: 8, height: 8)),
                     with: .color(InspectChrome.accent))
        }

        // Animated progress dot
        if let p = progress, p >= 0, p <= 1 {
            let y = OrbitAnimationsLogic.evaluateEasing(easing, t: p)
            let pt = AnimEasingPath.point(p, y, in: rect)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                     with: .color(InspectChrome.accent.opacity(0.9)))
        }
    }
}

// MARK: - Cubic bezier editor

struct AnimBezierEditorView: View {
    @Binding var edit: AnimBezierEdit
    var onCommit: (String) -> Void

    private let pad: CGFloat = 20
    @State private var dragging: Int? = nil  // 1 = p1, 2 = p2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { ctx, size in
                drawEditor(ctx: ctx, size: size)
            }
            .frame(width: 180, height: 180)
            .background(InspectChrome.surface)
            .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleDrag(value) }
                    .onEnded   { value in handleDragEnd(value) }
            )

            Text(edit.cssString)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .textSelection(.enabled)
        }
    }

    private func rect(in size: CGSize) -> CGRect {
        CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad)
    }

    private func drawEditor(ctx: GraphicsContext, size: CGSize) {
        let r = rect(in: size)

        // Grid
        ctx.stroke(Path(r), with: .color(InspectChrome.ink.opacity(0.15)), lineWidth: 1)
        for frac: CGFloat in [0.25, 0.5, 0.75] {
            let gx = r.minX + frac * r.width
            let gy = r.minY + frac * r.height
            ctx.stroke(Path { p in p.move(to: CGPoint(x: gx, y: r.minY)); p.addLine(to: CGPoint(x: gx, y: r.maxY)) },
                       with: .color(InspectChrome.ink.opacity(0.07)), lineWidth: 1)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: r.minX, y: gy)); p.addLine(to: CGPoint(x: r.maxX, y: gy)) },
                       with: .color(InspectChrome.ink.opacity(0.07)), lineWidth: 1)
        }

        // Curve
        let parsed: ParsedEasing = .cubicBezier(edit.p1x, edit.p1y, edit.p2x, edit.p2y)
        let curvePath = AnimEasingPath.bezierCurvePath(p1x: edit.p1x, p1y: edit.p1y, p2x: edit.p2x, p2y: edit.p2y, in: r)
        ctx.stroke(curvePath, with: .color(InspectChrome.accent), lineWidth: 2)

        // Handles
        let (arm1, arm2) = AnimEasingPath.handleArmPaths(p1x: edit.p1x, p1y: edit.p1y, p2x: edit.p2x, p2y: edit.p2y, in: r)
        ctx.stroke(arm1, with: .color(InspectChrome.muted.opacity(0.5)), lineWidth: 1)
        ctx.stroke(arm2, with: .color(InspectChrome.muted.opacity(0.5)), lineWidth: 1)

        let cp1 = AnimEasingPath.point(edit.p1x, edit.p1y, in: r)
        let cp2 = AnimEasingPath.point(edit.p2x, edit.p2y, in: r)
        ctx.fill(Path(ellipseIn: CGRect(x: cp1.x - 5, y: cp1.y - 5, width: 10, height: 10)), with: .color(InspectChrome.accent))
        ctx.fill(Path(ellipseIn: CGRect(x: cp2.x - 5, y: cp2.y - 5, width: 10, height: 10)), with: .color(InspectChrome.accent))
        ctx.stroke(Path(ellipseIn: CGRect(x: cp1.x - 5, y: cp1.y - 5, width: 10, height: 10)), with: .color(.white.opacity(0.5)), lineWidth: 1)
        ctx.stroke(Path(ellipseIn: CGRect(x: cp2.x - 5, y: cp2.y - 5, width: 10, height: 10)), with: .color(.white.opacity(0.5)), lineWidth: 1)
    }

    private func handleDrag(_ value: DragGesture.Value) {
        let size = CGSize(width: 180, height: 180)
        let r = rect(in: size)
        let loc = value.location

        if dragging == nil {
            // Pick the closest control point
            let cp1 = AnimEasingPath.point(edit.p1x, edit.p1y, in: r)
            let cp2 = AnimEasingPath.point(edit.p2x, edit.p2y, in: r)
            let d1 = hypot(loc.x - cp1.x, loc.y - cp1.y)
            let d2 = hypot(loc.x - cp2.x, loc.y - cp2.y)
            dragging = d1 <= d2 ? 1 : 2
        }
        let (t, y) = AnimEasingPath.normalize(loc, in: r)
        if dragging == 1 { edit.p1x = max(0, min(1, t)); edit.p1y = y }
        else              { edit.p2x = max(0, min(1, t)); edit.p2y = y }
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        dragging = nil
        onCommit(edit.cssString)
    }
}

// MARK: - Per-animation controls bar

struct AnimControlsBar: View {
    var record: AnimRecord
    var onPlay: () -> Void
    var onPause: () -> Void
    var onReplay: () -> Void
    var onFinish: () -> Void
    var onReverse: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if record.playState == .paused || record.playState == .idle {
                InspectIconButton(symbol: "play.fill", help: "Play", action: onPlay)
            } else {
                InspectIconButton(symbol: "pause.fill", help: "Pause", action: onPause)
            }
            InspectIconButton(symbol: "arrow.counterclockwise", help: "Replay", action: onReplay)
            InspectIconButton(symbol: "forward.end.fill", help: "Finish", action: onFinish)
            InspectIconButton(symbol: "backward.end.fill", help: "Reverse", action: onReverse)
            InspectIconButton(symbol: "xmark", help: "Cancel", action: onCancel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }
}

// MARK: - Details pane

struct AnimDetailsPane: View {
    var record: AnimRecord
    var session: OrbitInspectSession

    @State private var selectedKeyframeID: String? = nil
    @State private var editDuration: String = ""
    @State private var editDelay: String = ""
    @State private var editIterations: String = ""
    @State private var editEasing: String = ""
    @State private var bezierEdit: AnimBezierEdit = AnimBezierEdit()
    @State private var showBezierEditor: Bool = false

    private var model: OrbitAnimationsModel { session.animations }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                controlsSection
                InspectDivider()
                timingSection
                InspectDivider()
                keyframesSection
                InspectDivider()
                easingSection
            }
            .padding(.bottom, 16)
        }
        .onAppear { syncEditFields() }
        .onChange(of: record.id) { _, _ in syncEditFields() }
    }

    // MARK: Controls

    private var controlsSection: some View {
        AnimControlsBar(
            record: record,
            onPlay:    { model.play(id: record.id) },
            onPause:   { model.pause(id: record.id) },
            onReplay:  { model.replay(id: record.id) },
            onFinish:  { model.finish(id: record.id) },
            onReverse: { model.reverse(id: record.id) },
            onCancel:  { model.cancel(id: record.id) }
        )
    }

    // MARK: Timing

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectSectionHeader("Timing")
                .padding(.horizontal, 10)
                .padding(.top, 8)
            timingRows
            editSection
        }
    }

    private var timingRows: some View {
        VStack(spacing: 0) {
            timingRow("Play state", record.playState.rawValue)
            timingRow("Playback rate", String(format: "%.2f×", record.playbackRate))
            timingRow("Duration", record.durationDisplay)
            timingRow("Delay", record.delayDisplay)
            timingRow("End delay", record.endDelayDisplay)
            timingRow("Iterations", record.iterationsDisplay)
            timingRow("Direction", record.direction.rawValue)
            timingRow("Fill", record.fill.rawValue)
            timingRow("Easing", record.easing)
            timingRow("Composite", record.composite)
            if let ct = record.currentTime {
                timingRow("Current time", OrbitDevToolsFormat.milliseconds(ct))
            }
            if let st = record.startTime {
                timingRow("Start time", OrbitDevToolsFormat.milliseconds(st))
            }
            if record.timelineKind != .document {
                timingRow("Timeline", record.timelineKind.rawValue, muted: false)
            }
            // Non-compositable warnings
            ForEach(record.properties, id: \.self) { prop in
                if let hint = OrbitAnimationsLogic.compositabilityHint(prop) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(InspectChrome.warnColor)
                            .font(.system(size: 10))
                        Text("\(prop): triggers \(hint)")
                            .font(InspectChrome.caption)
                            .foregroundStyle(InspectChrome.warnColor)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: InspectChrome.rowHeight)
                }
            }
        }
    }

    private func timingRow(_ label: String, _ value: String, muted: Bool = false) -> some View {
        AnimTimingDetailRow(label: label, value: value, muted: muted)
            .padding(.horizontal, 10)
    }

    // MARK: Inline edit

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectSectionHeader("Edit timing")
                .padding(.horizontal, 10)
                .padding(.top, 8)
            editField("Duration ms", text: $editDuration) {
                if let v = Double(editDuration) { model.updateTiming(id: record.id, duration: v) }
            }
            editField("Delay ms", text: $editDelay) {
                if let v = Double(editDelay) { model.updateTiming(id: record.id, delay: v) }
            }
            editField("Iterations", text: $editIterations) {
                if editIterations == "∞" || editIterations.lowercased() == "infinite" {
                    model.updateTiming(id: record.id, iterations: .infinity)
                } else if let v = Double(editIterations) {
                    model.updateTiming(id: record.id, iterations: v)
                }
            }
            editField("Easing", text: $editEasing) {
                if !editEasing.isEmpty { model.updateTiming(id: record.id, easing: editEasing) }
            }
        }
    }

    private func editField(_ label: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 90, alignment: .trailing)
            InspectTextField(label, text: text)
                .onSubmit(onCommit)
                .frame(width: 120)
        }
        .padding(.horizontal, 10)
    }

    // MARK: Keyframes

    private var keyframesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectSectionHeader("Keyframes", detail: "\(record.keyframes.count)")
                .padding(.horizontal, 10)
                .padding(.top, 8)
            if record.keyframes.isEmpty {
                Text("No keyframes")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: 0) {
                    Text("offset")
                        .frame(width: 60, alignment: .trailing).padding(.trailing, 10)
                    Text("easing")
                        .frame(width: 100, alignment: .leading).padding(.trailing, 6)
                    Text("properties")
                }
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
                .padding(.horizontal, 10)
                .frame(height: 18)

                ForEach(record.keyframes) { kf in
                    AnimKeyframeRow(keyframe: kf, isSelected: selectedKeyframeID == kf.id)
                        .padding(.horizontal, 10)
                        .overlay(InspectHitTarget { selectedKeyframeID = kf.id })
                }
            }
        }
    }

    // MARK: Easing curve

    private var easingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectSectionHeader("Easing curve")
                .padding(.horizontal, 10)
                .padding(.top, 8)

            let parsed = OrbitAnimationsLogic.parseEasing(record.easing)
            let progress: Double? = {
                guard let ct = record.currentTime, record.duration > 0 else { return nil }
                return max(0, min(ct / record.duration, 1))
            }()

            HStack(alignment: .top, spacing: 16) {
                AnimEasingCurveView(easing: parsed, progress: progress)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.easing)
                        .font(InspectChrome.mono)
                        .foregroundStyle(InspectChrome.muted)
                        .textSelection(.enabled)
                    if case .cubicBezier = parsed {
                        InspectTextButton("Edit curve") {
                            bezierEdit = AnimBezierEdit(from: record.easing)
                            showBezierEditor.toggle()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

            if showBezierEditor, case .cubicBezier = parsed {
                AnimBezierEditorView(edit: $bezierEdit) { newCss in
                    model.updateTiming(id: record.id, easing: newCss)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    // MARK: Helpers

    private func syncEditFields() {
        editDuration   = record.duration == 0   ? "0" : String(format: "%.0f", record.duration)
        editDelay      = record.delay == 0      ? "0" : String(format: "%.0f", record.delay)
        editIterations = record.iterations.isInfinite ? "∞" : String(format: "%.2f", record.iterations)
        editEasing     = record.easing
        bezierEdit     = AnimBezierEdit(from: record.easing)
    }
}

// MARK: - Events tab

struct AnimEventsTab: View {
    var events: [AnimEvent]

    var body: some View {
        if events.isEmpty {
            InspectEmptyState(
                symbol: "waveform",
                title: "No events",
                message: "Animation and transition events appear here as they fire."
            )
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(events.reversed()) { event in
                        AnimEventRow(event: event)
                    }
                }
            }
        }
    }
}

struct AnimEventRow: View {
    var event: AnimEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(eventTypeLabel(event.type))
                .font(InspectChrome.mono)
                .foregroundStyle(eventColor(event.type))
                .frame(width: 110, alignment: .leading)
            Text(event.elementLabel.isEmpty ? "—" : event.elementLabel)
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
            Text(event.animationName.isEmpty ? "—" : event.animationName)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.0fms", event.elapsedTime * 1000))
                .font(InspectChrome.mono)
                .foregroundStyle(InspectChrome.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: InspectChrome.rowHeight)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(event.type) \(event.elementLabel) \(event.animationName)", forType: .string)
            }
        }
    }

    private func eventTypeLabel(_ t: String) -> String {
        switch t {
        case "animationstart":     return "start"
        case "animationend":       return "end"
        case "animationcancel":    return "cancel"
        case "animationiteration": return "iteration"
        case "transitionrun":      return "run"
        case "transitionstart":    return "start"
        case "transitionend":      return "end"
        case "transitioncancel":   return "cancel"
        default: return t
        }
    }

    private func eventColor(_ t: String) -> Color {
        switch t {
        case "animationstart", "transitionrun", "transitionstart":
            return InspectChrome.goodColor
        case "animationend", "transitionend":
            return InspectChrome.muted
        case "animationcancel", "transitioncancel":
            return InspectChrome.warnColor
        case "animationiteration":
            return InspectChrome.accent
        default: return InspectChrome.muted
        }
    }
}

// MARK: - Metrics

enum AnimMetrics {
    static let labelWidth: CGFloat = 180
    static let rulerHeight: CGFloat = 22
}
