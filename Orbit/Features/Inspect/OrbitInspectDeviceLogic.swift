// Foundation and CoreGraphics only, so OrbitTests can compile this file directly.

import CoreGraphics
import Foundation

enum OrbitDeviceLimits {
    static let minimum = 50
    static let maximum = 9999

    static func clamp(_ value: Int) -> Int {
        min(max(value, minimum), maximum)
    }

    static func clamp(_ value: Double) -> Int {
        if value.isNaN { return minimum }
        return Int(min(max(value, Double(minimum)), Double(maximum)).rounded())
    }
}


enum OrbitDeviceZoom: Equatable, Hashable, Sendable {
    case fit
    case percent(Int)

    static let choices: [OrbitDeviceZoom] = [.fit, .percent(50), .percent(75), .percent(100), .percent(125), .percent(150)]

    var factor: CGFloat? {
        switch self {
        case .fit: nil
        case .percent(let value): CGFloat(value) / 100
        }
    }

    var title: String {
        switch self {
        case .fit: "Fit to window"
        case .percent(let value): "\(value)%"
        }
    }

    var storageValue: Int {
        switch self {
        case .fit: 0
        case .percent(let value): value
        }
    }

    init(storageValue: Int) {
        let candidate = OrbitDeviceZoom.percent(storageValue)
        self = OrbitDeviceZoom.choices.contains(candidate) ? candidate : .fit
    }
}


enum OrbitDeviceResizeHandle: Equatable, Sendable {
    case right
    case bottom
    case corner
}

enum OrbitDeviceGeometry {
    /// Never above 1: fit shrinks a large viewport but does not enlarge a small one.
    static func fitScale(content: CGSize, available: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / content.width, available.height / content.height)
    }

    static func scale(zoom: OrbitDeviceZoom, content: CGSize, available: CGSize) -> CGFloat {
        zoom.factor ?? fitScale(content: content, available: available)
    }

    /// The viewport is drawn at `scale`, so a screen point is `1 / scale` CSS pixels.
    static func resized(
        width: Int,
        height: Int,
        translation: CGSize,
        scale: CGFloat,
        handle: OrbitDeviceResizeHandle
    ) -> (width: Int, height: Int) {
        let safeScale = Double(max(scale, 0.01))
        var newWidth = Double(width)
        var newHeight = Double(height)
        if handle != .bottom { newWidth += Double(translation.width) / safeScale }
        if handle != .right { newHeight += Double(translation.height) / safeScale }
        return (OrbitDeviceLimits.clamp(newWidth), OrbitDeviceLimits.clamp(newHeight))
    }
}

/// The stage reserves room for the size readout above the frame and the drag handles to its right and below it.
struct OrbitDeviceLayout: Equatable {
    static let inset: CGFloat = 16
    static let gripSpace: CGFloat = 18
    static let readoutHeight: CGFloat = 24

    var content: CGSize
    var scale: CGFloat

    var frame: CGSize {
        CGSize(width: content.width * scale, height: content.height * scale)
    }

    static func available(forFrameIn stage: CGSize) -> CGSize {
        CGSize(
            width: stage.width - inset * 2 - gripSpace,
            height: stage.height - inset * 2 - gripSpace - readoutHeight
        )
    }

    static func make(content: CGSize, zoom: OrbitDeviceZoom, stage: CGSize) -> OrbitDeviceLayout {
        OrbitDeviceLayout(
            content: content,
            scale: OrbitDeviceGeometry.scale(zoom: zoom, content: content, available: available(forFrameIn: stage))
        )
    }

    func overflows(stage: CGSize) -> Bool {
        let room = Self.available(forFrameIn: stage)
        return frame.width > room.width + 0.5 || frame.height > room.height + 0.5
    }
}

/// Chrome's four device types. Mobile types send a phone user agent; touch types report coarse-pointer input.
enum OrbitDeviceType: String, CaseIterable, Identifiable, Sendable {
    case mobile
    case mobileNoTouch
    case desktop
    case desktopTouch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobile: "Mobile"
        case .mobileNoTouch: "Mobile (no touch)"
        case .desktop: "Desktop"
        case .desktopTouch: "Desktop (touch)"
        }
    }

    var isMobile: Bool { self == .mobile || self == .mobileNoTouch }
    var hasTouch: Bool { self == .mobile || self == .desktopTouch }

