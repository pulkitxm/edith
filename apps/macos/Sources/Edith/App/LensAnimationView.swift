import SwiftUI

struct LensEntranceView: View {
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var phase: Phase = .hidden

    private enum Phase { case hidden, worn, split }

    private let lens: CGFloat = 116
    private let gap: CGFloat = 22

    private var restOffset: CGFloat { (lens + gap) / 2 }
    private var flungOffset: CGFloat { restOffset + lens * 1.9 }

    private var leftOffset: CGFloat { phase == .split ? -flungOffset : -restOffset }
    private var rightOffset: CGFloat { phase == .split ? flungOffset : restOffset }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()
                .opacity(phase == .split ? 0 : 1)

            ZStack {
                Bridge(span: lens + gap)
                    .stroke(rimStyle, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: lens + gap, height: lens * 0.42)
                    .opacity(phase == .split ? 0 : 1)

                Lens(kind: .waveform, size: lens, scheme: scheme, teal: teal, rim: rimStyle)
                    .rotationEffect(.degrees(phase == .split ? -26 : 0))
                    .offset(x: leftOffset)
                    .opacity(phase == .split ? 0 : 1)

                Lens(kind: .chart, size: lens, scheme: scheme, teal: teal, rim: rimStyle)
                    .rotationEffect(.degrees(phase == .split ? 26 : 0))
                    .offset(x: rightOffset)
                    .opacity(phase == .split ? 0 : 1)
            }
            .scaleEffect(phase == .hidden ? 0.5 : 1)
            .opacity(phase == .hidden ? 0 : 1)
        }
        .allowsHitTesting(false)
        .onAppear(perform: run)
    }

    private var teal: Color { Color(red: 0.36, green: 0.90, blue: 0.82) }

    private var rimStyle: LinearGradient {
        LinearGradient(
            colors: [
                Color(white: scheme == .dark ? 0.82 : 0.92),
                Color(white: scheme == .dark ? 0.5 : 0.6),
                Color(white: scheme == .dark ? 0.7 : 0.82),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func run() {
        if reduceMotion {
            onComplete()
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) {
            phase = .worn
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.easeIn(duration: 0.42)) {
                phase = .split
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.06) {
            onComplete()
        }
    }
}

private struct Bridge: Shape {
    let span: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private struct Lens: View {
    enum Kind { case waveform, chart }

    let kind: Kind
    let size: CGFloat
    let scheme: ColorScheme
    let teal: Color
    let rim: LinearGradient

    private var glass: RadialGradient {
        RadialGradient(
            colors: [
                Color(red: 0.10, green: 0.24, blue: 0.28),
                Color(red: 0.05, green: 0.12, blue: 0.17),
            ],
            center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: size * 0.75)
    }

    var body: some View {
        ZStack {
            Circle().fill(glass)

            content
                .frame(width: size * 0.52, height: size * 0.42)
                .foregroundStyle(teal)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear],
                        startPoint: .topLeading, endPoint: .center)
                )
                .padding(size * 0.12)

            Circle().strokeBorder(rim, lineWidth: 7)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .waveform:
            HStack(spacing: 3) {
                ForEach(waveHeights.indices, id: \.self) { i in
                    Capsule().frame(height: size * waveHeights[i])
                }
            }
        case .chart:
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(barHeights.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: size * 0.06, height: size * barHeights[i])
                }
            }
        }
    }

    private var waveHeights: [CGFloat] {
        [0.12, 0.24, 0.16, 0.34, 0.22, 0.4, 0.18, 0.28, 0.14]
    }
    private var barHeights: [CGFloat] {
        [0.16, 0.26, 0.2, 0.34, 0.42]
    }
}
