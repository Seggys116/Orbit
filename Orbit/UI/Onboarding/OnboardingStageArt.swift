import SwiftUI

// MARK: - Panel

struct OnboardingStageArt: View {
    var step: OnboardingStep

    var body: some View {
        ZStack {
            if step == .profileSetup {
                ExampleSpacesScene()
            } else {
                SpaceBackdrop()
                    .overlay {
                        Image(planet.asset)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: planet.frame, height: planet.frame)
                    }
            }
        }
        .clipped()
    }

    private var planet: (asset: String, frame: CGFloat) {
        switch step {
        case .welcome, .profileSetup: ("OnboardingPlanet", 162)
        case .importBrowser: ("OnboardingPlanetViolet", 260)
        case .searchEngine: ("OnboardingPlanetAmber", 260)
        case .defaultBrowser: ("OnboardingPlanet", 162)
        }
    }
}

// MARK: - Backdrop

private struct SpaceBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.024, green: 0.027, blue: 0.055),
                        Color(red: 0.047, green: 0.027, blue: 0.070),
                        Color(red: 0.016, green: 0.016, blue: 0.031),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                NebulaCloud(
                    hue: Color(red: 0.55, green: 0.32, blue: 0.92),
                    size: CGSize(width: 620, height: 300),
                    anchor: CGSize(width: -110, height: -170),
                    rotation: -24,
                    blur: 58,
                    opacity: 0.26
                )
            }
            .overlay {
                NebulaCloud(
                    hue: Color(red: 0.95, green: 0.45, blue: 0.30),
                    size: CGSize(width: 520, height: 250),
                    anchor: CGSize(width: 150, height: 230),
                    rotation: 22,
                    blur: 66,
                    opacity: 0.15
                )
            }
            .overlay {
                NebulaCloud(
                    hue: Color(red: 0.92, green: 0.34, blue: 0.62),
                    size: CGSize(width: 300, height: 170),
                    anchor: CGSize(width: 140, height: -40),
                    rotation: -8,
                    blur: 54,
                    opacity: 0.16
                )
            }
            .overlay { Starfield() }
            .overlay {
                RadialGradient(
                    colors: [.clear, .black.opacity(0.30), .black.opacity(0.72)],
                    center: .center,
                    startRadius: 90,
                    endRadius: 400
                )
                .blendMode(.multiply)
            }
            .overlay { GrainOverlay(opacity: 0.62, isDarkSurface: true) }
            // Without its own group, the screen/multiply blend modes above would blend against whatever sits behind the panel.
            .compositingGroup()
    }
}

private struct NebulaCloud: View {
    var hue: Color
    var size: CGSize
    var anchor: CGSize
    var rotation: Double
    var blur: CGFloat
    var opacity: Double

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [hue, hue.opacity(0.55), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size.width / 2
                )
            )
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(rotation))
            .blur(radius: blur)
            .opacity(opacity)
            .blendMode(.screen)
            .offset(x: anchor.width, y: anchor.height)
            .allowsHitTesting(false)
    }
}

private struct Starfield: View {
    private struct Star {
        var position: CGPoint
        var radius: CGFloat
        var opacity: Double
        var isBright: Bool
    }

    // Fixed seed so the sky is identical across stages and redraws.
    private static let stars: [Star] = {
        var generator = SeededGenerator(seed: 0x0B17_5EED_0F13_1D01)
        return (0..<260).map { index in
            let bright = index % 32 == 0
            return Star(
                position: CGPoint(
                    x: CGFloat.random(in: 0...1, using: &generator),
                    y: CGFloat.random(in: 0...1, using: &generator)
                ),
                radius: bright
                    ? CGFloat.random(in: 1.1...1.7, using: &generator)
                    : CGFloat.random(in: 0.35...1.05, using: &generator),
                opacity: bright
                    ? Double.random(in: 0.75...1.0, using: &generator)
                    : Double.random(in: 0.16...0.72, using: &generator),
                isBright: bright
            )
        }
    }()

    var body: some View {
        Canvas { context, size in
            for star in Starfield.stars {
                let center = CGPoint(x: star.position.x * size.width, y: star.position.y * size.height)

                if star.isBright {
                    let halo = CGRect(
                        x: center.x - star.radius * 3.4,
                        y: center.y - star.radius * 3.4,
                        width: star.radius * 6.8,
                        height: star.radius * 6.8
                    )
                    context.fill(
                        Path(ellipseIn: halo),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.16), .clear]),
                            center: center,
                            startRadius: 0,
                            endRadius: star.radius * 3.4
                        )
                    )
                }

                let dot = CGRect(
                    x: center.x - star.radius,
                    y: center.y - star.radius,
                    width: star.radius * 2,
                    height: star.radius * 2
                )
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(star.opacity)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Spaces stage

private struct ExampleSpacesScene: View {
    private static let examples: [(name: String, icon: String, theme: SpaceTheme)] = [
        ("Art & Inspiration", "paintpalette.fill", SpaceTheme(style: .mesh, colors: [
            ThemeColor(red: 0.20, green: 0.62, blue: 0.42), ThemeColor(red: 0.55, green: 0.78, blue: 0.35), ThemeColor(red: 0.85, green: 0.90, blue: 0.45),
        ], grain: 0.4)),
        ("Travel Planning", "airplane", SpaceTheme(style: .mesh, colors: [
            ThemeColor(red: 0.98, green: 0.55, blue: 0.42), ThemeColor(red: 0.95, green: 0.72, blue: 0.45), ThemeColor(red: 0.98, green: 0.42, blue: 0.55),
        ], grain: 0.4)),
        ("Deep Work", "briefcase.fill", SpaceTheme(style: .mesh, colors: [
            ThemeColor(red: 0.30, green: 0.32, blue: 0.85), ThemeColor(red: 0.45, green: 0.35, blue: 0.80), ThemeColor(red: 0.65, green: 0.45, blue: 0.90),
        ], grain: 0.35)),
    ]

    @State private var index = 0

    var body: some View {
        let example = ExampleSpacesScene.examples[index]
        ZStack {
            ThemeBackgroundView(theme: example.theme)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: example.icon).foregroundStyle(.white)
                    Text(example.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Spacer().frame(height: 40)
            }
        }
        .task { await rotate() }
    }

    private func rotate() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(OrbitMotion.dramatic) {
                index = (index + 1) % ExampleSpacesScene.examples.count
            }
        }
    }
}
