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

extension SpaceSwipeBlend {
    struct Stop: Equatable, Sendable {
        var theme: SpaceTheme
        var blur: Double
    }

    static func make(
        translation: CGFloat,
        width: CGFloat,
        isDragging: Bool,
        current: Stop?,
        previous: Stop?,
        next: Stop?
    ) -> SpaceSwipeBlend? {
        guard isDragging, width > 0, let current else { return nil }

        var blend = SpaceSwipeBlend(currentTheme: current.theme, currentBlur: current.blur)
        let fraction = min(max(translation / width, -1), 1)
        if fraction > 0, let previous {
            blend.incomingTheme = previous.theme
            blend.incomingBlur = previous.blur
            blend.incomingWeight = Double(fraction)
        } else if fraction < 0, let next {
            blend.incomingTheme = next.theme
            blend.incomingBlur = next.blur
            blend.incomingWeight = Double(-fraction)
        }
        return blend
    }
}

// Animatable because SwiftUI does not interpolate preference values; the blend must follow the sliding panel.
struct SpaceSwipeBlendPublisher: ViewModifier, Animatable {
    var translation: CGFloat
    var width: CGFloat
    var isDragging: Bool
    var current: SpaceSwipeBlend.Stop?
    var previous: SpaceSwipeBlend.Stop?
    var next: SpaceSwipeBlend.Stop?

    var animatableData: CGFloat {
        get { translation }
        set { translation = newValue }
    }

    var blend: SpaceSwipeBlend? {
        SpaceSwipeBlend.make(
            translation: translation,
            width: width,
            isDragging: isDragging,
            current: current,
            previous: previous,
            next: next
        )
    }

    func body(content: Content) -> some View {
        content.preference(key: SpaceSwipeBlendKey.self, value: blend)
    }
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
