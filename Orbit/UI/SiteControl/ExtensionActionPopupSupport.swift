import AppKit
import CoreGraphics
import Foundation

public enum ExtensionActionPopupSupport {

    // MARK: - Addressability (honesty requirement 2: path-derived ids)

    // An id is addressable only if the running engine's chrome-extension://
    // origin answers to it: engine-assigned, a manifest key that recomputes
    // to it, or (unpacked) the extension directory's own path via crx_file::id_util::GenerateIdForPath.
    public static func isExtensionIDAddressable(
        extensionID: String,
        manifestKey: String?,
        directory: URL? = nil,
        idIsEngineAssigned: Bool = false
    ) -> Bool {
        guard ChromeExtensionID.isValid(extensionID) else { return false }
        if idIsEngineAssigned { return true }
        if let manifestKey {
            guard let recomputed = ChromeExtensionID.id(fromPublicKeyBase64: manifestKey) else { return false }
            return recomputed == extensionID
        }
        guard let directory else { return false }
        return ChromeExtensionID.id(forUnpackedPath: directory) == extensionID
    }

    // MARK: - Session gate (honesty requirement 1: persistent sessions only)

    // A non-persistent (incognito-shaped) browser context fails extension navigations outright with ERR_BLOCKED_BY_CLIENT.
    public static func canHostExtensionSurfaces(sessionIsPersistent: Bool) -> Bool {
        sessionIsPersistent
    }

    // MARK: - `chrome-extension://` URL construction

