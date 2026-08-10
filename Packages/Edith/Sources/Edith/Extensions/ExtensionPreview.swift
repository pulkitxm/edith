import EdithKit
import SwiftUI

struct ExtensionPreview: View {
    let entry: ExtensionRegistryEntry
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            preview(phase: reduceMotion ? 1.1 : context.date.timeIntervalSinceReferenceDate)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func preview(phase: Double) -> some View {
        switch entry.id {
        case "usage": usagePreview(phase: phase)
        case "system": systemPreview(phase: phase)
        case "machines": machinesPreview(phase: phase)
        case "systemStats": systemStatsPreview(phase: phase)
        case "micMute": micMutePreview(phase: phase)
        case "calendar": calendarPreview(phase: phase)
        case "notchShelf": notchPreview(phase: phase)
        case "clipboard": clipboardPreview(phase: phase)
        case "music": musicPreview
        case "focusDim": focusDimPreview(phase: phase)
        case "presenter": presenterPreview(phase: phase)
        case "colorPicker": colorPickerPreview(phase: phase)
        default: staticPreview
        }
    }

    private func usagePreview(phase: Double) -> some View {
        let fill = CGFloat(0.48 + sin(phase * 1.7) * 0.2)
        return VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                Text("SESSION")
                    .font(DashSkin.mono(7, weight: .semibold))
                Spacer()
                Text("\(Int(fill * 100))%")
                    .font(DashSkin.mono(8, weight: .medium))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashSkin.lineStrong(dark))
                    Capsule()
                        .fill(brandAccent)
                        .frame(width: max(10, proxy.size.width * fill))
                }
            }
            .frame(height: UIScale.pt(7))
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(15))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func systemPreview(phase: Double) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            ForEach(Array(["⌘", "⌥", "E", "⏎"].enumerated()), id: \.offset) { index, key in
                let press = CGFloat(max(0, sin(phase * 2.2 - Double(index) * 0.7)))
                Text(key)
                    .font(.system(size: UIScale.pt(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(DashSkin.ink(dark))
                    .frame(width: UIScale.pt(28), height: UIScale.pt(25))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(6)).strokeBorder(
                            DashSkin.lineStrong(dark))
                    }
                    .shadow(color: .black.opacity(0.1), radius: UIScale.pt(0), y: 2 - press * 2)
                    .offset(y: press * 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func machinesPreview(phase: Double) -> some View {
        let pulse = CGFloat(max(0, sin(phase * 2.1)))
        let bars = (0..<4).map { index in
            CGFloat(0.32 + (sin(phase * 1.5 + Double(index) * 0.8) + 1) * 0.28)
        }
        return HStack(spacing: UIScale.pt(12)) {
            VStack(spacing: UIScale.pt(3)) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: UIScale.pt(15)))
                Text("MAC")
                    .font(DashSkin.mono(6, weight: .semibold))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))

            HStack(spacing: UIScale.pt(3)) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(brandAccent.opacity(index == Int(phase * 2) % 3 ? 1 : 0.25))
                        .frame(width: UIScale.pt(3), height: UIScale.pt(3))
                }
            }

            VStack(spacing: UIScale.pt(4)) {
                HStack(spacing: UIScale.pt(4)) {
                    Circle()
                        .fill(DashSkin.sage.opacity(0.55 + pulse * 0.45))
                        .frame(width: UIScale.pt(4), height: UIScale.pt(4))
                    Text("LINUX")
                        .font(DashSkin.mono(6, weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                HStack(alignment: .bottom, spacing: UIScale.pt(2.5)) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(brandAccent.opacity(0.85))
                            .frame(width: UIScale.pt(3.5), height: UIScale.pt(20) * height)
                    }
                }
                .frame(height: UIScale.pt(20), alignment: .bottom)
            }
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(7))
            .background(
                DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(DashSkin.lineStrong(dark))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func systemStatsPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.2)
        let percentages = [38, 47, 62, 54]
        let percentageIndex = min(Int(progress * Double(percentages.count)), percentages.count - 1)
        let percentage = percentages[percentageIndex]
        return HStack(spacing: UIScale.pt(10)) {
            Text("CPU")
                .font(DashSkin.mono(7, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text("\(percentage)%")
                .font(DashSkin.mono(10, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.28), value: percentage)
            HStack(alignment: .bottom, spacing: UIScale.pt(3)) {
                ForEach(0..<6) { index in
                    let wave = sin(
                        phase * Double.pi * 2 / 3.2 + Double(index) * 1.13)
                    Capsule()
                        .fill(index > 3 ? brandAccent.opacity(0.72) : brandAccent)
                        .frame(
                            width: UIScale.pt(4), height: UIScale.pt(7) + CGFloat((wave + 1) * 7.5))
                }
            }
            .frame(height: UIScale.pt(23), alignment: .bottom)
        }
        .padding(.horizontal, UIScale.pt(13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func micMutePreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.2)
        let slashEntry = smoothed(clamped((progress - 0.25) / 0.14))
        let slashExit = smoothed(clamped((progress - 0.68) / 0.14))
        let slashVisibility = slashEntry * (1 - slashExit)
        let barStrength = 1 - slashEntry + slashExit
        return ZStack {
            HStack(spacing: UIScale.pt(13)) {
                Image(systemName: "mic.fill")
                    .font(.system(size: UIScale.pt(24), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                HStack(alignment: .center, spacing: UIScale.pt(4)) {
                    ForEach(0..<3) { index in
                        let wave = (sin(phase * 4.4 + Double(index) * 1.7) + 1) / 2
                        let fullHeight = CGFloat(10 + index * 5) + CGFloat(wave * 7)
                        Capsule()
                            .fill(brandAccent.opacity(0.72 + Double(index) * 0.12))
                            .frame(
                                width: UIScale.pt(4),
                                height: max(3, fullHeight * CGFloat(barStrength)))
                    }
                }
                .frame(height: UIScale.pt(29))
            }
            Capsule()
                .fill(brandAccent)
                .frame(width: UIScale.pt(70), height: UIScale.pt(3))
                .scaleEffect(x: CGFloat(slashEntry), anchor: .leading)
                .rotationEffect(.degrees(-32))
                .offset(y: CGFloat(-slashExit * 13))
                .opacity(slashVisibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func calendarPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.2)
        let palette = [
            Color(red: 0.82, green: 0.45, blue: 0.38),
            Color(red: 0.82, green: 0.65, blue: 0.31),
            Color(red: 0.42, green: 0.62, blue: 0.48),
            Color(red: 0.43, green: 0.55, blue: 0.76),
        ]
        let resetOpacity = 1 - smoothed(clamped((progress - 0.84) / 0.12))
        return HStack(alignment: .bottom, spacing: UIScale.pt(7)) {
            ForEach(0..<4) { index in
                let start = 0.08 + Double(index) * 0.11
                let rise = smoothed(clamped((progress - start) / 0.28))
                RoundedRectangle(cornerRadius: UIScale.pt(4), style: .continuous)
                    .fill(palette[index].opacity(dark ? 0.78 : 0.68))
                    .frame(width: UIScale.pt(16), height: CGFloat(25 + index * 5))
                    .offset(y: CGFloat((1 - rise) * 25))
                    .opacity(rise * resetOpacity)
            }
        }
        .padding(.bottom, UIScale.pt(7))
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(DashSkin.lineStrong(dark))
                .frame(width: UIScale.pt(94), height: UIScale.pt(2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notchPreview(phase: Double) -> some View {
        let pulse = CGFloat((sin(phase * 1.8) + 1) / 2)
        return VStack(spacing: UIScale.pt(0)) {
            BottomRoundedRectangle(radius: UIScale.pt(12))
                .fill(Color.black)
                .frame(width: UIScale.pt(80) + pulse * 44, height: UIScale.pt(20) + pulse * 13)
            Spacer(minLength: 0)
            HStack(spacing: UIScale.pt(5)) {
                Circle().fill(brandAccent).frame(width: UIScale.pt(5), height: UIScale.pt(5))
                Capsule().fill(DashSkin.lineStrong(dark)).frame(
                    width: UIScale.pt(38), height: UIScale.pt(4))
            }
        }
        .padding(.top, UIScale.pt(1))
        .padding(.bottom, UIScale.pt(7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clipboardPreview(phase: Double) -> some View {
        VStack(spacing: UIScale.pt(4)) {
            ForEach(0..<3) { index in
                let progress = (sin(phase * 1.8 - Double(index) * 0.8) + 1) / 2
                HStack(spacing: UIScale.pt(7)) {
                    RoundedRectangle(cornerRadius: UIScale.pt(2))
                        .fill(brandAccent.opacity(0.55 + Double(index) * 0.12))
                        .frame(width: UIScale.pt(8), height: UIScale.pt(8))
                    Capsule()
                        .fill(DashSkin.inkFaint(dark).opacity(0.48))
                        .frame(width: CGFloat(44 + index * 14), height: UIScale.pt(4))
                    Spacer(minLength: 0)
                }
                .offset(x: -8 + progress * 8)
                .opacity(0.5 + progress * 0.5)
            }
        }
        .padding(.horizontal, UIScale.pt(25))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var musicPreview: some View {
        HStack(spacing: UIScale.pt(13)) {
            PlaybackWave(
                playing: !reduceMotion, color: brandAccent, barCount: 7, maxHeight: UIScale.pt(28))
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Capsule().fill(DashSkin.inkSoft(dark).opacity(0.65)).frame(
                    width: UIScale.pt(62), height: UIScale.pt(5))
                Capsule().fill(DashSkin.inkFaint(dark).opacity(0.42)).frame(
                    width: UIScale.pt(43), height: UIScale.pt(4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func focusDimPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3)
        let backOpacity = 0.625 + cos(progress * Double.pi * 2) * 0.375
        return ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(DashSkin.paper2(dark))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                        .strokeBorder(DashSkin.lineStrong(dark))
                }
                .frame(width: UIScale.pt(76), height: UIScale.pt(39))
                .offset(x: -15, y: -7)
                .opacity(backOpacity)
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(DashSkin.paper(dark))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                        .strokeBorder(brandAccent.opacity(0.5), lineWidth: UIScale.pt(1.5))
                }
                .frame(width: UIScale.pt(76), height: UIScale.pt(39))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: UIScale.pt(4)) {
                        Circle().fill(brandAccent).frame(
                            width: UIScale.pt(5), height: UIScale.pt(5))
                        Capsule().fill(DashSkin.inkFaint(dark)).frame(
                            width: UIScale.pt(24), height: UIScale.pt(4))
                    }
                    .padding(UIScale.pt(8))
                }
                .offset(x: 15, y: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presenterPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.2)
        let travel = smoothed(clamped((progress - 0.15) / 0.53))
        let bandVisible = progress >= 0.15 && progress <= 0.68
        let bandOpacity = bandVisible ? sin(travel * Double.pi) : 0
        return ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(DashSkin.paper2(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Capsule()
                    .fill(DashSkin.inkSoft(dark).opacity(0.68))
                    .frame(width: UIScale.pt(64), height: UIScale.pt(4))
                Capsule()
                    .fill(brandAccent.opacity(0.76))
                    .frame(width: UIScale.pt(76), height: UIScale.pt(5))
                Capsule()
                    .fill(DashSkin.inkFaint(dark).opacity(0.52))
                    .frame(width: UIScale.pt(50), height: UIScale.pt(4))
            }
            Capsule()
                .fill(DashSkin.paper(dark).opacity(0.92))
                .frame(width: UIScale.pt(30), height: UIScale.pt(11))
                .blur(radius: UIScale.pt(3.5))
                .offset(x: CGFloat(-48 + travel * 96))
                .opacity(bandOpacity)
        }
        .frame(width: UIScale.pt(108), height: UIScale.pt(48))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .strokeBorder(DashSkin.lineStrong(dark))
        }
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colorPickerPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.4)
        let travel = smoothed(1 - abs(progress * 2 - 1))
        let loupeColor = interpolatedPreviewColor(at: travel)
        return ZStack {
            LinearGradient(
                colors: previewColorStops.map(\.color), startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: UIScale.pt(112), height: UIScale.pt(14))
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(DashSkin.lineStrong(dark))
            }
            Circle()
                .fill(loupeColor)
                .frame(width: UIScale.pt(21), height: UIScale.pt(21))
                .overlay {
                    Circle().strokeBorder(DashSkin.paper(dark), lineWidth: UIScale.pt(3))
                }
                .shadow(color: .black.opacity(dark ? 0.32 : 0.16), radius: UIScale.pt(3), y: 1)
                .offset(x: CGFloat(-49 + travel * 98), y: -7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loopProgress(_ phase: Double, duration: Double) -> Double {
        phase.truncatingRemainder(dividingBy: duration) / duration
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func smoothed(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private func interpolatedPreviewColor(at progress: Double) -> Color {
        let scaled = progress * Double(previewColorStops.count - 1)
        let lowerIndex = min(Int(scaled), previewColorStops.count - 2)
        let upperIndex = lowerIndex + 1
        let amount = scaled - Double(lowerIndex)
        let lower = previewColorStops[lowerIndex]
        let upper = previewColorStops[upperIndex]
        return Color(
            red: lower.red + (upper.red - lower.red) * amount,
            green: lower.green + (upper.green - lower.green) * amount,
            blue: lower.blue + (upper.blue - lower.blue) * amount)
    }

    private var staticPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
                .fill(brandAccent.opacity(0.1))
            RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
                .strokeBorder(brandAccent.opacity(0.18))
            Image(systemName: entry.symbolName)
                .font(.system(size: UIScale.pt(22), weight: .semibold))
                .foregroundStyle(brandAccent)
        }
        .frame(width: UIScale.pt(46), height: UIScale.pt(42))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewColorStop {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

private let previewColorStops = [
    PreviewColorStop(red: 0.82, green: 0.24, blue: 0.28),
    PreviewColorStop(red: 0.94, green: 0.65, blue: 0.23),
    PreviewColorStop(red: 0.43, green: 0.62, blue: 0.44),
    PreviewColorStop(red: 0.29, green: 0.52, blue: 0.82),
    PreviewColorStop(red: 0.58, green: 0.34, blue: 0.76),
]

private struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let cornerRadius = min(radius, min(rect.width / 2, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
