import AppKit
import UniformTypeIdentifiers
import WebKit

enum OrbitConsoleExport {
    @MainActor
    static func savePanel(text: String) {
        let panel = NSSavePanel()
        panel.title = "Save Console Log"
        panel.nameFieldStringValue = "console.log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
