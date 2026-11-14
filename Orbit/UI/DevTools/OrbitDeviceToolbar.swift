// Pixel ratio and touch are emulated in JavaScript because WKWebView cannot change either.

import AppKit
import SwiftUI

struct OrbitDeviceToolbar: View {
    var model: OrbitInspectDeviceModel

    @State private var showingDevices = false

    private enum Level { case full, compact }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            ScrollView(.horizontal, showsIndicators: false) { row(.full, spacer: false) }
                .frame(height: InspectChrome.controlHeight)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .orbitAnimation(OrbitMotion.quick, value: model.needsReload)
        .popover(isPresented: $showingDevices, arrowEdge: .bottom) {
            OrbitDeviceCustomEditor(model: model)
        }
    }

    @ViewBuilder
    private func row(_ level: Level, spacer: Bool = true) -> some View {
        HStack(spacing: 6) {
            devicePill
            OrbitDeviceSizeFields(model: model)
            InspectIconButton(symbol: "rotate.right", help: "Rotate viewport") { model.rotate() }
            zoomPill
            if level == .full {
                dprPill
                typePill
                Text("Emulated (JS)")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .orbitTooltip("Pixel ratio and touch are emulated in JavaScript. The page is not rendered at that density and receives no real touch events.")
            }
            if spacer { Spacer(minLength: 4) }
            reloadChip
            InspectMenuButton(symbol: "ellipsis", help: "More device options") { moreItems(includeEmulation: level == .compact) }
        }
    }

    private var devicePill: some View {
        OrbitDevicePill(title: model.deviceTitle, symbol: model.currentProfile.map(Self.symbol(for:)) ?? "arrow.left.and.right", help: "Device") {
            deviceItems()
        }
    }

    private var zoomPill: some View {
        let title = model.zoom == .fit
            ? "Fit \(OrbitDeviceFormat.percentText(model.scale))"
            : model.zoom.title
        return OrbitDevicePill(title: title, symbol: nil, help: "Zoom") {
            OrbitDeviceZoom.choices.map { choice in
                InspectMenuItem(title: choice.title, checked: model.zoom == choice) { model.setZoom(choice) }
            }
        }
    }

    /// A device fixes its own pixel ratio and type; they are editable only in the responsive mode.
    private var dprPill: some View {
        OrbitDevicePill(
            title: model.settings.dpr.map { "DPR \(OrbitDeviceFormat.number($0))" } ?? "DPR default",
            symbol: nil,
            help: "Device pixel ratio, emulated in JavaScript",
            enabled: model.settings.profileID == nil
        ) { dprItems() }
    }

    private var typePill: some View {
        OrbitDevicePill(
            title: model.settings.type.title,
            symbol: nil,
            help: "Device type, emulated in JavaScript",
            enabled: model.settings.profileID == nil
        ) { typeItems() }
    }

    @ViewBuilder
    private var reloadChip: some View {
        if model.needsReload {
            OrbitDeviceReloadChip { model.reloadNow() }
                .transition(.opacity)
        }
    }

    private func deviceItems() -> [InspectMenuItem] {
        var items = [
            InspectMenuItem(title: "Responsive", checked: model.settings.profileID == nil) { model.selectResponsive() },
        ]
        for section in model.sections {
            items.append(.separator)
            items.append(InspectMenuItem(title: section.category.title, enabled: false))
            for profile in section.profiles {
                items.append(InspectMenuItem(
                    title: "\(profile.name)   \(OrbitDeviceFormat.sizeText(width: profile.width, height: profile.height))",
                    checked: model.settings.profileID == profile.id
                ) { model.select(profile) })
            }
        }
        items.append(.separator)
        items.append(InspectMenuItem(title: "Edit custom devices\u{2026}") { showingDevices = true })
        return items
    }

    private static let dprChoices: [Double?] = [nil, 1, 1.5, 2, 2.625, 3]

    private func dprItems() -> [InspectMenuItem] {
        var items = [InspectMenuItem(title: "Emulated in JavaScript, not real rendering", enabled: false)]
        for choice in Self.dprChoices {
            items.append(InspectMenuItem(
                title: choice.map { OrbitDeviceFormat.number($0) } ?? "Default (display)",
                checked: model.settings.dpr == choice
            ) { model.setDPR(choice) })
        }
        return items
    }

    private func typeItems() -> [InspectMenuItem] {
        var items = [InspectMenuItem(title: "Touch is emulated in JavaScript", enabled: false)]
        for type in OrbitDeviceType.allCases {
            items.append(InspectMenuItem(title: type.title, checked: model.settings.type == type) { model.setType(type) })
        }
        return items
    }

    private func moreItems(includeEmulation: Bool) -> [InspectMenuItem] {
        var items: [InspectMenuItem] = []
        if includeEmulation {
            let editable = model.settings.profileID == nil
            items.append(InspectMenuItem(title: "Pixel ratio (emulated, JS)", enabled: false))
            for choice in Self.dprChoices {
                items.append(InspectMenuItem(
                    title: choice.map { OrbitDeviceFormat.number($0) } ?? "Default (display)",
                    checked: model.settings.dpr == choice,
                    enabled: editable
                ) { model.setDPR(choice) })
            }
            items.append(.separator)
            items.append(InspectMenuItem(title: "Device type (emulated, JS)", enabled: false))
            for type in OrbitDeviceType.allCases {
                items.append(InspectMenuItem(
                    title: type.title, checked: model.settings.type == type, enabled: editable
                ) { model.setType(type) })
            }
            items.append(.separator)
        }
        items.append(InspectMenuItem(title: "Edit custom devices\u{2026}") { showingDevices = true })
        items.append(InspectMenuItem(title: "Reset to responsive") { model.selectResponsive() })
        items.append(.separator)
        items.append(InspectMenuItem(title: "Close device toolbar") { model.deactivate() })
        return items
    }

    private static func symbol(for profile: OrbitDeviceProfile) -> String {
        switch profile.category {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .custom: "rectangle.dashed"
        }
    }
}

