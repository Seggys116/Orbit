// GENERATED FILE - DO NOT EDIT.
//
// Written by Scripts/chromium from Chromium/chromium-version.json.
// To change the Chromium version, edit that manifest (or run
// `Scripts/chromium pin <version>`) and re-run `Scripts/chromium sync`.

import Foundation

/// Facts about the Chromium build Orbit is compiled against.
///
/// Every value here comes from `Chromium/chromium-version.json`. Nothing in the
/// app hardcodes a Chromium version; read it from this type instead.
public enum ChromiumBuild {

    /// Full Chromium version, e.g. `151.0.7922.109`.
    public static let version = "152.0.7977.54"

    /// Chromium major version, e.g. `151`. This is what sites see.
    public static let majorVersion = 152

    /// Upstream release channel the pin was taken from.
    public static let channel = "stable"

    /// Date the version pin was last moved (ISO-8601).
    public static let pinnedAt = "2026-08-20"

    /// The user agent Orbit presents to websites, matching stock Chrome for this
    /// Chromium major so that sites serve Orbit their Chrome experience.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

    /// The product token used to build the default Chrome-style User-Agent string.
    public static let userAgentProduct = "Chrome/152.0.0.0"

    /// Short human-readable engine description for the About window, the
    /// General settings pane and the "About Orbit" command.
    public static let engineDescription = "Chromium \(version)"
}
