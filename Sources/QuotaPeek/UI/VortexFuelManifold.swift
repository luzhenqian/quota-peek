import SwiftUI
import Vortex

struct VortexFuelManifold: View {
    let remaining: Double
    let isRefreshing: Bool

    private let flow = VortexSystem(
        tags: ["fuel", "vapor"],
        position: [0, 0.5],
        shape: .box(width: 0, height: 0.34),
        birthRate: 34,
        emissionDuration: 1,
        idleDuration: 0,
        lifespan: 2.7,
        lifespanVariation: 0.45,
        speed: 0.42,
        speedVariation: 0.13,
        angle: .degrees(90),
        angleRange: .degrees(2.8),
        acceleration: [0.13, 0],
        dampingFactor: 0.06,
        colors: .randomRamp(
            [.clear, .cyan.opacity(0.58), .white, .cyan.opacity(0.2), .clear],
            [.clear, .blue.opacity(0.4), .cyan.opacity(0.78), .clear]
        ),
        size: 0.62,
        sizeVariation: 0.28,
        sizeMultiplierAtDeath: 0.42,
        stretchFactor: 7,
        startTimeOffset: 1.6
    )

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.52))

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.14), .cyan.opacity(0.22), .blue.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            VortexView(flow, targetFrameRate: 60) {
                Capsule()
                    .fill(.white)
                    .frame(width: 9, height: 2.2)
                    .blendMode(.plusLighter)
                    .tag("fuel")

                Capsule()
                    .fill(.white)
                    .blur(radius: 1.2)
                    .frame(width: 5, height: 1.4)
                    .blendMode(.plusLighter)
                    .tag("vapor")
            }
            .opacity(flowOpacity)
        }
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(.cyan.opacity(isRefreshing ? 0.34 : 0.16), lineWidth: 0.65)
        }
        .allowsHitTesting(false)
    }

    private var flowOpacity: Double {
        let pressure = max(0, min(100, remaining)) / 100
        return (isRefreshing ? 0.92 : 0.68) + pressure * 0.08
    }
}
