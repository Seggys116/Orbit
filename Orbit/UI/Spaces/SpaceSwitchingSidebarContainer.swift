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
            .modifier(
                SpaceSwipeBlendPublisher(
                    translation: translation,
                    width: width,
                    isDragging: isDragging,
                    current: blendStop(at: activeIndex, in: orderedSpaces),
                    previous: blendStop(at: activeIndex.map { $0 - 1 }, in: orderedSpaces),
                    next: blendStop(at: activeIndex.map { $0 + 1 }, in: orderedSpaces)
                )
            )
        }
    }


    // The Library owns horizontal scrolling (the Spaces section scrolls sideways), so the swipe between Spaces is off while it is open; the pager still switches.
    private var swipeIsSuppressed: Bool {
        #if DEBUG
        screenshotModeDragDisabled || env.isLibraryMode
        #else
        env.isLibraryMode
        #endif
    }

    // Nil under Reduce Motion so the settle snaps; its completion still runs.
    private static var settleAnimation: Animation? {
        OrbitMotion.resolved(OrbitMotion.interactive, reduceMotion: OrbitMotion.prefersReducedMotion)
    }

    @ViewBuilder
    private func gestureCatcher(width: CGFloat, height: CGFloat, orderedSpaces: [Space], activeIndex: Int?) -> some View {
        if swipeIsSuppressed {
            Color.clear.allowsHitTesting(false)
        } else {
            realGestureCatcher(width: width, height: height, orderedSpaces: orderedSpaces, activeIndex: activeIndex)
        }
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


    // nil outside a drag lets the window fall back to ThemeBackgroundView.
    private func blendStop(at index: Int?, in orderedSpaces: [Space]) -> SpaceSwipeBlend.Stop? {
        guard isDragging, let index, orderedSpaces.indices.contains(index) else { return nil }
        let space = orderedSpaces[index]
        return SpaceSwipeBlend.Stop(theme: space.theme, blur: SpaceVisualPrefsStore.shared.blur(for: space.id))
    }


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

        let destinationIndex = Self.commitDestinationIndex(
            finalTranslation: finalTranslation,
            velocity: velocity,
            width: width,
            activeIndex: activeIndex,
            spaceCount: orderedSpaces.count
        )

        if let destinationIndex {
            let destination = orderedSpaces[destinationIndex]
            let originID = orderedSpaces[activeIndex].id
            let settleTarget: CGFloat = destinationIndex > activeIndex ? -width : width
            withAnimation(Self.settleAnimation, completionCriteria: .logicallyComplete) {
                translation = settleTarget
            } completion: {
                // A click (e.g. on the bottom pager) made while this settle animation ran must win: only apply the swipe's destination if nothing else already moved the active Space.
                if Self.shouldApplySwipeDestination(activeSpaceIDAtCompletion: env.activeSpace?.id, originSpaceID: originID) {
                    env.selectSpace(destination.id, animated: false)
                }
                translation = 0
                isDragging = false
            }
        } else {
            withAnimation(Self.settleAnimation, completionCriteria: .logicallyComplete) {
                translation = 0
            } completion: {
                isDragging = false
            }
        }
    }


    /// -1 = commit next (index increases), +1 = commit previous (index decreases), 0 = spring back; `nil` covers both "spring back" and "no such neighbour Space".
    static func commitDestinationIndex(
        finalTranslation: CGFloat,
        velocity: CGFloat,
        width: CGFloat,
        activeIndex: Int,
        spaceCount: Int
    ) -> Int? {
        guard width > 0 else { return nil }
        let distanceFraction = finalTranslation / width
        let velocityFraction = velocity / width

        var direction = 0
        if distanceFraction <= -commitDistanceFraction || velocityFraction <= -commitVelocityFraction {
            direction = -1
        } else if distanceFraction >= commitDistanceFraction || velocityFraction >= commitVelocityFraction {
            direction = 1
        }
        guard direction != 0 else { return nil }

        let destinationIndex = activeIndex - direction
        guard (0..<spaceCount).contains(destinationIndex) else { return nil }
        return destinationIndex
    }

    static func shouldApplySwipeDestination(activeSpaceIDAtCompletion: SpaceID?, originSpaceID: SpaceID) -> Bool {
        activeSpaceIDAtCompletion == originSpaceID
    }


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
