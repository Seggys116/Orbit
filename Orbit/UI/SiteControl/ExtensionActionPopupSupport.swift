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

    // Shown only until the renderer reports its first preferred size: opening at popupDefaultSize instead would flash a tall empty box for every popup smaller than it, which is most of them.
    public static let popupLoadingSize = CGSize(width: 200, height: 112)

    // Every Orbit-drawn state of an extension popup (load failure, pending activation) shares this width so they read as one surface.
    public static let popupMessageWidth: CGFloat = 260

    public static func clampedPopupSize(_ proposed: CGSize?) -> CGSize {
        guard let proposed else { return popupDefaultSize }
        let width = min(max(proposed.width, popupMinimumSize.width), popupMaximumSize.width)
        let height = min(max(proposed.height, popupMinimumSize.height), popupMaximumSize.height)
        return CGSize(width: width, height: height)
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
    public static func effectiveActionPopupPath(
        extensionID: String,
        manifestPopupPath: String?,
        engineReportedPopupURL: String
    ) -> String? {
        guard !engineReportedPopupURL.isEmpty else { return manifestPopupPath }
        guard let url = URL(string: engineReportedPopupURL),
              url.scheme == "chrome-extension",
              url.host == extensionID
        else { return manifestPopupPath }
        let path = String(url.path.drop(while: { $0 == "/" }))
        return path.isEmpty ? nil : path
    }
}
