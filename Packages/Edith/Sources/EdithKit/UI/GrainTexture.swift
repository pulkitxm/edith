import SwiftUI

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

public struct PaperGrain: View {
    let dark: Bool
    let opacity: Double
    let seed: UInt64

    public init(dark: Bool, opacity: Double = 0.05, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.dark = dark
        self.opacity = opacity
        self.seed = seed
    }

    public var body: some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: seed)
            let speckColor = DashSkin.ink(dark)
            let density = (size.width * size.height) / 900
            let count = max(80, min(Int(density), 1400))
            for _ in 0..<count {
                let x = Double.random(in: 0...size.width, using: &rng)
                let y = Double.random(in: 0...size.height, using: &rng)
                let r = Double.random(in: 0.4...1.1, using: &rng)
                let a = Double.random(in: 0.3...1.0, using: &rng) * opacity
                context.opacity = a
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(speckColor))
            }
        }
        .allowsHitTesting(false)
        .blendMode(dark ? .plusLighter : .multiply)
    }
}

extension View {
    public func paperGrain(
        dark: Bool, opacity: Double = 0.05, in shape: some Shape = Rectangle()
    ) -> some View {
        overlay(PaperGrain(dark: dark, opacity: opacity).clipShape(shape))
    }
}