    public static func extensionResourceURL(extensionID: String, path: String) -> URL? {
        guard ChromeExtensionID.isValid(extensionID), !path.isEmpty else { return nil }
        var allowedCharacters = CharacterSet.urlPathAllowed
        // urlPathAllowed excludes `/`, which a manifest-relative path legitimately contains.
        allowedCharacters.insert(charactersIn: "/")
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: "chrome-extension://\(extensionID)/\(encodedPath)")
    }

    // MARK: - Action popup

    // actionPopupPath must be non-empty: a declared toolbar button with no popup expects chrome.action.onClicked instead, which Orbit has no path to dispatch, so it gets no icon rather than a disabled one.
    public static func canShowActionIcon(
        extensionID: String,
        isEnabled: Bool,
        hasToolbarAction: Bool,
        manifestKey: String?,
        actionPopupPath: String?,
        sessionIsPersistent: Bool,
        directory: URL? = nil,
        idIsEngineAssigned: Bool = false
    ) -> Bool {
        guard canHostExtensionSurfaces(sessionIsPersistent: sessionIsPersistent) else { return false }
        guard isEnabled, hasToolbarAction else { return false }
        guard let actionPopupPath, !actionPopupPath.isEmpty else { return false }
        return isExtensionIDAddressable(
            extensionID: extensionID,
            manifestKey: manifestKey,
            directory: directory,
            idIsEngineAssigned: idIsEngineAssigned
        )
    }

    public static func actionPopupURL(
        extensionID: String,
        isEnabled: Bool,
        hasToolbarAction: Bool,
        manifestKey: String?,
        actionPopupPath: String?,
        sessionIsPersistent: Bool,
        directory: URL? = nil,
        idIsEngineAssigned: Bool = false
    ) -> URL? {
        guard canShowActionIcon(
            extensionID: extensionID,
            isEnabled: isEnabled,
            hasToolbarAction: hasToolbarAction,
            manifestKey: manifestKey,
            actionPopupPath: actionPopupPath,
            sessionIsPersistent: sessionIsPersistent,
            directory: directory,
            idIsEngineAssigned: idIsEngineAssigned
        ), let actionPopupPath else { return nil }
        return extensionResourceURL(extensionID: extensionID, path: actionPopupPath)
    }

    // MARK: - Options page

    public enum OptionsPagePresentation: Equatable, Sendable {
        case tab
        case panel
    }

    public static func optionsPagePresentation(optionsOpenInTab: Bool) -> OptionsPagePresentation {
        optionsOpenInTab ? .tab : .panel
    }

    public static func canShowOptionsControl(
        extensionID: String,
        isEnabled: Bool,
        manifestKey: String?,
        optionsPagePath: String?,
        sessionIsPersistent: Bool,
        directory: URL? = nil,
        idIsEngineAssigned: Bool = false
    ) -> Bool {
        guard canHostExtensionSurfaces(sessionIsPersistent: sessionIsPersistent) else { return false }
        guard isEnabled else { return false }
        guard let optionsPagePath, !optionsPagePath.isEmpty else { return false }
        return isExtensionIDAddressable(
            extensionID: extensionID,
            manifestKey: manifestKey,
            directory: directory,
            idIsEngineAssigned: idIsEngineAssigned
        )
    }

    public static func optionsPageURL(
        extensionID: String,
        isEnabled: Bool,
        manifestKey: String?,
        optionsPagePath: String?,
        sessionIsPersistent: Bool,
        directory: URL? = nil,
        idIsEngineAssigned: Bool = false
    ) -> URL? {
        guard canShowOptionsControl(
            extensionID: extensionID,
            isEnabled: isEnabled,
            manifestKey: manifestKey,
            optionsPagePath: optionsPagePath,
            sessionIsPersistent: sessionIsPersistent,
            directory: directory,
            idIsEngineAssigned: idIsEngineAssigned
        ), let optionsPagePath else { return nil }
        return extensionResourceURL(extensionID: extensionID, path: optionsPagePath)
    }

    // Settings lists every installed extension, including ones the running engine has not activated; those must not offer an options page whose chrome-extension:// origin answers nothing yet.
    public static func settingsOptionsPageURL(
        extensionID: String,
        isEnabled: Bool,
        isActivatedInRunningEngine: Bool,
        manifestKey: String?,
        optionsPagePath: String?,
        sessionIsPersistent: Bool
    ) -> URL? {
        guard !requiresRestartToActivate(isActivatedInRunningEngine: isActivatedInRunningEngine) else { return nil }
        return optionsPageURL(
            extensionID: extensionID,
            isEnabled: isEnabled,
            manifestKey: manifestKey,
            optionsPagePath: optionsPagePath,
            sessionIsPersistent: sessionIsPersistent
        )
    }

    // MARK: - Restart-to-activate gate

    // True for an extension installed or re-enabled since browser start-up: its chrome-extension:// origin answers nothing until Orbit restarts, so callers must not attempt that navigation while this is true.
    public static func requiresRestartToActivate(isActivatedInRunningEngine: Bool) -> Bool {
        !isActivatedInRunningEngine
    }

    // MARK: - Popup sizing

    // Chrome's own ExtensionPopup::kMinSize/kMaxSize; the popup document is laid out at its own preferred size inside them, never at the host's size.
    public static let popupMinimumSize = CGSize(width: 25, height: 25)
    public static let popupMaximumSize = CGSize(width: 800, height: 600)
    public static let popupDefaultSize = CGSize(width: 320, height: 420)

    // The viewport until the page reports its own size. It is the minimum on purpose: the
    // observer reads the root border box, and a taller host (the old 200×112 loading box,
    // or the web view's initial 800×600) is what comes back as the page height. The popover
    // then stays that tall, or a scrollbar shorter, and both scroll bars appear.
    public static let popupLoadingSize = popupMinimumSize

    // NSPopover draws its border and arrow outside the content rect (the window is 26pt
    // larger than the content on each axis). Subtracted once, and only when fitting the
    // window to the screen. Adding it to the web view frame as well insets the page.
    public static let popupWindowChrome = CGSize(width: 26, height: 26)

    // A viewport even a point shorter than the page shows a scrollbar, which shrinks the
    // other axis, which shows the second scrollbar. Overlay scrollers still consume this much.
    public static var popupScrollbarThickness: CGFloat {
        max(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay), 1)
    }

    // Every Orbit-drawn state of an extension popup (load failure, pending activation) shares this width so they read as one surface.
    public static let popupMessageWidth: CGFloat = 260

    public static func clampedPopupSize(_ proposed: CGSize?) -> CGSize {
        guard let proposed else { return popupDefaultSize }
        let width = min(max(proposed.width, popupMinimumSize.width), popupMaximumSize.width)
        let height = min(max(proposed.height, popupMinimumSize.height), popupMaximumSize.height)
        return CGSize(width: width, height: height)
    }

    /// The web view's frame for a measured page. Chrome's min/max apply, then the screen,
    /// with the popover's own chrome removed once.
    ///
    /// When one axis is clamped, that axis scrolls. The scrollbar takes space from the
    /// other axis, and the page then scrolls sideways as well. The other axis grows by
    /// one scrollbar so only the axis that actually overflowed scrolls.
    public static func popupFrame(fitting content: CGSize, on screen: CGSize = .zero) -> CGSize {
        let screenWidth = screen.width > 0 ? screen.width - popupWindowChrome.width : popupMaximumSize.width
        let screenHeight = screen.height > 0 ? screen.height - popupWindowChrome.height : popupMaximumSize.height
        let widthLimit = min(popupMaximumSize.width, screenWidth)
        let heightLimit = min(popupMaximumSize.height, screenHeight)
        guard widthLimit >= popupMinimumSize.width, heightLimit >= popupMinimumSize.height else {
            return clampedPopupSize(content)
        }
        var size = CGSize(
            width: min(max(content.width, popupMinimumSize.width), widthLimit),
            height: min(max(content.height, popupMinimumSize.height), heightLimit)
        )
        if content.height > size.height + 0.5 {
            size.width = min(size.width + popupScrollbarThickness, widthLimit)
        }
        if content.width > size.width + 0.5 {
            size.height = min(size.height + popupScrollbarThickness, heightLimit)
        }
        return size
    }

    /// True when `reported` is the web view's bounds (or that bounds clamped to the maximum),
    /// which is what the observer returns before the page has a height of its own.
    public static func isUnlaidOutViewportSize(_ reported: CGSize, viewBounds: CGSize) -> Bool {
        guard viewBounds.width > 1, viewBounds.height > 1 else { return false }
        let slack = popupScrollbarThickness
        // Equal to the viewport, or shorter by at most one scrollbar (the gutter the viewport
        // lost while the page was overflowing it). A page smaller than that is its own size.
        func matchesViewport(_ reported: CGFloat, _ view: CGFloat) -> Bool {
            abs(reported - view) <= slack && reported + 0.5 >= view - slack
        }
        if matchesViewport(reported.width, viewBounds.width) || matchesViewport(reported.height, viewBounds.height) {
            return true
        }
        // The observer clamps a viewport taller than the maximum down to the maximum, so the
        // report is 800 or 600 while the web view is still the larger host.
        if reported.width == popupMaximumSize.width, viewBounds.width > popupMaximumSize.width { return true }
        if reported.height == popupMaximumSize.height, viewBounds.height > popupMaximumSize.height { return true }
        return false
    }

    /// Both axes are the host. One axis matching is a real document edge; rejecting
    /// that report and substituting a fixed popup size is what leaves the page wider
    /// than the bubble, scrolling sideways.
    public static func isEntirelyTheViewport(_ reported: CGSize, viewBounds: CGSize) -> Bool {
        guard viewBounds.width > 1, viewBounds.height > 1 else { return false }
        let slack = popupScrollbarThickness
        func matches(_ reported: CGFloat, _ view: CGFloat) -> Bool {
            abs(reported - view) <= slack && reported + 0.5 >= view - slack
        }
        return matches(reported.width, viewBounds.width) && matches(reported.height, viewBounds.height)
    }

    /// The mismatch that puts scroll bars on both axes: the page is smaller than the frame,
    /// or the frame is shorter than the page by less than one scrollbar (so the first bar
    /// shrinks the other axis). A page that genuinely exceeds the maximum is allowed to scroll.
    public static func showsSpuriousScrollbars(content: CGSize, frame: CGSize) -> Bool {
        if content.width + 1 < frame.width || content.height + 1 < frame.height { return true }
        let widthShortfall = content.width - frame.width
        let heightShortfall = content.height - frame.height
        if widthShortfall > 1, widthShortfall < popupScrollbarThickness { return true }
        if heightShortfall > 1, heightShortfall < popupScrollbarThickness { return true }
        return false
    }

    /// The root's own border box, with the root at max-content on both axes: it contains the body's margins, which the body's border box does not. Only the root is widened. The body keeps any width the author declared; widening it as well measured the longest unwrapped row instead of the popup the author designed.
    public static let contentMeasureScript = """
    (function () {
      var root = document.documentElement, body = document.body;
      if (!root || !body) return "";
      var rootNames = ["width", "height", "min-height", "max-height", "overflow"];
      var bodyNames = ["min-height", "max-height", "overflow"];
      function save(element, names) {
        var saved = {};
        names.forEach(function (name) {
          saved[name] = [element.style.getPropertyValue(name), element.style.getPropertyPriority(name)];
        });
        return saved;
      }
      function restore(element, saved) {
        Object.keys(saved).forEach(function (name) {
          if (saved[name][0]) element.style.setProperty(name, saved[name][0], saved[name][1]);
          else element.style.removeProperty(name);
        });
      }
      var rootSaved = save(root, rootNames), bodySaved = save(body, bodyNames);
      var width = 0, height = 0;
      try {
        root.style.setProperty("width", "max-content", "important");
        root.style.setProperty("height", "max-content", "important");
        root.style.setProperty("min-height", "0", "important");
        root.style.setProperty("max-height", "none", "important");
        root.style.setProperty("overflow", "visible", "important");
        body.style.setProperty("min-height", "0", "important");
        body.style.setProperty("max-height", "none", "important");
        body.style.setProperty("overflow", "visible", "important");
        var style = getComputedStyle(body);
        var marginLeft = parseFloat(style.marginLeft) || 0;
        var marginTop = parseFloat(style.marginTop) || 0;
        var box = root.getBoundingClientRect();
        // scrollWidth/Height are measured from the body's padding edge, so only the leading margin is added.
        width = Math.ceil(Math.max(box.width, body.scrollWidth + marginLeft));
        height = Math.ceil(Math.max(box.height, body.scrollHeight + marginTop));
      } finally {
        restore(root, rootSaved);
        restore(body, bodySaved);
      }
      if (!(width > 0) || !(height > 0)) return "";
      return width + "x" + height;
    })()
    """

    public static func parseMeasuredSize(_ value: Any?) -> CGSize? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0, width.isFinite, height.isFinite
        else { return nil }
        return CGSize(width: width, height: height)
    }

    public static func measuredContentSize(in contents: any WebContents) async -> CGSize? {
        guard !contents.isClosed else { return nil }
        let value: Any?
        do {
            value = try await contents.evaluateJavaScript(contentMeasureScript)
        } catch {
            return nil
        }
        return parseMeasuredSize(value)
    }

    // MARK: - Icon fallback chain

    public enum ActionIconChoice: Equatable, Sendable {
        case actionIcon
        case extensionIcon
        case genericGlyph
    }

    public static func actionIconChoice(hasActionIcon: Bool, hasExtensionIcon: Bool) -> ActionIconChoice {
        if hasActionIcon { return .actionIcon }
        if hasExtensionIcon { return .extensionIcon }
        return .genericGlyph
    }

    public static func actionIconFileURL(extensionDirectory: URL, relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        return extensionDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - chrome.action state

    // nil when there is nothing to draw. Trimmed because a badge is drawn in a
    // fixed slot on the icon; Chrome clips at about the same width.
    public static func displayBadgeText(_ badgeText: String) -> String? {
        let trimmed = badgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(OrbitControlMetrics.extensionBadgeMaximumCharacters))
    }

    // chrome.action.setPopup overrides the manifest's default_popup (including
    // clearing it via ""); reduced here to the extension-relative path in force.
    // Orbit stores the path itself: WKWebExtension.Action has no popup URL, so
    // engineReportedPopupURL stays empty unless something else copied it.
    public static func effectiveActionPopupPath(
        extensionID: String,
        manifestPopupPath: String?,
        engineReportedPopupURL: String,
        popupOverride: String? = nil
    ) -> String? {
        if let popupOverride {
            return popupOverride.isEmpty ? nil : popupOverride
        }
        guard !engineReportedPopupURL.isEmpty else { return manifestPopupPath }
        guard let url = URL(string: engineReportedPopupURL),
              url.scheme == "chrome-extension",
              url.host == extensionID
        else { return manifestPopupPath }
        let path = String(url.path.drop(while: { $0 == "/" }))
        return path.isEmpty ? nil : path
    }
}
