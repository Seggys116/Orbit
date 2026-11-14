
import AppKit
import Foundation


extension OrbitElementsModel {
    /// Cookies and credentials are not sent, so CSS served behind authentication fails silently.
    func makeEditable(href: String) {
        guard let url = URL(string: href) else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("text/css,*/*;q=0.1", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil,
                      let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                else {
                    self.session?.notice = "Couldn't fetch \(url.lastPathComponent) — check the console for details."
                    return
                }
                self.session?.command(["op": "el.injectCSS", "href": href, "content": content])
                if let id = self.selectedID {
                    self.session?.command(["op": "el.style", "id": id])
                }
            }
        }.resume()
    }
}


let commonCSSProperties: [String] = [
    "align-content", "align-items", "align-self", "all", "animation", "animation-delay",
    "animation-direction", "animation-duration", "animation-fill-mode",
    "animation-iteration-count", "animation-name", "animation-play-state",
    "animation-timing-function", "appearance", "aspect-ratio",
    "backdrop-filter", "backface-visibility", "background", "background-attachment",
    "background-blend-mode", "background-clip", "background-color", "background-image",
    "background-origin", "background-position", "background-repeat", "background-size",
    "border", "border-bottom", "border-bottom-color", "border-bottom-left-radius",
    "border-bottom-right-radius", "border-bottom-style", "border-bottom-width",
    "border-collapse", "border-color", "border-image", "border-left", "border-left-color",
    "border-left-style", "border-left-width", "border-radius", "border-right",
    "border-right-color", "border-right-style", "border-right-width", "border-spacing",
    "border-style", "border-top", "border-top-color", "border-top-left-radius",
    "border-top-right-radius", "border-top-style", "border-top-width", "border-width",
    "bottom", "box-shadow", "box-sizing",
    "caption-side", "clear", "clip-path", "color", "column-count", "column-gap",
    "column-rule", "column-width", "columns", "contain", "content",
    "counter-increment", "counter-reset", "cursor",
    "direction", "display",
    "empty-cells",
    "filter", "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow",
    "flex-shrink", "flex-wrap", "float", "font", "font-family", "font-feature-settings",
    "font-kerning", "font-size", "font-size-adjust", "font-stretch", "font-style",
    "font-variant", "font-variant-caps", "font-weight",
    "gap", "grid", "grid-area", "grid-auto-columns", "grid-auto-flow", "grid-auto-rows",
    "grid-column", "grid-column-end", "grid-column-gap", "grid-column-start",
    "grid-row", "grid-row-end", "grid-row-gap", "grid-row-start", "grid-template",
    "grid-template-areas", "grid-template-columns", "grid-template-rows",
    "height",
    "image-rendering", "inset",
    "isolation",
    "justify-content", "justify-items", "justify-self",
    "left", "letter-spacing", "line-height", "list-style", "list-style-image",
    "list-style-position", "list-style-type",
    "margin", "margin-bottom", "margin-left", "margin-right", "margin-top",
    "max-height", "max-width", "min-height", "min-width", "mix-blend-mode",
    "object-fit", "object-position", "opacity", "order", "orphans", "outline",
    "outline-color", "outline-offset", "outline-style", "outline-width", "overflow",
    "overflow-x", "overflow-y",
    "padding", "padding-bottom", "padding-left", "padding-right", "padding-top",
    "perspective", "perspective-origin", "place-content", "place-items", "place-self",
    "pointer-events", "position",
    "quotes",
    "resize", "right", "rotate", "row-gap",
    "scale", "scroll-behavior", "scroll-margin", "scroll-padding", "scroll-snap-align",
    "scroll-snap-type",
    "tab-size", "table-layout", "text-align", "text-align-last", "text-decoration",
    "text-decoration-color", "text-decoration-line", "text-decoration-style",
    "text-decoration-thickness", "text-indent", "text-justify", "text-overflow",
    "text-shadow", "text-transform", "text-underline-offset", "top", "transform",
    "transform-origin", "transform-style", "transition", "transition-delay",
    "transition-duration", "transition-property", "transition-timing-function", "translate",
    "user-select",
    "vertical-align", "visibility",
    "white-space", "widows", "width", "will-change", "word-break", "word-spacing",
    "word-wrap", "writing-mode",
    "z-index",
]
