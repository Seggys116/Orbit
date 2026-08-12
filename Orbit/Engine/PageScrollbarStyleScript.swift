import Foundation

enum PageScrollbarStyleScript {

    static let scriptID = UUID(uuidString: "5C401BA0-0000-4000-8000-5C0117BA0001")!

    /// Load-bearing: `ChromiumScrollbarLiveTests` finds this by its text.
    static let marker = "orbit-scrollbar"

    static let css = """
    /* \(marker): Orbit's page scrollbar. Orbit/Engine/PageScrollbarStyleScript.swift */
    ::-webkit-scrollbar {
      width: 9px;
      height: 9px;
      background: transparent;
    }
    ::-webkit-scrollbar-track,
    ::-webkit-scrollbar-track-piece,
    ::-webkit-scrollbar-corner {
      background: transparent;
    }
    ::-webkit-scrollbar-button {
      display: none;
      width: 0;
      height: 0;
    }
    ::-webkit-scrollbar-thumb {
      border: 2px solid transparent;
      background-clip: padding-box;
      border-radius: 5px;
      background-color: rgba(128, 128, 128, 0.45);
      background-color: color-mix(in srgb, currentColor 38%, transparent);
    }
    ::-webkit-scrollbar-thumb:hover {
      background-color: rgba(128, 128, 128, 0.7);
      background-color: color-mix(in srgb, currentColor 58%, transparent);
    }
    """

    /// `allFrames: true`: an iframe's own scrollbar is a real scrollbar too.
    static var userScript: UserScript {
        UserScript(
            id: scriptID,
            kind: .stylesheet,
            source: css,
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"],
            allFrames: true
        )
    }
}