var userAgent: String? { isMobile ? OrbitDeviceUserAgents.iPhone : nil }

    init(mobile: Bool, touch: Bool) {
        switch (mobile, touch) {
        case (true, true): self = .mobile
        case (true, false): self = .mobileNoTouch
        case (false, true): self = .desktopTouch
        case (false, false): self = .desktop
        }
    }
}

struct OrbitDeviceEmulationConfig: Equatable {
    var dpr: Double?
    var touch: Bool
    var screenWidth: Int?
    var screenHeight: Int?

    var isEmpty: Bool { dpr == nil && !touch && screenWidth == nil && screenHeight == nil }
}

struct OrbitDeviceAppliedState: Equatable {
    var userAgent: String?
    var mobile: Bool
    var touch: Bool

    static let untouched = OrbitDeviceAppliedState(userAgent: nil, mobile: false, touch: false)

    static func needsReload(document: OrbitDeviceAppliedState, target: OrbitDeviceAppliedState) -> Bool {
        document != target
    }
}

struct OrbitDeviceSettings: Equatable {
    var profileID: String?
    var width: Int
    var height: Int
    var dpr: Double?
    var type: OrbitDeviceType
var userAgent: String?
    /// A size-only setting is a window, not a screen; a tool that emulates a whole device (Lighthouse) sets this so
    /// screen and outer sizes match it too.
    var emulatesScreen = false

    static let responsiveDefault = OrbitDeviceSettings(
        profileID: nil, width: 800, height: 600, dpr: nil, type: .desktop, userAgent: nil
    )

    init(profileID: String?, width: Int, height: Int, dpr: Double?, type: OrbitDeviceType, userAgent: String?) {
        self.profileID = profileID
        self.width = OrbitDeviceLimits.clamp(width)
        self.height = OrbitDeviceLimits.clamp(height)
        self.dpr = dpr
        self.type = type
        self.userAgent = userAgent
    }

    init(profile: OrbitDeviceProfile) {
        self.init(
            profileID: profile.id,
            width: profile.width,
            height: profile.height,
            dpr: profile.dpr,
            type: OrbitDeviceType(mobile: profile.mobile, touch: profile.touch),
            userAgent: profile.userAgent
        )
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var isLandscape: Bool { width > height }

    func rotated() -> OrbitDeviceSettings {
        var copy = self
        copy.width = height
        copy.height = width
        return copy
    }

    /// Resizing a device leaves it: the result is the responsive mode keeping the device's ratio, type and user agent, as in Chrome.
    func resized(width: Int, height: Int) -> OrbitDeviceSettings {
        var copy = self
        copy.profileID = nil
        copy.width = OrbitDeviceLimits.clamp(width)
        copy.height = OrbitDeviceLimits.clamp(height)
        return copy
    }

    func asResponsive() -> OrbitDeviceSettings {
        OrbitDeviceSettings(profileID: nil, width: width, height: height, dpr: nil, type: .desktop, userAgent: nil)
    }

    func withDPR(_ dpr: Double?) -> OrbitDeviceSettings {
        var copy = self
        copy.profileID = nil
        copy.dpr = dpr
        return copy
    }

    func withType(_ type: OrbitDeviceType) -> OrbitDeviceSettings {
        var copy = self
        copy.profileID = nil
        copy.type = type
        copy.userAgent = type.userAgent
        return copy
    }

    var emulation: OrbitDeviceEmulationConfig {
        OrbitDeviceEmulationConfig(
            dpr: dpr,
            touch: type.hasTouch,
            // The screen is only a device's; a responsive window is not a screen.
            screenWidth: profileID == nil && !emulatesScreen ? nil : width,
            screenHeight: profileID == nil && !emulatesScreen ? nil : height
        )
    }

    var applied: OrbitDeviceAppliedState {
        OrbitDeviceAppliedState(userAgent: userAgent, mobile: type.isMobile, touch: type.hasTouch)
    }
}


enum OrbitDeviceFormat {
    static func number(_ value: Double) -> String {
        String(format: "%g", value)
    }

    static func sizeText(width: Int, height: Int) -> String {
        "\(width) \u{00D7} \(height)"
    }

