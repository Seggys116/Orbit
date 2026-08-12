import SwiftUI

// Paints no background: the window paints one, and the crossfade is published via SpaceSwipeBlendKey.
struct SpaceSwitchingSidebarContainer: View {
    @Environment(AppEnvironment.self) private var env

    @State private var translation: CGFloat = 0
    @State private var isDragging = false

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private static let commitDistanceFraction: CGFloat = 0.3
    private static let commitVelocityFraction: CGFloat = 1.2

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            // env.pagerSpaces: must not reveal another window's persistent Space.
            let orderedSpaces = env.pagerSpaces
            let activeIndex = orderedSpaces.firstIndex(where: { $0.id == env.activeSpace?.id })

            ZStack(alignment: .leading) {
                if let activeIndex {
                    let displayTranslation = rubberBanded(
                        translation,
                        width: width,
                        canRevealPrevious: activeIndex > 0,
                        canRevealNext: activeIndex < orderedSpaces.count - 1
                    )

                    if isDragging, activeIndex > 0, displayTranslation > 0 {
                        panel(for: orderedSpaces[activeIndex - 1], width: width)
                            .offset(x: -width + displayTranslation)
                    }

                    if isDragging, activeIndex < orderedSpaces.count - 1, displayTranslation < 0 {
                        panel(for: orderedSpaces[activeIndex + 1], width: width)
                            .offset(x: width + displayTranslation)
                    }

                    currentPanel(orderedSpaces[activeIndex], width: width)
                        .offset(x: displayTranslation)
                } else {
                    SidebarView()
                }
            }
            .clipped()
            .background(
                gestureCatcher(width: width, height: geo.size.height, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
            )
            .environment(\.spaceSwipeProgress, SpaceSwipeProgress(fraction: translation / width, isDragging: isDragging))
            .preference(
                key: SpaceSwipeBlendKey.self,
                value: swipeBlend(width: width, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
            )
        }
    }

    // MARK: Gesture catcher

    @ViewBuilder
    private func gestureCatcher(width: CGFloat, height: CGFloat, orderedSpaces: [Space], activeIndex: Int?) -> some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            Color.clear.allowsHitTesting(false)
        } else {
            realGestureCatcher(width: width, height: height, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
        }
        #else
        realGestureCatcher(width: width, height: height, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
        #endif
    }

    private func realGestureCatcher(width: CGFloat, height: CGFloat, orderedSpaces: [Space], activeIndex: Int?) -> some View {
        SpaceSwipeGestureCatcher(
            onBegin: { isDragging = true },
            onChange: { newTranslation in translation = newTranslation },
            onEnd: { finalTranslation, velocity in
                handleGestureEnd(finalTranslation: finalTranslation, velocity: velocity, width: width, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
            }
        )
        .frame(width: width, height: height)
    }

    // MARK: Panels

    @ViewBuilder
    private func currentPanel(_ space: Space, width: CGFloat) -> some View {
        if isDragging {
            panel(for: space, width: width)
        } else {
            SidebarView()
        }
    }

    private func panel(for space: Space, width: CGFloat) -> some View {
        SpaceSidebarContent(space: space)
            .frame(width: width)
    }

    // MARK: Background crossfade (published upward, painted window-wide)

    // nil at rest lets the window fall back to ThemeBackgroundView.
    private func swipeBlend(width: CGFloat, orderedSpaces: [Space], activeIndex: Int?) -> SpaceSwipeBlend? {
        guard isDragging, let activeIndex, orderedSpaces.indices.contains(activeIndex) else { return nil }

        let currentSpace = orderedSpaces[activeIndex]
        var blend = SpaceSwipeBlend(
            currentTheme: currentSpace.theme,
            currentBlur: SpaceVisualPrefsStore.shared.blur(for: currentSpace.id)
        )

        let fraction = min(max(translation / width, -1), 1)
        if fraction > 0, activeIndex > 0 {
            let previousSpace = orderedSpaces[activeIndex - 1]
            blend.incomingTheme = previousSpace.theme
            blend.incomingBlur = SpaceVisualPrefsStore.shared.blur(for: previousSpace.id)
            blend.incomingWeight = Double(fraction)
        } else if fraction < 0, activeIndex < orderedSpaces.count - 1 {
            let nextSpace = orderedSpaces[activeIndex + 1]
            blend.incomingTheme = nextSpace.theme
            blend.incomingBlur = SpaceVisualPrefsStore.shared.blur(for: nextSpace.id)
            blend.incomingWeight = Double(-fraction)
        }

        return blend
    }

    // MARK: Gesture end

    private func handleGestureEnd(
        finalTranslation: CGFloat,
        velocity: CGFloat,
        width: CGFloat,
        orderedSpaces: [Space],
        activeIndex: Int?
    ) {
        guard let activeIndex else {
            isDragging = false
            translation = 0
            return
        }

        let distanceFraction = finalTranslation / width
        let velocityFraction = velocity / width

        // -1 = commit next, +1 = commit previous, 0 = spring back.
        var direction = 0
        if distanceFraction <= -Self.commitDistanceFraction || velocityFraction <= -Self.commitVelocityFraction {
            direction = -1
        } else if distanceFraction >= Self.commitDistanceFraction || velocityFraction >= Self.commitVelocityFraction {
            direction = 1
        }

        let destinationIndex = activeIndex - direction
        let canCommit = direction != 0 && orderedSpaces.indices.contains(destinationIndex)

        if canCommit {
            let destination = orderedSpaces[destinationIndex]
            let settleTarget: CGFloat = direction < 0 ? -width : width
            withAnimation(OrbitMotion.interactive, completionCriteria: .logicallyComplete) {
                translation = settleTarget
            } completion: {
                env.selectSpace(destination.id)
                translation = 0
                isDragging = false
            }
        } else {
            withAnimation(OrbitMotion.interactive, completionCriteria: .logicallyComplete) {
                translation = 0
            } completion: {
                isDragging = false
            }
        }
    }

    // MARK: Rubber banding

    private func rubberBanded(_ raw: CGFloat, width: CGFloat, canRevealPrevious: Bool, canRevealNext: Bool) -> CGFloat {
        func damp(_ overflow: CGFloat) -> CGFloat {
            let c: CGFloat = 0.55
            let d = width
            let sign: CGFloat = overflow < 0 ? -1 : 1
            let magnitude = abs(overflow)
            return sign * (magnitude * c * d) / (d + c * magnitude)
        }

        if raw > 0, !canRevealPrevious {
            return damp(raw)
        }
        if raw < 0, !canRevealNext {
            return damp(raw)
        }
        return raw
    }
}