/// A value inside the limits applies as it is typed; anything else is clamped on Return or focus loss.
private struct OrbitDeviceSizeFields: View {
    var model: OrbitInspectDeviceModel

    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var widthFocused: Bool
    @FocusState private var heightFocused: Bool

    private static let fieldWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 4) {
            OrbitTextField(
                placeholder: "Width", text: $widthText,
                accentColor: OrbitNeutral.accent, accessibilityLabel: "Viewport width in CSS pixels",
                externalFocus: $widthFocused
            )
            .frame(width: Self.fieldWidth)
            .onChange(of: widthText) { _, text in applyLive(text, isWidth: true) }
            .onChange(of: widthFocused) { _, focused in if !focused { commit(isWidth: true) } }
            .onSubmit { commit(isWidth: true) }
            Text("\u{00D7}")
                .font(InspectChrome.label)
                .foregroundStyle(InspectChrome.muted)
                .accessibilityHidden(true)
            OrbitTextField(
                placeholder: "Height", text: $heightText,
                accentColor: OrbitNeutral.accent, accessibilityLabel: "Viewport height in CSS pixels",
                externalFocus: $heightFocused
            )
            .frame(width: Self.fieldWidth)
            .onChange(of: heightText) { _, text in applyLive(text, isWidth: false) }
            .onChange(of: heightFocused) { _, focused in if !focused { commit(isWidth: false) } }
            .onSubmit { commit(isWidth: false) }
        }
        .fixedSize()
        .onAppear(perform: syncFromModel)
        .onChange(of: model.settings.width) { _, _ in if !widthFocused { syncFromModel() } }
        .onChange(of: model.settings.height) { _, _ in if !heightFocused { syncFromModel() } }
    }

    private func syncFromModel() {
        let width = String(model.settings.width)
        let height = String(model.settings.height)
        if widthText != width { widthText = width }
        if heightText != height { heightText = height }
    }

    private func applyLive(_ text: String, isWidth: Bool) {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              (OrbitDeviceLimits.minimum...OrbitDeviceLimits.maximum).contains(value) else { return }
        let settings = model.settings
        if isWidth, value != settings.width {
            model.setSize(width: value, height: settings.height)
        } else if !isWidth, value != settings.height {
            model.setSize(width: settings.width, height: value)
        }
    }

    private func commit(isWidth: Bool) {
        let text = isWidth ? widthText : heightText
        let settings = model.settings
        if let value = Int(text.trimmingCharacters(in: .whitespaces)) {
            let clamped = OrbitDeviceLimits.clamp(value)
            if isWidth { model.setSize(width: clamped, height: settings.height) }
            else { model.setSize(width: settings.width, height: clamped) }
        }
        syncFromModel()
    }
}