    static func percentText(_ scale: CGFloat) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static func emulationSummary(for settings: OrbitDeviceSettings) -> String {
        var parts: [String] = []
        if let dpr = settings.dpr { parts.append("DPR \(number(dpr))") }
        if settings.type.hasTouch { parts.append("touch") }
        guard !parts.isEmpty else { return "" }
        return (parts + ["emulated (JS)"]).joined(separator: ", ")
    }
}

/// Overrides only what a page can read, not how WebKit renders; idempotent, so a live change reaches the page without a reload.
enum OrbitDeviceEmulationScript {
    static let marker = "/* orbit-device */"

    static let remove = "window.__orbitDeviceEmu && window.__orbitDeviceEmu.apply({ on: false });"

    static func install(_ config: OrbitDeviceEmulationConfig) -> String {
        marker + "\n" + head + configJSON(config) + tail
    }

    static func configJSON(_ config: OrbitDeviceEmulationConfig) -> String {
        var fields: [String] = []
        if let dpr = config.dpr { fields.append("\"dpr\":\(OrbitDeviceFormat.number(dpr))") }
        fields.append("\"on\":true")
        if let height = config.screenHeight { fields.append("\"screenHeight\":\(height)") }
        if let width = config.screenWidth { fields.append("\"screenWidth\":\(width)") }
        fields.append("\"touch\":\(config.touch ? "true" : "false")")
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static let head = ##"""
    (function (cfg) {
      'use strict';
      var existing = window.__orbitDeviceEmu;
      if (existing) { existing.apply(cfg); return; }
      var state = { on: false };
      var touchTargets = [];

      function realValue(desc, self) {
        if (!desc) return undefined;
        return desc.get ? desc.get.call(self) : desc.value;
      }
      function active() { return state.on === true; }
      function override(target, name, emulated) {
        var desc = Object.getOwnPropertyDescriptor(target, name);
        try {
          Object.defineProperty(target, name, {
            configurable: true,
            enumerable: desc ? !!desc.enumerable : true,
            get: function () {
              var value = emulated();
              return value === undefined ? realValue(desc, this) : value;
            }
          });
        } catch (e) {}
      }

      override(window, 'devicePixelRatio', function () { return active() && state.dpr > 0 ? state.dpr : undefined; });
      override(Navigator.prototype, 'maxTouchPoints', function () { return active() && state.touch ? 5 : undefined; });
      if (typeof Screen !== 'undefined') {
        var screenWidth = function () { return active() && state.screenWidth > 0 ? state.screenWidth : undefined; };
        var screenHeight = function () { return active() && state.screenHeight > 0 ? state.screenHeight : undefined; };
        override(Screen.prototype, 'width', screenWidth);
        override(Screen.prototype, 'availWidth', screenWidth);
        override(Screen.prototype, 'height', screenHeight);
        override(Screen.prototype, 'availHeight', screenHeight);
        // On an emulated device the browser window is the screen, as in Chrome's device mode.
        override(window, 'outerWidth', screenWidth);
        override(window, 'outerHeight', screenHeight);
      }

      // Each tested pointer/hover feature becomes always-true or always-false, so the rest of the query still evaluates.
      var realMatchMedia = window.matchMedia;
      if (typeof realMatchMedia === 'function') {
        var TRUE_FEATURE = '(min-width: 0px)';
        var FALSE_FEATURE = '(width: 0px)';
        // A resolution value in dppx: dpi is 96 per dppx, dpcm 96 / 2.54, and x or a bare ratio is dppx already.
        function dppx(value, unit) {
          var v = parseFloat(value);
          var u = (unit || '').toLowerCase();
          if (u === 'dpi') return v / 96;
          if (u === 'dpcm') return v * 2.54 / 96;
          return v;
        }
        window.matchMedia = function matchMedia(query) {
          var text = String(query);
          var touch = active() && state.touch === true;
          var ratio = active() && state.dpr > 0 ? state.dpr : 0;
          if (!touch && !ratio) return realMatchMedia.call(window, text);
          var rewritten = text;
          if (touch) {
            rewritten = rewritten
              .replace(/\(\s*(?:any-)?pointer\s*:\s*(coarse|fine|none)\s*\)/gi, function (match, value) {
                return value.toLowerCase() === 'coarse' ? TRUE_FEATURE : FALSE_FEATURE;
              })
              .replace(/\(\s*(?:any-)?hover\s*:\s*(hover|none)\s*\)/gi, function (match, value) {
                return value.toLowerCase() === 'none' ? TRUE_FEATURE : FALSE_FEATURE;
              });
          }
          if (ratio) {
            rewritten = rewritten.replace(
              /\(\s*(min-|max-)?(-webkit-(min-|max-)?device-pixel-ratio|resolution)\s*:\s*([0-9]*\.?[0-9]+)\s*(dppx|dpi|dpcm|x)?\s*\)/gi,
              function (match, prefix, name, webkitPrefix, value, unit) {
                var bound = (prefix || webkitPrefix || '').toLowerCase();
                var wanted = dppx(value, name.toLowerCase() === 'resolution' ? unit : 'x');
                var holds = bound === 'min-' ? ratio >= wanted - 1e-6
                  : bound === 'max-' ? ratio <= wanted + 1e-6
                  : Math.abs(ratio - wanted) < 1e-6;
                return holds ? TRUE_FEATURE : FALSE_FEATURE;
              });
          }
          var list = realMatchMedia.call(window, rewritten);
          if (rewritten !== text) {
            try { Object.defineProperty(list, 'media', { configurable: true, get: function () { return text; } }); } catch (e) {}
          }
          return list;
        };
      }

      // 'ontouchstart' in window is how most libraries detect touch.
      function syncTouchHandlers() {
        var want = active() && state.touch === true;
        [window, document].forEach(function (target) {
          var index = touchTargets.indexOf(target);
          if (want && index < 0 && !('ontouchstart' in target)) {
            var handler = null;
            Object.defineProperty(target, 'ontouchstart', {
              configurable: true,
              enumerable: true,
              get: function () { return handler; },
              set: function (value) { handler = value; }
            });
            touchTargets.push(target);
          } else if (!want && index >= 0) {
            delete target.ontouchstart;
            touchTargets.splice(index, 1);
          }
        });
      }

      var api = {
        apply: function (next) {
          state = next && typeof next === 'object' ? next : { on: false };
          syncTouchHandlers();
        }
      };
      Object.defineProperty(window, '__orbitDeviceEmu', { value: api, configurable: true, writable: true, enumerable: false });
      api.apply(cfg);
    })(
    """##

    private static let tail = ");"
}

/// Whether the toolbar is on is not saved; it starts off for every page.
struct OrbitDevicePreferences {
    static let customDevicesKey = "orbit.inspect.device.custom"
    static let zoomKey = "orbit.inspect.device.zoom"
    static let selectionKey = "orbit.inspect.device.selection"
    static let sizeKey = "orbit.inspect.device.size"

    private static let responsiveSelection = "responsive"

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Entries that no longer validate (a hand-edited preferences file) are dropped, never applied.
    var customDevices: [OrbitDeviceProfile] {
        get {
            guard let data = defaults.data(forKey: Self.customDevicesKey),
                  let decoded = try? JSONDecoder().decode([OrbitDeviceProfile].self, from: data) else { return [] }
            return decoded.filter { $0.isCustom && $0.isValid }
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.customDevicesKey)
        }
    }

    var zoom: OrbitDeviceZoom {
        get { OrbitDeviceZoom(storageValue: defaults.integer(forKey: Self.zoomKey)) }
        nonmutating set { defaults.set(newValue.storageValue, forKey: Self.zoomKey) }
    }

    func saveSelection(_ settings: OrbitDeviceSettings) {
        defaults.set(settings.profileID ?? Self.responsiveSelection, forKey: Self.selectionKey)
        defaults.set([settings.width, settings.height], forKey: Self.sizeKey)
    }

    /// A device deleted since the viewport was saved comes back as the responsive mode at the saved size.
    func restoredSettings() -> OrbitDeviceSettings {
        let size = defaults.array(forKey: Self.sizeKey) as? [Int]
        if let id = defaults.string(forKey: Self.selectionKey),
           let profile = OrbitDeviceCatalog.profile(id: id, custom: customDevices) {
            let settings = OrbitDeviceSettings(profile: profile)
            if let size, size.count == 2, size[0] == profile.height, size[1] == profile.width, profile.width != profile.height {
                return settings.rotated()
            }
            return settings
        }
        var settings = OrbitDeviceSettings.responsiveDefault
        if let size, size.count == 2 {
            settings = settings.resized(width: size[0], height: size[1])
        }
        return settings
    }
}
