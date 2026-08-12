import SwiftUI

struct SpaceSwipeProgress: Equatable {
    // -1...1, negative revealing next, positive previous, 0 at rest.
    var fraction: CGFloat = 0
    var isDragging: Bool = false
}

private struct SpaceSwipeProgressKey: EnvironmentKey {
    static let defaultValue = SpaceSwipeProgress()
}

extension EnvironmentValues {
    var spaceSwipeProgress: SpaceSwipeProgress {
        get { self[SpaceSwipeProgressKey.self] }
        set { self[SpaceSwipeProgressKey.self] = newValue }
    }
}

// nil means no drag in progress.
struct SpaceSwipeBlend: Equatable, Sendable {
    var currentTheme: SpaceTheme
    var currentBlur: Double
    var incomingTheme: SpaceTheme?
    var incomingBlur: Double = 0
    var incomingWeight: Double = 0
}

struct SpaceSwipeBlendKey: PreferenceKey {
    static let defaultValue: SpaceSwipeBlend? = nil

    // Last non-nil wins; only one container is ever mounted per window.
    static func reduce(value: inout SpaceSwipeBlend?, nextValue: () -> SpaceSwipeBlend?) {
        if let next = nextValue() {
            value = next
        }
    }
}
