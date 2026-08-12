//  DEBUG-only flag: ImageRenderer cannot snapshot a .draggable-decorated view or flatten an NSViewRepresentable, so screenshot/render tests disable both via this flag. Default false; real drag-and-drop and click-catching are unaffected.

#if DEBUG
import SwiftUI

private struct OrbitScreenshotModeDragDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var orbitScreenshotModeDragDisabled: Bool {
        get { self[OrbitScreenshotModeDragDisabledKey.self] }
        set { self[OrbitScreenshotModeDragDisabledKey.self] = newValue }
    }
}
#endif