/// A labelled button that opens a menu on the first click. Radius and height match the inspector's other controls.
private struct OrbitDevicePill: View {
    var title: String
    var symbol: String?
    var help: String
    var enabled = true
    var items: () -> [InspectMenuItem]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(InspectChrome.muted)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(InspectChrome.ink)
        .padding(.horizontal, 8)
        .frame(height: InspectChrome.controlHeight)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(hovering && enabled ? InspectChrome.selection : InspectChrome.hover)
        )
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .overlay { if enabled { InspectMenuTarget(items: items) } }
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .orbitTooltip(enabled ? help : "\(help). Fixed by the selected device; choose Responsive to change it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(help), \(title)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The "Reload to apply" prompt: a user agent or flag change needs a new document. Nothing reloads by itself.
private struct OrbitDeviceReloadChip: View {
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold))
            Text("Reload to apply").lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(InspectChrome.ink)
        .padding(.horizontal, 8)
        .frame(height: InspectChrome.controlHeight)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(InspectChrome.warnColor.opacity(hovering ? 0.26 : 0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .strokeBorder(InspectChrome.warnColor.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(focusable: true, action: action))
        .onHover { hovering = $0 }
        .orbitAnimation(OrbitMotion.fade, value: hovering)
        .orbitTooltip("The user agent or device flags changed. Reload the page to load it as this device.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reload to apply")
        .accessibilityHint("The user agent or device flags changed after this page loaded")
        .accessibilityAddTraits(.isButton)
    }
}

/// The custom devices list with a form to add one. Saving an entry selects it.
private struct OrbitDeviceCustomEditor: View {
    var model: OrbitInspectDeviceModel

    @State private var name = ""
    @State private var widthText = "390"
    @State private var heightText = "844"
    @State private var dprText = "3"
    @State private var userAgent = ""
    @State private var mobile = true
    @State private var touch = true

    private var width: Int? { Int(widthText.trimmingCharacters(in: .whitespaces)) }
    private var height: Int? { Int(heightText.trimmingCharacters(in: .whitespaces)) }
    private var dpr: Double? { Double(dprText.trimmingCharacters(in: .whitespaces)) }

    private var canAdd: Bool {
        guard let dpr else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && width != nil && height != nil && dpr > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectSectionHeader("Custom devices")
            if model.customDevices.isEmpty {
                Text("Devices you add show up in the device menu.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.customDevices) { device in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(device.name).font(InspectChrome.label).lineLimit(1)
                                Text("\(OrbitDeviceFormat.sizeText(width: device.width, height: device.height)), DPR \(OrbitDeviceFormat.number(device.dpr))")
                                    .font(InspectChrome.caption)
                                    .foregroundStyle(InspectChrome.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            InspectIconButton(symbol: "trash", help: "Delete \(device.name)") {
                                model.removeCustomDevice(id: device.id)
                            }
                        }
                    }
                }
            }
            InspectDivider()
            InspectSectionHeader("Add a device")
            InspectTextField("Name", text: $name, accessibilityLabel: "Device name")
            HStack(spacing: 6) {
                InspectTextField("Width", text: $widthText, accessibilityLabel: "Width in CSS pixels")
                InspectTextField("Height", text: $heightText, accessibilityLabel: "Height in CSS pixels")
                InspectTextField("DPR", text: $dprText, accessibilityLabel: "Device pixel ratio, emulated in JavaScript")
            }
            InspectTextField("User agent (optional)", text: $userAgent, accessibilityLabel: "User agent")
            HStack(spacing: 6) {
                InspectChip("Mobile", selected: mobile) { mobile.toggle() }
                InspectChip("Touch (emulated, JS)", selected: touch) { touch.toggle() }
                Spacer(minLength: 0)
                InspectTextButton("Add device", enabled: canAdd, prominent: true, action: add)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(InspectChrome.panel)
        .foregroundStyle(InspectChrome.ink)
        .tint(InspectChrome.accent)
    }

    private func add() {
        guard canAdd, let width, let height, let dpr else { return }
        let saved = model.saveCustomDevice(
            name: name, width: width, height: height, dpr: dpr,
            userAgent: userAgent, mobile: mobile, touch: touch
        )
        if saved != nil { name = ""; userAgent = "" }
    }
}
